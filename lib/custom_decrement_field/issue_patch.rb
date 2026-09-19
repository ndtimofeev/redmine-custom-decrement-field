module CustomDecrementField
  # Two callbacks are enough to make a decrementable field behave like a
  # "write-once, then derived forever after" counter, without ever needing
  # to distinguish "who" is writing to it:
  #
  # * after_create seeds the very first history entry from whatever number
  #   the user typed into the field on the New Issue form.
  # * after_save (which also fires for the very save that after_create's
  #   own logic triggers, as well as for every later update, including
  #   ones made through the REST API) unconditionally recomputes the
  #   field from the current comment history and writes the result back,
  #   silently discarding anything else that might have been submitted
  #   for it in the same request.
  #
  # Neither of these ever calls Issue#save/#save! on `self` from within a
  # callback. An earlier version of this file did, for both the seed and
  # the zero-status transition, and it intermittently raised
  # ActiveRecord::StaleObjectError: re-saving the very same Issue instance
  # from inside its own after_save/after_create, while Redmine's
  # optimistic locking (issues.lock_version) is active, is a well-known
  # fragile pattern - re-entrant saves on one instance can trip the
  # version check even though nothing else touched the row. Both call
  # sites below were rewritten to never do that; see each method's
  # comment for the Redmine-native mechanism that replaces it.
  module IssuePatch
    def self.included(base)
      base.class_eval do
        after_create :custom_decrement_field_seed
        after_save :custom_decrement_field_recalculate_all
      end
    end

    private

    # Turns whatever the user typed into a decrementable field on the
    # issue-creation form into the first entry of its comment history,
    # instead of leaving it sitting only in custom_values where nothing
    # else would ever account for it.
    #
    # This only calls init_journal - it deliberately does NOT call save
    # afterwards. init_journal merely stages @current_journal in memory;
    # Redmine's own Issue#create_journal (`# Called after_save`, see
    # app/models/issue.rb) is already registered as a core after_save
    # callback, and since after_create always fires before after_save
    # within the very same save, it runs after this method and persists
    # @current_journal on its own - as `current_journal.save`, a plain
    # Journal save, never a second Issue save. There is nothing left for
    # us to save here.
    #
    # This runs once, in after_create, specifically because the New Issue
    # form is the *only* moment a human is meant to type a plain number
    # directly into one of these fields: every later save is instead
    # handled by custom_decrement_field_recalculate below, which always
    # overwrites the field with the value derived from history, regardless
    # of what was submitted. There is no separate "is this still the
    # first save" flag anywhere in this code - after_create simply never
    # fires again for a given record, so this seeding logic can never
    # accidentally run a second time for the same issue.
    #
    # If several decrementable fields exist on the same tracker, all of
    # their seed values are folded into a single journal note (one line
    # per field), rather than calling init_journal once per field - Issue
    # only tracks one pending journal per save (`@current_journal`), so a
    # second init_journal call would silently replace the first call's
    # text instead of adding to it.
    def custom_decrement_field_seed
      notes_lines = CustomDecrementField::TokenConfig.fields_for_tracker(tracker).filter_map do |field|
        amount = custom_value_for(field)&.value.to_i
        next if amount.zero? # nothing typed (or explicitly zero) - no history entry needed

        config = CustomDecrementField::TokenConfig.for_field(field)
        "#{config.token}:#{amount}"
      end

      return if notes_lines.empty?

      init_journal(User.current, notes_lines.join("\n"))
    end

    # Recomputes every decrementable field on this issue's tracker and
    # writes the results back. This is the only place that ever writes to
    # a decrementable custom field after issue creation, and that is what
    # makes the "field can only be changed through comments" guarantee
    # hold: whatever a user (or a REST API client) submits directly for
    # the field on an update is simply overwritten here, in the very same
    # request, before the response is ever rendered back to them.
    #
    # Re-entrancy note: the zero-status transition below persists a
    # Journal directly (see custom_decrement_field_apply_zero_status),
    # which re-triggers JournalPatch's after_save hook, which calls back
    # into this very method on the same Issue instance. That's still
    # genuine re-entrancy, just no longer through Issue#save - the guard
    # flag exists to skip that redundant nested pass outright (its result
    # would be thrown away anyway, since nothing about the computed value
    # changes between the two passes), not to work around any locking
    # error - update_column and Journal#save don't touch issues.lock_version.
    def custom_decrement_field_recalculate_all
      return if @custom_decrement_field_processing

      @custom_decrement_field_processing = true
      begin
        CustomDecrementField::TokenConfig.fields_for_tracker(tracker).each do |field|
          custom_decrement_field_recalculate(field)
        end
      ensure
        @custom_decrement_field_processing = false
      end
    end

    def custom_decrement_field_recalculate(field)
      calculator = CustomDecrementField::StockCalculator.new(self, field)
      return unless calculator.enabled?

      old_value = calculator.value_in_db
      new_value = calculator.value

      cv = custom_value_for(field) || custom_values.build(custom_field: field)
      if cv.value.to_i != new_value
        cv.value = new_value
        cv.save!
      end

      zero_status = calculator.zero_status
      return unless zero_status
      # Only fire on the exact crossing from "still had some left" to "now
      # at or below zero" - never merely "currently at or below zero".
      # Without this edge check, an unrelated recalculation (e.g. someone
      # editing the wording of a comment that doesn't even touch the
      # token, or a save triggered by something else entirely) would fire
      # again every time it happens to run while the value is still
      # sitting at zero - even after an operator has deliberately moved
      # the issue to a different status to keep working on it while
      # waiting for a restock. Checking the transition rather than the
      # current state means this automation only ever acts once per
      # depletion event, and it leaves a human's later status change alone
      # until the counter is topped back up and drained again.
      return unless old_value.positive? && new_value <= 0
      return if status_id == zero_status.id

      custom_decrement_field_apply_zero_status(zero_status)
    end

    # Moves the issue to zero_status and records that as a normal
    # "Status changed from X to Y" journal entry, without ever calling
    # Issue#save on `self` (see the re-entrancy note above for why that
    # matters here specifically).
    #
    # update_column bypasses validations, callbacks and the optimistic
    # locking check entirely - appropriate here, since this is a system-
    # triggered side effect of running out of stock, not a user-picked
    # status transition, and it should not be blocked by the Workflow
    # transition-permission check that exists to constrain *users*, nor
    # by re-entrant-save fragility. Journal#add_attribute_detail is the
    # same private helper Redmine's own core code uses (e.g. Issue's
    # parent/child change tracking) to build a normal attribute-change
    # journal detail by hand. Reusing (rather than creating a second)
    # current_journal, when one is already pending from whatever add-a-
    # comment action triggered this recalculation (typically the
    # decrement controller), makes the status change show up as part of
    # that same journal entry - "removed 1, status: New -> Depleted" as
    # one history entry, not two.
    def custom_decrement_field_apply_zero_status(zero_status)
      Issue.transaction do
        old_status_id = status_id
        update_column(:status_id, zero_status.id)

        journal = init_journal(User.current)
        journal.send(:add_attribute_detail, 'status_id', old_status_id, zero_status.id)
        journal.save!
      end
    end
  end
end

Issue.include(CustomDecrementField::IssuePatch) unless Issue.include?(CustomDecrementField::IssuePatch)
