module CustomDecrementField
  # Moving a ticket to a status on the plugin's own initiative: the "status on
  # reaching zero" of a decrementable field and the "status when triggered" of
  # a watchdog both end up here. Two questions - may it move there at all
  # (#blocker, also what the fields' admin forms warn about) and the move
  # itself (#apply).
  #
  # Redmine's statuses are global; a status belongs to a tracker only by
  # appearing in that tracker's workflow. The move is made without going
  # through the workflow, so nothing in core stops it from landing a ticket in
  # a status its tracker has no rules for - and from there nobody can move it
  # anywhere. #blocker is the stop.
  module StatusTransition
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
    # what the admin forms warn about.
    def trackers_without(field, status)
      field.trackers.reject { |tracker| in_workflow?(tracker, status) }
    end

    # Moves `issue` to `status` and records that as a normal "Status changed
    # from X to Y" journal entry, without ever calling Issue#save on it.
    #
    # An earlier version of the zero-status code did save the issue, and it
    # intermittently raised ActiveRecord::StaleObjectError: re-saving the very
    # same Issue instance from inside its own after_save, while Redmine's
    # optimistic locking (issues.lock_version) is active, is a well-known
    # fragile pattern. update_columns bypasses validations, callbacks and the
    # locking check entirely - appropriate here, since this is a system-
    # triggered side effect, not a user-picked transition, and it should not
    # be blocked by the Workflow transition-permission check that exists to
    # constrain *users*. (Whether the status makes sense for this ticket at
    # all is #blocker's job, asked before we get here.)
    #
    # Skipping the callbacks also skips what core's before_save callbacks do
    # when a status changes, so the two that matter are repeated by hand:
    # closed_on (core: set when the issue goes from open to closed, kept when
    # it is reopened) and, when the instance uses statuses for the done
    # ratio, done_ratio. Not repeated: the recalculation of a parent's
    # derived dates/ratio, which only runs through a real save.
    #
    # Journal#add_attribute_detail is the same private helper Redmine's own
    # core code uses (e.g. Issue's parent/child change tracking) to build a
    # normal attribute-change journal detail by hand. Reusing (rather than
    # creating a second) current_journal, when one is already pending from
    # whatever add-a-comment action triggered this - typically the decrement
    # controller - makes the status change show up as part of that same
    # journal entry: "removed 1, status: New -> Depleted" as one history
    # entry, not two.
    def apply(issue, status)
      Issue.transaction do
        old_status_id = issue.status_id
        columns = { status_id: status.id }
        columns[:closed_on] = Time.current if status.is_closed? && !issue.closed?
        columns[:done_ratio] = status.default_done_ratio if Issue.use_status_for_done_ratio? && status.default_done_ratio
        issue.update_columns(columns)

        journal = issue.init_journal(User.current)
        journal.send(:add_attribute_detail, 'status_id', old_status_id, status.id)
        journal.save!
      end
    end
  end
end
