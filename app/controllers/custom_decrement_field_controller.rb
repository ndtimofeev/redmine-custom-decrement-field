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
    literal = decrement_literal

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

      # Checked before exhausted?, and short-circuits regardless of
      # current stock either way: a caller that supplies a literal is
      # telling us "this is one specific decrement, not just any
      # decrement" - if that exact one is already on record, the right
      # answer is "nothing to do", not re-evaluating whether a fresh
      # decrement would currently be allowed.
      if literal && calculator.literal_used?(literal)
        @error = l(:error_custom_decrement_field_duplicate_literal)
        raise ActiveRecord::Rollback
      end

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
      # comment are literally the same operation. The literal, when
      # given, rides along as trailing text on the same line purely so
      # a later request can find it again via
      # StockCalculator#literal_used? - it plays no part in computing
      # the value itself.
      note = "#{calculator.config.token} : -#{DECREMENT_AMOUNT}"
      note = "#{note} #{literal}" if literal
      @issue.init_journal(User.current, note)
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

  # nil for anything that isn't a non-empty string made only of characters
  # that never need percent-encoding in a URL (RFC 3986's "unreserved" set:
  # letters, digits, "-", ".", "_", "~") - which also happens to be a safe
  # character class to embed as trailing text in a journal note without
  # needing any escaping of our own. A caller doesn't have to supply this
  # at all (params[:literal] simply absent is the common case, and behaves
  # exactly as before this existed); one that supplies something outside
  # this character class is treated the same as not having supplied one,
  # rather than rejecting the request outright, since a malformed literal
  # can't corrupt anything - it just can't be recorded/matched later.
  def decrement_literal
    raw = params[:literal].to_s
    raw if raw.match?(/\A[A-Za-z0-9_.~-]+\z/)
  end

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
