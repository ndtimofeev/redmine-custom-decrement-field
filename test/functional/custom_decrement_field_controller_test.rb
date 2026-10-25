require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# The endpoint behind the "-" button (and the QR scanner's equivalent):
# permissions, the written note, the duplicate guard, the exhausted refusal.
class CustomDecrementFieldControllerTest < Redmine::ControllerTest
  tests CustomDecrementFieldController

  def setup
    @case = Class.new(CustomDecrementField::TestCase) { def runnable_methods; []; end }.new('noop')
    @case.setup
    @issue = @case.create_issue(@case.instance_variable_get(:@batch), 'button',
                                { @case.instance_variable_get(:@stock) => '3' })
    @stock = @case.instance_variable_get(:@stock)
    @sum = @case.instance_variable_get(:@sum)
    @request.session[:user_id] = 1
  end

  def teardown
    @case.teardown
  end

  def decrement(extra = {})
    post :decrement, params: { issue_id: @issue.id, custom_field_id: @stock.id }.merge(extra)
  end

  def current
    Issue.find(@issue.id)
  end

  test 'it writes one write-off line and redirects back to the issue' do
    assert_difference -> { current.journals.count }, 1 do
      decrement
    end
    assert_redirected_to issue_path(@issue)
    assert_equal 'RASHOD : 1', current.journals.reorder(:id).last.notes
    assert_equal 2, current.custom_value_for(@stock).value.to_i
  end

  test 'it answers json with what is left' do
    decrement(format: 'json')
    assert_response :success
    assert_equal({ 'remaining' => 2, 'error' => nil }, JSON.parse(response.body))
  end

  test 'a literal rides along on the same line, and a repeat of it is refused' do
    decrement(literal: 'scan-1')
    assert_equal 'RASHOD : 1 scan-1', current.journals.reorder(:id).last.notes
    assert_no_difference -> { current.journals.count } do
      decrement(literal: 'scan-1')
    end
    assert_equal 2, current.custom_value_for(@stock).value.to_i
    assert_equal I18n.t(:error_custom_decrement_field_duplicate_literal), flash[:notice]
  end

  test 'a literal with characters outside the safe set is ignored, the write-off still counts' do
    decrement(literal: 'not ok!')
    assert_equal 'RASHOD : 1', current.journals.reorder(:id).last.notes
  end

  test 'it refuses when nothing is left' do
    3.times { decrement }
    assert_equal 0, current.custom_value_for(@stock).value.to_i
    assert_no_difference -> { current.journals.count } do
      decrement
    end
    assert_equal I18n.t(:error_custom_decrement_field_exhausted), flash[:notice]
  end

  test 'a field that is not a decrementable one is a 404' do
    post :decrement, params: { issue_id: @issue.id, custom_field_id: @sum.id }
    assert_response :not_found
  end

  test 'it needs exactly the permission to add notes' do
    role = Role.find(1)
    role.remove_permission!(:add_issue_notes)
    @request.session[:user_id] = 2 # a member of the project with that role
    assert_no_difference -> { current.journals.count } do
      decrement
    end
    assert_response :forbidden
    assert_equal 3, current.custom_value_for(@stock).value.to_i

    role.add_permission!(:add_issue_notes)
    assert_difference -> { current.journals.count }, 1 do
      decrement
    end
  end
end
