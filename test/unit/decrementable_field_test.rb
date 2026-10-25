require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# The decrementable field itself: a value derived from comments written with
# two keywords, the number typed on creation or on an edit of an issue with no
# history, the zero status, duplicates and inconsistency.
class DecrementableFieldTest < CustomDecrementField::TestCase
  def calculator(issue)
    CustomDecrementField::StockCalculator.new(reload(issue), @stock)
  end

  test 'the number typed on creation becomes the first entry under the add keyword' do
    issue = create_issue(@batch, 'a', { @stock => '20' })
    assert_equal 20, stock_of(issue)
    assert_equal ['PRIHOD : 20'], issue.journals.map(&:notes)
  end

  test 'the add keyword adds, the write-off keyword subtracts, and the sign is ignored' do
    issue = create_issue(@batch, 'a', { @stock => '20' })
    comment(issue, 'RASHOD : 1')
    assert_equal 19, stock_of(issue)
    comment(issue, 'PRIHOD : 5')
    assert_equal 24, stock_of(issue)
    comment(issue, 'RASHOD : -3')
    assert_equal 21, stock_of(issue), 'a sign typed in front of the amount must not flip a write-off into an addition'
  end

  test 'the unspaced form counts, a word on the next line is not a literal' do
    issue = create_issue(@batch, 'a', { @stock => '10' })
    comment(issue, 'RASHOD:2')
    comment(issue, "RASHOD : 1\nthanks")
    comment(issue, "RASHOD : 1\nthanks")
    assert_equal 6, stock_of(issue)
    assert_empty calculator(issue).duplicate_literals
  end

  test 'a literal that was already used is found, and a repeat makes the field inconsistent' do
    issue = create_issue(@batch, 'a', { @stock => '10' })
    issue = comment(issue, 'PRIHOD : 5 delivery-42')
    assert calculator(issue).literal_used?('delivery-42')
    refute calculator(issue).inconsistent?
    issue = comment(issue, 'RASHOD : 1 delivery-42')
    assert_equal ['delivery-42'], calculator(issue).duplicate_literals.keys
    assert calculator(issue).inconsistent?
  end

  test 'overspending goes negative and is reported as inconsistent' do
    issue = create_issue(@batch, 'a', { @stock => '2' })
    issue = comment(issue, 'RASHOD : 9')
    assert_equal(-7, stock_of(issue))
    assert calculator(issue).negative?
    assert calculator(issue).inconsistent?
    assert CustomDecrementField::StockCalculator.inconsistent_issue_ids(Issue.where(id: issue.id)).include?(issue.id)
  end

  test 'editing a comment recomputes the value' do
    issue = create_issue(@batch, 'a', { @stock => '10' })
    issue = comment(issue, 'RASHOD : 1')
    journal = issue.journals.reorder(:id).last
    journal.notes = 'RASHOD : 4'
    journal.save!
    assert_equal 6, stock_of(issue)
  end

  test 'an issue made without an amount can be given one on the edit form, once' do
    issue = create_issue(@batch, 'a')
    assert_equal 0, stock_of(issue)
    issue = edit(issue, { @stock => '15' })
    assert_equal 15, stock_of(issue)
    assert_includes issue.journals.reorder(:id).last.notes, 'PRIHOD : 15'
    issue = edit(issue, { @stock => '99' })
    assert_equal 15, stock_of(issue), 'once there is a history the typed number is ignored'
  end

  test 'the amount typed on the edit form shares the journal with the comment' do
    issue = create_issue(@batch, 'a')
    issue = edit_with_note(issue, 'received from the supplier', @stock => '8')
    assert_equal ['received from the supplier', 'PRIHOD : 8'], issue.journals.last.notes.lines.map(&:chomp)
    assert_equal 1, issue.journals.count
  end

  test 'a zero or blank amount on the edit form records nothing' do
    issue = create_issue(@batch, 'a')
    issue = edit(issue, { @stock => '0' })
    issue = edit(issue, { @stock => '' })
    assert_empty calculator(issue).entries
  end

  test 'deleting the only entry makes the field editable again' do
    issue = create_issue(@batch, 'a', { @stock => '5' })
    issue.journals.first.destroy
    assert_equal 0, stock_of(issue)
    issue = edit(issue, { @stock => '7' })
    assert_equal 7, stock_of(issue)
  end

  test 'reaching zero moves the issue to the zero status' do
    @stock.update!(zero_status_id: @low.id.to_s)
    issue = create_issue(@batch, 'a', { @stock => '2' })
    issue = comment(issue, 'RASHOD : 1')
    assert_equal @normal, issue.status
    issue = comment(issue, 'RASHOD : 1')
    assert_equal @low, issue.status
    assert_nil issue.closed_on
  end

  test 'the zero-status move happens only on the crossing' do
    @stock.update!(zero_status_id: @low.id.to_s)
    issue = create_issue(@batch, 'a', { @stock => '1' })
    issue = comment(issue, 'RASHOD : 1')
    issue = edit(issue, status: @normal)
    issue = comment(issue, 'a remark that does not touch the stock')
    assert_equal @normal, issue.status
  end

  test 'a closing zero status sets closed_on' do
    @stock.update!(zero_status_id: @closed.id.to_s)
    issue = create_issue(@batch, 'a', { @stock => '1' })
    issue = comment(issue, 'RASHOD : 1')
    assert issue.closed?
    assert_not_nil issue.closed_on
  end

  test 'a zero status outside the tracker workflow is skipped and the issue is reported' do
    @stock.update!(zero_status_id: @orphan.id.to_s)
    issue = create_issue(@batch, 'a', { @stock => '1' })
    issue = comment(issue, 'RASHOD : 1')
    assert_equal @normal, issue.status
    assert_equal 0, stock_of(issue)
    assert_equal :not_in_workflow, calculator(issue).zero_status_problem
    assert calculator(issue).inconsistent?
  end

  test 'a closing zero status is skipped while the issue has an open subtask' do
    @stock.update!(zero_status_id: @closed.id.to_s)
    issue = create_issue(@batch, 'a', { @stock => '1' })
    child = create_issue(@batch, 'child', {}, parent: issue)
    issue = comment(issue, 'RASHOD : 1')
    assert_equal @normal, issue.status
    assert_equal :not_closable, calculator(issue).zero_status_problem
    edit(child, status: @closed)
    assert_nil calculator(issue).zero_status_problem, 'the report clears once the cause is gone'
  end

  test 'a deleted zero status is reported' do
    @stock.update!(zero_status_id: '999999')
    issue = create_issue(@batch, 'a', { @stock => '1' })
    issue = comment(issue, 'RASHOD : 1')
    assert_equal :status_missing, calculator(issue).zero_status_problem
  end

  test 'a field with a missing keyword, or the same one twice, is inert' do
    @stock.update_columns(format_store: @stock.format_store.merge('increment_token' => ''))
    assert_nil CustomDecrementField::TokenConfig.for_field(IssueCustomField.find(@stock.id))
    field = IssueCustomField.new(name: 'Same', field_format: 'decrementable_int', is_for_all: true,
                                 increment_token: 'X', decrement_token: 'X')
    refute field.valid?, 'saving the same word for both keywords must be refused'
  end

  private

  def edit_with_note(issue, note, values)
    current = Issue.find(issue.id)
    current.init_journal(@admin)
    current.notes = note
    current.custom_field_values = values.transform_keys(&:id)
    current.save!
    Issue.find(issue.id)
  end
end
