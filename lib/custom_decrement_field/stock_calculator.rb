module CustomDecrementField
  # The single source of truth for a decrementable field's value is the
  # current text of the issue's journal notes - never a separately
  # maintained counter. Editing or deleting a comment that contains one of
  # the field's keywords changes the result on its own, the next time anything triggers a
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
      scope.where(tracker_id: TokenConfig.tracker_ids_with_fields).includes(:journals, :tracker, :status)
    end

    def self.inconsistent_issue_ids(scope = Issue.all)
      candidate_issues(scope).select { |issue| inconsistent?(issue) }.map(&:id)
    end

    def enabled?
      config.present?
    end

    # One line of history: how much it moved the stock (positive for an
    # addition, negative for a write-off), the optional literal riding on it,
    # and the journal it was found in.
    Entry = Struct.new(:delta, :literal, :journal)

    # Characters a literal may consist of - RFC 3986's "unreserved" set, the
    # same one CustomDecrementFieldController#decrement_literal accepts, so
    # this is the full set of literals the controller could ever have written.
    LITERAL = '[A-Za-z0-9_.~-]+'.freeze

    # Every entry currently in the issue's history, in no particular order.
    # This is the single place that knows the grammar
    #
    #   KEYWORD : <amount> [literal]
    #
    # where KEYWORD is the field's add keyword or its write-off keyword. The
    # keyword alone decides the direction, so any sign typed in front of the
    # amount is ignored ("RASHOD : -1" still writes one off, never adds one
    # back - a habit from when the single token was signed must not silently
    # flip a write-off into an addition). The literal has to sit on the same
    # line as the amount, and is only recognised when followed by whitespace
    # or the end of the text, so a plain "RASHOD : 1" followed by a line that
    # happens to start with a word doesn't get that word taken for a literal.
    #
    # The colon's surrounding whitespace is optional on both sides ("a:1",
    # "a : 1"), even though every writer in this plugin produces the spaced
    # form; that keeps hand-typed comments counting.
    #
    # Re-scans the full history on every call rather than keeping a running
    # total, because the whole point of this design is that editing or
    # deleting a past comment must change the result - a cached total,
    # updated incrementally, would never notice either of those on its own.
    def entries
      return [] unless enabled?

      keywords = [config.increment_token, config.decrement_token].map { |k| Regexp.escape(k) }.join('|')
      pattern = /(?<keyword>#{keywords})\s*:\s*[+-]?(?<amount>\d+)(?:[ \t]+(?<literal>#{LITERAL})(?=\s|\z))?/

      issue.journals.flat_map do |journal|
        next [] if journal.notes.blank?

        journal.notes.to_enum(:scan, pattern).map do
          match = Regexp.last_match
          amount = match[:amount].to_i
          Entry.new(match[:keyword] == config.increment_token ? amount : -amount, match[:literal], journal)
        end
      end
    end

    def value
      entries.sum(&:delta)
    end

    # True if an entry carrying this exact literal is already in the history.
    # The literal is free-form data supplied by whatever posted the entry (see
    # CustomDecrementFieldController#decrement) - typically a one-off
    # reference that caller generates for exactly this purpose, so a retried
    # or duplicated request (a network retry, a double-tap before a button
    # could disable itself, the same code scanned twice within a moment of
    # itself) can be recognized as "this already happened" instead of being
    # applied a second time. One namespace across both keywords: a delivery
    # note number used as the literal of an addition is protected the same
    # way a scan id on a write-off is.
    #
    # Matches on the literal's presence alone, not the amount next to it - a
    # genuine duplicate of the same request would carry the same amount
    # anyway.
    def literal_used?(literal)
      return false unless enabled? && literal.present?

      entries.any? { |entry| entry.literal == literal }
    end

    # Every literal that shows up on more than one entry, mapped to every
    # journal that carries it. Through the normal flow a literal can only ever
    # reach history once - the controller refuses to write a second one (see
    # #literal_used?) - so anything this finds can only have come from
    # hand-editing or hand-duplicating a comment.
    def duplicate_literals
      entries.select(&:literal).group_by(&:literal)
             .select { |_, found| found.size > 1 }
             .transform_values { |found| found.map(&:journal) }
    end

    # Strictly negative, not <= 0 - see #exhausted? for why zero itself is
    # a normal, reachable state and not a sign of anything wrong.
    def negative?
      enabled? && value.negative?
    end

    # The single question everywhere this plugin needs to ask "does this
    # field need a human to look at it" - the issue-page banner, the
    # tracker's row highlighting in list views, and the query filter all just
    # ask this one method. Two unrelated kinds of trouble count:
    #
    # * the history was tampered with outside the normal button/controller
    #   flow: a negative total and a duplicated literal are both only
    #   reachable by hand-editing a comment (see #negative? and
    #   #duplicate_literals);
    # * the ticket ran out but its status says otherwise, and the configured
    #   move to the zero status can't be made (see #zero_status_problem).
    #
    # There is no reason to tell them apart at the call sites that just need
    # to flag or filter on "something here needs attention"; only the banner
    # goes into the specifics.
    def inconsistent?
      negative? || duplicate_literals.any? || zero_status_problem.present?
    end

    # Why the ticket is not where the field's "status on reaching zero"
    # setting says it should be, or nil when nothing is wrong. Derived from
    # the current state each time rather than remembered when a transition
    # was skipped (IssuePatch), like everything else here: it clears on its
    # own once the cause is fixed, and there is no flag to forget to unset.
    #
    # It holds when the history records some stock that is now used up, a
    # zero status is configured, the ticket is not in it, and either the
    # status no longer exists (:status_missing) or ZeroStatusCheck says the
    # ticket can't be moved there (:not_in_workflow, :not_closable,
    # :not_reopenable). A ticket at zero whose zero status *would* be
    # accepted is not flagged - it is just waiting, or somebody moved it
    # elsewhere on purpose (the transition deliberately fires only on the
    # crossing, so a later manual choice stands). Neither is a ticket that
    # never had any stock recorded.
    def zero_status_problem
      return unless enabled? && config.zero_status_id

      recorded = entries
      return if recorded.empty? || recorded.sum(&:delta).positive?

      status = zero_status
      return :status_missing unless status
      return if issue.status_id == status.id

      ZeroStatusCheck.blocker(issue, status)
    end

    # We deliberately check <= 0 here, not == 0. The safe path (the
    # decrement button/controller) can never push the value below zero,
    # since it refuses to act once this predicate is already true. A
    # negative value can therefore only appear through the unsafe path -
    # someone hand-editing a comment to contain a larger write-off than
    # what was actually left. When that happens, the field should
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
