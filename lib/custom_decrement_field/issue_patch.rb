module CustomDecrementField
  module IssuePatch
    def self.included(base)
      base.class_eval do
        after_create :custom_decrement_field_seed
        after_save :custom_decrement_field_recalculate_all
      end
    end

    private

    # То, что пользователь вписал в декрементируемое поле на форме
    # создания задачи, становится первой записью истории — дальше поле
    # никогда больше не принимает прямой ввод, только через комментарии
    # (см. custom_decrement_field_recalculate, который перезатирает любое
    # постороннее значение при следующем же сохранении).
    def custom_decrement_field_seed
      notes_lines = CustomDecrementField::TokenConfig.fields_for_tracker(tracker).filter_map do |field|
        amount = custom_value_for(field)&.value.to_i
        next if amount.zero?

        config = CustomDecrementField::TokenConfig.for_field(field)
        "#{config.token}:#{amount}"
      end

      return if notes_lines.empty?

      init_journal(User.current, notes_lines.join("\n"))
      save!
    end

    def custom_decrement_field_recalculate_all
      # Защита от рекурсии: переход статуса ниже сам вызывает save!, что
      # снова триггерит этот же after_save. Без гарда это не бесконечный
      # цикл (на втором проходе граница уже не пересекается и переход не
      # повторится), но лишний повторный save! на пустом месте лучше не
      # допускать.
      return if @custom_decrement_field_processing

      @custom_decrement_field_processing = true
      begin
        CustomDecrementField::TokenConfig.fields_for_tracker(tracker).each do |field|
          custom_decrement_field_recalculate(field)
        end
      ensure
        @custom_decrement_field_processing = false
      end
    end

    def custom_decrement_field_recalculate(field)
      calculator = CustomDecrementField::StockCalculator.new(self, field)
      return unless calculator.enabled?

      old_value = calculator.value_in_db
      new_value = calculator.value

      cv = custom_value_for(field) || custom_values.build(custom_field: field)
      if cv.value.to_i != new_value
        cv.value = new_value
        cv.save!
      end

      zero_status = calculator.zero_status
      return unless zero_status
      return unless old_value.positive? && new_value <= 0
      return if status_id == zero_status.id

      self.status = zero_status
      init_journal(User.current)
      save!
    end
  end
end

Issue.include(CustomDecrementField::IssuePatch) unless Issue.include?(CustomDecrementField::IssuePatch)
