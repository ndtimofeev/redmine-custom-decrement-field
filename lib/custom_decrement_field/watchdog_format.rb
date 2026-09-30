module CustomDecrementField
  # A plain editable number (the critical level) plus one setting: which other
  # numeric field of the same issue it watches. The association lives here, on
  # the watchdog's own definition, not on the watched field.
  class WatchdogFormat < Redmine::FieldFormat::FloatFormat
    include WholeNumberDisplay

    add 'watchdog'
    self.customized_class_names = %w(Issue)
    self.totalable_supported = false # a sum of thresholds means nothing
    self.form_partial = 'custom_fields/formats/watchdog'
    field_attributes :watched_field_id
    CustomField.safe_attributes 'watched_field_id'

    def label
      'label_watchdog'
    end
  end
end
