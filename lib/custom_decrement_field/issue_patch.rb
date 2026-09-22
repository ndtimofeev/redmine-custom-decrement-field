module CustomDecrementField
  # Two callbacks are enough to make a decrementable field behave like a
  # "write-once, then derived forever after" counter, without ever needing
  # to distinguish "who" is writing to it:
  #
  # * an after_save seeds the very first history entry from whatever
  #   number the user typed into the field on the New Issue form, guarded
  #   to only ever do this on the save that created the record.
  # * a second after_save unconditionally recomputes the field from the
  #   current comment history and writes the result back on every save,
  #   including the one seed just triggered, silently discarding anything
  #   else that might have been submitted for the field in the same
  #   request.
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
        # Both hooks are after_save, and declaration order matters here:
        # seed must run - and its journal must be persisted - before
        # recalculate reads the comment history, and seed must also run
        # after Redmine's own Acts::Customizable#save_custom_field_values
        # (also after_save, registered by core long before this plugin
        # loads) has actually written the just-typed value into
        # custom_values. See custom_decrement_field_seed's comment for
        # why after_create is too early for that.
        after_save :custom_decrement_field_seed
        after_save :custom_decrement_field_recalculate_all
      end
    end

    private

    # Turns whatever the user typed into a decrementable field on the
    # issue-creation form into the first entry of its comment history,
    # instead of leaving it sitting only in custom_values where nothing
    # else would ever account for it.
    #
    # This has to be an after_save callback, not after_create as an
    # earlier version had it. custom_value_for reads from the `custom_values`
    # association - the actual persisted CustomValue records - and those
    # are only written by Redmine's own Acts::Customizable module via
    # `after_save :save_custom_field_values`. after_create always fires
    # before any after_save, for the very same save, so at after_create
    # time custom_value_for(field) is still reading whatever was there
    # *before* this save (nothing, for a brand new issue) - amount comes
    # out zero every time and the seed is silently skipped. Waiting for
    # our own after_save (which core's callback, registered first, has
    # already run by the time ours fires) is what makes the just-typed
    # value actually visible here.
    #
    # id_previously_changed? is the guard that makes this fire exactly
    # once, on creation, rather than every update: the primary key only
    # ever transitions from nil to a real value on the save that inserts
    # the row, so this is true on that one save and false on every save
    # after it - a well-established Rails idiom for "was this record just
    # created" from inside an after_save/after_commit callback, and more
    # robust than trying to infer it from field state.
    #
    # Unlike core's create_journal, we can no longer rely on some *later*
    # after_save picking up @current_journal for us - core's create_journal
    # is registered earlier than this plugin's callbacks and has already
    # run by the time we get here - so this method saves the journal
    # itself. That's still only ever a Journal#save, never a second
    # Issue#save, so it carries none of the re-entrant-save fragility
    # described in the module comment above. journals.reload guards
    # against the (in practice unlikely, but cheap to rule out) case
    # where something already cached the journals association before this
    # point, which would otherwise hide the just-created journal from
    # custom_decrement_field_recalculate_all's history scan that runs
    # right after this, on the same save.
    #
    # If several decrementable fields exist on the same tracker, all of
    # their seed values are folded into a single journal note (one line
    # per field), rather than calling init_journal once per field - Issue
    # only tracks one pending journal per save (`@current_journal`), so a
    # second init_journal call would silently replace the first call's
    # text instead of adding to it.
    def custom_decrement_field_seed
      return unless id_previously_changed?

      notes_lines = CustomDecrementField::TokenConfig.fields_for_tracker(tracker).filter_map do |field|
        amount = custom_value_for(field)&.value.to_i
        next if amount.zero? # nothing typed (or explicitly zero) - no history entry needed

        config = CustomDecrementField::TokenConfig.for_field(field)
        "#{config.token} : #{amount}"
      end

      return if notes_lines.empty?

      init_journal(User.current, notes_lines.join("\n"))
      current_journal.save!
      journals.reload
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
