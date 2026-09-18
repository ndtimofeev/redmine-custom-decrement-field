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
    # per field) and a single save, rather than calling init_journal once
    # per field. Issue only tracks one pending journal per save
    # (`@current_journal`), so a second init_journal call would silently
    # replace the first call's text instead of adding to it - joining the
    # lines ourselves avoids losing all but the last field's seed value.
    def custom_decrement_field_seed
      notes_lines = CustomDecrementField::TokenConfig.fields_for_tracker(tracker).filter_map do |field|
        amount = custom_value_for(field)&.value.to_i
        next if amount.zero? # nothing typed (or explicitly zero) - no history entry needed

        config = CustomDecrementField::TokenConfig.for_field(field)
        "#{config.token}:#{amount}"
      end

      return if notes_lines.empty?

      init_journal(User.current, notes_lines.join("\n"))
      save!
    end

    # Recomputes every decrementable field on this issue's tracker and
    # writes the results back. This is the only place that ever writes to
    # a decrementable custom field after issue creation, and that is what
    # makes the "field can only be changed through comments" guarantee
    # hold: whatever a user (or a REST API client) submits directly for
    # the field on an update is simply overwritten here, in the very same
    # request, before the response is ever rendered back to them.
    #
    # Re-entrancy note: the zero-status transition below calls `save!`
    # again on this same Issue instance, purely to record the status
    # change through Redmine's normal save path (see the comment on that
    # call for why). That nested save re-triggers this very same
    # after_save callback. Without the guard flag this would not be
    # infinite recursion - by the second pass, value_in_db already equals
    # the freshly computed value, so the ">0 crossing to <=0" condition
    # below can no longer be true, and the transition simply does not fire
    # again - but it would still mean a wasted extra pass recomputing
    # every decrementable field on the tracker, whose result is thrown
    # away. The @custom_decrement_field_processing flag skips that
    # redundant pass outright, instead of relying on the transition
    # condition to merely make it a no-op.
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

      # The status is set directly on the model and saved, bypassing the
      # Workflow transition-permission check that would normally apply if
      # a user picked this status from the issue's status dropdown. That
      # check exists to stop a *user* from moving an issue somewhere their
      # role isn't allowed to send it; it should not also stop an
      # *automated* consequence of running out of stock just because the
      # operator who happened to press the decrement button doesn't
      # personally have permission to, say, close the issue. This is the
      # same technique used by other "auto-transition on some system
      # condition" style Redmine plugins (e.g. auto-closing a parent once
      # its last sub-issue closes).
      self.status = zero_status
      init_journal(User.current) # empty notes: only the status change itself needs to be recorded
      save!
    end
  end
end

Issue.include(CustomDecrementField::IssuePatch) unless Issue.include?(CustomDecrementField::IssuePatch)
