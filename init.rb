require 'redmine'

# Load everything under lib/ in every environment. Redmine runs this file from
# inside its own to_prepare callback (see Redmine::PluginLoader.load), so a
# to_prepare block registered from here would never run - an earlier version of
# this file had one, and it was dead code. The plugin's lib/ is on the autoload
# path, and production's eager load happens to load all of it, but development
# and test do not: nothing refers to the field formats or the patches by name,
# so they would never register and the plugin would silently do nothing there.
# The path is built from __FILE__ and not __dir__, which resolves symlinks and
# would no longer match the directory Zeitwerk was given.
Rails.autoloaders.main.eager_load_dir(File.expand_path('lib', File.dirname(__FILE__)))

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
