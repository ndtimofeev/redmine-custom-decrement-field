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

    # field_attributes only makes decrement_token/zero_status_id exist as
    # methods on CustomField - it says nothing about whether they may be
    # mass-assigned. CustomField#safe_attributes is Redmine's own
    # whitelist (a hardcoded list of attribute names in
    # app/models/custom_field.rb), and CustomFieldsController#update
    # saves through exactly that: `@custom_field.safe_attributes =
    # params[:custom_field]`. Without this call, the admin form happily
    # displays our two inputs and accepts whatever you type into them,
    # but the values never survive the round trip: safe_attributes=
    # silently drops any key not on the whitelist before the record is
    # even saved, so the field always reads back blank.
    #
    # Redmine's safe_attributes macro accumulates rather than replaces
    # (each call appends to the class's own list), so this adds our two
    # names to the existing core list instead of needing to duplicate it.
    CustomField.safe_attributes 'decrement_token', 'zero_status_id'

    def label
      'label_decrementable_int'
    end

    # Draws the "-1" button as part of the field's own HTML, instead of
    # injecting it with JavaScript after the page has already rendered
    # (an earlier version of this plugin did that; see git history/README
    # on the `main` branch). That JS-based approach turned out to be
    # fragile in practice - it depended on Redmine's Propshaft plugin
    # asset pipeline (worked around once already by inlining the script),
    # and was later found to not even run at all in some mobile browsers,
    # for reasons that were hard to pin down without access to the actual
    # device. Rendering the button as ordinary server-side HTML sidesteps
    # both classes of problem entirely: there is no separate script to
    # fail to load or fail to execute, on any browser.
    #
    # This is safe to do here - and does NOT leak the button into every
    # place this field's value is ever displayed - because of exactly how
    # Redmine calls this method, verified against 6.0-stable source:
    #
    # * The issue's own show page (custom_fields_helper.rb#show_value,
    #   called from issues_helper.rb's
    #   render_half_width_custom_fields_rows /
    #   render_full_width_custom_fields_rows) is the ONLY call site that
    #   reaches here with html=true for an Issue custom field.
    # * Issue list/query columns never call this method at all for an
    #   integer-backed field: QueryCustomFieldColumn#value already casts
    #   the value to a plain Ruby Integer before queries_helper.rb's
    #   column_value renders it, so it's format_object's generic Integer
    #   branch that handles it, not this class.
    # * CSV export, PDF export, and issue notification emails all reach
    #   this method, but always with html=false explicitly (see
    #   issues_pdf_helper.rb and issues_helper.rb#email_issue_attributes)
    #   - so `html` being true really does mean "this is the live issue
    #   page", not merely "some caller asked for HTML".
    #
    # If a future Redmine version changes any of that, the worst case is
    # the button quietly stops appearing somewhere it used to (html now
    # false where it used to be true) or starts appearing somewhere new
    # (html now true where it used to be false) - neither crashes, and
    # both would be caught by simply looking at the affected page again
    # after upgrading.
    def formatted_custom_value(view, custom_value, html=false)
      text = super
      return text unless html

      issue = custom_value.customized
      return text unless issue.is_a?(Issue) && issue.persisted?
      return text unless User.current.allowed_to?(:add_issue_notes, issue.project)

      calculator = CustomDecrementField::StockCalculator.new(issue, custom_value.custom_field)
      return text unless calculator.enabled?

      view.safe_join([text.to_s, decrement_button(view, issue, custom_value.custom_field, calculator)])
    end

    # The only moment a human is meant to type a plain number directly
    # into this field is issue creation (see
    # IssuePatch#custom_decrement_field_seed, which turns that number
    # into the field's first history entry). Every save after that is
    # handled purely by recalculation, so rendering an editable input on
    # the ordinary edit form would just be confusing: whatever gets typed
    # there is silently discarded on save anyway. Making the field
    # non-editable here prevents that confusion natively, on top of (not
    # instead of) the server-side overwrite, which remains the real
    # guarantee regardless of what any particular form renders.
    #
    # `disabled` rather than `readonly`: tried `readonly` first, but in
    # practice a readonly text input renders visually identical to an
    # ordinary editable one in most browsers - it just silently refuses
    # keystrokes, which read as confusing/broken rather than "this isn't
    # meant to be edited". `disabled` gets the browser's built-in greyed-
    # out styling for free, at the cost of the field not being submitted
    # with the form - a non-issue, since the server-side recalculation
    # overwrites the field regardless of what (if anything) was submitted
    # for it.
    def edit_tag(view, tag_id, tag_name, custom_value, options={})
      if custom_value.customized.new_record?
        super
      else
        view.text_field_tag(
          tag_name, custom_value.value,
          options.merge(
            :id => tag_id,
            :disabled => true,
            :title => l(:text_decrementable_int_readonly_hint)
          )
        )
      end
    end

    private

    # A plain button_to - an ordinary HTML <form>, not a link with a
    # click handler - so it keeps working with JavaScript disabled, and
    # needs no CSRF token handling of its own (Rails' own form helpers
    # already embed one). All actual styling lives in
    # assets/stylesheets/custom_decrement_field.css (inlined into <head>
    # by Hooks - see that file's own comment for why) - only the
    # class name lives here, so this method has nothing to change the
    # next time the button's look needs adjusting.
    def decrement_button(view, issue, field, calculator)
      exhausted = calculator.exhausted?
      view.button_to(
        '−', # U+2212 MINUS SIGN - reads as a solid bar, unlike a plain hyphen
        view.decrement_issue_custom_field_path(issue_id: issue.id, custom_field_id: field.id),
        method: :post,
        disabled: exhausted,
        title: exhausted ? l(:error_custom_decrement_field_exhausted) : l(:button_custom_decrement_field_decrement),
        class: 'custom-decrement-field-button'
      )
    end
  end
end
