module CustomDecrementField
  # Sum over the issue's direct children of (child's stored count x child's
  # multiplier). Counts are the children's already-persisted values; the
  # multipliers are declared in the PARENT's own comments:
  #
  #   STOCKMULT : #57 : 0.5      (point or comma decimal, last one wins)
  #
  # A child nobody mentions counts x1.
  class SumCalculator
    def initialize(issue, field)
      @issue = issue
      @field = field
      @config = SumConfig.for_field(field)
    end

    attr_reader :issue, :field, :config

    def enabled?
      config.present?
    end

    def value
      return BigDecimal('0') unless enabled?

      factors = multipliers
      total = issue.children.to_a.sum(BigDecimal('0')) do |child|
        count = child.custom_value_for(config.source_field)&.value.to_i
        count * factors.fetch(child.id, BigDecimal('1'))
      end
      total.round(2)
    end

    # { child_issue_id => BigDecimal }, scanned chronologically so a later
    # declaration replaces an earlier one. A declaration is a current fact,
    # not an event, hence replace rather than add (unlike decrements).
    def multipliers
      return {} unless config.multiplier_token

      pattern = /#{Regexp.escape(config.multiplier_token)}\s*:\s*#(\d+)\s*:\s*(\d+(?:[.,]\d+)?)/
      issue.journals.reorder(:created_on, :id).each_with_object({}) do |journal, found|
        next if journal.notes.blank?

        journal.notes.scan(pattern) { |child_id, factor| found[child_id.to_i] = BigDecimal(factor.tr(',', '.')) }
      end
    end
  end
end
