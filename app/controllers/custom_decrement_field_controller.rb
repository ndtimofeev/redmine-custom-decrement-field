class CustomDecrementFieldController < ApplicationController
  before_action :find_issue
  before_action :find_field
  before_action :require_write_permission

  # The button (and any future QR-code flow) always decrements by exactly
  # 1 unit. Arbitrary amounts are only ever possible by hand-editing a
  # comment's text directly, and that is deliberately never exposed
  # anywhere in the UI: that path bypasses the concurrency-safe
  # check-then-write sequence below entirely, since it goes straight
  # through Redmine's ordinary comment editing, not this controller.
  DECREMENT_AMOUNT = 1

  def decrement
    Issue.transaction do
      # Locks the issue row for the duration of this transaction so that
      # two concurrent decrement requests for the same issue - e.g. two
      # people tapping the button, or two QR scans, at nearly the same
      # instant - are serialized rather than racing. The second request's
      # transaction only starts reading `calculator.value` once the
      # first one's comment has already been committed and the lock
      # released, so it correctly sees the updated total instead of a
      # stale one that would otherwise let both requests believe there
      # was still stock left.
      @issue.lock!

      calculator = CustomDecrementField::StockCalculator.new(@issue, @field)
      @remaining = calculator.value

      if calculator.exhausted?
        @error = l(:error_custom_decrement_field_exhausted)
        raise ActiveRecord::Rollback
      end

      # Adding this journal note is the only state change this action
      # makes directly. It does not touch the custom field's stored
      # value itself - that happens automatically afterwards, through
      # the very same after_save recalculation hook that reacts to any
      # other comment change (see
      # IssuePatch#custom_decrement_field_recalculate_all). From this
      # controller's point of view, decrementing and leaving a plain
      # comment are literally the same operation.
      @issue.init_journal(User.current, "#{calculator.config.token}:-#{DECREMENT_AMOUNT}")
      @issue.save!

      # Re-read after save! rather than doing simple arithmetic
      # (old value minus DECREMENT_AMOUNT) so that the reported number
      # always reflects an actual recalculation from history, exactly
      # like every other value this plugin ever shows.
      @remaining = CustomDecrementField::StockCalculator.new(@issue, @field).value
    end

    respond_to do |format|
      format.json { render json: { remaining: @remaining, error: @error } }
      format.html { redirect_to issue_path(@issue), notice: @error || l(:notice_custom_decrement_field_decremented) }
    end
  end

  private

  def find_issue
    @issue = Issue.find(params[:issue_id])
  end

  def find_field
    @field = IssueCustomField.find(params[:custom_field_id])
    # A plain 404 here, rather than a more specific error, is deliberate:
    # this controller should behave as if it does not exist at all for
    # any field that isn't marked as decrementable - exactly like a
    # stale or forged URL pointing at a field that was never configured
    # this way, rather than a "real" error worth explaining to the
    # caller.
    render_404 and return unless CustomDecrementField::TokenConfig.for_field(@field)
  end

  # No dedicated permission is introduced for this action. By design, the
  # right to decrement a field is exactly the right to leave a note on
  # the issue - add_issue_notes - because under the hood a decrement *is*
  # a specially formatted note, nothing more. Symmetrically, undoing a
  # decrement is exactly the standard Redmine permission to edit or
  # delete a note (edit_issue_notes / edit_own_issue_notes,
  # delete_issue_notes / delete_own_issue_notes), enforced by Redmine's
  # own issue controller at the moment the comment itself is edited or
  # removed - this controller never needs to duplicate that check
  # anywhere, because it never handles the undo path at all.
  def require_write_permission
    deny_access unless User.current.allowed_to?(:add_issue_notes, @issue.project)
  end
end
