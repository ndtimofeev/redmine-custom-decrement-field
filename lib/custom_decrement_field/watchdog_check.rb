module CustomDecrementField
  # The whole "barking" decision. Reads two already-stored numbers per
  # watchdog, nothing is recomputed and no flag is persisted, so it is cheap
  # enough to ask for every row of an issue list.
  module WatchdogCheck
    def self.barking?(issue)
      barking_fields(issue).any?
    end

    # The watchdogs of +issue+ that are barking right now (none for a closed
    # issue). WatchdogTransition compares this before and after a change to
    # find the watchdogs that just started.
    def self.barking_fields(issue)
      return [] if issue.closed?

      available = issue.available_custom_fields
      available.select do |watchdog|
        watched = WatchdogConfig.watched_field(watchdog)
        watched && available.include?(watched) && reached?(issue, watched, watchdog)
      end
    end

    # Barking watchdogs whose trigger status the issue is not in and cannot be
    # moved to: [[watchdog, reason], ...], with a reason from
    # StatusTransition.blocker, or :status_missing when the status was deleted.
    # Like the barking check itself, derived from the stored numbers each time:
    # it clears once the cause is fixed. A barking issue whose trigger status
    # would be accepted is not reported - it is waiting, or somebody moved it
    # elsewhere on purpose.
    def self.status_problems(issue)
      barking_fields(issue).filter_map do |watchdog|
        next unless WatchdogConfig.trigger_status_id(watchdog)

        status = WatchdogConfig.trigger_status(watchdog)
        reason = status ? (StatusTransition.blocker(issue, status) unless issue.status_id == status.id) : :status_missing
        [watchdog, reason] if reason
      end
    end

    # Blank on either side means "nothing to compare" - an unset threshold
    # disables the watchdog, an unfilled watched field doesn't bark.
    def self.reached?(issue, watched, watchdog)
      level = number(issue, watchdog)
      current = number(issue, watched)
      !level.nil? && !current.nil? && current <= level
    end

    def self.number(issue, field)
      raw = issue.custom_value_for(field)&.value
      raw.blank? ? nil : Float(raw, exception: false)
    end
  end
end
