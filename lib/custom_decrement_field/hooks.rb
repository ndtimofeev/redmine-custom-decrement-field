module CustomDecrementField
  # Draws the decrement button's stylesheet as an inline <style> block in
  # <head>, instead of serving it as a separate file through Redmine's
  # plugin asset pipeline (stylesheet_link_tag ..., plugin: ...). That
  # pipeline is Propshaft-based and, on at least one real deployment this
  # plugin was tested against, turned out to depend on `bin/rails
  # assets:precompile` having actually been run - when it hadn't, a
  # <link> tag would have rendered but its href 404ed with no visible
  # error anywhere (this is exactly what happened to this plugin's JS,
  # back when it still shipped one; see `main` branch's history).
  # Reading the file's own content and inlining it sidesteps that
  # pipeline entirely. The file stays on disk as a normal .css file for
  # editing purposes; only how it reaches the browser differs.
  #
  # view_layouts_base_html_head fires in <head>, after Redmine's own
  # stylesheet <link> tags (see app/views/layouts/base.html.erb) - on
  # every single page, not just the issue view, since a page's CSS needs
  # to be present before any of its content renders, unlike the old JS
  # hook which could afford to check for an @issue first.
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_layouts_base_html_head, partial: 'custom_decrement_field/stylesheet'

    # Memoized at the class level: the file's content can't change
    # without a restart anyway (Ruby source and plugin assets are both
    # only (re-)read at boot/reload), so there's no reason to hit the
    # filesystem again on every single page render.
    def self.inline_stylesheet
      @inline_stylesheet ||= File.read(stylesheet_path)
    end

    def self.stylesheet_path
      File.join(
        Redmine::Plugin.find(:redmine_custom_decrement_field).assets_directory,
        'stylesheets', 'custom_decrement_field.css'
      )
    end
  end
end
