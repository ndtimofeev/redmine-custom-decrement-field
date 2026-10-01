module CustomDecrementField
  # Moves a ticket to a watchdog's statuses at the moment it starts barking
  # (trigger status) and at the moment it stops (release status).
  #
  # The barking itself is derived from two stored numbers and remembers
  # nothing (WatchdogCheck), so "starts" and "stops" have to be found by
  # comparing the set of watchdogs that are at or below their level before and
  # after something changed the numbers - the same edge the zero-status
  # transition fires on, for the same reason: a ticket that is already below
  # its level, or whose status somebody changed on purpose afterwards, is left
  # alone.
  #
  # The comparison is on the numbers (WatchdogCheck.reached_fields), not on
  # "barking": closing a ticket makes it stop barking without anything having
  # recovered, and must not release it; a closed ticket is not moved at all.
  #
  # Two kinds of caller supply the "before":
  # * IssuePatch, around everything that can change an issue's own numbers (a
  #   comment, an edit of the level or of a plain watched field, the
  #   recalculations);
  # * .around, for a parent whose sum is rewritten because a child changed
  #   (SumRecalculation) - the parent is not being saved at all.
  # A ticket being created never fires: its numbers are stored before any
  # recalculation looks at them, so there is nothing to compare against - a
  # new parent with no children yet is "below" any level, and must not be
  # moved the instant it is made.
  module WatchdogTransition
    module_function

    # Runs the block (which changes `issue`'s stored numbers), then fires for
    # whatever started or stopped inside it.
    def around(issue)
      before = WatchdogCheck.reached_fields(issue)
      result = yield
      fire(issue, before)
      result
    end

    # At most one move per call, and a trigger comes before a release: the
    # first watchdog (by field order) that started and has a trigger status
    # the issue may be moved to; failing that, the first that stopped and has a
    # release status it may be moved to. A move that is blocked is logged and
    # skipped (and shows up as an inconsistency - see
    # WatchdogCheck.status_problems).
    def fire(issue, before)
      return if issue.closed?

      after = WatchdogCheck.reached_fields(issue)
      started = after - before
      stopped = before - after
      return if started.empty? && stopped.empty?

      move_for(issue, started, :trigger) { |watchdog| WatchdogConfig.trigger_status(watchdog) } ||
        move_for(issue, stopped, :release) { |watchdog| WatchdogConfig.release_status(watchdog) }
    end

    # Returns true once a watchdog of `watchdogs` has moved the issue.
    def move_for(issue, watchdogs, kind)
      watchdogs.each do |watchdog|
        status = yield(watchdog)
        next if status.nil? || issue.status_id == status.id

        reason = StatusTransition.blocker(issue, status)
        if reason
          Rails.logger.warn(
            "[custom_decrement_field] issue ##{issue.id}: watchdog '#{watchdog.name}' #{kind == :trigger ? 'triggered' : 'released'} " \
            "but the issue was not moved to status '#{status.name}' (#{reason})"
          )
          next
        end

        return true if StatusTransition.apply(issue, status)
      end
      false
    end
  end
end
