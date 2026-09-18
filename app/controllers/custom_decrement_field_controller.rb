class CustomDecrementFieldController < ApplicationController
  before_action :find_issue
  before_action :find_field
  before_action :require_write_permission

  # Кнопка всегда списывает ровно 1 — произвольные величины возможны
  # только руками, через текст комментария, сознательно не выведены в
  # интерфейс (см. README).
  DECREMENT_AMOUNT = 1

  def decrement
    Issue.transaction do
      @issue.lock!

      calculator = CustomDecrementField::StockCalculator.new(@issue, @field)
      @remaining = calculator.value

      if calculator.exhausted?
        @error = l(:error_custom_decrement_field_exhausted)
        raise ActiveRecord::Rollback
      end

      @issue.init_journal(User.current, "#{calculator.config.token}:-#{DECREMENT_AMOUNT}")
      @issue.save!

      @remaining = CustomDecrementField::StockCalculator.new(@issue, @field).value
    end

    respond_to do |format|
      format.json { render json: { remaining: @remaining, error: @error } }
      format.html { redirect_to issue_path(@issue), notice: @error || l(:notice_custom_decrement_field_decremented) }
    end
  end

  private

  def find_issue
    @issue = Issue.find(params[:issue_id])
  end

  def find_field
    @field = IssueCustomField.find(params[:custom_field_id])
    render_404 and return unless CustomDecrementField::TokenConfig.for_field(@field)
  end

  # Своего permission не заводим: право списывать = право оставлять
  # заметки к задаче. Откат (удаление заметки) точно так же подчиняется
  # штатным правам Redmine на удаление своих/любых заметок — отдельно
  # это здесь проверять не нужно, соответствующий контроллер ядра уже
  # это делает сам.
  def require_write_permission
    deny_access unless User.current.allowed_to?(:add_issue_notes, @issue.project)
  end
end
