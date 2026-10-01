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
    # happened to a child (it was changed, moved away, deleted). Takes the id
    # and does three things around the plain +refresh+:
    #
    # * locks the parent's row for the rest of the caller's transaction, then
    #   reads it. The sum is recomputed from the children's stored values and
    #   written back, and two children changing at the same moment would each
    #   compute it without the other's change and the later write would win
    #   (a lost update: 2+2 with both written off by one ends up 3, not 2).
    #   With the lock the second one waits for the first to commit and then
    #   reads its result. (Core's own save of a child already takes this lock
    #   implicitly when it updates the parent's derived attributes, so this
    #   adds no new kind of deadlock risk.) It only has teeth on databases that
    #   honor row locks - PostgreSQL, MySQL - and on MySQL's default
    #   REPEATABLE READ the later plain SELECTs of the children can still come
    #   from an older snapshot; SQLite serializes writers anyway.
    # * notices a watchdog on the parent that starts or stops because of the
    #   new sum (WatchdogTransition) - the parent is not being saved, so nothing
    #   else would.
    #
    # Plain +refresh+ stays for callers that must not move any ticket - the
    # backfill when a field is saved, and an issue's own sums, which its caller
    # already watches.
    def self.refresh_parent(parent_id)
      return unless parent_id

      parent = Issue.lock.find_by(id: parent_id)
      return unless parent

      WatchdogTransition.around(parent) { refresh(parent) }
    end

    # Called whenever +issue+'s own numbers or comments may have changed:
    # its own sums (its comments carry the multipliers) and its parent's
    # (its count is one of the parent's terms). Re-fetches the parent instead
    # of using the cached association, which may hold stale custom_values.
    def self.cascade(issue)
      refresh(issue)
      refresh_parent(issue.parent_id)
    end
  end
end
