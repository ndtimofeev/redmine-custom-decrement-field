# Loads Redmine's own test helper (and with it every core fixture), so the
# plugin's tests run the way core's do: from Redmine's root, in the test
# environment, e.g.
#
#   RAILS_ENV=test bundle exec ruby -Itest \
#     plugins/redmine_custom_decrement_field/test/unit/watchdog_test.rb
#
# or all of them, through core's plugin task:
#
#   RAILS_ENV=test bundle exec rake redmine:plugins:test NAME=redmine_custom_decrement_field
require File.expand_path(File.dirname(__FILE__) + '/../../../test/test_helper')

module CustomDecrementField
  # The world every test starts from: two trackers of our own with a small
  # workflow of our own (so nothing depends on what core's fixtures happen to
  # allow), the plugin's fields on them, and a few helpers to make issues and
  # write comments the way the controller does. Each test runs in a
  # transaction that is rolled back, like core's.
  #
  #   @batch    tracker with the decrementable field, @stock, and a watchdog on it
  #   @parent   tracker with the sum field, @sum, and a watchdog on it
  #   statuses: @normal (the default), @low, @back, @closed (all in the workflow
  #             of both trackers), @orphan (in nobody's workflow)
  class TestCase < ActiveSupport::TestCase
    def setup
      @admin = User.find(1)
      User.current = @admin
      @project = Project.find(1)

      @normal = IssueStatus.find(1)
      @closed = IssueStatus.find(5)
      @low = IssueStatus.create!(name: 'Low stock')
      @back = IssueStatus.create!(name: 'Back in stock')
      @orphan = IssueStatus.create!(name: 'Orphan')

      @batch = create_tracker('Batch')
      @parent = create_tracker('Parent')

      @stock = IssueCustomField.create!(
        name: 'Stock', field_format: 'decrementable_int', is_for_all: true, tracker_ids: [@batch.id],
        increment_token: 'PRIHOD', decrement_token: 'RASHOD'
      )
      @sum = IssueCustomField.create!(
        name: 'Sum', field_format: 'decrement_sum', is_for_all: true, tracker_ids: [@parent.id],
        source_field_id: @stock.id.to_s, multiplier_token: 'FASOVKA'
      )
      @batch_dog = IssueCustomField.create!(
        name: 'Batch level', field_format: 'watchdog', is_for_all: true, tracker_ids: [@batch.id],
        watched_field_id: @stock.id.to_s
      )
      @parent_dog = IssueCustomField.create!(
        name: 'Parent level', field_format: 'watchdog', is_for_all: true, tracker_ids: [@parent.id],
        watched_field_id: @sum.id.to_s
      )
    end

    def teardown
      User.current = nil
    end

    def create_tracker(name)
      tracker = Tracker.create!(name: name, default_status: @normal)
      @project.trackers << tracker
      role = Role.find(1)
      [@low, @back, @closed].each do |status|
        WorkflowTransition.create!(tracker: tracker, role: role, old_status: @normal, new_status: status)
        WorkflowTransition.create!(tracker: tracker, role: role, old_status: status, new_status: @normal)
      end
      [[@low, @back], [@back, @low]].each do |from, to|
        WorkflowTransition.create!(tracker: tracker, role: role, old_status: from, new_status: to)
      end
      tracker
    end

    # values: { custom field => value }
    def create_issue(tracker, subject, values = {}, parent: nil)
      issue = Issue.new(project: @project, tracker: tracker, subject: subject, author: @admin,
                        status: tracker.default_status, priority: IssuePriority.first)
      issue.custom_field_values = values.transform_keys(&:id)
      issue.parent_issue_id = parent.id if parent
      issue.save!
      Issue.find(issue.id)
    end

    # A comment saved the way the decrement controller (and any user adding a
    # note) does it.
    def comment(issue, note)
      current = Issue.find(issue.id)
      current.init_journal(@admin, note)
      current.save!
      Issue.find(issue.id)
    end

    # An ordinary edit: values is { custom field => value }, status optional.
    def edit(issue, values = {}, status: nil)
      current = Issue.find(issue.id)
      current.init_journal(@admin)
      current.custom_field_values = values.transform_keys(&:id) unless values.empty?
      current.status = status if status
      current.save!
      Issue.find(issue.id)
    end

    def reload(issue)
      Issue.find(issue.id)
    end

    def stock_of(issue)
      reload(issue).custom_value_for(@stock)&.value.to_i
    end

    def status_of(issue)
      reload(issue).status
    end

    def watchdog_problems(issue)
      CustomDecrementField::WatchdogCheck.status_problems(reload(issue)).map { |_, kind, reason| [kind, reason] }
    end

    def configure_dog(dog, trigger: nil, release: nil)
      dog.trigger_status_id = trigger ? trigger.id.to_s : ''
      dog.release_status_id = release ? release.id.to_s : ''
      dog.save!
    end
  end
end
