module CustomDecrementField
  # Where a decrementable field's configuration lives, and why.
  #
  # The obvious place to store "which keyword marks a decrement comment
  # for this field" and "which status to move the issue to once it hits
  # zero" would be a small table owned by this plugin
  # (custom_field_id -> config). We deliberately avoid that, for two
  # reasons:
  #
  # 1. Vanilla compatibility. If this plugin is ever disabled or removed,
  #    the custom field itself must keep working as an ordinary Redmine
  #    integer field, showing whatever number was last computed. A
  #    plugin-owned table would simply vanish along with the plugin,
  #    leaving no way to even inspect the configuration afterwards.
  # 2. Portability. Redmine already knows how to copy, export and import
  #    custom field definitions (e.g. when duplicating a tracker or a
  #    project). By keeping the configuration inside the custom field's
  #    own `description` column, it automatically travels along with the
  #    field through all of those operations, with zero extra code.
  #
  # The trade-off is that `description` is also user-facing help text
  # shown on the issue form, so the configuration is hidden inside an
  # HTML comment: it renders invisibly wherever the description itself is
  # displayed, but is still plain text we can pull back out of the stored
  # column.
  #
  # Marker format (a single line anywhere inside the field's description;
  # the rest of the text is ordinary help text for end users):
  #
  #   <!-- custom-decrement-field: token=MATSTOCK; zero-status-id=5 -->
  #
  # token          - required. The keyword we search for inside journal
  #                  notes, e.g. "MATSTOCK:-1" or "MATSTOCK:100".
  # zero-status-id - optional. The numeric id of the IssueStatus the issue
  #                  should be moved to the first time the computed value
  #                  crosses from positive into zero or negative.
  #
  # zero-status-id is stored as a numeric id rather than a status name on
  # purpose, for the same reason nothing else in this plugin links records
  # to each other by name: a name is free text an administrator can rename
  # at any time through the ordinary Redmine UI, while an id is stable for
  # the lifetime of the record. The settings page (see
  # app/views/settings/_custom_decrement_field.html.erb) renders a
  # `<select>` populated from real IssueStatus records, so nobody ever has
  # to type this id by hand.
  module TokenConfig
    MARKER_REGEXP = /<!--\s*custom-decrement-field:\s*(.+?)\s*-->/m

    Config = Struct.new(:token, :zero_status_id, keyword_init: true)

    def self.marker(token:, zero_status_id: nil)
      attrs = ["token=#{token}"]
      attrs << "zero-status-id=#{zero_status_id}" if zero_status_id.present?
      "<!-- custom-decrement-field: #{attrs.join('; ')} -->"
    end

    # Returns a Config, or nil if this custom field has not been marked as
    # decrementable (its description does not contain our marker, or the
    # marker is missing a token). Every other piece of this plugin treats
    # a field for which this returns nil exactly like a plain vanilla
    # custom field: the calculator and the view hooks simply do nothing
    # for it.
    def self.for_field(custom_field)
      return nil unless custom_field&.description

      match = custom_field.description.match(MARKER_REGEXP)
      return nil unless match

      attrs = match[1].split(';').each_with_object({}) do |pair, memo|
        key, value = pair.split('=', 2).map(&:strip)
        memo[key] = value if key.present?
      end

      return nil if attrs['token'].blank?

      Config.new(
        token: attrs['token'],
        zero_status_id: attrs['zero-status-id'].presence&.to_i
      )
    end

    # Most trackers will only ever have one decrementable field, but
    # nothing stops an administrator from adding several - e.g. two
    # independent counters on the same tracker. Each one carries its own
    # token inside its own description, so they are parsed and
    # recalculated completely independently of one another; a comment can
    # even affect more than one of them at once, if it happens to contain
    # more than one field's token.
    def self.fields_for_tracker(tracker)
      return [] unless tracker

      tracker.custom_fields.select { |f| for_field(f) }
    end
  end
end
