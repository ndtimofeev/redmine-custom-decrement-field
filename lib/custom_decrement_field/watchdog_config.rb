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
  end
end
