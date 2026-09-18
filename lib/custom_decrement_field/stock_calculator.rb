module CustomDecrementField
  # The single source of truth for a decrementable field's value is the
  # current text of the issue's journal notes - never a separately
  # maintained counter. Editing or deleting a comment that contains the
  # token changes the result on its own, the next time anything triggers a
  # recalculation (see IssuePatch and JournalPatch). There is no separate
  # decrement log to keep in sync, and therefore nothing that can drift
  # out of sync with it.
  class StockCalculator
    def initialize(issue, field)
      @issue = issue
      @field = field
      @config = TokenConfig.for_field(field)
    end

    attr_reader :issue, :field, :config

    def enabled?
      config.present?
    end

    # Sums every occurrence of "<token>:<signed integer>" across every
    # journal note currently attached to the issue. This intentionally
    # re-scans the full history on every call rather than maintaining a
    # running total, because the whole point of this design is that
    # editing or deleting a past comment must change the result - a cached
    # running total, updated incrementally, would never notice either of
    # those on its own.
    def value
      return 0 unless enabled?

      pattern = /#{Regexp.escape(config.token)}\s*:\s*([+-]?\d+)/

      issue.journals.sum do |journal|
        next 0 if journal.notes.blank?

        journal.notes.scan(pattern).sum { |m| m.first.to_i }
      end
    end

    # We deliberately check <= 0 here, not == 0. The safe path (the
    # decrement button/controller) can never push the value below zero,
    # since it refuses to act once this predicate is already true. A
    # negative value can therefore only appear through the unsafe path -
    # someone hand-editing a comment to contain a larger negative number
    # than what was actually left, or editing an unrelated field's
    # description in a way that changes the token. When that happens, the
    # field should behave exactly like "out of stock" everywhere the
    # calculator is consulted (button disabled, zero-status transition
    # fires), while still visibly showing the negative number rather than
    # silently clamping it to zero - precisely so a negative reading stays
    # a visible signal that the history was tampered with outside the
    # normal button flow, instead of being quietly hidden.
    def exhausted?
      value <= 0
    end

    def zero_status
      return nil unless config&.zero_status_id

      @zero_status ||= IssueStatus.find_by(id: config.zero_status_id)
    end

    # The value currently persisted in custom_values - i.e. the result of
    # the previous recalculation - before this one overwrites it. Callers
    # use this to detect the exact moment the value crosses from positive
    # into zero-or-negative, so that the zero-status transition (see
    # IssuePatch#custom_decrement_field_recalculate) fires exactly once
    # per crossing, instead of on every single recalculation that happens
    # to run while the value is already sitting at or below zero.
    def value_in_db
      issue.custom_value_for(field)&.value.to_i
    end
  end
end
