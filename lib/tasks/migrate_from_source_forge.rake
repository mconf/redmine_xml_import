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
    
    class SourceForgeMigrate
      
      require 'rexml/document'
      include REXML

      def initialize
        # make source forge id unique so we can import from other sites
        @id_format = 'sf-%s'
        
        # select all issues so we can find by custom value (legacy id)
        @issues = Issue.find(:all)
        
        # save issues in a cache so we can re-use them in a 2nd pass
        @issue_cache = Hash.new
      end

      def migrate(filename, project)
        @project = Project.find(project)
        
        # load uploaded xml in to rexml document
        puts 'reading: ' + filename
        file = File.new(filename, 'r')
        doc = Document.new(file.read)
        
        puts 'importing issues...'
        XPath.each(doc, '/project_export/artifacts/artifact') { |el|
          legacy_id = @id_format % get_field_value(el, 'artifact_id')
          
          puts 'issue: ' + legacy_id
          issue = find_or_new_issue(legacy_id)
          
          # save as struct so we have both issue and xml element
          ip = Struct.new(:issue, :el).new
          ip.issue = issue
          ip.el = el
          @issue_cache[legacy_id] = ip
        }
        puts 'done'
        
        puts 'imported ' + String(@issue_cache.length) + ' issues'
      end

      def find_or_new_issue(legacy_id)
        found = find_issue(legacy_id)
        if found
          return found
        else
          return Issue.new
        end
      end

      def find_issue(legacy_id)
        return nil
      end

      def get_field_value(el, name)
        # source forge likes to use <field> tags with a name attribute
        # instead of just naming the elements... weird.
        return el.elements["field[@name='artifact_id']"].text
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
