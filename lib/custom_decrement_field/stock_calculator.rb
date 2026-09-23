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

    # An issue's tracker can carry more than one decrementable field (see
    # TokenConfig.fields_for_tracker) - these two class methods are the
    # entry points for callers that care about "is anything on this issue
    # inconsistent", without needing to know how many decrementable
    # fields it actually has.
    def self.calculators_for(issue)
      TokenConfig.fields_for_tracker(issue.tracker).map { |field| new(issue, field) }
    end

    def self.inconsistent?(issue)
      calculators_for(issue).any?(&:inconsistent?)
    end

    # Issues that could possibly be inconsistent at all - i.e. whose
    # tracker has at least one configured decrementable field - out of
    # +scope+ (defaults to every issue). #inconsistent_issue_ids uses this
    # to bound how many issues it has to actually load journals for and
    # run through #inconsistent? in Ruby, since that check has no SQL
    # equivalent (see IssueQueryPatch for why, and why that's fine here).
    def self.candidate_issues(scope = Issue.all)
      scope.where(tracker_id: TokenConfig.tracker_ids_with_fields).includes(:journals)
    end

    def self.inconsistent_issue_ids(scope = Issue.all)
      candidate_issues(scope).select { |issue| inconsistent?(issue) }.map(&:id)
    end

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
    #
    # The colon's surrounding whitespace is optional on both sides - "a:1",
    # "a : 1", "a:  1" all match - even though every writer in this plugin
    # now produces "a : 1" (spaced) consistently; this stays permissive so
    # existing history written before that, or a hand-typed comment,
    # doesn't silently stop counting. A decrement can also carry an
    # optional trailing literal (see #literal_used?) - "a : -1 xyz123" -
    # which this pattern doesn't need to know anything about: it only
    # captures the number, and scan() finds that regardless of whatever
    # non-matching text follows it on the same line.
    def value
      return 0 unless enabled?

      pattern = /#{Regexp.escape(config.token)}\s*:\s*([+-]?\d+)/

      issue.journals.sum do |journal|
        next 0 if journal.notes.blank?

        journal.notes.scan(pattern).sum { |m| m.first.to_i }
      end
    end

    # True if a decrement carrying this exact literal already appears in
    # this field's history. The literal is free-form data supplied by
    # whatever posted the decrement (see
    # CustomDecrementFieldController#decrement) - typically a one-off
    # reference that caller generates for exactly this purpose, so a
    # retried or duplicated request (a network retry, a double-tap before
    # a button could disable itself, the same code scanned twice within a
    # moment of itself) can be recognized as "this already happened"
    # instead of silently decrementing a second time.
    #
    # Matches on the literal's presence alone, not the amount next to it -
    # a genuine duplicate of the same request would carry the same amount
    # anyway, so there is nothing extra to gain from also comparing it,
    # and it keeps this method usable regardless of whether the amount is
    # ever anything other than DECREMENT_AMOUNT's -1.
    def literal_used?(literal)
      return false unless enabled? && literal.present?

      pattern = /#{Regexp.escape(config.token)}\s*:\s*[+-]?\d+\s+#{Regexp.escape(literal)}(?=\s|\z)/

      issue.journals.any? { |journal| journal.notes.present? && pattern.match?(journal.notes) }
    end

    # Every literal that shows up on more than one decrement in this
    # field's history, mapped to every journal that carries it. Through
    # the normal flow a literal can only ever reach history once - the
    # controller refuses to write a second one (see #literal_used? and
    # CustomDecrementFieldController#decrement) - so anything this finds
    # can only have come from hand-editing or hand-duplicating a comment.
    #
    # The character class mirrors CustomDecrementFieldController's own
    # #decrement_literal validation exactly (RFC 3986 "unreserved"
    # characters), since that's the full set of literals the controller
    # could ever have written in the first place.
    def duplicate_literals
      return {} unless enabled?

      pattern = /#{Regexp.escape(config.token)}\s*:\s*[+-]?\d+\s+([A-Za-z0-9_.~-]+)/

      by_literal = Hash.new { |h, k| h[k] = [] }
      issue.journals.each do |journal|
        next if journal.notes.blank?

        journal.notes.scan(pattern).each { |(literal)| by_literal[literal] << journal }
      end

      by_literal.select { |_, journals| journals.size > 1 }
    end

    # Strictly negative, not <= 0 - see #exhausted? for why zero itself is
    # a normal, reachable state and not a sign of anything wrong.
    def negative?
      enabled? && value.negative?
    end

    # The single question everywhere this plugin needs to ask "did this
    # field's history get tampered with outside the normal button/
    # controller flow" - a negative total and a duplicated literal are
    # both only reachable by hand-editing a comment (see #negative? and
    # #duplicate_literals), and there's no reason to tell them apart at
    # the call sites that just need to flag or filter on "something here
    # needs a human to look at it": the issue-page banner, the tracker's
    # row highlighting in list views, and the query filter all just ask
    # this one method.
    def inconsistent?
      negative? || duplicate_literals.any?
    end

    # We deliberately check <= 0 here, not == 0. The safe path (the
    # decrement button/controller) can never push the value below zero,
    # since it refuses to act once this predicate is already true. A
    # negative value can therefore only appear through the unsafe path -
    # someone hand-editing a comment to contain a larger negative number
    # than what was actually left. When that happens, the field should
    # behave exactly like "out of stock" everywhere the
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
