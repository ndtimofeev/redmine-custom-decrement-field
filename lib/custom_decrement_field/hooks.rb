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
  # and this hook's only job is to load that script and hand it the data
  # it needs (via app/views/custom_decrement_field/_assets.html.erb).
  #
  # view_layouts_base_body_bottom fires on every single page in Redmine,
  # not just the issue view, so the partial itself is responsible for
  # checking whether there is even an @issue instance variable to act on
  # before rendering anything.
  class ViewHooks < Redmine::Hook::ViewListener
    render_on :view_layouts_base_body_bottom, partial: 'custom_decrement_field/assets'
  end
end
