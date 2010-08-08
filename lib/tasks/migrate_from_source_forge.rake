# -*- coding: utf-8 -*-
# redmine_source_forge_migrate - migrate to redmine from source forge
# Copyright (C) 2010  Nick Bolton
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  
# 02110-1301, USA

require 'active_record'

namespace :redmine do
  desc 'Source Forge migration script'
  task :migrate_from_source_forge => :environment do
    
    class SourceForgeMigrate < XmlImporter
      
      require 'rexml/document'
      include REXML

      def initialize
        super
        
        # make source forge id unique so we can import from other sites
        @id_format = 'sf-%s'
      end

      def migrate(filename, project)
        @project = Project.find(project)
        
        # load uploaded xml in to rexml document
        puts 'reading: ' + filename
        file = File.new(filename, 'r')
        doc = Document.new(file.read)
        
        puts 'importing issues...'
        XPath.each(doc, '/project_export/artifacts/artifact') { |el|
          legacy_id = @id_format % get_field(el, 'artifact_id')

          author = get_field(el, 'submitted_by')
          author = 'Unknown' if not author
          sf_user = '@SourceForge user: ' + author + "@\n\n"
          status = get_field(el, 'status')
          resolution = get_field(el, 'resolution')
          
          puts 'issue: ' + legacy_id
          issue = find_or_new_issue(legacy_id)
          
          issue.project = @project
          issue.author = User.anonymous
          issue.tracker = find_tracker(get_field(el, 'artifact_type'))
          issue.created_on = parse_date(get_field(el, 'open_date'))
          issue.subject = get_field(el, 'summary')
          issue.status = find_status(status, resolution)
          issue.priority = find_priority(Integer(get_field(el, 'priority')))
          issue.description = sf_user + get_field(el, 'details')
          issue.save_with_validation!()
          
          # set custom values after saving
          set_custom_value(issue, 'Legacy ID', legacy_id)
          set_custom_value(issue, 'Found in version', 
                           get_version(get_field(el, 'artifact_group_id')))
          
          reset_journal(issue.id)
          messages_xpath = 'field[@name="artifact_messages"]/message'
          messages = el.elements.to_a(messages_xpath)
          history_xpath = 'field[@name="artifact_history"]/message'
          history = el.elements.to_a(history_xpath)
          create_journal(issue, messages, history)
          
          # save as struct so we have both issue and xml element
          ip = Struct.new(:issue, :el).new
          ip.issue = issue
          ip.el = el
          @issue_cache[legacy_id] = ip
        }
        puts 'done'
        
        puts 'imported ' + String(@issue_cache.length) + ' issues'
      end

      def get_version(sf_group_id)
        if sf_group_id == 'None'
          return nil
        else
          # remove v from front of version number
          return sf_group_id.sub(/^v/, '')
        end
      end

      def find_status(sf_status, sf_res)
        case sf_status
        when 'Open'
          case sf_res
          when 'Rejected'
            name = 'WontFix'
          else
            name = 'New'
          end
        when 'Closed'
          case sf_res
          when 'Rejected'
            name = 'WontFix'
          else
            name = 'MaybeFixed'
          end
        when 'Deleted'
          case sf_res
          when 'Duplicate'
            name = 'Duplicate'
          else
            name = 'Invalid'
          end
        end
        IssueStatus.find(:first, :conditions => { :name => name })
      end

      def find_priority(sf_prio)
        case sf_prio
        when 1..3; name = 'Low'
        when 4..6; name = 'Normal'
        when 7..9; name = 'High'
        else name = 'Normal'
        end
        IssuePriority.find(:first, :conditions => { :name => name })
      end
      
      def create_journal(issue, messages, history)
        messages.each { |el|
          notes = get_field(el, 'body')
          created_on = parse_date(get_field(el, 'adddate'))

          author = get_field(el, 'user_name')
          sf_user = '@SourceForge user: ' + author + "@\n\n" if author
          notes = sf_user + notes if sf_user
          
          j = Journal.new(:journalized => issue,
                          :user => User.anonymous,
                          :notes => notes,
                          :created_on => created_on)
          
          j.save_with_validation!
        }
      end
      
      def parse_date(date_str)
        return Time.at(Integer(date_str))
      end

      def find_tracker(sf_name)
        case sf_name
          when 'Bugs'; name = 'Bug'
          when 'Feature Requests'; name = 'Feature'
          when 'Patches'; name = 'Patch'
          when 'Support Requests'; name = 'Support'
          else; raise 'Unknown SourceForge tracker: ' + sf_name
        end
        tracker = @project.trackers.find(:first, :conditions => { 
                                           :name => name })
        if not tracker
          raise "Cannot find tracker: " + name
        end
        return tracker
      end
      
      def get_field(el, name)
        # source forge likes to use <field> tags with a name attribute
        # instead of just naming the elements... weird.
        return el.elements["field[@name='" + name + "']"].text
      end

    end

    filename = ENV['filename']
    project = ENV['project']

    raise "filename not spcified" unless filename
    raise "project name not spcified" unless project

    sfm = SourceForgeMigrate.new
    sfm.migrate(filename, project)
  end
end
