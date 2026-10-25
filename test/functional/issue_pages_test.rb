require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# What the issue page, the edit form and the lists show: the button, the
# banner, the row classes, and the field's editability.
class IssuePagesTest < Redmine::ControllerTest
  tests IssuesController

  def setup
    @case = Class.new(CustomDecrementField::TestCase) { def runnable_methods; []; end }.new('noop')
    @case.setup
    %i[@batch @parent @stock @sum @batch_dog @parent_dog @low @orphan].each do |name|
      instance_variable_set(name, @case.instance_variable_get(name))
    end
    @request.session[:user_id] = 1
  end

  def teardown
    @case.teardown
  end

  def create(*args, **kw)
    @case.create_issue(*args, **kw)
  end

  test 'the issue page draws the button as a form that posts to the decrement endpoint' do
    issue = create(@batch, 'a', { @stock => '3' })
    get :show, params: { id: issue.id }
    assert_response :success
    assert_select "form[action=?] input.custom-decrement-field-button[type=submit]",
                  decrement_issue_custom_field_path(issue_id: issue.id, custom_field_id: @stock.id)
  end

  test 'the button is disabled when nothing is left' do
    issue = create(@batch, 'a')
    get :show, params: { id: issue.id }
    assert_select 'input.custom-decrement-field-button[disabled]'
  end

  test 'a list never shows the button, even with the field as a column' do
    create(@batch, 'a', { @stock => '3' })
    get :index, params: { set_filter: 1, tracker_id: @batch.id, c: ['subject', "cf_#{@stock.id}"] }
    assert_response :success
    assert_select 'input.custom-decrement-field-button', 0
  end

  test 'a negative value raises the banner, the marker and the row class' do
    issue = create(@batch, 'a', { @stock => '1' })
    @case.comment(issue, 'RASHOD : 5')
    get :show, params: { id: issue.id }
    assert_select '#custom-decrement-field-inconsistency-banner'
    assert_select '.custom-decrement-field-inconsistency-marker'
    assert_select 'div.issue.custom-decrement-field-inconsistent'
  end

  test 'the banner names why a move to the watchdog status could not be made' do
    @case.configure_dog(@batch_dog, trigger: @orphan)
    issue = @case.comment(create(@batch, 'a', { @stock => '4', @batch_dog => '3' }), 'RASHOD : 1')
    get :show, params: { id: issue.id }
    assert_select '#custom-decrement-field-inconsistency-banner li', text: /not in the workflow/
  end

  test 'a healthy issue has no banner' do
    issue = create(@batch, 'a', { @stock => '4' })
    get :show, params: { id: issue.id }
    assert_select '#custom-decrement-field-inconsistency-banner', 0
  end

  test 'the inconsistent filter finds the issue' do
    issue = create(@batch, 'a', { @stock => '1' })
    @case.comment(issue, 'RASHOD : 5')
    create(@batch, 'fine', { @stock => '4' })
    get :index, params: { set_filter: 1, f: ['custom_decrement_field_inconsistent'],
                          op: { custom_decrement_field_inconsistent: '=' },
                          v: { custom_decrement_field_inconsistent: ['1'] } }
    assert_response :success
    assert_select 'tr.issue', 1
    assert_select "tr#issue-#{issue.id}"
  end

  test 'the field is editable on the edit form only while it has no history' do
    empty = create(@batch, 'empty')
    get :edit, params: { id: empty.id }
    assert_select "input#issue_custom_field_values_#{@stock.id}:not([disabled])"

    filled = create(@batch, 'filled', { @stock => '5' })
    get :edit, params: { id: filled.id }
    assert_select "input#issue_custom_field_values_#{@stock.id}[disabled]"
  end

  test 'the sum field is never editable, the watchdog input explains that empty and 0 mean off' do
    parent = create(@parent, 'p')
    get :edit, params: { id: parent.id }
    assert_select "input#issue_custom_field_values_#{@sum.id}[disabled]"
    assert_select "input#issue_custom_field_values_#{@parent_dog.id}[title=?]",
                  I18n.t(:text_watchdog_level_hint)
  end

  test 'a barking issue is highlighted in the list and on its page' do
    issue = create(@batch, 'a', { @stock => '2', @batch_dog => '3' })
    get :show, params: { id: issue.id }
    assert_select 'div.issue.custom-decrement-field-low'
    get :index, params: { set_filter: 1, tracker_id: @batch.id }
    assert_select "tr#issue-#{issue.id}.custom-decrement-field-low"
  end

  test 'a watchdog with a level of zero does not highlight anything' do
    issue = create(@batch, 'a', { @stock => '0', @batch_dog => '0' })
    get :show, params: { id: issue.id }
    assert_select 'div.issue.custom-decrement-field-low', 0
  end
end
