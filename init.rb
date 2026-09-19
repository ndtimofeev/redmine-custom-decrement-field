require 'redmine'

Rails.application.config.to_prepare do
  # decrementable_int_format.rb must load before anything that reads a
  # field's configuration, since it's what makes field_format ==
  # 'decrementable_int' mean anything at all.
  require_relative 'lib/custom_decrement_field/decrementable_int_format'
  require_relative 'lib/custom_decrement_field/token_config'
  require_relative 'lib/custom_decrement_field/stock_calculator'
  require_relative 'lib/custom_decrement_field/issue_patch'
  require_relative 'lib/custom_decrement_field/journal_patch'
  require_relative 'lib/custom_decrement_field/hooks'
end

Redmine::Plugin.register :redmine_custom_decrement_field do
  name 'Custom Decrement Field'
  author 'Your Company'
  description 'A custom field that can only be decremented from the issue view. ' \
              'History and undo are handled through ordinary issue comments, with no separate ledger table.'
  version '0.1.0'
  url 'https://github.com/ndtimofeev/redmine-custom-decrement-field'
  requires_redmine version_or_higher: '6.0.0'

  # No settings page: per-field configuration (token, zero-status) lives
  # directly on each field's own admin edit form, via
  # DecrementableIntFormat's form_partial - there is nothing left for a
  # plugin-wide settings screen to do.
end
