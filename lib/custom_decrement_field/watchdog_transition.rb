module CustomDecrementField
  # Moves a ticket to a watchdog's trigger status at the moment the watchdog
  # starts barking.
  #
  # The barking itself is derived from two stored numbers and remembers
  # nothing (WatchdogCheck), so "starts" has to be found by comparing the set
  # of barking watchdogs before and after something changed the numbers - the
  # same edge the zero-status transition fires on, for the same reason: a
  # ticket that is already below its level, or whose status somebody changed
  # on purpose afterwards, is left alone.
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
    # whatever started barking inside it.
    def around(issue)
      before = WatchdogCheck.barking_fields(issue)
      result = yield
      fire(issue, before)
      result
    end

    # Moves `issue` for the first watchdog that started barking since `before`
    # and has a trigger status the issue may be moved to. At most one move per
    # call; a watchdog whose move is blocked is logged and skipped (and shows
    # up as an inconsistency - see WatchdogCheck.status_problems).
    def fire(issue, before)
      (WatchdogCheck.barking_fields(issue) - before).each do |watchdog|
        status = WatchdogConfig.trigger_status(watchdog)
        next if status.nil? || issue.status_id == status.id

        reason = StatusTransition.blocker(issue, status)
        if reason
          Rails.logger.warn(
            "[custom_decrement_field] issue ##{issue.id}: watchdog '#{watchdog.name}' triggered but the issue " \
            "was not moved to status '#{status.name}' (#{reason})"
          )
          next
        end

        StatusTransition.apply(issue, status)
        break
      end
    end
  end
end
