namespace :redmine do

  class XmlImporter

    class AttachmentInfo
      
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
      # select all issues so we can find by custom value (legacy id)
      @issues = Issue.find(:all)
      
      # save issues in a cache so we can re-use them in a 2nd pass
      @issue_cache = Hash.new
    end

    def get_issue(legacy_id)
      found = find_issue(legacy_id)
      if found
        return found
      else
        raise 'issue does not exist: ' + legacy_id
      end
    end

    def find_issue(legacy_id)
      cf = CustomField.find_by_name('Legacy ID')
      
      # TODO: see if we can use CustomField.find instead of looping
      @issues.each { |issue|
        cv = find_custom_value(issue, cf)
        if cv.value == legacy_id
          return issue
        end
      }
      
      return nil
    end

    def find_or_new_issue(legacy_id)
      found = find_issue(legacy_id)
      if found
        return found
      else
        return Issue.new
      end
    end

    def set_custom_value(issue, name, value)
      cf = CustomField.find_by_name(name)
      cv = find_custom_value(issue, cf)
      if not cv
        raise 'custom value not found: ' + name
      end
      cv.value = value
      cv.save_with_validation!
    end

    def find_custom_value(issue, cf)
      issue.custom_field_values.each { |cv|
        if cv.custom_field_id == cf.id
          return cv
        end
      }
      return nil
    end

    def reset_attachments(issue_id)
      Attachment.delete_all("container_type = 'Issue' " + 
                            "and container_id = " + String(issue_id))
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

    def create_attachment(uri, filename, issue, created_on=nil)
      resp = download_attachment(uri)
      
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
      file_info = AttachmentInfo.new(resp.file, filename)
      
      # create the redmine attachment
      a = Attachment.new
      a.file = file_info
      a.author = User.anonymous
      a.container = issue
      a.created_on = created_on
      a.save_with_validation!
      
      return a
    end

  end

end
