module CustomDecrementField
  # Конфигурация декрементируемого поля хранится не в отдельной таблице
  # плагина, а прямо в description самого кастомного поля — так она
  # путешествует вместе с полем (копирование трекера, экспорт проекта) и
  # не оставляет никакого следа в схеме БД, если плагин отключить.
  #
  # Формат (одна строка где-нибудь внутри description, остальной текст —
  # обычная подсказка к полю для пользователей):
  #
  #   <!-- custom-decrement-field: token=MATSTOCK; zero-status-id=5 -->
  #
  # token — обязателен, ключевое слово, которое ищем в тексте комментариев.
  # zero-status-id — необязателен, id статуса, в который переводим задачу,
  # когда счётчик впервые достигает нуля или уходит ниже.
  module TokenConfig
    MARKER_REGEXP = /<!--\s*custom-decrement-field:\s*(.+?)\s*-->/m

    Config = Struct.new(:token, :zero_status_id, keyword_init: true)

    def self.marker(token:, zero_status_id: nil)
      attrs = ["token=#{token}"]
      attrs << "zero-status-id=#{zero_status_id}" if zero_status_id.present?
      "<!-- custom-decrement-field: #{attrs.join('; ')} -->"
    end

    # Возвращает Config либо nil, если поле не размечено как декрементируемое.
    def self.for_field(custom_field)
      return nil unless custom_field&.description

      match = custom_field.description.match(MARKER_REGEXP)
      return nil unless match

      attrs = match[1].split(';').each_with_object({}) do |pair, memo|
        key, value = pair.split('=', 2).map(&:strip)
        memo[key] = value if key.present?
      end

      return nil if attrs['token'].blank?

      Config.new(
        token: attrs['token'],
        zero_status_id: attrs['zero-status-id'].presence&.to_i
      )
    end

    # Обычно на трекере одно такое поле, но ничто не мешает завести
    # несколько — у каждого свой токен, и они считаются независимо друг
    # от друга.
    def self.fields_for_tracker(tracker)
      return [] unless tracker

      tracker.custom_fields.select { |f| for_field(f) }
    end
  end
end
