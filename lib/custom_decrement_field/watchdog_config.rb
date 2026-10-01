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
    # barking, or nil when none is set (the setting is optional). The status
    # itself may have been deleted since - see .trigger_status.
    def self.trigger_status_id(custom_field)
      return nil unless custom_field&.field_format == 'watchdog'

      custom_field.trigger_status_id.presence&.to_i
    end

    def self.trigger_status(custom_field)
      id = trigger_status_id(custom_field)
      id && IssueStatus.find_by(id: id)
    end

    # Trackers carrying a watchdog that has a trigger status set - the ones
    # whose issues can have a stuck transition to report.
    def self.tracker_ids_with_trigger_status
      IssueCustomField.where(field_format: 'watchdog').select { |f| trigger_status_id(f) }
                      .flat_map(&:tracker_ids).uniq
    end
  end
end
