namespace :redmine do

  class XmlImporter
    
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

  end

end
