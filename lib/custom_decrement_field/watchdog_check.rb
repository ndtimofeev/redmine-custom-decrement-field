module CustomDecrementField
  # The whole "barking" decision. Reads two already-stored numbers per
  # watchdog, nothing is recomputed and no flag is persisted, so it is cheap
  # enough to ask for every row of an issue list.
  module WatchdogCheck
    def self.barking?(issue)
      return false if issue.closed?

      available = issue.available_custom_fields
      available.any? do |watchdog|
        watched = WatchdogConfig.watched_field(watchdog)
        watched && available.include?(watched) && reached?(issue, watched, watchdog)
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
