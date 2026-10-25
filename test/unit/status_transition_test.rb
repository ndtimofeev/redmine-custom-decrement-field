require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# The shared "move this ticket to that status" step used by the zero status and
# by the watchdog: when it may happen, and the move itself.
class StatusTransitionTest < CustomDecrementField::TestCase
  def blocker(issue, status)
    CustomDecrementField::StatusTransition.blocker(reload(issue), status)
  end

  test 'a status is known to a tracker through its workflow or as its default' do
    assert CustomDecrementField::StatusTransition.in_workflow?(@batch, @low)
    assert CustomDecrementField::StatusTransition.in_workflow?(@batch, @normal)
    refute CustomDecrementField::StatusTransition.in_workflow?(@batch, @orphan)
  end

  test 'a status outside the workflow blocks the move' do
    issue = create_issue(@batch, 'a')
    assert_equal :not_in_workflow, blocker(issue, @orphan)
    assert_nil blocker(issue, @low)
  end

  test 'a closing status is blocked while the issue has an open subtask' do
    issue = create_issue(@batch, 'a')
    child = create_issue(@batch, 'child', {}, parent: issue)
    assert_equal :not_closable, blocker(issue, @closed)
    edit(child, status: @closed)
    assert_nil blocker(issue, @closed)
  end

  test 'an open status is blocked for a subtask of a closed parent' do
    parent = create_issue(@batch, 'parent')
    child = create_issue(@batch, 'child', {}, parent: parent)
    edit(child, status: @closed)
    edit(parent, status: @closed)
    assert_equal :not_reopenable, blocker(child, @low)
  end

  test 'the trackers a field is attached to that lack a status are listed' do
    other = create_tracker('Other')
    other.update!(default_status: @orphan)
    WorkflowTransition.where(tracker_id: other.id).delete_all
    @stock.update!(tracker_ids: [@batch.id, other.id])
    assert_equal [other], CustomDecrementField::StatusTransition.trackers_without(@stock.reload, @low)
  end

  test 'apply moves the issue, writes one journal detail and keeps the in-memory copy in step' do
    issue = reload(create_issue(@batch, 'a'))
    assert CustomDecrementField::StatusTransition.apply(issue, @low)
    assert_equal @low.id, issue.status_id
    assert_equal @low, status_of(issue)
    detail = reload(issue).journals.last.details.find { |d| d.prop_key == 'status_id' }
    assert_equal [@normal.id.to_s, @low.id.to_s], [detail.old_value, detail.value]
  end

  test 'apply sets closed_on when the issue becomes closed, and not otherwise' do
    issue = reload(create_issue(@batch, 'a'))
    CustomDecrementField::StatusTransition.apply(issue, @low)
    assert_nil reload(issue).closed_on
    CustomDecrementField::StatusTransition.apply(issue, @closed)
    assert_not_nil reload(issue).closed_on
  end

  test 'apply takes the done ratio from the status when the instance works that way' do
    with_settings issue_done_ratio: 'issue_status' do
      @low.update!(default_done_ratio: 40)
      issue = reload(create_issue(@batch, 'a'))
      CustomDecrementField::StatusTransition.apply(issue, @low)
      assert_equal 40, reload(issue).done_ratio
    end
  end

  test 'of two movers that both saw the same status only the first one moves the issue' do
    issue = create_issue(@batch, 'a')
    first = Issue.find(issue.id)
    stale = Issue.find(issue.id)
    assert CustomDecrementField::StatusTransition.apply(first, @low)
    journals = reload(issue).journals.count
    refute CustomDecrementField::StatusTransition.apply(stale, @low)
    assert_equal journals, reload(issue).journals.count, 'the loser must not write a journal entry'
    assert_equal @low, status_of(issue)
  end
end
