module CustomDecrementField
  # A sum field is only ever computed in reaction to events on issues (a save,
  # a comment, a child changing). Adding the field to a tracker that already
  # has parents - or changing its source field or multiplier token - is an
  # event on the FIELD, which nothing above listens to, so those parents would
  # show an empty value until someone happened to touch them. Saving the field
  # therefore recomputes it for every issue of the trackers it is attached to.
  module CustomFieldPatch
    def self.included(base)
      base.class_eval do
        # Registered after the has_and_belongs_to_many :trackers autosave, so
        # tracker_ids already reflects trackers attached in this same save.
        after_save :custom_decrement_field_backfill_sums
      end
    end

    private

    def custom_decrement_field_backfill_sums
      return unless field_format == 'decrement_sum'

      Issue.where(tracker_id: tracker_ids).find_each do |issue|
        CustomDecrementField::SumRecalculation.refresh(issue)
      end
    end
  end
end

unless IssueCustomField.include?(CustomDecrementField::CustomFieldPatch)
  IssueCustomField.include(CustomDecrementField::CustomFieldPatch)
end
