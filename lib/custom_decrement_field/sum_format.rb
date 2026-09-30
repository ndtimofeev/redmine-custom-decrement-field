module CustomDecrementField
  # Read-only total of the children's decrementable field, weighted per child.
  # Stored in custom_values like any other field so filters, sorting, CSV and
  # the watchdog all see it as an ordinary number.
  class SumFormat < Redmine::FieldFormat::FloatFormat
    include WholeNumberDisplay

    add 'decrement_sum'
    self.customized_class_names = %w(Issue)
    self.bulk_edit_supported = false
    self.form_partial = 'custom_fields/formats/decrement_sum'
    field_attributes :source_field_id, :multiplier_token
    CustomField.safe_attributes 'source_field_id', 'multiplier_token'

    def label
      'label_decrement_sum'
    end

    # Always derived, never typed - the value is overwritten on every
    # recalculation anyway, so don't invite editing it.
    def edit_tag(view, tag_id, tag_name, custom_value, options = {})
      view.text_field_tag(
        tag_name, custom_value.value,
        options.merge(id: tag_id, disabled: true, title: l(:text_sum_readonly_hint))
      )
    end
  end
end
