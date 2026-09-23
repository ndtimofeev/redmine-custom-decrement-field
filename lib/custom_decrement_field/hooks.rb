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

  # Renders a Wikipedia-"marked for deletion"-style banner above an
  # issue's own content on its show page, whenever one of its
  # decrementable fields is inconsistent (see StockCalculator#inconsistent?).
  #
  # There is no hook that fires above an issue's own heading on its show
  # page - verified against 6.0-stable's app/views/issues/show.html.erb,
  # the closest one (view_issues_show_details_bottom) already sits well
  # below it, inside the attributes box. view_layouts_base_body_top,
  # verified against app/views/layouts/base.html.erb, is the only hook
  # that fires above ANY of a page's own content at all - but, like
  # view_layouts_base_html_head above, it does so on every single page,
  # not just an issue's. The partial itself is responsible for rendering
  # nothing on every page this doesn't apply to - the same
  # controller/action/issue check formatted_custom_value uses to keep the
  # decrement button off list/CSV/PDF/email views, reused here for the
  # same reason - which is why this uses the same render_on macro Hooks
  # above does, rather than a hand-written render call.
  class InconsistencyBannerHook < Redmine::Hook::ViewListener
    render_on :view_layouts_base_body_top, partial: 'custom_decrement_field/inconsistency_banner'
  end

  # Editing a comment's text (including blanking it out entirely, which is
  # how Redmine's web UI deletes one - see JournalsController#update:
  # it saves the now-edited note, then destroys the journal outright if
  # that leaves it with neither notes nor details) normally updates the
  # page in place via JS (format.js), swapping just that one comment's own
  # DOM node - deliberately, so editing/removing a comment elsewhere on a
  # long history doesn't reload the whole page. But a decrementable
  # field's value, its warning marker, the button's disabled state, and
  # the inconsistency banner are all rendered server-side, as part of the
  # surrounding page rather than that comment's own node, so none of them
  # notice a change made this way until something re-renders the page -
  # previously, that meant a manual reload.
  #
  # view_journals_update_js_bottom (called from
  # app/views/journals/update.js.erb, verified against 6.0-stable source)
  # fires once that in-place swap has already happened, with the
  # journal - saved or destroyed - available as context[:journal].
  #
  # This only bothers reloading when the issue's own tracker has a
  # decrementable field at all, not when the edited text can be shown to
  # actually contain that field's token. An earlier version tried the
  # more targeted check - comparing the note's text before and after the
  # edit against the token - using Journal#notes_before_last_save, but
  # that came back nil here even for a save that had just visibly
  # persisted a real change (verified directly against a live instance:
  # editing a journal's notes through this exact controller action, then
  # inspecting notes_before_last_save from within this same hook,
  # consistently returned nil rather than the pre-edit text). Rather than
  # rely on that, this reloads on every comment edit/delete on a tracker
  # that has a decrementable field, whether or not that particular
  # comment's text ever mentioned one - a comment edit is not a frequent
  # enough action for the occasional unnecessary reload to matter, and
  # this is guaranteed correct rather than dependent on a Journal dirty-
  # tracking API that didn't behave as documented here.
  #
  # A full reload, rather than trying to patch the value/marker/button/
  # banner in place by hand, is a deliberate simplicity trade-off: it
  # doesn't need to know or reproduce any of core's own markup for those
  # (see decrementable_int_format.rb's own history for how fragile
  # hand-matching Redmine's rendering has turned out to be elsewhere in
  # this plugin).
  class InconsistencyRefreshHook < Redmine::Hook::ViewListener
    def view_journals_update_js_bottom(context = {})
      journal = context[:journal]
      issue = journal&.journalized
      return '' unless issue.is_a?(Issue)
      return '' if CustomDecrementField::TokenConfig.fields_for_tracker(issue.tracker).empty?

      'window.location.reload();'
    end
  end
end
