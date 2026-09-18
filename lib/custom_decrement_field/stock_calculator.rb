module CustomDecrementField
  # Единственный источник истины — текущий текст комментариев к задаче.
  # Значение поля никогда не хранит ничего, кроме кэша последнего
  # пересчёта: правка или удаление комментария меняет результат сама
  # по себе, без отдельного журнала декрементов.
  class StockCalculator
    def initialize(issue, field)
      @issue = issue
      @field = field
      @config = TokenConfig.for_field(field)
    end

    attr_reader :issue, :field, :config

    def enabled?
      config.present?
    end

    def value
      return 0 unless enabled?

      pattern = /#{Regexp.escape(config.token)}\s*:\s*([+-]?\d+)/

      issue.journals.sum do |journal|
        next 0 if journal.notes.blank?

        journal.notes.scan(pattern).sum { |m| m.first.to_i }
      end
    end

    # <= 0, а не == 0: число может уйти в минус в обход кнопки (кто-то
    # руками поправил комментарий) — это тоже "закончилось", просто ещё и
    # сигнал, что стоит проверить историю.
    def exhausted?
      value <= 0
    end

    def zero_status
      return nil unless config&.zero_status_id

      @zero_status ||= IssueStatus.find_by(id: config.zero_status_id)
    end

    # То, что прямо сейчас лежит в custom_values, ДО пересчёта — нужно,
    # чтобы поймать момент пересечения границы >0 -> <=0 и не дёргать
    # переход статуса на каждый пересчёт подряд.
    def value_in_db
      issue.custom_value_for(field)&.value.to_i
    end
  end
end
