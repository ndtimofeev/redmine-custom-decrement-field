module CustomDecrementField
  # A decrementable field has no dedicated "undo" button of its own.
  # Instead, editing or deleting the comment that recorded a decrement
  # *is* the entire undo mechanism: this hook makes sure that whenever a
  # journal's notes change, or a journal is removed outright, every
  # decrementable field on the parent issue gets recomputed from the
  # comment history that remains - exactly as if that comment had read
  # differently, or had never existed, from the very start. There is
  # nothing else anywhere in this plugin that treats "undo" as a separate
  # operation from "the history changed".
  module JournalPatch
    def self.included(base)
      base.class_eval do
        after_save :custom_decrement_field_recalculate
        after_destroy :custom_decrement_field_recalculate
      end
    end

    private

    def custom_decrement_field_recalculate
      # journalized_type can in principle be something other than 'Issue'
      # (Journal is a polymorphic model), even though in practice Redmine
      # core only ever attaches journals to issues. Guarding here costs
      # nothing and avoids assuming that will always stay true.
      return unless journalized_type == 'Issue'

      # custom_decrement_field_recalculate_all is a private method defined
      # on Issue by IssuePatch. It is intentionally kept private, since
      # nothing outside this plugin's own hooks should ever call it
      # directly, and `send` is the standard way to reach across that
      # boundary from a sibling patch living in a different class.
      journalized&.send(:custom_decrement_field_recalculate_all)
    end
  end
end

Journal.include(CustomDecrementField::JournalPatch) unless Journal.include?(CustomDecrementField::JournalPatch)
