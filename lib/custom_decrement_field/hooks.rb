module CustomDecrementField
  # No core Redmine hook renders anything *inside* one specific custom
  # field's row - only hooks that fire before or after the entire block
  # of issue attributes. Patching the core partial that renders custom
  # field rows, just to splice a button into the middle of it, would be
  # exactly the kind of version-fragile change this plugin otherwise goes
  # out of its way to avoid everywhere else (see the "vanilla fallback"
  # reasoning throughout IssuePatch and TokenConfig). Instead, the
  # decrement button is added by JavaScript after the page has already
  # rendered normally (see assets/javascripts/custom_decrement_field.js),
  # and this hook's only job is to hand that script's content, and the
  # data it needs, to app/views/custom_decrement_field/_assets.html.erb.
  #
  # view_layouts_base_body_bottom fires on every single page in Redmine,
  # not just the issue view, so the partial itself is responsible for
  # checking whether there is even an @issue instance variable to act on
  # before rendering anything.
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_layouts_base_body_bottom, partial: 'custom_decrement_field/assets'

    # The script is inlined directly into the page rather than served as
    # a separate file through javascript_include_tag(plugin: ...) - that
    # goes through Redmine's Propshaft-based plugin asset pipeline, which
    # in practice turned out to depend on `bin/rails assets:precompile`
    # having been run (and kept up to date) on at least one real
    # deployment, with no visible error when it hadn't been - the script
    # tag rendered, its src 404ed, and the button silently never
    # appeared. Reading the file's own content and inlining it sidesteps
    # that pipeline entirely: this hook is already proven to render
    # correctly (it's how the config data reaches the page today), so
    # piggybacking the script's source on the very same render path
    # removes an entire class of "did the asset pipeline actually pick
    # this up" failure modes. The file stays on disk as a normal .js file
    # for editing purposes; only how it reaches the browser changed.
    #
    # Memoized at the class level: the file's content can't change
    # without a restart anyway (Ruby source and plugin assets are both
    # only (re-)read at boot/reload), so there's no reason to hit the
    # filesystem again on every single page render.
    def self.inline_javascript
      @inline_javascript ||= File.read(javascript_path)
    end

    def self.javascript_path
      File.join(
        Redmine::Plugin.find(:redmine_custom_decrement_field).assets_directory,
        'javascripts', 'custom_decrement_field.js'
      )
    end
  end
end
