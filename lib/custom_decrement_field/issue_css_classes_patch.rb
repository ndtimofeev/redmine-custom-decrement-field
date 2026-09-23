module CustomDecrementField
  # Adds a CSS class to an issue's own row/box wherever Issue#css_classes
  # is consulted - issue list rows (app/views/issues/_list.html.erb) and
  # the issue's own show page (app/views/issues/show.html.erb) alike -
  # exactly the same mechanism core itself uses for "overdue" (see
  # Issue#css_classes in Redmine 6.0-stable). This is a separate module
  # from IssuePatch, and prepended rather than included: overriding an
  # existing method and calling `super` requires sitting above the class
  # in the ancestor chain, which `include` does not do, while IssuePatch's
  # own after_save hooks only ever add new methods, so plain `include`
  # is enough there.
  module IssueCssClassesPatch
    def css_classes(user=User.current)
      classes = super
      return classes unless CustomDecrementField::StockCalculator.inconsistent?(self)

      "#{classes} custom-decrement-field-inconsistent"
    end
  end
end

unless Issue.ancestors.include?(CustomDecrementField::IssueCssClassesPatch)
  Issue.prepend(CustomDecrementField::IssueCssClassesPatch)
end
