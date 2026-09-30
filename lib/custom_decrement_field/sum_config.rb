module CustomDecrementField
  module SumConfig
    Config = Struct.new(:source_field, :multiplier_token, keyword_init: true)

    # nil unless +custom_field+ is a sum field pointing at a properly
    # configured decrementable field - everything else treats nil as
    # "not ours", same as TokenConfig.
    def self.for_field(custom_field)
      return nil unless custom_field&.field_format == 'decrement_sum'

      source = IssueCustomField.find_by(id: custom_field.source_field_id.presence)
      return nil unless TokenConfig.for_field(source)

      Config.new(source_field: source, multiplier_token: custom_field.multiplier_token.presence)
    end

    def self.fields_for_tracker(tracker)
      return [] unless tracker

      tracker.custom_fields.select { |f| for_field(f) }
    end
  end
end
