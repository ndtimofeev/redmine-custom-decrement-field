module CustomDecrementField
  # Writes sum fields back. Like IssuePatch it never saves the Issue itself,
  # only the one CustomValue row - re-saving an Issue from inside another
  # issue's callback is what trips optimistic locking.
  module SumRecalculation
    # Recompute every sum field on +issue+ (treating it as a parent).
    def self.refresh(issue)
      return unless issue

      SumConfig.fields_for_tracker(issue.tracker).each do |field|
        new_value = SumCalculator.new(issue, field).value.to_s('F')
        cv = issue.custom_value_for(field) || issue.custom_values.build(custom_field: field)
        next if cv.persisted? && cv.value == new_value

        cv.value = new_value
        cv.save!
      end
    end

    # Refresh for a parent whose sum changes because of something that
    # happened to a child (it was changed, moved away, deleted): the parent is
    # not being saved, so a watchdog on it that starts barking because of the
    # new sum is noticed here (WatchdogTransition). Plain +refresh+ stays for
    # callers that must not move any ticket - the backfill when a field is
    # saved, and an issue's own sums, which its caller already watches.
    def self.refresh_parent(parent)
      return unless parent

      WatchdogTransition.around(parent) { refresh(parent) }
    end

    # Called whenever +issue+'s own numbers or comments may have changed:
    # its own sums (its comments carry the multipliers) and its parent's
    # (its count is one of the parent's terms). Re-fetches the parent instead
    # of using the cached association, which may hold stale custom_values.
    def self.cascade(issue)
      refresh(issue)
      refresh_parent(Issue.find_by(id: issue.parent_id)) if issue.parent_id
    end
  end
end
