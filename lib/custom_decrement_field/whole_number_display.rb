module CustomDecrementField
  # Core renders every Float through ApplicationHelper#format_object as
  # sprintf('%.2f') - a whole 50.0 shows up as "50.00". Handing format_object
  # an Integer instead takes its Integer branch, which also keeps the field's
  # thousands-delimiter setting working.
  module WholeNumberDisplay
    def formatted_value(view, custom_field, value, customized = nil, html = false)
      casted = super
      return casted unless casted.is_a?(Float)

      rounded = casted.round(2)
      rounded == rounded.to_i ? rounded.to_i : casted
    end
  end
end
