module CustomDecrementField
  # Reads a decrementable field's configuration (its token, and the
  # optional status to move the issue to once it reaches zero).
  #
  # This used to parse a marker hidden inside the field's `description`,
  # back when "decrementable" was just an ordinary `int` field with a
  # magic string in it. Now that decrementability is a real, distinct
  # field format (CustomDecrementField::DecrementableIntFormat), both the
  # marker and the parsing are gone: "is this field decrementable" is
  # simply "is its field_format == 'decrementable_int'", and its settings
  # are just custom_field.decrement_token / custom_field.zero_status_id -
  # ordinary accessors backed by the format_store column, filled in
  # directly on the field's own edit form.
  module TokenConfig
    Config = Struct.new(:token, :zero_status_id, keyword_init: true)

    # Returns a Config, or nil if this custom field isn't a decrementable
    # field (wrong format) or hasn't had a token filled in yet (created
    # but not finished being configured). Everything else in this plugin
    # treats a field for which this returns nil exactly like a field it
    # has never heard of.
    def self.for_field(custom_field)
      return nil unless custom_field&.field_format == 'decrementable_int'
      return nil if custom_field.decrement_token.blank?

      Config.new(
        token: custom_field.decrement_token,
        zero_status_id: custom_field.zero_status_id.presence&.to_i
      )
    end

    # Most trackers will only ever have one decrementable field, but
    # nothing stops an administrator from adding several - e.g. two
    # independent counters on the same tracker. Each one carries its own
    # token, so they are parsed and recalculated completely independently
    # of one another; a comment can even affect more than one of them at
    # once, if it happens to contain more than one field's token.
    def self.fields_for_tracker(tracker)
      return [] unless tracker

      tracker.custom_fields.select { |f| for_field(f) }
    end

    # Every tracker that has at least one properly-configured
    # decrementable field on it - used to bound the candidate set for the
    # "inconsistent history" query filter (see StockCalculator.candidate_issues)
    # to trackers where an issue could possibly be inconsistent at all,
    # instead of scanning every issue in the database.
    #
    # decrement_token lives inside format_store (a serialized blob, see
    # this file's own header comment), not a real column, so there's no
    # SQL way to filter "fields with a token filled in" - loading every
    # decrementable_int field and checking each in Ruby is fine, since
    # there are only ever a handful of custom fields total, regardless of
    # how many issues or trackers exist.
    def self.tracker_ids_with_fields
      IssueCustomField
        .where(field_format: 'decrementable_int')
        .select { |f| for_field(f) }
        .flat_map { |f| f.trackers.pluck(:id) }
        .uniq
    end
  end
end
