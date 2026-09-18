# redmine-custom-decrement-field

A Redmine 6+ plugin: a custom field whose value can only be decreased,
via a button on the issue view. History and undo are handled through
ordinary issue comments, with no separate ledger table.

**Status: sketch.** This is a working example built out of a design
discussion, not a production-ready plugin. See "Known limitations / TODO"
below before relying on it for anything real.

## Design

- The field itself is a completely ordinary Redmine custom field
  (`int`), with no custom `field_format` registered for it. If the
  plugin is ever disabled, the field just becomes a plain integer field
  showing whatever value was last computed - nothing breaks.
- The field's value is **always derived**: it equals the sum of every
  signed number tagged with a keyword (a "token") across the issue's
  comments, including the very first entry - "how many units did we
  start with". There is no separate field for the initial quantity:
  whatever number a user types into the field on issue creation is
  automatically turned into that first comment
  (`IssuePatch#custom_decrement_field_seed`), and from that point on the
  field never accepts direct input again - any attempt to edit it by
  hand is silently overwritten on the very next recalculation
  (`IssuePatch#custom_decrement_field_recalculate`).
- Configuration (the token to look for, and an optional status the issue
  should move to once the counter reaches zero) is not stored in a table
  owned by this plugin at all - it lives inside the `description` of the
  custom field itself. See `lib/custom_decrement_field/token_config.rb`
  for the reasoning. The plugin's own settings page doesn't persist
  anything; it's just a small helper that generates that description
  string for you.
- No dedicated permission is introduced for decrementing. It reuses
  Redmine's own `add_issue_notes` permission, since a decrement is
  nothing more than a specially formatted comment. Undoing a mistaken
  decrement is just editing or deleting that comment, using Redmine's
  ordinary note permissions - the recalculation happens automatically.
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

3. **Create the custom field** that you want to make decrementable:
   Administration &rarr; Custom fields &rarr; New custom field &rarr;
   choose "Issues" as the object, format "Integer". Give it whatever
   name and default value you like, and attach it to the tracker(s) it
   should appear on.

4. **Generate the configuration marker**: Administration &rarr; Plugins
   &rarr; Custom Decrement Field &rarr; Configure. Fill in a token
   (a short keyword such as `MATSTOCK`) and, optionally, the status the
   issue should be moved to once the field reaches zero. Copy the
   generated `<!-- custom-decrement-field: ... -->` line.

5. **Paste that line into the custom field's own description**:
   go back to the custom field created in step 3 (Administration &rarr;
   Custom fields &rarr; your field) and append the copied line to the
   end of its "Description" text. The rest of the description can stay
   whatever human-readable help text you want - only the HTML comment
   itself is machine-read.

6. *(Optional, cosmetic)* Make the field read-only through
   Administration &rarr; Workflow &rarr; field permissions, for every
   status except the tracker's initial one. This is purely a UI hint so
   users aren't tempted to type into a field that won't keep their
   input - the actual guarantee that the field can't be changed by hand
   comes from the code itself (`IssuePatch#custom_decrement_field_recalculate`),
   not from this setting.

7. **Verify it works**: create a new issue on that tracker, type a
   number into the field, and save. The issue's history should show a
   comment containing your token, and the field should still show the
   same number. Open the issue again - you should see a "&minus;1"
   button next to the field; click it and confirm the field decreases by
   one and a new comment appears. Decrement it down to zero and confirm
   the button becomes disabled.

## Structure

- `lib/custom_decrement_field/token_config.rb` - parses/builds the
  configuration marker stored in a field's description.
- `lib/custom_decrement_field/stock_calculator.rb` - computes the
  current value from comment history.
- `lib/custom_decrement_field/issue_patch.rb` - seeds the first history
  entry on issue creation, and recalculates the field (plus the
  zero-status transition) on every save.
- `lib/custom_decrement_field/journal_patch.rb` - triggers a
  recalculation whenever a comment is added, edited, or deleted.
- `app/controllers/custom_decrement_field_controller.rb` - the
  decrement endpoint (always -1, refuses to act once already at or
  below zero).
- `assets/javascripts/custom_decrement_field.js` + `lib/.../hooks.rb` -
  the "-1" button, drawn in by JavaScript on top of the field's normal
  markup, without patching any core view partial.

## Known limitations / TODO

- Not yet verified against a real Redmine 6.x install - the exact hook
  name (`view_layouts_base_body_bottom`), the custom field row's CSS
  class (`cf_<id>`), and the exact wording of the note-deletion
  permission checkboxes should all be double-checked against your
  specific version.
- No automated tests yet.
- The decrement amount is hardcoded to 1 (`DECREMENT_AMOUNT` in the
  controller). Arbitrary amounts are only possible by hand-editing a
  comment's text, deliberately not exposed anywhere in the UI - see the
  concurrency note in the controller's comments for why.
- A QR-code scanner was deliberately kept out of this plugin. It was
  discussed as a separate, independent plugin with its own contract (a
  scanned code is just a plain issue URL) and was never added here.
- The settings page doesn't persist any state - that's intentional (see
  "Design" above), but it does look unlike a typical Redmine settings
  page, which normally has something to save.
- User-facing strings in `assets/javascripts/custom_decrement_field.js`
  (the button's tooltip text) are hardcoded in English rather than
  going through Redmine's i18n system, unlike the controller's
  `error_custom_decrement_field_exhausted` / `notice_custom_decrement_field_decremented`,
  which are already translatable (see `config/locales/`).
