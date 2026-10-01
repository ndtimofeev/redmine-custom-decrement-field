module CustomDecrementField
  # The whole "barking" decision. Reads two already-stored numbers per
  # watchdog, nothing is recomputed and no flag is persisted, so it is cheap
  # enough to ask for every row of an issue list.
  module WatchdogCheck
    def self.barking?(issue)
      barking_fields(issue).any?
    end

    # The watchdogs of +issue+ that are barking right now (none for a closed
    # issue - a closed ticket is done with, whatever its numbers say).
    def self.barking_fields(issue)
      issue.closed? ? [] : reached_fields(issue)
    end

    # The watchdogs whose watched value is at or below their level, closed or
    # not. This - not #barking_fields - is what WatchdogTransition compares
    # before and after a change: a ticket that merely got closed must not
    # look like a watchdog that stopped barking.
    def self.reached_fields(issue)
      available = issue.available_custom_fields
      available.select do |watchdog|
        watched = WatchdogConfig.watched_field(watchdog)
        watched && available.include?(watched) && reached?(issue, watched, watchdog)
      end
    end

    # Watchdogs whose status move is stuck on +issue+, as
    # [[watchdog, kind, reason], ...]. kind is :trigger or :release; reason is
    # one of StatusTransition.blocker's, or :status_missing when the configured
    # status was deleted. Like the barking check itself, derived from the
    # stored numbers each time: it clears once the cause is fixed.
    #
    # * :trigger - the watchdog is barking and the ticket is not in its trigger
    #   status. A barking ticket whose status would be accepted is not
    #   reported: it is waiting, or somebody moved it elsewhere on purpose.
    # * :release - the ticket is still in a watchdog's trigger status although
    #   that watchdog no longer barks, and the release status can't be applied.
    #   Limited to a ticket sitting in the trigger status, because that is the
    #   one place "stuck" can be told from "never moved": without a memory of
    #   attempts, every healthy ticket not in the release status would
    #   otherwise look stuck.
    def self.status_problems(issue)
      barking = barking_fields(issue)
      available = issue.available_custom_fields

      available.flat_map do |watchdog|
        trigger_id = WatchdogConfig.trigger_status_id(watchdog)
        release_id = WatchdogConfig.release_status_id(watchdog)

        if barking.include?(watchdog)
          problem = status_problem(issue, trigger_id, WatchdogConfig.trigger_status(watchdog))
          problem ? [[watchdog, :trigger, problem]] : []
        elsif trigger_id && release_id && !issue.closed? && issue.status_id == trigger_id && recovered?(issue, watchdog)
          problem = status_problem(issue, release_id, WatchdogConfig.release_status(watchdog))
          problem ? [[watchdog, :release, problem]] : []
        else
          []
        end
      end
    end

    # Nil when moving +issue+ to the configured status would be accepted, or
    # when nothing is configured or the ticket is already there.
    def self.status_problem(issue, status_id, status)
      return nil unless status_id
      return :status_missing unless status
      return nil if issue.status_id == status.id

      StatusTransition.blocker(issue, status)
    end
    private_class_method :status_problem

    # Both numbers present and the watched one strictly above the level - the
    # opposite of "reached", but with the same blank-means-nothing rule, so a
    # watchdog with no level never counts as having recovered.
    def self.recovered?(issue, watchdog)
      available = issue.available_custom_fields
      watched = WatchdogConfig.watched_field(watchdog)
      return false unless watched && available.include?(watched)

      level = number(issue, watchdog)
      current = number(issue, watched)
      !level.nil? && !current.nil? && current > level
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
