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
  description 'A custom field that can only be decremented from the issue view. ' \
              'History and undo are handled through ordinary issue comments, with no separate ledger table.'
  version '0.1.0'
  url 'https://github.com/ndtimofeev/redmine-custom-decrement-field'
  requires_redmine version_or_higher: '6.0.0'

  # This settings page does not persist anything of its own - it only
  # helps an administrator assemble the configuration string that has to
  # be pasted into the target custom field's own description. See
  # lib/custom_decrement_field/token_config.rb for why the configuration
  # lives there instead of in a table owned by this plugin.
  settings partial: 'settings/custom_decrement_field', default: {}
end
