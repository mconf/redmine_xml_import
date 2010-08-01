# redmine_google_code_migrate - migrate to redmine from google code
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
require 'cgi'

namespace :redmine do
  desc 'Google Code migration script'
  task :migrate_from_google_code => :environment do
    
    class GoogleCodeMigrate
      require 'rexml/document'
      include REXML

      def migrate(filename, project)
        # load uploaded xml in to rexml document
        puts 'reading: ' + filename
        file = File.new(filename, 'r')

        doc = Document.new(file.read)
          
        # select all issues so we can find by custom value (legacy id)
        @issues = Issue.find(:all)
        @project = Project.find(project)
        
        i = 0
        XPath.each(doc, '/googleCodeExport/issues/issue') { |el|
          legacy_id = el.attributes['id']
          
          puts 'importing issue: ' + legacy_id
          issue = find_or_new_issue(legacy_id)
          
          labels = el.elements.to_a('labels/label')
          comments = el.elements.to_a('comments/comment')

          issue.project = @project
          issue.author = User.anonymous
          issue.created_on = parse_datetime(el.elements['reportDate'].text)
          issue.tracker = find_tracker(labels)
          issue.status = find_status(el.elements['status'].text)
          issue.priority = find_priority(labels)
          issue.votes_value = el.attributes['stars']
          issue.fixed_version = find_version(labels, 'Milestone')
          issue.subject = el.elements['summary'].text
          issue.description = clean_html(el.elements['details'].text)
          issue.save_with_validation!()
          
          # set custom values after saving
          set_custom_value(issue, 'Legacy ID', legacy_id)
          set_custom_value(issue, 'Found in version', 
                           find_in_labels(labels, /Version-(.*)/))
          
          reset_journal(issue.id)
          create_journal(issue, comments)

          
          
          # save once more (e.g. for status, etc)
          issue.save_with_validation!
          
          # counter so we can say how many issues were imported
          i += 1
        }
        
        puts 'imported ' + String(i) + ' issues'
      end

      private

      def find_in_labels(labels, re)
        labels.each { |label|
          match = label.text.match(re)
          if match
            return match[1]
          end
        }
        return nil
      end
      
      def reset_journal(issue_id)
        Journal.find(:all, :conditions => {
                       :journalized_id => issue_id,
                       :journalized_type => 'Issue'
                     }).each { |journal|
          Journal.delete(journal.id)
          JournalDetail.delete_all({:journal_id => journal.id})
        }
      end
      
      def create_journal(issue, comments)

        last_status = find_status('New')
        found_in_cf = CustomField.find_by_name('Found in version')
        last_date = issue.created_on

        last_id = 0
        comments.each { |comment|
          id = Integer(comment.attributes['id'])
          created_on = parse_datetime(comment.attributes['date'])
          author = comment.attributes['author']
          google_user = '@Google user: ' +  author + "@\n\n"
          
          if comment.elements['text']
            # since we cant export users from google code, we'll
            # have to make do with hard-coding the username, so to speak
            notes = google_user + clean_html(comment.elements['text'].text)
          else
            # if no text was entered (e.g. status change), still show
            # the user, so we know who changed the issue state
            notes = google_user
          end
          
          # add dummy comments to fill the gaps between non-sequential
          # comments (can occurr when comments were deleted)
          while last_id + 1 != id
            # create dummy comments 1 second later to order is correct
            one_second_later = last_date + 0.86400
            Journal.create(:journalized => issue,
                           :user => User.anonymous,
                           :notes => '-Missing comment-',
                           :created_on => one_second_later)
            last_id += 1
          end
          
          last_id = id
          last_date = created_on
          
          j = Journal.new(:journalized => issue,
                          :user => User.anonymous,
                          :notes => notes,
                          :created_on => created_on)
          
          new_status_text = comment.attributes['newStatus']
          if new_status_text
            new_status = find_status(new_status_text)
            j.details << JournalDetail.new(:property => 'attr',
                                           :prop_key => 'status_id',
                                           :old_value => last_status.id,
                                           :value => new_status.id)
            last_status = new_status
          end

          new_summary = comment.elements['newSummary']
          if new_summary
            j.details << JournalDetail.new(:property => 'attr',
                                           :prop_key => 'subject',
                                           :value => new_summary.text)
          end

          owner_removed = comment.attributes['ownerRemoved']
          if owner_removed
            j.details << JournalDetail.new(:property => 'attr',
                                           :prop_key => 'assigned_to_id',
                                           :old_value => User.anonymous)
          end

          labels_added = comment.elements.to_a('labelsAdded/label')
          labels_removed = comment.elements.to_a('labelsRemoved/label')
          
          new_priority = find_priority(labels_added)
          if new_priority
            last_priority = find_priority(labels_removed)
            if last_priority
              last_priority_id = last_priority.id
            end
            j.details << JournalDetail.new(:property => 'attr',
                                           :prop_key => 'priority_id',
                                           :old_value => last_priority_id,
                                           :value => new_priority.id)
          end

          new_version = find_version(labels_added, 'Milestone')
          if new_version
            last_version = find_version(labels_removed, 'Milestone')
            if last_version
              last_version_id = last_version.id
            end
            j.details << JournalDetail.new(:property => 'attr',
                                           :prop_key => 'fixed_version_id',
                                           :old_value => last_version_id,
                                           :value => new_version.id)
          end

          # if there's a "Found in version" custom field, use it
          if found_in_cf
            new_found_in = find_in_labels(labels_added, /Version-(.*)/)
            if new_found_in
              last_found_in = find_in_labels(labels_removed, /Version-(.*)/)
              j.details << JournalDetail.new(:property => 'cf',
                                             :prop_key => found_in_cf.id,
                                             :old_value => last_found_in,
                                             :value => new_found_in)
            end
          end
          
          j.save_with_validation!
        }
      end

      def parse_datetime(string)
        return Date.strptime(string, '%Y-%m-%d %H:%M%:%S')
      end

      def clean_html(html)
        # get unescaped version
        html = CGI.unescapeHTML(html)
        
        # turn html in to redmine wiki syntax
        html = html.gsub(/<b>(.*)<\/b>/, '*\1*')
        html = html.gsub(/<a.*href=\"(.*)\">(.*)<\/a>/, '"\1":\2 ')
        
        return html
      end

      def find_status(name)
        status = IssueStatus.find(:first, :conditions => { :name => name })
        raise "Unknown status: " + name unless status
        return status
      end

      def find_priority(labels)
        labels.each { |label|
          priority = map_priority(label.text)
          return priority if priority
        }
        return nil
      end

      def find_tracker(labels)
        labels.each { |label|
          tracker = map_tracker(label.text)
          return tracker if tracker
        }
        return nil
      end
      
      def find_version(labels, label_prefix)
        labels.each { |label|
          version = map_version(label.text, label_prefix)
          return version if version
        }
        return nil
      end
      
      def map_priority(legacy_name)
        case legacy_name
        when 'Priority-Critical'; name = 'Urgent'
        when 'Priority-High'; name = 'High'
        when 'Priority-Medium'; name = 'Normal'
        when 'Priority-Low'; name = 'Low'
        end
        if name
          IssuePriority.find(:first, :conditions => { :name => name })
        end
      end

      def map_version(legacy_name, label_prefix)
        name_match = legacy_name.match(/#{label_prefix}-(.*)/)
        if name_match
          @project.versions.find(:first, :conditions => { 
                                   :name => name_match[1] })
        end
      end
      
      def map_tracker(legacy_name)
        case legacy_name
        when 'Type-Defect'; name = 'Bug'
        when 'Type-Enhancement'; name = 'Feature'
        when 'Type-Task'; name = 'Task'
        end
        if name
          @project.trackers.find(:first, :conditions => { :name => name })
        end
      end

      def find_or_new_issue(legacy_id)
        cf = CustomField.find_by_name('Legacy ID')

        # TODO: see if we can use CustomField.find instead of looping
        @issues.each { |issue|
          cv = find_custom_value(issue, cf)
          if cv.value == legacy_id
            return issue
          end
        }
        
        # if no issue was found in search loop, create a new one
        return Issue.new
      end

      def set_custom_value(issue, name, value)
        cf = CustomField.find_by_name(name)
        cv = find_custom_value(issue, cf)
        cv.value = value
        cv.save_with_validation!
      end

      def find_custom_value(issue, cf)
        issue.custom_field_values.each { |cv|
          if cv.custom_field_id == cf.id
            return cv
          end
        }
      end

    end

    filename = ENV['filename']
    project = ENV['project']

    raise "filename not spcified" unless filename
    raise "project name not spcified" unless project

    gcm = GoogleCodeMigrate.new
    gcm.migrate(filename, project)
  end
end
