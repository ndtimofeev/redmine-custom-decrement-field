(function () {
  document.addEventListener('DOMContentLoaded', function () {
    var configEl = document.getElementById('custom-decrement-field-config');
    if (!configEl) return;

    var fields;
    try {
      fields = JSON.parse(configEl.dataset.fields || '[]');
    } catch (e) {
      return;
    }

    var csrfToken = document.querySelector('meta[name="csrf-token"]');

    fields.forEach(function (field) {
      // Redmine стабильно помечает строку кастомного поля классом cf_<id> —
      // если вёрстка страницы это когда-нибудь изменит, кнопка просто не
      // появится (деградация до отсутствия кнопки, а не сломанной страницы).
      var row = document.querySelector('.cf_' + field.id);
      if (!row) return;

      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'icon icon-del custom-decrement-field-button';
      button.textContent = '−1';
      button.disabled = field.exhausted;
      button.title = field.exhausted ? 'Значение уже равно нулю (или меньше)' : 'Списать 1';

      button.addEventListener('click', function () {
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
              // Проще всего честно показать всё новое состояние карточки —
              // число, новый комментарий и возможный переход статуса.
              window.location.reload();
            }
          })
          .catch(function () {
            button.disabled = false;
          });
      });

      row.appendChild(button);
    });
  });
})();
