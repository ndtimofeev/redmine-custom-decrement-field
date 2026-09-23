module CustomDecrementField
  # Adds a single "decrementable field history is inconsistent" filter to
  # the issue query, so an inconsistent issue can be found the same way
  # any other issue is - through Filters, not by browsing every issue's
  # row-highlighting (see IssueCssClassesPatch) by hand.
  #
  # Verified against Redmine 6.0-stable's app/models/query.rb before
  # writing this: Query#statement dispatches a filter named "foo" to a
  # method called sql_for_foo_field if the query class defines one
  # (`respond_to?("sql_for_#{field}_field")`), *before* falling back to
  # the generic, hardcoded operator handling in Query#sql_for_field. That
  # generic path only knows how to build a WHERE clause against a real
  # column, keyed by one of a fixed set of operators per filter type
  # (Query.operators_by_filter_type) - there is no registry a plugin can
  # add a wholly new operator or column to. The dynamic sql_for_..._field
  # dispatch is the actual, intended extension point for a filter like
  # this one that has no backing column at all, and it needs no
  # monkey-patching of that generic method to use.
  #
  # initialize_available_filters is a plain public instance method (no
  # `private`/`protected` above it in issue_query.rb), so it can be
  # wrapped the ordinary `prepend` + `super` way, same as
  # IssueCssClassesPatch does for Issue#css_classes.
  module IssueQueryPatch
    def initialize_available_filters
      super

      add_available_filter(
        'custom_decrement_field_inconsistent',
        type: :list,
        label: :label_custom_decrement_field_inconsistent,
        values: [[l(:general_text_yes), '1'], [l(:general_text_no), '0']]
      )
    end

    # "inconsistent" has no backing column to compare against - it's the
    # result of scanning journal notes in Ruby (see
    # StockCalculator#inconsistent?), so this can't be expressed as a
    # comparison the way a real field's filter would be. Instead it
    # computes the actual set of matching issue ids up front and turns
    # that into a plain id IN (...) / NOT IN (...) clause - mirroring
    # core's own sql_for_is_private_field, which is also a :list filter
    # over two fixed values and switches between IN/NOT IN depending on
    # the operator ("=" vs "!") the same way this does.
    #
    # Restricting the scan to issues the current user can already see
    # avoids doing this (relatively expensive, journal-scanning) work for
    # every decrementable-field issue in the database on every query,
    # most of which would just be filtered back out again by the
    # visibility condition Query#statement always ANDs in regardless of
    # which filters are active.
    def sql_for_custom_decrement_field_inconsistent_field(field, operator, value)
      selected = Array(value)
      matches_inconsistent = selected.include?('1')
      matches_consistent = selected.include?('0')
      # A :list filter's "!" means "anything other than the selected
      # values", not "flip the meaning of each value" - swapping which
      # outcome each flag represents reproduces that without needing two
      # separate branches per operator.
      matches_inconsistent, matches_consistent = matches_consistent, matches_inconsistent if operator == '!'

      return '1=1' if matches_inconsistent && matches_consistent
      return '1=0' if !matches_inconsistent && !matches_consistent

      visible_scope = Issue.where(Issue.visible_condition(User.current))
      inconsistent_ids = CustomDecrementField::StockCalculator.inconsistent_issue_ids(visible_scope)

      if matches_inconsistent
        inconsistent_ids.any? ? "#{Issue.table_name}.id IN (#{inconsistent_ids.join(',')})" : '1=0'
      else
        inconsistent_ids.any? ? "#{Issue.table_name}.id NOT IN (#{inconsistent_ids.join(',')})" : '1=1'
      end
    end
  end
end

unless IssueQuery.ancestors.include?(CustomDecrementField::IssueQueryPatch)
  IssueQuery.prepend(CustomDecrementField::IssueQueryPatch)
end
