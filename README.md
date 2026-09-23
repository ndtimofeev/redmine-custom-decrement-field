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
- **The token grammar**: `TOKEN : <signed integer>`, optionally followed
  by a trailing literal - `TOKEN : -1 xyz123`. Every writer in this
  plugin (the seed, the decrement controller) now produces the spaced
  form consistently, but `StockCalculator#value`'s own regex stays
  permissive on both sides of the colon (`TOKEN:-1` still counts) so
  existing history, or a hand-typed comment, isn't silently excluded.
  The optional literal is free-form data made only of characters that
  never need percent-encoding in a URL (RFC 3986's "unreserved" set) -
  supplied by `POST .../decrement`'s optional `literal` param, and
  otherwise absent (this is all opt-in; nothing about the field's own
  behavior changes if no caller ever uses it). If a caller supplies one
  that already appears in this field's history
  (`StockCalculator#literal_used?`), the request short-circuits to "this
  already happened" (`error_custom_decrement_field_duplicate_literal`)
  instead of decrementing again - meant for exactly the kind of caller
  that can't always tell whether its own previous request actually
  landed (a network retry, a double-tap before a button could disable
  itself, the same code scanned twice within a moment of itself) and
  wants to say so explicitly rather than relying on being fast enough to
  avoid it.
- **Detecting an inconsistent history.** The safe path (button/controller)
  can never produce a negative value or a repeated `literal` on its own -
  both are only reachable by hand-editing or duplicating a comment
  directly. `StockCalculator#inconsistent?` treats a negative value and a
  duplicated literal as one single concept (deliberately not two separate
  ones to check/filter on) and is the one method everywhere in this
  plugin that answers "does this need a human to look at it":
  - A small warning marker appears right next to the field's own value
    (`DecrementableIntFormat#inconsistency_marker`) - purely a nudge,
    visible to anyone who can see the value at all (unlike the decrement
    button, it isn't gated on `add_issue_notes`).
  - A Wikipedia-"marked for deletion"-style banner renders above the
    issue's own content on its show page (`InconsistencyBannerHook`),
    naming the specific problem and, for a duplicated literal, linking to
    the exact comments involved via Redmine's own `#note-N` anchors -
    filtered through `Issue#visible_journals_with_index` so a link never
    points at a private note the current viewer isn't allowed to see.
    There is no hook that fires between the top of `#content` and the
    issue's own heading (verified against 6.0-stable source), so the
    banner actually renders via `view_layouts_base_body_top` - the only
    hook that fires above any of a page's own content at all, but that
    means literally the top of `<body>`, above Redmine's own top menu and
    header too. The partial renders it there `hidden`, then a small
    inline script moves it into `#content` (as the first child, ahead of
    the issue's own heading) and reveals it once `DOMContentLoaded` fires
    - `hidden` avoids a flash of the banner in the wrong place while the
    rest of the page is still loading. With JavaScript disabled the
    banner simply never appears; the marker next to the field's value,
    the row highlighting, and the query filter below are all still fully
    server-rendered and don't depend on it.
  - Affected issues get a `custom-decrement-field-inconsistent` CSS class
    on their row in list/query views (`IssueCssClassesPatch`, prepended
    onto `Issue#css_classes` - the same mechanism core itself uses for
    "overdue" rows).
  - A "Decrement field history is inconsistent" query filter
    (`IssueQueryPatch`) makes inconsistent issues findable directly.
    There's no column to filter on - the filter is registered via
    `add_available_filter`, and answered through Redmine's
    `sql_for_<name>_field` dynamic dispatch (verified against
    `Query#statement`/`Query#sql_for_field` in 6.0-stable source: this
    dispatch is checked *before* the generic, hardcoded per-operator
    path, so it needs no monkey-patching of that generic method to add a
    filter with no backing column at all). Since "inconsistent" can only
    be answered by scanning journal notes in Ruby, the filter computes
    the actual matching issue ids up front (scoped to issues the current
    user can already see, and to trackers that have a decrementable
    field at all) and turns that into a plain `id IN (...)`/`NOT IN
    (...)` clause - no caching, on purpose (consistent with this
    plugin's "no separate ledger" design throughout): this is meant for
    occasional auditing, not high-frequency access, so it starts as
    simple as possible and would only grow a cache if that ever proved
    too slow in practice. The "current user can already see" scope has to
    `.joins(:project)`: `Issue.visible_condition`'s SQL references
    `projects.status` directly (see `Project.allowed_to_condition`),
    assuming it's layered onto a scope that already joins `:project` the
    way `Query#issues`'s own generated SQL always does - without that
    join this 500s (an unqualified/missing-table column error, verified
    directly against a live instance).
  - Editing a comment's text through the web UI - including blanking it
    out entirely, which is how Redmine deletes one (see
    `JournalsController#update`) - normally patches just that comment's
    own bit of the page via JS, without a full reload, so none of the
    above (the marker, the button's state, the banner) update on their
    own until something re-renders the page. `InconsistencyRefreshHook`
    hangs a `window.location.reload()` off `view_journals_update_js_bottom`
    (fired from `app/views/journals/update.js.erb`, verified against
    6.0-stable source) whenever the edited journal's issue is on a
    tracker that has a decrementable field at all - not a more targeted
    "only if this comment's own text mentioned the token" check, since
    `Journal#notes_before_last_save` came back `nil` even right after a
    save that had visibly just changed `notes` (verified directly against
    a live instance) - rather than depend on that, this reloads on every
    comment edit/delete on such a tracker, and accepts the occasional
    unnecessary reload as the cost of not depending on a Journal dirty-
    tracking API that didn't behave as documented here.
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
- `lib/custom_decrement_field/issue_css_classes_patch.rb` - adds a CSS
  class to an inconsistent issue's row/box, wherever `Issue#css_classes`
  is consulted. A separate file from `issue_patch.rb` on purpose: it
  `prepend`s rather than `include`s, since overriding an existing method
  and calling `super` needs to sit above the class in the ancestor chain,
  which plain `include` (used by `issue_patch.rb`'s after_save hooks,
  which only ever add new methods) does not do.
- `lib/custom_decrement_field/issue_query_patch.rb` - adds the
  "inconsistent history" query filter to `IssueQuery`.
- `app/views/custom_decrement_field/_inconsistency_banner.html.erb` +
  `InconsistencyBannerHook` (in `hooks.rb`) - the banner rendered above
  an inconsistent issue's own content, and the script that moves it
  there from `view_layouts_base_body_top`'s actual render position.
- `InconsistencyRefreshHook` (in `hooks.rb`) - reloads the page after a
  comment edit/delete on a tracker with a decrementable field, so the
  marker/button/banner don't need a manual reload to catch up.
- `app/controllers/custom_decrement_field_controller.rb` - the
  decrement endpoint (always -1, refuses to act once already at or
  below zero, and now also refuses a duplicate of an already-recorded
  `literal` param - see "Design"). Unchanged from `main` otherwise: it
  still responds to both `html` (redirect back to the issue, used by
  this branch's plain `<form>` button) and `json` (used by `main`'s JS
  button).
- `DecrementableIntFormat#formatted_custom_value` (in
  `decrementable_int_format.rb`) - draws the "-1" button as part of the
  field's own HTML. `html` alone is not enough to tell this call apart
  from an issue *list* rendering this field as a column - an earlier
  version of this file claimed it was, based on misreading a core
  helper method, and the button did in fact leak into every row of any
  list/query showing this column until that was caught (see the
  method's own comment for the exact call chain: `column_content` in
  queries_helper.rb reaches this same method with `html=true`). The fix
  checks `view.controller`/`action_name` instead, since
  `render_half_width_custom_fields_rows` /
  `render_full_width_custom_fields_rows` - what actually draws the
  issue's own attribute rows - are only ever invoked from
  `IssuesController#show`.
  - CSV export, PDF export, and notification emails reach this method
    with `html=false` explicitly, so they're excluded regardless.
  - Unlike `main`, nothing here is injected into the page after the fact
    by JavaScript, so there's nothing that depends on JavaScript running
    at all in the visitor's browser.
- `assets/stylesheets/custom_decrement_field.css` +
  `lib/.../hooks.rb` - the button's actual styling (size, color, hover/
  disabled states) - kept out of `decrementable_int_format.rb` entirely,
  which only sets the `custom-decrement-field-button` class name and
  nothing else, so restyling the button never touches Ruby code. Reuses
  the same lesson `main` learned the hard way with its JS: the file is
  inlined into `<head>` as a `<style>` block by `Hooks.inline_stylesheet`
  rather than served through Redmine's plugin asset pipeline
  (`stylesheet_link_tag ..., plugin: ...`), which depends on `bin/rails
  assets:precompile` having actually been run. See the CSS file's own
  comment for why it needs to fight Redmine's default
  `input[type=submit]`/`button[type=submit]` styling specifically (that
  rule's fixed 28px height is what made the button look oversized and
  disrupt the row's layout in the first place).

## Known limitations / TODO

- This branch's button has not yet been tested against a real Redmine
  install the way `main`'s was - re-verify it (including on the mobile
  browser that motivated this branch) before relying on it. The
  underlying field mechanics (creation, seeding, derived value/history)
  are unchanged from `main`, where they are confirmed working. The
  note-deletion permission checkboxes' exact wording is the one thing
  from the original "verify this" list still worth double-checking
  against your specific version.
- The button's color (`#169`) is hardcoded to match Redmine's *default*
  theme link color, unlike `main`'s JS version, which sampled the
  active theme's actual link color at runtime via `getComputedStyle`
  (there is no equivalent trick available from plain CSS). On a custom
  theme with a different accent color, the button will keep working but
  may not match it exactly.
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
