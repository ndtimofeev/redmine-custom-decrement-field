module CustomDecrementField
  # Answers "may an issue of this tracker be moved to the field's zero
  # status?" - the one question both the transition itself (IssuePatch) and
  # the warning on the field's admin form (_decrementable_int.html.erb) need.
  #
  # Redmine's statuses are global; a status belongs to a tracker only by
  # appearing in that tracker's workflow. The transition into the zero status
  # is made without going through the workflow (see
  # IssuePatch#custom_decrement_field_apply_zero_status), so nothing in core
  # stops it from landing a ticket in a status its tracker has no rules for -
  # and from there nobody can move it anywhere. This module is the stop.
  module ZeroStatusCheck
    module_function

    # A status counts as known to a tracker when it is the tracker's default
    # status or takes part in one of its workflow transitions (core's own
    # Tracker#issue_statuses definition, plus the default, which a tracker
    # with no rules at all would otherwise not list).
    def in_workflow?(tracker, status)
      return false unless tracker && status

      tracker.default_status_id == status.id || tracker.issue_status_ids.include?(status.id)
    end

    # Why `issue` must not be moved to `status` right now, or nil when it may.
    # Beyond "not in the workflow" this mirrors the two rules core applies to
    # the status dropdown (Issue#new_statuses_allowed_to) and which a system
    # transition would otherwise skip: a ticket with open subtasks or a
    # blocker cannot be closed, and a subtask of a closed parent cannot be
    # reopened.
    def blocker(issue, status)
      return :not_in_workflow unless in_workflow?(issue.tracker, status)

      if status.is_closed? && !issue.closed?
        :not_closable unless issue.closable?
      elsif !status.is_closed? && issue.closed?
        :not_reopenable unless issue.reopenable?
      end
    end

    # The trackers `field` is attached to whose workflow lacks `status` -
    # what the admin form warns about.
    def trackers_without(field, status)
      field.trackers.reject { |tracker| in_workflow?(tracker, status) }
    end
  end
end
