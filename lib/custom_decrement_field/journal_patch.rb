module CustomDecrementField
  module JournalPatch
    def self.included(base)
      base.class_eval do
        after_save :custom_decrement_field_recalculate
        after_destroy :custom_decrement_field_recalculate
      end
    end

    private

    # Правка или удаление комментария с токеном — штатный способ отката
    # случайного списания: пересчёт срабатывает сам, отдельного действия
    # "отменить" не существует.
    def custom_decrement_field_recalculate
      return unless journalized_type == 'Issue'

      journalized&.send(:custom_decrement_field_recalculate_all)
    end
  end
end

Journal.include(CustomDecrementField::JournalPatch) unless Journal.include?(CustomDecrementField::JournalPatch)
