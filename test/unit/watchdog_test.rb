require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# The watchdog: when it is on, when it barks, the statuses it moves a ticket
# to when it starts and when it stops, and how a stuck move is reported.
class WatchdogTest < CustomDecrementField::TestCase
  def barking?(issue)
    CustomDecrementField::WatchdogCheck.barking?(reload(issue))
  end

  def batch(stock, level = nil)
    values = { @stock => stock.to_s }
    values[@batch_dog] = level.to_s if level
    create_issue(@batch, "batch #{stock}/#{level}", values)
  end

  def parent_with(level)
    create_issue(@parent, "parent #{level}", level.nil? ? {} : { @parent_dog => level.to_s })
  end

  # --- on and off -----------------------------------------------------------

  test 'it barks when the value is at or below a level above zero' do
    assert barking?(batch(3, 3))
    assert barking?(batch(2, 3))
    refute barking?(batch(4, 3))
  end

  test 'an empty level, zero and a negative level all mean off' do
    refute barking?(batch(0, nil))
    refute barking?(batch(0, 0))
    refute barking?(batch(0, -1))
    refute barking?(batch(5, 0))
  end

  test 'a new empty parent with a level of zero does not bark, and with a level above zero it does' do
    refute barking?(parent_with(0))
    refute barking?(parent_with(nil))
    assert barking?(parent_with(3)), 'no stock at all is below any real level'
  end

  test 'a closed issue does not bark' do
    issue = batch(2, 3)
    edit(issue, status: @closed)
    refute barking?(issue)
  end

  test 'it stays silent when the watched value is blank' do
    issue = create_issue(@batch, 'no stock', { @batch_dog => '3' })
    assert_nil reload(issue).custom_value_for(@stock)&.value.presence
    refute barking?(issue)
  end

  # --- starting and stopping ------------------------------------------------

  test 'it moves the issue when it starts barking and again when it starts after a recovery' do
    configure_dog(@batch_dog, trigger: @low, release: @back)
    issue = batch(4, 3)
    assert_equal @normal, status_of(issue)
    comment(issue, 'RASHOD : 1')
    assert_equal @low, status_of(issue)
    comment(issue, 'PRIHOD : 5')
    assert_equal @back, status_of(issue)
    comment(issue, 'RASHOD : 6')
    assert_equal @low, status_of(issue)
  end

  test 'it does not move the issue again while it keeps barking' do
    configure_dog(@batch_dog, trigger: @low, release: @back)
    issue = batch(4, 3)
    issue = comment(issue, 'RASHOD : 1')
    edit(issue, status: @normal)
    comment(issue, 'RASHOD : 1')
    assert_equal @normal, status_of(issue), 'a later manual choice stands'
  end

  test 'a ticket created below its level is not moved' do
    configure_dog(@batch_dog, trigger: @low, release: @back)
    assert_equal @normal, status_of(batch(1, 3))
  end

  test 'a new parent is not moved the moment it is made, and its first sufficient child releases it' do
    configure_dog(@parent_dog, trigger: @low, release: @back)
    parent = parent_with(3)
    assert_equal @normal, status_of(parent)
    create_issue(@batch, 'child', { @stock => '5' }, parent: parent)
    assert_equal @back, status_of(parent)
  end

  test 'a comment edited on its own is noticed' do
    configure_dog(@batch_dog, trigger: @low)
    issue = comment(batch(5, 3), 'RASHOD : 1')
    assert_equal @normal, status_of(issue)
    journal = issue.journals.reorder(:id).last
    journal.notes = 'RASHOD : 3'
    journal.save!
    assert_equal @low, status_of(issue)
  end

  test 'raising the level above the value starts it, lowering it below the value stops it' do
    configure_dog(@batch_dog, trigger: @low, release: @back)
    issue = batch(5, 3)
    edit(issue, { @batch_dog => '10' })
    assert_equal @low, status_of(issue)
    edit(issue, { @batch_dog => '1' })
    assert_equal @back, status_of(issue)
  end

  test 'a closed issue is never moved' do
    configure_dog(@batch_dog, trigger: @low, release: @back)
    issue = batch(2, 3)
    edit(issue, status: @closed)
    comment(issue, 'PRIHOD : 10')
    assert_equal @closed, status_of(issue)
  end

  # --- switching it off or on -----------------------------------------------

  test 'switching it off while it barks does not release the issue' do
    configure_dog(@batch_dog, trigger: @low, release: @back)
    [nil, '0'].each do |off|
      issue = comment(batch(4, 3), 'RASHOD : 1')
      assert_equal @low, status_of(issue)
      edit(issue, { @batch_dog => off.to_s })
      assert_equal @low, status_of(issue), "level #{off.inspect} switched it off, nothing recovered"
    end
  end

  test 'typing a level in later, when the value is already below it, starts it' do
    configure_dog(@batch_dog, trigger: @low)
    issue = batch(2)
    edit(issue, { @batch_dog => '3' })
    assert_equal @low, status_of(issue)
  end

  test 'typing zero in later does nothing' do
    configure_dog(@batch_dog, trigger: @low)
    issue = batch(2)
    edit(issue, { @batch_dog => '0' })
    assert_equal @normal, status_of(issue)
  end

  # --- a parent's sum -------------------------------------------------------

  test 'a parent moves when its sum crosses the level because a child changed' do
    configure_dog(@parent_dog, trigger: @low, release: @back)
    parent = parent_with(3)
    first = create_issue(@batch, 'one', { @stock => '5' }, parent: parent)
    second = create_issue(@batch, 'two', { @stock => '5' }, parent: parent)
    assert_equal @back, status_of(parent)
    comment(first, 'RASHOD : 5')
    comment(second, 'RASHOD : 2')
    assert_equal 3, reload(parent).custom_value_for(@sum).value.to_f
    assert_equal @low, status_of(parent)
    comment(second, 'PRIHOD : 6')
    assert_equal @back, status_of(parent)
  end

  test 'saving a sum field does not move anything' do
    configure_dog(@parent_dog, trigger: @low)
    parent = parent_with(3)
    @sum.update!(multiplier_token: 'FASOVKA2')
    assert_equal @normal, status_of(parent)
  end

  # --- a move that cannot be made -------------------------------------------

  test 'a trigger status outside the workflow is skipped and reported, and off silences the report' do
    configure_dog(@batch_dog, trigger: @orphan)
    issue = comment(batch(4, 3), 'RASHOD : 1')
    assert_equal @normal, status_of(issue)
    assert_equal [[:trigger, :not_in_workflow]], watchdog_problems(issue)
    assert reload(issue).css_classes.include?('custom-decrement-field-inconsistent')
    edit(issue, { @batch_dog => '0' })
    assert_empty watchdog_problems(issue)
  end

  test 'a release status that cannot be applied is reported for an issue still in the trigger status' do
    configure_dog(@batch_dog, trigger: @low, release: @orphan)
    issue = comment(batch(4, 3), 'RASHOD : 1')
    issue = comment(issue, 'PRIHOD : 5')
    assert_equal @low, status_of(issue)
    assert_equal [[:release, :not_in_workflow]], watchdog_problems(issue)
    edit(issue, { @batch_dog => '0' })
    assert_empty watchdog_problems(issue), 'switched off: nothing to report'
  end

  test 'a healthy issue that never sat in the trigger status is not reported for a bad release status' do
    configure_dog(@batch_dog, trigger: @low, release: @orphan)
    assert_empty watchdog_problems(batch(10, 3))
  end

  test 'a deleted trigger status is reported' do
    @batch_dog.update!(trigger_status_id: '999999')
    issue = comment(batch(4, 3), 'RASHOD : 1')
    assert_equal [[:trigger, :status_missing]], watchdog_problems(issue)
  end

  test 'the stuck-move report fills the inconsistent query filter' do
    configure_dog(@batch_dog, trigger: @orphan)
    issue = comment(batch(4, 3), 'RASHOD : 1')
    assert_includes CustomDecrementField::StockCalculator.inconsistent_issue_ids(Issue.where(id: issue.id)), issue.id
  end
end
