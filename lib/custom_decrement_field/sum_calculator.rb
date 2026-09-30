module CustomDecrementField
  # Sum over the issue's direct children of (child's stored count x child's
  # multiplier). Counts are the children's already-persisted values; the
  # multipliers are declared in the PARENT's own comments:
  #
  #   PACK : #57 : 0,5 bottle 0.5 l, 12 to a box
  #
  # TOKEN : #<child id> : <multiplier> [comment]. The multiplier takes a point
  # or a comma decimal; for one child the last declaration wins. Everything
  # after the multiplier up to the end of the line is a free-form note for the
  # storekeeper, never interpreted. It is consumed by the pattern itself, not
  # merely skipped over, so text inside it that happens to look like another
  # declaration ("see PACK : #12 : 3") is not picked up as one.
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

      pattern = /#{Regexp.escape(config.multiplier_token)}\s*:\s*#(\d+)\s*:\s*(\d+(?:[.,]\d+)?)[^\r\n]*/
      issue.journals.reorder(:created_on, :id).each_with_object({}) do |journal, found|
        next if journal.notes.blank?

        journal.notes.scan(pattern) { |child_id, factor| found[child_id.to_i] = BigDecimal(factor.tr(',', '.')) }
      end
    end
  end
end
