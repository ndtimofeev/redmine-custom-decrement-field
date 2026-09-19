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

    // Redmine's link color isn't a fixed, guessable value - it depends on
    // whichever theme is active. Rather than hardcode a hex that would be
    // right for one theme and wrong for the next, sample it straight off
    // an actual link already on the page (there's always at least one -
    // the top menu, breadcrumb, etc.), so this always matches whatever
    // the current theme really uses.
    function redmineLinkColor() {
      var probe = document.querySelector('#top-menu a, #main-menu a, #content a, a');
      return probe ? getComputedStyle(probe).color : '#c00';
    }

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
      button.textContent = '−'; // U+2212 MINUS SIGN - reads as a solid bar, unlike a plain hyphen
      button.disabled = field.exhausted;
      button.title = field.exhausted
        ? 'Already at zero (or below) - decrementing is disabled'
        : 'Decrement by 1';
      // A small outlined circle - border and glyph both in whatever this
      // theme's own link color is - rather than a filled, oversized
      // button. Grey rather than that color once disabled, so the color
      // itself hints that clicking won't do anything.
      var color = field.exhausted ? '#999' : redmineLinkColor();
      button.style.cssText =
        'display: inline-flex; align-items: center; justify-content: center;' +
        'box-sizing: border-box; width: 1.4em; height: 1.4em; margin-left: 0.4em; padding: 0;' +
        'border-radius: 50%; border: 1px solid ' + color + '; background: none;' +
        'color: ' + color + '; font-size: 0.85em; font-weight: bold; line-height: 1;' +
        'vertical-align: middle; cursor: ' + (field.exhausted ? 'default' : 'pointer') + ';';

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
