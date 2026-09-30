module CustomDecrementField
  # Reads a decrementable field's configuration: its two keywords - one that
  # adds material, one that writes it off - and the optional status to move
  # the issue to once it reaches zero.
  #
  # This used to parse a marker hidden inside the field's `description`,
  # back when "decrementable" was just an ordinary `int` field with a
  # magic string in it. Now that decrementability is a real, distinct
  # field format (CustomDecrementField::DecrementableIntFormat), both the
  # marker and the parsing are gone: "is this field decrementable" is
  # simply "is its field_format == 'decrementable_int'", and its settings
  # are just custom_field.increment_token / decrement_token /
  # zero_status_id - ordinary accessors backed by the format_store column,
  # filled in directly on the field's own edit form.
  module TokenConfig
    # The keyword alone fixes the direction of an entry, so the amount is
    # always written as a plain positive number: "PRIHOD : 10" adds ten,
    # "RASHOD : 1" writes one off. (decrement_token keeps its name from when
    # it was the field's only, signed, token; it is now the write-off keyword.)
    Config = Struct.new(:increment_token, :decrement_token, :zero_status_id, keyword_init: true) do
      def increment_note(amount)
        "#{increment_token} : #{amount}"
      end

      def decrement_note(amount, literal = nil)
        [ "#{decrement_token} : #{amount}", literal.presence ].compact.join(' ')
      end
    end

    # Returns a Config, or nil if this custom field isn't a decrementable
    # field (wrong format) or isn't fully configured yet: both keywords are
    # needed (there is no way to tell what "10" means with only one of them),
    # and they must differ (the same word can't mean both directions).
    # Everything else in this plugin treats a field for which this returns
    # nil exactly like a field it has never heard of - which is also what
    # happens to a field saved before there were two keywords, until an
    # administrator fills in the new one.
    def self.for_field(custom_field)
      return nil unless custom_field&.field_format == 'decrementable_int'
      return nil if custom_field.increment_token.blank? || custom_field.decrement_token.blank?
      return nil if custom_field.increment_token == custom_field.decrement_token

      Config.new(
        increment_token: custom_field.increment_token,
        decrement_token: custom_field.decrement_token,
        zero_status_id: custom_field.zero_status_id.presence&.to_i
      )
    end

    # Most trackers will only ever have one decrementable field, but
    # nothing stops an administrator from adding several - e.g. two
    # independent counters on the same tracker. Each one carries its own
    # keywords, so they are parsed and recalculated completely independently
    # of one another; a comment can even affect more than one of them at
    # once, if it happens to contain more than one field's keyword.
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
    # The keywords live inside format_store (a serialized blob, see
    # this file's own header comment), not a real column, so there's no
    # SQL way to filter "fields with keywords filled in" - loading every
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
