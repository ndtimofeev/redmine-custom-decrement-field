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

      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'icon icon-del custom-decrement-field-button';
      button.textContent = '−1';
      button.disabled = field.exhausted;
      button.title = field.exhausted
        ? 'Already at zero (or below) - decrementing is disabled'
        : 'Decrement by 1';

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

      row.appendChild(button);
    });
  });
})();
