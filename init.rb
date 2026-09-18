require 'redmine'

Rails.application.config.to_prepare do
  require_relative 'lib/custom_decrement_field/token_config'
  require_relative 'lib/custom_decrement_field/stock_calculator'
  require_relative 'lib/custom_decrement_field/issue_patch'
  require_relative 'lib/custom_decrement_field/journal_patch'
  require_relative 'lib/custom_decrement_field/hooks'
end

Redmine::Plugin.register :redmine_custom_decrement_field do
  name 'Custom Decrement Field'
  author 'Your Company'
  description 'Кастомное поле-счётчик: значение можно только уменьшать кнопкой на карточке задачи. ' \
              'История и откат списаний — через обычные комментарии, без отдельной таблицы декрементов.'
  version '0.1.0'
  url 'https://github.com/ndtimofeev/redmine-custom-decrement-field'
  requires_redmine version_or_higher: '6.0.0'

  # Ничего не хранит сам — страница нужна только как генератор строки-маркера
  # для description кастомного поля, см. app/views/settings.
  settings partial: 'settings/custom_decrement_field', default: {}
end
