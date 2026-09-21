# redmine-custom-decrement-field

A Redmine 6+ plugin: a custom field whose value can only be decreased,
via a button on the issue view. History and undo are handled through
ordinary issue comments, with no separate ledger table.

**Status: sketch.** This is a working example built out of a design
discussion, not a production-ready plugin. See "Known limitations / TODO"
below before relying on it for anything real.

**This branch (`server-rendered-button`) is an alternative to `main`'s
decrement button.** Everything about the field's design, storage, and
derivation is identical to `main` - the only difference is how the "-1"
button reaches the page. `main` draws it with JavaScript, injected into
the page after it has already rendered; see `main`'s README/git history
for that version. This branch instead renders the button as ordinary
server-side HTML, from inside `DecrementableIntFormat`'s own
value-formatting method - see "Structure" below for exactly why that's
safe to do without leaking a button into issue lists, CSV/PDF export, or
notification emails. It exists because the JS version turned out to be
fragile in practice - most recently, it was found to not appear at all in
at least one mobile browser, for a reason that couldn't be pinned down
without device access. A plain server-rendered `<form>` button has no
separate script to fail to load or execute, on any browser, at the cost
of a full page reload on click instead of an in-place AJAX update.

## Design

- The field is a real, distinct entry in the custom field Format
  dropdown - "Decrementable integer" - registered as
  `CustomDecrementField::DecrementableIntFormat`, a subclass of
  Redmine's own `Redmine::FieldFormat::IntFormat`. Because it inherits
  from the built-in Integer format rather than reimplementing it, it
  behaves identically to a plain integer everywhere Redmine cares
  (query filters, sorting, totals, CSV/PDF export). If the plugin is
  ever disabled, `Redmine::FieldFormat.find` falls back to a generic
  built-in format (verified against Redmine 6.0-stable source): the
  field keeps working everywhere issue values are shown or edited, just
  as a plain text-like value (numeric sort/filter/totals are the only
  casualty) - it does not crash anywhere. The one place the plugin's
  absence is enforced is Administration &rarr; Custom fields: Redmine
  refuses to re-save a field's *own* definition while its format is
  unregistered, until you pick a different format there.
- Per-field settings (the token to look for, and an optional status the
  issue should move to once the counter reaches zero) are not stored in
  a table owned by this plugin. They're declared as `format_store`
  attributes (`field_attributes :decrement_token, :zero_status_id` in
  `DecrementableIntFormat`) - the same built-in per-format storage
  mechanism core uses for e.g. Numeric's thousands separator or
  Version's status filter - and rendered right on the field's own admin
  edit form via `form_partial`. No plugin-owned schema at all.
- The field's value is **always derived**: it equals the sum of every
  signed number tagged with the field's token across the issue's
  comments, including the very first entry - "how many units did we
  start with". There is no separate field for the initial quantity:
  whatever number a user types into the field on issue creation is
  automatically turned into that first comment
  (`IssuePatch#custom_decrement_field_seed`), and from that point on the
  field never accepts direct input again. This is enforced twice, on
  purpose: `DecrementableIntFormat#edit_tag` renders the field
  `readonly` on every save after creation (so the form itself doesn't
  invite editing it), and `IssuePatch#custom_decrement_field_recalculate`
  silently overwrites whatever was submitted anyway on every save - the
  second one is the real guarantee, the first is just honest UI.
- No dedicated permission is introduced for decrementing. It reuses
  Redmine's own `add_issue_notes` permission, since a decrement is
  nothing more than a specially formatted comment. Undoing a mistaken
  decrement is just editing or deleting that comment, using Redmine's
  ordinary note permissions - the recalculation happens automatically.
- The field is excluded from bulk edit (`self.bulk_edit_supported =
  false`): a bulk-set value would just be overwritten by the next
  recalculation like any other direct edit, so there's no point
  offering it there.
- Once the value reaches zero (or drops below it - which can only happen
  by hand-editing a comment, bypassing the button), the decrement button
  becomes unavailable. A negative value is not clamped to zero for
  display - it's shown as-is, since it's a visible signal that the
  history was edited outside of the normal flow.

## Installation

These steps assume a working Redmine 6.x installation you can already
run `bundle` and restart, with shell access to its `plugins/` directory.

1. **Clone the plugin** directly into Redmine's `plugins/` directory,
   under the name `redmine_custom_decrement_field` (Redmine identifies
   plugins by the `Redmine::Plugin.register` call in `init.rb`, but it's
   still conventional - and expected by some tooling - for the directory
   name to match):

   ```bash
   cd /path/to/redmine/plugins
   git clone https://github.com/ndtimofeev/redmine-custom-decrement-field redmine_custom_decrement_field
   ```

2. **Install dependencies and restart Redmine** from the Redmine root:

   ```bash
   cd /path/to/redmine
   bundle install
   bin/rails redmine:plugins:migrate   # harmless no-op: this plugin ships no migrations
   sudo systemctl restart redmine      # or however your instance is normally restarted/passenger-touched
   ```

   Confirm it loaded: Administration &rarr; Plugins should now list
   "Custom Decrement Field".

3. **Create the custom field**: Administration &rarr; Custom fields
   &rarr; New custom field &rarr; choose "Issues" as the object, then
   pick **"Decrementable integer"** directly from the Format dropdown
   (it's a real option now, not a step performed after the fact). Give
   it a name, attach it to the tracker(s) it should appear on, and fill
   in the two extra fields this format adds to the form: a **Token**
   (a short keyword such as `MATSTOCK` - pick something that reads
   naturally, since it will show up in the comment history) and,
   optionally, a **Status on reaching zero**.

4. *(Optional, cosmetic)* Note that the Format dropdown itself is
   disabled by Redmine once the field exists, so there's no "convert
   this field back to a plain integer" option through the normal UI -
   by design, this plugin doesn't need one either (see "Known
   limitations" for why a fallback conversion action wasn't built).

5. **Verify it works**: create a new issue on that tracker, type a
   number into the field, and save. The issue's history should show a
   comment containing your token, and the field should still show the
   same number; opening the issue again for editing, the field should
   now render read-only. Open the issue's own page - you should see a
   "&minus;1" button next to the field; click it and confirm the field
   decreases by one and a new comment appears. Decrement it down to
   zero and confirm the button becomes disabled.

## Structure

- `lib/custom_decrement_field/decrementable_int_format.rb` - registers
  the "Decrementable integer" format, its per-field settings, and the
  read-only editing behavior.
- `app/views/custom_fields/formats/_decrementable_int.html.erb` - the
  Token / Status-on-zero fields shown on the custom field's own admin
  edit form.
- `lib/custom_decrement_field/token_config.rb` - reads a decrementable
  field's token/zero-status settings.
- `lib/custom_decrement_field/stock_calculator.rb` - computes the
  current value from comment history.
- `lib/custom_decrement_field/issue_patch.rb` - seeds the first history
  entry on issue creation, and recalculates the field (plus the
  zero-status transition) on every save.
- `lib/custom_decrement_field/journal_patch.rb` - triggers a
  recalculation whenever a comment is added, edited, or deleted.
- `app/controllers/custom_decrement_field_controller.rb` - the
  decrement endpoint (always -1, refuses to act once already at or
  below zero). Unchanged from `main`: it still responds to both `html`
  (redirect back to the issue, used by this branch's plain `<form>`
  button) and `json` (used by `main`'s JS button).
- `DecrementableIntFormat#formatted_custom_value` (in
  `decrementable_int_format.rb`) - draws the "-1" button as part of the
  field's own HTML. This is only safe to do here, and doesn't leak the
  button into every place the value is ever shown, because of exactly
  how Redmine calls this method (verified against 6.0-stable source,
  full reasoning in the method's own comment):
  - the issue's own show page is the *only* call site that reaches this
    method with `html=true` for an Issue custom field;
  - issue list/query columns never call it at all for an integer-backed
    field - the value is already cast to a plain Ruby `Integer` before
    the generic renderer sees it, bypassing the custom field format
    entirely;
  - CSV export, PDF export, and notification emails do reach this
    method, but always with `html=false` explicitly.
  - There is no equivalent of `main`'s `hooks.rb` /
    `assets/javascripts/custom_decrement_field.js` /
    `view_layouts_base_body_bottom` hook on this branch - nothing is
    injected after the fact, so there's nothing that depends on the
    plugin asset pipeline or on JavaScript running at all.

## Known limitations / TODO

- This branch's button has not yet been tested against a real Redmine
  install the way `main`'s was - re-verify it (including on the mobile
  browser that motivated this branch) before relying on it. The
  underlying field mechanics (creation, seeding, derived value/history)
  are unchanged from `main`, where they are confirmed working. The
  note-deletion permission checkboxes' exact wording is the one thing
  from the original "verify this" list still worth double-checking
  against your specific version.
- The button's styling is minimal/unstyled for now (see `TODO.md`) -
  `main`'s JS version had gone through several rounds of cosmetic
  polish (a small outlined circle sampling the theme's own link color)
  that has no equivalent here yet, since there is no client-side script
  left to sample anything with.
- No automated tests yet.
- The decrement amount is hardcoded to 1 (`DECREMENT_AMOUNT` in the
  controller). Arbitrary amounts are only possible by hand-editing a
  comment's text, deliberately not exposed anywhere in the UI - see the
  concurrency note in the controller's comments for why.
- A QR-code scanner was deliberately kept out of this plugin. It was
  discussed as a separate, independent plugin with its own contract (a
  scanned code is just a plain issue URL) and was never added here.
- Falling back to Redmine's generic `Base` format (rather than literally
  back to plain `int`) when the plugin is removed was an accepted
  trade-off, not an oversight: it costs numeric filtering/sorting/totals
  on affected fields until the plugin comes back, but was judged not
  worth a dedicated "convert back to int" action, since Redmine disables
  the format dropdown for existing fields anyway (any such action would
  need its own admin screen, not the standard form).
- Saved custom queries that filter on this field are expected to mostly
  keep working after the plugin is removed - Redmine's filter SQL
  generation dispatches mainly on the operator, not the field's current
  type - but this hasn't been confirmed hands-on against a live saved
  query yet.
- Unlike `main`'s JS button, this branch's button text/tooltip go
  through Redmine's own i18n system (`button_custom_decrement_field_decrement`,
  `error_custom_decrement_field_exhausted` in `config/locales/`), since
  it's now rendered by Ruby view code rather than a script with no
  access to `l()`.
