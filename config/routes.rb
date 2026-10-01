# Two endpoints, each acting on one specific decrementable custom field of
# one specific issue (see the controller): `decrement` writes off
# DECREMENT_AMOUNT, `increment` records the very first amount of a field that
# has no history yet. Scoped under issues/:issue_id rather than a bare
# /custom_fields/:id route so that the issue is always unambiguous from the
# URL alone.
post 'issues/:issue_id/custom_fields/:custom_field_id/decrement',
     to: 'custom_decrement_field#decrement',
     as: 'decrement_issue_custom_field'

post 'issues/:issue_id/custom_fields/:custom_field_id/increment',
     to: 'custom_decrement_field#increment',
     as: 'increment_issue_custom_field'
