module CustomDecrementField
  # A plain editable number (the critical level) plus three settings: which
  # other numeric field of the same issue it watches (the association lives
  # here, on the watchdog's own definition, not on the watched field), and
  # optionally a status the issue is moved to at the moment the watchdog starts
  # barking and another for the moment it stops (WatchdogTransition).
  class WatchdogFormat < Redmine::FieldFormat::FloatFormat
    include WholeNumberDisplay

    add 'watchdog'
    self.customized_class_names = %w(Issue)
    self.totalable_supported = false # a sum of thresholds means nothing
    self.form_partial = 'custom_fields/formats/watchdog'
    field_attributes :watched_field_id, :trigger_status_id, :release_status_id
    CustomField.safe_attributes 'watched_field_id', 'trigger_status_id', 'release_status_id'

    def label
      'label_watchdog'
    end

    # The level is typed on the issue itself, where nothing says that empty and
    # 0 mean "off"; the tooltip does.
    def edit_tag(view, tag_id, tag_name, custom_value, options={})
      super(view, tag_id, tag_name, custom_value, options.merge(title: l(:text_watchdog_level_hint)))
    end
  end
end
