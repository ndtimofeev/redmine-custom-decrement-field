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
- Per-field settings (the two keywords to look for, and an optional status
  the issue should move to once the counter reaches zero) are not stored in
  a table owned by this plugin. They're declared as `format_store`
  attributes (`field_attributes :increment_token, :decrement_token,
  :zero_status_id` in `DecrementableIntFormat`) - the same built-in per-format storage
  mechanism core uses for e.g. Numeric's thousands separator or
  Version's status filter - and rendered right on the field's own admin
  edit form via `form_partial`. No plugin-owned schema at all.
- The field's value is **always derived**: it equals everything added minus
  everything written off across the issue's comments, including the very
  first entry - "how many units did we start with". There is no separate
  field for the initial quantity. A number may be typed straight into the
  field in exactly two situations, and in both it is automatically turned
  into that first comment under the add keyword (`PRIHOD : 15`):
  - on the New Issue form (`IssuePatch#custom_decrement_field_seed`);
  - on the ordinary edit form of an issue whose field **has no history at
    all** - a ticket created without an amount, or whose only entry was
    deleted (`IssuePatch#custom_decrement_field_seed_on_update`). The entry
    is appended to the edit's own journal, so one history item holds the
    user's comment (if any), the `PRIHOD : N` line, and core's "Stock set to
    N" detail. Only a changed, nonzero value counts, and the usual Redmine
    permissions and workflow field rules apply, since this is a plain edit.

  From the first entry on, the field never accepts direct input again. This
  is enforced twice, on purpose: `DecrementableIntFormat#edit_tag` renders
  the input `disabled` once the field has history (so the form itself
  doesn't invite editing it), and `IssuePatch#custom_decrement_field_recalculate`
  silently overwrites whatever was submitted anyway on every save - the
  second one is the real guarantee, the first is just honest UI. A field
  with no history shows an ordinary enabled input with a tooltip saying what
  typing there does; the issue page itself shows no "+" or entry form for it
  (an inline "+" form existed briefly in the history of this branch and was
  replaced by this).
- **Two keywords, one grammar**: `KEYWORD : <amount> [literal]`, where
  KEYWORD is the field's **add keyword** (`PRIHOD : 10` adds ten) or its
  **write-off keyword** (`RASHOD : 1` writes one off). The keyword alone
  decides the direction, so the amount is always written as a plain positive
  number, and any sign typed in front of it is ignored - `RASHOD : -1` still
  writes one off and never adds one back, so a habit from when the single
  token was signed can't silently flip a write-off into an addition. Both
  keywords are required and must differ (a field missing one, or with the
  same word for both, is treated like a field the plugin has never heard of;
  saving such a pair is refused in the admin form). `PRIHOD`/`RASHOD` are
  just the suggested words (the form's placeholders); pick whatever reads
  naturally - the words show up in the comment history. Latin is safer than
  Cyrillic for the same look-alike reason as the multiplier keyword below.
  Every writer in this plugin produces the spaced form (`TOKEN : 1`), but the
  parser stays permissive about the colon's whitespace (`RASHOD:1` counts).
  The initial amount typed on a new issue is recorded under the add keyword.
  - `StockCalculator#entries` is the one place that knows this grammar;
    the value, the duplicate check and the inconsistency check are all
    derived from it.
  - The optional literal is free-form data made only of characters that
    never need percent-encoding in a URL (RFC 3986's "unreserved" set) -
    supplied by `POST .../decrement`'s optional `literal` param, and
    otherwise absent (this is all opt-in). It has to sit on the **same
    line** as the amount and be followed by whitespace or the end of the
    text; a word on the next line is not a literal. If a caller supplies
    one that already appears in this field's history
    (`StockCalculator#literal_used?`), the request short-circuits to "this
    already happened" (`error_custom_decrement_field_duplicate_literal`)
    instead of writing off again - meant for exactly the kind of caller
    that can't always tell whether its own previous request actually
    landed (a network retry, a double-tap before a button could disable
    itself, the same code scanned twice within a moment of itself). One
    namespace across both keywords, so a delivery-note number used as the
    literal of an addition (`PRIHOD : 5 delivery-42`) is protected the same
    way.
  - Recalculation reads the history as it is *now*. Core's `create_journal`
    builds the journal with `journalized: self` and `has_many_inversing` is
    off, so a `journals` association already loaded on the issue - the
    decrement controller loads it to check the current value before writing -
    doesn't contain the journal the very same save just created. Computing
    from that cache left the stored value one entry behind (and the
    zero-status transition one entry late), so the recalculation starts by
    dropping it (`journals.reset`).
  - **Migrating a field that has only the old single token.** That token is
    now the write-off keyword, and the field stays inert (no button, no
    recalculation) until the add keyword is filled in too. Old history is
    *not* reinterpreted for you: lines written under the old token as
    `TOKEN : -1` keep counting as write-offs (the sign is ignored), but the
    old positive lines - typically the initial amount - would now count as
    write-offs as well, so edit those comments to start with the new add
    keyword. Nothing is recomputed when the field is saved; each issue picks
    the new meaning up on its next save or comment.
- **The status on reaching zero is a system transition, not a user one.**
  When the value crosses from positive to zero or below, the issue is moved
  to the field's configured status without going through the workflow (it
  would otherwise depend on whoever happened to write the last unit off
  being allowed that transition). Redmine's statuses are global, though - a
  status belongs to a tracker only by appearing in its workflow - so before
  moving anything `StatusTransition.blocker` asks whether the move makes sense
  for *this* ticket, and the transition is **skipped** (the value still
  changes, and the write-off still succeeds) when:
  - the status is not in the ticket's tracker's workflow (nor its default
    status): the ticket would land where nobody can move it out, and a later
    restock would not bring it back, since the transition fires only on the
    crossing;
  - the status is a closed one and the ticket has open subtasks or is blocked
    by another issue (core's `closable?`);
  - the status is an open one, the ticket is closed, and it is a subtask of a
    closed parent (core's `reopenable?`).

  A skipped transition writes one line to the Rails log naming the issue,
  the field and the reason, and is not retried when the cause is fixed later.
  It also shows up on the ticket as an inconsistency
  (`StockCalculator#zero_status_problem`, below) - derived from the current
  state each time rather than remembered when the transition was skipped, so
  it clears by itself once the cause is gone. It is reported only for a
  ticket that has recorded stock, now used up, whose zero status it is not in
  and could not be moved to; a ticket at zero whose zero status *would* be
  accepted is not flagged, since it is either waiting or was moved elsewhere
  on purpose, and a ticket that never had any stock is not flagged either.
  The field's admin form warns about the misconfigurations that can be seen
  there: a status missing from the workflow of any tracker the field is
  attached to (listing them), and a status id that no longer exists. Neither
  blocks saving - the workflow may legitimately be edited afterwards.
  Because the transition bypasses core's callbacks, the two things core would
  have done on a status change are repeated by hand: `closed_on` (set when
  the ticket goes from open to closed) and, on instances that derive the done
  ratio from the status, `done_ratio`. A parent's derived dates/ratio are not
  recalculated by this move (that only happens in a real `Issue#save`).
  One status per field is deliberate; a status per tracker was considered and
  put off - it would live in `format_store` as a tracker-id-to-status-id map,
  with the single status as the default for trackers without an entry.
- **Detecting an inconsistent field.** The safe path (button/controller)
  can never produce a negative value or a repeated `literal` on its own -
  both are only reachable by hand-editing or duplicating a comment
  directly. A third kind of trouble has nothing to do with the history: the
  stock is used up but the ticket could not be moved to the field's zero
  status (see the previous point), so it sits in a status that says
  otherwise - and the same for a watchdog whose trigger status can't be
  applied (see the watchdog). `StockCalculator#inconsistent?` treats all of these as one
  single concept (deliberately not separate ones to check/filter on) and is
  the one method everywhere in this plugin that answers "does this need a
  human to look at it":
  - A small warning marker appears right next to the field's own value
    (`DecrementableIntFormat#inconsistency_marker`) - purely a nudge,
    visible to anyone who can see the value at all (unlike the decrement
    button, it isn't gated on `add_issue_notes`).
  - A Wikipedia-"marked for deletion"-style banner renders above the
    issue's own content on its show page (`InconsistencyBannerHook`),
    naming the specific problem - including, for the zero-status kind, why
    the move can't be made (the status isn't in this tracker's workflow, the
    ticket has open subtasks or a blocker, it is a subtask of a closed parent,
    or the configured status no longer exists) - and, for a duplicated literal, linking to
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
  - A "Decrement field is inconsistent" query filter
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
- **Stock kept as several child tickets: the sum field** (`decrement_sum`
  format, `SumFormat`). A parent ticket (Redmine's native parent/child, direct
  children only) shows the total of its children's decrementable field. The
  value is always derived and never typed (`edit_tag` is disabled), but - like
  the decrementable field itself - it is persisted in `custom_values`, so
  filters, sorting, CSV and the watchdog below treat it as an ordinary number.
  - Per-field settings (`format_store`): `source_field_id` (which
    decrementable field of the children to add up) and an optional
    `multiplier_token`.
  - **Per-child multipliers live in the parent's comments**, same philosophy
    as everything else here (history in comments, nothing separate to drift):
    `PACK : #57 : 0,5 bottle 0.5 l, 12 to a box` makes child #57 count 0.5 per
    unit. The grammar is `TOKEN : #<child id> : <multiplier> [comment]`: the
    multiplier takes a point or comma decimal, and everything after it to the
    end of the line is a free-form note for the storekeeper that the system
    never interprets - the pattern consumes it, so text inside it that looks
    like another declaration is not picked up as one. `PACK` is only the
    suggested keyword (the admin form's placeholder); it is a per-field
    setting and nothing in the plugin hardcodes it. Latin on purpose:
    Cyrillic look-alikes (A/A, C/C, P/P, X/X) are typed by mistake and read
    identically, which would silently turn a declaration off. Only the parent
    knows how a child's whole units add up
    in the parent's unit (20 bottles of solvent may be wanted in liters, kg
    or pounds - add one sum field per unit, each with its own token, e.g.
    `PACK_L` and `PACK_KG`; a token only matches when followed by the colon,
    so neither is taken for the other). A
    child nobody mentions counts x1. The last declaration for a child wins -
    it's a current fact, not an event like a decrement - so, unlike a
    duplicated decrement literal, repeating one is not an inconsistency.
  - `SumCalculator` is a pure function (children's stored counts x
    multipliers, rounded to 2 places, computed in BigDecimal).
    `SumRecalculation` writes the result back and, like `IssuePatch`, only
    ever saves the one `CustomValue` row - never the Issue - to stay clear of
    optimistic-locking trouble.
  - Recalculation is driven from the same place as the decrementable field:
    every issue save and every comment change already runs
    `custom_decrement_field_recalculate_all`, which now also refreshes the
    issue's own sum fields (its comments carry the multipliers) and its
    parent's (its count is one of the terms). Two extra hooks cover a child
    moved to another parent (the old parent is refreshed) and a destroyed
    child.
  - Those triggers are all events on *issues*. Adding the field to a tracker
    that already has parents, re-attaching it, or changing its source field
    or multiplier token is an event on the *field*, which they never see -
    existing parents would show an empty value until someone touched them.
    `CustomFieldPatch` therefore recomputes the field for every issue of its
    trackers whenever it is saved.
- **The watchdog** (`watchdog` format, `WatchdogFormat`). A plain editable
  Float - the critical level - plus two settings: `watched_field_id`, which
  other numeric field of the same issue it watches (Integer, Float,
  decrementable or sum), and an optional `trigger_status_id` (below). The association is kept on the watchdog, not on the
  watched field, so any numeric field can be watched. Whenever the watched
  value is at or below the watchdog's (`<=`), the issue gets a
  `custom-decrement-field-low` CSS class (`IssueCssClassesPatch`) and is
  highlighted in lists and on its own page. `WatchdogCheck` only compares two
  already-stored numbers; nothing is recomputed and no flag is persisted.
  - Stays silent for: a closed issue, an empty threshold (that disables the
    watchdog), an empty watched value, a watched field that was deleted, or
    one not attached to the issue's tracker.
  - Deliberately a dedicated class and not core's `overdue`: every `overdue`
    rule in core CSS only colors the due-date cell/value, so the class would
    show nothing on a ticket that has no due date (and `overdue?` is only
    consulted for CSS and Gantt - `Mailer.reminders` filters on `due_date`
    in SQL and never calls it).
  - **Optional statuses: when it triggers, and when it stops.** With a "status
    when triggered" set, the ticket is moved to it at the moment the watchdog
    *starts* barking, once; with a "status when back to normal" set, at the
    moment the watched value rises above the level again. It is the same edge
    the zero-status transition fires on, and the same system move
    (`StatusTransition`: outside the workflow, skipped when the status is not
    in the tracker's workflow or the ticket can't be closed/reopened, with
    `closed_on` set by hand; the field's admin form warns about the same
    misconfigurations for both settings). Every new crossing fires - not "once
    per ticket": below the level, up again, below again moves the ticket
    three times. Not fired: for a ticket that is already below its level, one
    moved elsewhere by hand afterwards (a later manual choice stands), a ticket
    being created, and any **closed** ticket - closing makes a watchdog stop
    barking without anything having recovered, so the comparison is on the
    numbers (`WatchdogCheck.reached_fields`), not on "barking", and a closed
    ticket is simply not moved. The release is unconditional otherwise: it
    moves the ticket whatever status it is in now (somebody having put it in
    "ordered" in the meantime does not stop it), and also when the ticket was
    never moved by the trigger (it was created below its level, or the level
    was lowered).
    Because the barking itself remembers nothing, "starts" and "stops" are found
    by comparing which watchdogs are at or below their level before and after
    something changed the numbers (`WatchdogTransition`): around a save
    (`IssuePatch` takes the "before" in a `before_save`, as core only writes
    the edit's custom values afterwards - this covers editing the level or a
    plain watched field, a comment, and the recalculations), around a comment
    edited or deleted on its own, and around a parent's sum being rewritten
    because a child changed (`SumRecalculation.refresh_parent` - the parent
    isn't being saved at all). The backfill that runs when a sum field is
    saved deliberately does not fire. One move per call: a trigger comes
    before a release, and within each the first watchdog (by field order)
    whose status is allowed. A new parent starts out with a stored sum of 0, so
    it is "below" any level from the start (and highlighted) without firing;
    the first child that lifts the sum above the level makes it stop barking,
    which moves it to the release status if there is one.
  - **Concurrency.** Two children of one parent changing at the same moment
    would each recompute the parent's sum without the other's change, and the
    later write would win (a lost update, independent of any status). So
    `refresh_parent` locks the parent's row (`SELECT ... FOR UPDATE`) before
    reading and recomputing it; the second change waits for the first to commit
    and then sees its result. The move itself is a compare-and-set
    (`UPDATE ... WHERE status_id = <the status the caller saw>`): if two
    requests notice the same crossing, only one moves the ticket and writes the
    journal entry. The compare-and-set is covered by a deterministic check; the
    lock has **not** been exercised under real concurrency (the development
    instance runs SQLite, which serializes writers and ignores the lock), and
    on MySQL's default REPEATABLE READ the children's later plain SELECTs can
    still come from an older snapshot.
  - A watchdog that is barking while its trigger status can't be applied
    (missing from the workflow, open subtasks/blocker, a subtask of a closed
    parent, status deleted) makes the ticket count as inconsistent, like the
    zero-status case (`WatchdogCheck.status_problems`): banner with the
    reason, row highlight, query filter - derived each time, so it clears once
    the cause is fixed. The release side is reported only for a ticket still
    sitting in the watchdog's trigger status although the watchdog no longer
    barks and the release status can't be applied: without a memory of
    attempts, that is the one place "stuck" can be told from "never moved".
  - Passive otherwise, like the rest: it shows up for whoever opens a list or
    the ticket. There is no notification when the level is crossed (see TODO).
- Both new formats render whole values without a fractional part
  (`WholeNumberDisplay`): core formats every Float with `'%.2f'`, so 50 would
  show as "50.00". Handing `format_object` an Integer instead takes its
  Integer branch, which keeps the thousands-delimiter setting working.
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
   in the extra fields this format adds to the form: an **Add keyword**
   and a **Write-off keyword** (short, different words such as `PRIHOD` and
   `RASHOD` - pick something that reads naturally, since they show up in
   the comment history) and, optionally, a **Status on reaching zero**.

   Two core Redmine defaults that make a new field look like it "isn't
   displayed anywhere", and apply to every custom field, this plugin's or
   not: a new issue field is **not** "For all projects" until you tick that
   box (otherwise enable it per project under Settings &rarr; Issue tracking),
   and it is not offered as a query filter until "Used as a filter" is ticked.
   For the sum and watchdog fields, also attach them to the parent tracker
   (and the watchdog and the field it watches to the *same* tracker).

4. *(Optional, cosmetic)* Note that the Format dropdown itself is
   disabled by Redmine once the field exists, so there's no "convert
   this field back to a plain integer" option through the normal UI -
   by design, this plugin doesn't need one either (see "Known
   limitations" for why a fallback conversion action wasn't built).

5. **Verify it works**: create a new issue on that tracker, type a
   number into the field, and save. The issue's history should show a
   comment like `PRIHOD : <your number>`, and the field should still show the
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
  Add keyword / Write-off keyword / Status-on-zero fields shown on the
  custom field's own admin edit form.
- `lib/custom_decrement_field/token_config.rb` - reads a decrementable
  field's two keywords and zero-status setting (and builds the notes the
  plugin writes).
- `lib/custom_decrement_field/stock_calculator.rb` - computes the
  current value from comment history.
- `lib/custom_decrement_field/issue_patch.rb` - seeds the first history
  entry (on issue creation, and on an edit while the field has no history),
  and recalculates the field (plus the zero-status transition) on every
  save.
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
- `lib/custom_decrement_field/sum_format.rb`, `sum_config.rb`,
  `sum_calculator.rb`, `sum_recalculation.rb` +
  `app/views/custom_fields/formats/_decrement_sum.html.erb` - the sum field:
  format and its admin-form partial, settings reader, the calculation, and
  writing the result back.
- `lib/custom_decrement_field/custom_field_patch.rb` - recomputes a sum field
  for all issues of its trackers when the field itself is saved.
- `lib/custom_decrement_field/watchdog_format.rb`, `watchdog_config.rb`,
  `watchdog_check.rb` + `app/views/custom_fields/formats/_watchdog.html.erb` -
  the watchdog: format and its admin-form partial, the watched-field lookup,
  and the "has it reached its level" check used by `css_classes`.
- `lib/custom_decrement_field/status_transition.rb` - moving a ticket to a
  status on the plugin's own initiative: whether it may (workflow membership,
  closable / reopenable - also what the admin forms warn about) and the move
  itself. Shared by the zero status and the watchdog's two statuses.
- `lib/custom_decrement_field/watchdog_transition.rb` - fires the watchdog's
  trigger status when a watchdog starts barking and its release status when it stops (before/after comparison).
- `app/views/custom_decrement_field/_status_setting_warning.html.erb` - the
  red notes under a status setting on a field's admin form.
- `lib/custom_decrement_field/whole_number_display.rb` - shared display
  tweak for both new formats.
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
- Sum and watchdog are drafts verified against a live Redmine 6.0-stable
  instance through the model layer and the admin/issue pages (children added,
  re-weighted, decremented, moved between parents, destroyed; threshold
  crossed in both directions) - not yet by hand in a browser the way the
  decrement button was. Closed-issue silence is implemented but was not
  exercised.
- `IssueCssClassesPatch` now reads `available_custom_fields` and custom
  values for every row of a list. Whether core preloads those is unchecked -
  a possible N+1 to look at if lists with many rows feel slow.
- A sum field must not be marked required: it is always disabled in the
  issue form, so the requirement could never be satisfied. Its disabled input
  in the edit form shows the raw stored string (e.g. "0.0").
- Not done yet, on purpose: a notification when a watchdog's level is crossed
  (`WatchdogTransition.fire` is now the one place that knows a watchdog just
  started barking, so that is where it would hook in), and a warning on a
  parent when some of its
  children have an inconsistent history (their contribution can't be fully
  trusted).
- No automated tests yet.
- The decrement amount is hardcoded to 1 (`DECREMENT_AMOUNT` in the
  controller). Arbitrary amounts are only possible by hand-editing a
  comment's text, deliberately not exposed anywhere in the UI - see the
  concurrency note in the controller's comments for why.
- The QR scanner plugin's inspector decides "inconsistent" on its own, from
  the journals alone (it deliberately shares no code with this plugin), so it
  does not know the zero-status kind of inconsistency: it flags a negative
  value and a duplicated literal, but not a ticket stuck outside its zero
  status.
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
