module CustomDecrementField
  # Registers "Decrementable integer" as a real, selectable entry in the
  # custom field Format dropdown, instead of relying on an ordinary `int`
  # field plus a marker hidden in its description.
  #
  # It subclasses Redmine's own Redmine::FieldFormat::IntFormat rather
  # than reimplementing storage/casting/validation/sorting/filtering/
  # totals from scratch, so this format behaves identically to plain
  # Integer everywhere Redmine cares (query filters, sort order, CSV/PDF
  # export, totals) - we only override the two things that actually need
  # to differ: where per-field settings live, and how the value is
  # edited.
  #
  # Verified against Redmine 6.0-stable source before committing to this
  # approach (see project history/README for the reasoning):
  #
  # - Redmine::FieldFormat.all is a Hash with a default value of
  #   Base.instance. Redmine::FieldFormat.find(name) therefore NEVER
  #   returns nil for an unregistered name - if this plugin is removed,
  #   every place that reads or edits a field using this format falls
  #   back to the generic Base behavior (plain text input, string-typed
  #   filters/sorting) instead of crashing. The one place this bites is
  #   CustomField's own `validates_inclusion_of :field_format` - editing
  #   the FIELD'S OWN definition (not issue values) while the plugin is
  #   absent will be rejected until the format is changed to a known one.
  # - format_store (the column field_attributes below writes into) is a
  #   plain `text` column that has existed in Redmine core since 2013 -
  #   using it needs no migration of our own, and its contents survive
  #   the plugin being disabled/removed untouched (just inaccessible via
  #   Ruby methods or any UI until the plugin comes back).
  # - No core Redmine code branches on the literal string 'int' outside
  #   of FieldFormat's own dispatch, so subclassing IntFormat really does
  #   inherit numeric behavior everywhere, rather than only in the few
  #   places we've explicitly tested.
  class DecrementableIntFormat < Redmine::FieldFormat::IntFormat
    add 'decrementable_int'

    # Restrict this format to Issue custom fields only: everything this
    # plugin does (parsing journal notes, checking issue.tracker, etc.)
    # assumes the customized object is an Issue, so there's no reason to
    # ever offer it when creating a Project/TimeEntry/... custom field.
    self.customized_class_names = %w(Issue)

    # A bulk-edited value would just be silently overwritten by the next
    # recalculation anyway (see IssuePatch#custom_decrement_field_recalculate),
    # since that hook runs on every save regardless of who or what
    # triggered it. Rather than let users discover that the hard way,
    # don't offer the field for bulk edit at all.
    self.bulk_edit_supported = false

    # Renders app/views/custom_fields/formats/_decrementable_int.html.erb
    # on the custom field's own admin edit form (Administration > Custom
    # fields > this field) - see custom_fields_helper.rb's
    # render_custom_field_format_partial, which every core format uses
    # for its own extra settings the same way.
    self.form_partial = 'custom_fields/formats/decrementable_int'

    # Declares :decrement_token and :zero_status_id as ordinary
    # custom_field.decrement_token / custom_field.zero_status_id
    # accessors, backed by the format_store column - this is the exact
    # same mechanism core formats use for e.g. Numeric's
    # thousands_delimiter or Version's version_status. Per-instance
    # settings, no new table, no migration.
    field_attributes :decrement_token, :zero_status_id

    def label
      'label_decrementable_int'
    end

    # The only moment a human is meant to type a plain number directly
    # into this field is issue creation (see
    # IssuePatch#custom_decrement_field_seed, which turns that number
    # into the field's first history entry). Every save after that is
    # handled purely by recalculation, so rendering an editable input on
    # the ordinary edit form would just be confusing: whatever gets typed
    # there is silently discarded on save anyway. Making the field
    # `readonly` here prevents that confusion natively, on top of (not
    # instead of) the server-side overwrite, which remains the real
    # guarantee regardless of what any particular form renders.
    #
    # `readonly` rather than `disabled` on purpose: a disabled input is
    # not submitted with the form at all (fine either way, since the
    # server-side recalculation doesn't care what was submitted), but a
    # readonly one still looks like an ordinary filled-in field and stays
    # selectable/copyable, instead of looking greyed-out and broken.
    def edit_tag(view, tag_id, tag_name, custom_value, options={})
      if custom_value.customized.new_record?
        super
      else
        view.text_field_tag(
          tag_name, custom_value.value,
          options.merge(
            :id => tag_id,
            :readonly => true,
            :title => l(:text_decrementable_int_readonly_hint)
          )
        )
      end
    end
  end
end
