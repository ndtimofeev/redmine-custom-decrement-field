# A single endpoint: decrement one specific decrementable custom field on
# one specific issue by DECREMENT_AMOUNT (see the controller). Scoped
# under issues/:issue_id rather than a bare /custom_fields/:id route so
# that the issue is always unambiguous from the URL alone.
post 'issues/:issue_id/custom_fields/:custom_field_id/decrement',
     to: 'custom_decrement_field#decrement',
     as: 'decrement_issue_custom_field'
