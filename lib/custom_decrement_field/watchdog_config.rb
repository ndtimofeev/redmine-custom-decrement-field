module CustomDecrementField
  module WatchdogConfig
    WATCHABLE_FORMATS = %w[int float decrementable_int decrement_sum].freeze

    # Fields offered in the dropdown on the watchdog's admin form.
    def self.candidate_fields(watchdog)
      IssueCustomField.where(field_format: WATCHABLE_FORMATS).where.not(id: watchdog.id).order(:name)
    end

    # The field this custom field watches, or nil if it isn't a watchdog
    # (or its target was deleted - then it simply stays silent).
    def self.watched_field(custom_field)
      return nil unless custom_field&.field_format == 'watchdog'

      id = custom_field.watched_field_id.presence
      id && IssueCustomField.find_by(id: id)
    end

    # The id of the status this watchdog moves a ticket to when it starts
    # barking (the trigger status) or when it stops (the release status), or
    # nil when none is set - both are optional. The status itself may have been
    # deleted since - see .trigger_status / .release_status.
    def self.trigger_status_id(custom_field)
      status_id(custom_field, :trigger_status_id)
    end

    def self.release_status_id(custom_field)
      status_id(custom_field, :release_status_id)
    end

    def self.trigger_status(custom_field)
      id = trigger_status_id(custom_field)
      id && IssueStatus.find_by(id: id)
    end

    def self.release_status(custom_field)
      id = release_status_id(custom_field)
      id && IssueStatus.find_by(id: id)
    end

    # Trackers carrying a watchdog that has either status set - the ones whose
    # issues can have a stuck transition to report.
    def self.tracker_ids_with_status
      IssueCustomField.where(field_format: 'watchdog')
                      .select { |f| trigger_status_id(f) || release_status_id(f) }
                      .flat_map(&:tracker_ids).uniq
    end

    def self.status_id(custom_field, setting)
      return nil unless custom_field&.field_format == 'watchdog'

      custom_field.public_send(setting).presence&.to_i
    end
    private_class_method :status_id
  end
end
