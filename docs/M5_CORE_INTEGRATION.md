# Milestone 5 core integration

The review and dish-quality core is intentionally isolated from the current
order/customer refactor. The following hooks complete the runtime integration
without moving this logic back into the monolithic scripts.

## Group experience and payment

Create one `ReviewSystem` instance and one experience dictionary per customer
group:

```gdscript
var reviews := ReviewSystem.new()
var experience := reviews.begin_experience(group_id, {
    "customer_type": customer_type,
    "recipe_ids": recipe_ids,
})
```

All members of the group must share that dictionary. Update it through the
structured helpers:

- `record_wait(experience, "order" | "food" | "bill", seconds)`;
- `record_food_quality(experience, average_group_dish_quality)`;
- `record_service(experience, waiter_service_score)`;
- `record_ambience(experience, beauty_score, cleanliness_score)`;
- `record_change_order(experience, response_seconds, resolved)`;
- `record_visible_pest(experience, "mouse" | "insect")`;
- `record_incident_resolution(experience, incident_id, response_seconds)`.

At payment, call exactly once for the group:

```gdscript
var completion := reviews.complete_group(
    experience,
    group_order_total,
    "paid",
    {
        "day": GameState.world_clock.day,
        "minute": GameState.world_clock.minute,
        "service_tip_modifier": waiter_modifier,
    }
)
if completion.accepted:
    var review: Dictionary = completion.review
    GameState.earn(int(round(group_order_total)) + int(review.tip), "Conto gruppo")
```

`submit_review()` is idempotent by review ID, so a repeated group completion
does not duplicate review state, album progress, or its tip record. Abandonment
after seating/ordering uses `complete_group(..., "abandoned", ...)`. A customer
who leaves before entering is filtered by the configured seedable chance.

Remove the old per-order tip calculation from
`SimulationManager.complete_order_payment()`. Keep completed-order counters and
recipe progression, but do not call the current reputation increment in
`GameState.record_completed_order()`; reputation must be written only by
`ReviewSystem`.

The current `GameState` has no descending reputation setter. `ReviewSystem`
prefers `GameState.set_reputation_value(value)` or
`GameState.set_reputation(value)` when either is available, and otherwise uses
one centralized compatibility fallback that emits `reputation_changed` and
marks the save dirty. A future setter only needs to accept the absolute
clamped 1–5 value.

## Dish completion and defects

Build the quality context from the employee and the physical work that
produced the order:

```gdscript
var result := quality.apply_to_order(order, {
    "station": task.station,
    "ingredient_qualities": reserved_lot_qualities,
    "employee_id": employee.id,
    "employee_skill": employee.skills.get(task.station, 0.65),
    "employee_precision": employee.precision,
    "stress": employee.stress,
    "cleanliness": relevant_cleanliness,
    "station_condition": station_condition,
    "remake_stock_available": can_reserve_remake,
    "remake_attempts": order.get("remake_attempts", 0),
})
```

Perform the random defect roll once per finished dish, not once per recipe
step. Intermediate step samples can be merged without another defect roll via
`accumulate_order_quality()`.

- `result.requires_remake`: reserve a replacement portion and enqueue a new
  production chain; increment `order.remake_attempts`.
- `result.requires_change_order`: invoke the existing change-order flow.
- `result.serveable`: serve normally; a mild/moderate defect remains in
  `quality_events` and becomes a visible review cause.

Each quality event provides `review_tag` and an existing generated
`icon_id`. Import the event into the shared group experience with
`record_cause()` so its penalty is visible rather than hidden.

## UI and CI

- `ReviewsScreen.create()` builds the complete review UI once, consumes
  `ReviewSystem.recent_summary()` plus `GameState.reviews`, and then updates
  the existing controls from `reviews_changed`, `reputation_changed`, and
  `review_reward_progress_changed`.
- The integration point is the start of
  `ManagementScreens._statistics(content, ui)`: add one
  `ReviewsScreen.create()` instance before the existing live service metrics.
  Do not call `RestaurantUI.show_screen("Statistiche", false)` every second
  while this screen is visible; that path clears and rebuilds the whole
  container. Cache/reparent the instance when reopening Statistiche, or only
  rebuild the legacy task-board subsection when its own data changes.
- Add `res://tests/review_quality_smoke.tscn` to the deploy workflow.
- Add `res://tests/reviews_screen_smoke.tscn` to the deploy workflow.
- Keep `data/review_templates.json` in the PWA export; no runtime API or
  network call is used for review text.
