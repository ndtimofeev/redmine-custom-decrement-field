module CustomDecrementField
  # Ни один хук ядра Redmine не рендерит что-то ВНУТРИ конкретной строки
  # кастомного поля — только "до"/"после" всего блока атрибутов. Патчить
  # партиал рендера кастомных полей ради одной кнопки было бы тем самым
  # хрупким местом, которого мы избегаем во всей архитектуре. Поэтому
  # кнопку дорисовывает JS на уже готовой странице (см.
  # assets/javascripts/custom_decrement_field.js), а этот хук только
  # подключает скрипт и передаёт ему исходные данные.
  class ViewHooks < Redmine::Hook::ViewListener
    render_on :view_layouts_base_body_bottom, partial: 'custom_decrement_field/assets'
  end
end
