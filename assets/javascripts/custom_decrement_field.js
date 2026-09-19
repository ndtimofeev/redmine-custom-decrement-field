// Adds a "-1" button next to a decrementable custom field's value on the
// issue view. See lib/custom_decrement_field/hooks.rb for why this is
// done with JavaScript after the page has already rendered, rather than
// by patching the core view partial that renders custom field rows.
(function () {
  document.addEventListener('DOMContentLoaded', function () {
    var configEl = document.getElementById('custom-decrement-field-config');
    if (!configEl) return; // not an issue page, or no decrementable field on this tracker

    var fields;
    try {
      fields = JSON.parse(configEl.dataset.fields || '[]');
    } catch (e) {
      return;
    }

    var csrfToken = document.querySelector('meta[name="csrf-token"]');

    fields.forEach(function (field) {
      // Redmine renders each custom field's row with a stable "cf_<id>"
      // class, keyed by the field's own database id. If a future
      // Redmine version changes that markup, this selector simply finds
      // nothing and the button never appears - a silent, harmless
      // degradation to "no button", rather than a broken page.
      var row = document.querySelector('.cf_' + field.id);
      if (!row) return;

      // The row is <div class="..._cf cf_<id> attribute"> containing a
      // "label" div and a "value" div (see Redmine's IssueFieldsRows).
      // Appending into .value specifically, rather than the row itself,
      // puts the button right after the number, on the same line, instead
      // of as a third block-level sibling below the label/value pair.
      var valueEl = row.querySelector('.value') || row;

      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'custom-decrement-field-button';
      button.textContent = '−'; // a plain hyphen renders too thin at this size; U+2212 MINUS SIGN reads as a solid bar
      button.disabled = field.exhausted;
      button.title = field.exhausted
        ? 'Already at zero (or below) - decrementing is disabled'
        : 'Decrement by 1';
      // No background/border/icon - just a bare, oversized glyph. Grey
      // rather than red once disabled, so the color itself hints that
      // clicking won't do anything, without relying on the tooltip.
      button.style.cssText =
        'background: none; border: none; padding: 0; margin-left: 0.35em;' +
        'font-size: 1.5em; font-weight: bold; line-height: 1; vertical-align: middle;' +
        'color: ' + (field.exhausted ? '#999' : '#c00') + ';' +
        'cursor: ' + (field.exhausted ? 'default' : 'pointer') + ';';

      button.addEventListener('click', function () {
        // Disable immediately on click, before the request even starts,
        // so a slow response (or a user double-clicking) can't fire a
        // second request from the same button before the first one's
        // result - and the resulting page reload - has come back.
        button.disabled = true;

        fetch(field.url, {
          method: 'POST',
          headers: Object.assign(
            { Accept: 'application/json' },
            csrfToken ? { 'X-CSRF-Token': csrfToken.content } : {}
          )
        })
          .then(function (response) { return response.json(); })
          .then(function (data) {
            if (data.error) {
              alert(data.error);
              button.disabled = false;
            } else {
              // A full reload is the simplest way to honestly reflect
              // every consequence of the decrement at once: the new
              // field value, the new comment in the activity feed, and
              // any automatic status change - rather than trying to
              // patch each of those into the DOM independently here.
              window.location.reload();
            }
          })
          .catch(function () {
            // Network failure or non-JSON response: re-enable so the
            // user can simply try again, instead of being stuck with a
            // permanently disabled button after a transient error.
            button.disabled = false;
          });
      });

      valueEl.appendChild(button);
    });
  });
})();
