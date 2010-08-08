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
    
    class GoogleCodeMigrate < XmlImporter
      
      require 'rexml/document'
      require 'open-uri'
      
      include REXML
      
      class GoogleCodeAttachment
        
        def initialize(file, filename)
          @file = file
          @filename = filename
        end

        def original_filename
          @filename
        end

        def read(*args)
          @file.read(*args)
        end

        def size(*args)
          @file.size(*args)
        end

        def content_type
          ''
        end
      end

      def initialize
        super
        
        # make google code id unique so we can import from other sites
        @id_format = 'gc-%s'
      end

      def migrate(filename, project)
        @project = Project.find(project)

        # load uploaded xml in to rexml document
        puts 'reading: ' + filename
        file = File.new(filename, 'r')
        doc = Document.new(file.read)
                
        puts 'importing issues...'
        XPath.each(doc, '/googleCodeExport/issues/issue') { |el|
          legacy_id = @id_format % el.attributes['id']
          
          puts 'issue: ' + legacy_id
          issue = find_or_new_issue(legacy_id)
          
          labels = el.elements.to_a('labels/label')
          comments = el.elements.to_a('comments/comment')
          details = clean_html(el.elements['details'].text)
          reporter = el.elements['reporter'].text
          google_user = '@Google user: ' + reporter + "@\n\n"
          
          issue.project = @project
          issue.author = User.anonymous
          issue.created_on = parse_datetime(el.elements['reportDate'].text)
          issue.tracker = find_tracker(labels, 'Type-Defect')
          issue.priority = find_priority(labels, 'Priority-Medium')
          issue.status = find_status_for_issue(el.elements['status'].text)
          issue.votes_value = el.attributes['stars']
          issue.fixed_version = find_version(labels, 'Milestone')
          issue.subject = CGI.unescapeHTML(el.elements['summary'].text)
          issue.description = google_user + details
          issue.save_with_validation!()
          
          # set custom values after saving
          set_custom_value(issue, 'Legacy ID', legacy_id)
          set_custom_value(issue, 'Found in version', 
                           find_in_labels(labels, /Version-(.*)/))

          # reset attachments before creating the journal, since the files
          # from comments are added to the issue, not the comments.
          reset_attachments(issue.id)
          create_attachments(issue, el)

          reset_journal(issue.id)
          create_journal(issue, comments)

          # TODO: is this really necessary?
          # save once more (e.g. for status, etc)
          issue.save_with_validation!
          
          # save as struct so we have both issue and xml element
          ip = Struct.new(:issue, :el).new
          ip.issue = issue
          ip.el = el
          @issue_cache[legacy_id] = ip
        }
        puts 'done'

        # create relations after first pass, as we need to have all
        # of the issues already in the db.
        puts 'creating issue relations...'
        @issue_cache.each { |k,v|
          reset_relations(v.issue.id)
          create_relations(v.el, v.issue)
        }
        puts 'done'
        
        puts 'imported ' + String(@issue_cache.length) + ' issues'
      end

      private

      def reset_relations(issue_id)
        IssueRelation.delete_all("issue_from_id = " + String(issue_id))
      end

      def create_relations(el, issue_from)
        if el.elements['status'].text == 'Duplicate'
          legacy_id = @id_format % el.elements['mergeInto'].text
          issue_to = get_issue_from_cache(legacy_id)
          
          r = IssueRelation.new
          r.relation_type = IssueRelation::TYPE_DUPLICATES
          r.issue_from = issue_from
          r.issue_to = issue_to
          r.save_with_validation!
          
        end

        el.elements.to_a('relations/relation').each { |relation|
          type = relation.attributes['type']
          legacy_id = legacy_id = @id_format % relation.attributes['id']
          issue_to = get_issue_from_cache(legacy_id)
          
          case type
          when 'Blocks'
            r = IssueRelation.new
            r.relation_type = IssueRelation::TYPE_BLOCKS
            r.issue_from = issue_from
            r.issue_to = issue_to
            r.save_with_validation!
          end
        }
      end

      def get_issue_from_cache(legacy_id)
        if @issue_cache.has_key?(legacy_id)
          return @issue_cache[legacy_id].issue
        else
          throw 'issue not in cache: ' + legacy_id
        end
      end

      def find_in_labels(labels, re)
        labels.each { |label|
          match = label.text.match(re)
          if match
            return match[1]
          end
        }
        return nil
      end
      
      def download_attachment(uri_str)
        uri = URI.parse(uri_str)
        http = Net::HTTP.new(uri.host)
        get = Net::HTTP::Get.new(uri.path + '?' + uri.query)
        resp = http.request(get)
        result = Struct.new(:file, :invalid).new
        
        # dectct google's annoying token expiry
        if resp.code != '200'
          result.invalid = true
          if resp.header['location'].match(/accounts\/ServiceLogin/)
            # seems to be the url that google goes to when the url has an
            # expired token (yuck)
            puts 'expired google attachment token'
          else
            puts 'unrecognised redirect: ' + resp.header['location']
          end
        else
          io = StringIO.new
          io << resp.body
          io.rewind
          result.file = io
        end
        
        return result
      end
      
      def create_attachments(issue, el)
        created = Array.new
        el.elements.to_a('attachments/attachment').each { |attach|
          
          filename = attach.attributes['filename'] 
          resp = download_attachment(attach.text)

          if resp.invalid
            puts 'ignoring invalid attachment: ' + filename
            next
          end
          
          # redmine doesn't like empty files
          if resp.file.size <= 0
            puts 'ignoring empty attachment: ' + filename
            next
          end
          
          # create file wrapper for redmine
          file_info = GoogleCodeAttachment.new(resp.file, filename)
          
          # create the redmine attachment
          a = Attachment.new
          a.file = file_info
          a.author = User.anonymous
          a.container = issue
          a.save_with_validation!
          
          created << a
        }
        return created
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
          
          # after saving, create the attachments
          create_attachments(issue, comment).each { |a|
            j.details << JournalDetail.new(:property => 'attachment',
                                           :prop_key => a.id,
                                           :value => a.filename)
          }
          
          j.save_with_validation!
        }
      end
      
      def parse_datetime(string)
        return Date.strptime(string, '%Y-%m-%d %H:%M:%S')
      rescue
        print 'could not parse date: ', string, "\n"
        raise
      end
      
      def clean_html(html)
        # get unescaped version
        html = CGI.unescapeHTML(html)
        
        # turn html in to redmine wiki syntax
        html = html.gsub(/<b>(.*)<\/b>/, '*\1*')
        html = html.gsub(/<a.*href=\"(.*)\">(.*)<\/a>/, '"\1":\2 ')
        
        return html
      end

      def find_status_for_issue(name)
        # google code does not have a concept of issue relations, so instead
        # of setting status to Duplicate, set to invalid, and later on, create
        # the duplicate relation.
        if name == 'Duplicate'
          name = 'Invalid'
        end
        return find_status(name)
      end

      def find_status(name)
        status = IssueStatus.find(:first, :conditions => { :name => name })
        raise "Unknown status: " + name unless status
        return status
      end

      def find_priority(labels, default_name=nil)
        labels.each { |label|
          priority = map_priority(label.text)
          return priority if priority
        }
        return map_priority(default_name) if default_name
      end

      def find_tracker(labels, default_name=nil)
        labels.each { |label|
          tracker = map_tracker(label.text)
          return tracker if tracker
        }
        return map_tracker(default_name) if default_name
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

    end

    filename = ENV['filename']
    project = ENV['project']

    raise "filename not spcified" unless filename
    raise "project name not spcified" unless project

    gcm = GoogleCodeMigrate.new
    gcm.migrate(filename, project)
  end
end
