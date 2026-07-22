extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var previous_writes := SaveManager.writes_enabled
	SaveManager.writes_enabled = false
	var original_state := GameState.serialize().duplicate(true)
	var original_speed := SimulationManager.simulation_speed
	SimulationManager.simulation_speed = 1.0
	DayCycleManager.set_paused(false, false)

	_test_balance_window()
	_test_milestones_require_real_events()
	_test_first_config_useful_album_reward()
	_test_closed_management_clocks()
	_test_existing_save_bypass()

	GameState.deserialize(original_state)
	OnboardingPacingService.reload_from_state()
	SimulationManager.simulation_speed = original_speed
	DayCycleManager.set_paused(false, false)
	SaveManager.writes_enabled = previous_writes
	var result := "M2 FIRST LOOP PACING: %s | checks=%d failures=%d" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
	]
	print(result)
	for failure: String in failures:
		print(failure)
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_balance_window() -> void:
	var duration := float(DataRegistry.balance_value("day_cycle.real_seconds_at_1x", 0.0))
	var start_minute := float(DataRegistry.balance_value("day_cycle.start_minute", 0.0))
	var first_loop_seconds := duration * (1440.0 - start_minute) / 1440.0
	var loop_min := float(DataRegistry.balance_value("onboarding_pacing.first_loop_min_seconds", 0.0))
	var loop_max := float(DataRegistry.balance_value("onboarding_pacing.first_loop_max_seconds", 0.0))
	_expect(first_loop_seconds >= loop_min and first_loop_seconds <= loop_max, "09:00-midnight at 1x lasts 30-45 real minutes")
	var windows := DayCycleManager.configured_rush_windows()
	var first_rush_seconds := duration * (float(windows[0].start) - start_minute) / 1440.0
	_expect(first_rush_seconds > 0.0 and first_rush_seconds < 12.0 * 60.0, "the first natural rush is experienced before minute 12")
	_expect(first_loop_seconds <= 40.0 * 60.0, "the causal day summary is reachable before minute 40")


func _test_milestones_require_real_events() -> void:
	_reset_fresh()
	OnboardingPacingService.advance_unpaused_time_for_test(500.0)
	_expect((OnboardingPacingService.snapshot().milestones as Dictionary).is_empty(), "elapsed time alone never completes onboarding milestones")

	GameState.set_restaurant_state("open")
	OnboardingPacingService.advance_unpaused_time_for_test(100.0)
	SimulationManager.group_review_completed.emit({
		"id": "first_loop_review",
		"stars": 4,
		"outcome": "paid",
		"day": 1,
		"minute": 650.0,
	})
	var after_review := OnboardingPacingService.snapshot()
	_expect((after_review.milestones as Dictionary).has("configuration_complete"), "opening after a valid configuration records the configuration event")
	_expect((after_review.milestones as Dictionary).has("first_review"), "an actual completed review records the first-review event")
	_expect(float(after_review.milestones.first_review.elapsed_seconds) == 600.0, "first-review timestamp stores real unpaused play time")
	var recommendation: Dictionary = OnboardingPacingService.current_recommendation()
	_expect(not recommendation.is_empty() and String(recommendation.cta.screen) == "Magazzino", "the first review creates a persistent, actionable warehouse suggestion")
	_expect(_active_requirement_ids().has(String(recommendation.ingredient_id)), "the suggested purchase is consumed by the active starter menu")

	OnboardingPacingService.advance_unpaused_time_for_test(300.0)
	EconomyManager.clear_delivery_cart()
	var recommended_amount := mini(int(recommendation.amount), StorageManager.max_orderable_amount(String(recommendation.ingredient_id)))
	_expect(recommended_amount > 0 and EconomyManager.add_to_delivery_cart(String(recommendation.ingredient_id), recommended_amount), "the suggested quantity fits current storage")
	_expect(EconomyManager.confirm_delivery_cart(false), "the useful suggestion is a real affordable purchase")
	var after_purchase := OnboardingPacingService.snapshot()
	_expect(float(after_purchase.milestones.useful_purchase_ordered.elapsed_seconds) == 900.0, "the first useful purchase is recorded by the delivery transaction")

	OnboardingPacingService.advance_unpaused_time_for_test(200.0)
	DayCycleManager.rush_started.emit("lunch")
	OnboardingPacingService.advance_unpaused_time_for_test(700.0)
	DayCycleManager.day_completed.emit(1)
	var completed := OnboardingPacingService.snapshot()
	_expect(bool(completed.complete), "configuration, review, purchase, rush and summary complete the first loop")
	_expect(float(completed.milestones.first_day_summary.elapsed_seconds) == 1800.0, "the deterministic first loop completes at the 30-minute lower bound")
	var health: Dictionary = completed.timing_health
	_expect(bool(health.first_review_on_target) and bool(health.useful_purchase_on_target) and bool(health.first_loop_on_target), "the measured loop passes all 12/20/30-45 minute pacing gates")
	_expect(not (completed.last_day_summary as Dictionary).is_empty() and not (completed.last_day_summary.causes as Array).is_empty(), "the end-of-day record includes concrete causal feedback")


func _test_first_config_useful_album_reward() -> void:
	_reset_fresh()
	CollectionManager.set_reward_seed(20260722, 0)
	var first := CollectionManager.grant_weighted_reward("day_completed", 1)
	_expect(bool(first.get("first_config_useful_forced", false)), "the first real Album reward is explicitly marked as configuration-useful")
	_expect(_active_requirement_ids().has(String(first.get("ingredient_id", ""))), "the forced first Album reward belongs to the active recipes")
	var pacing: Dictionary = GameState.progress.onboarding_pacing
	_expect(bool(pacing.first_album_reward_complete) and not bool(pacing.first_album_reward_pending), "the one-shot reward marker persists in progress")
	var second := CollectionManager.grant_weighted_reward("day_completed", 1)
	_expect(not bool(second.get("first_config_useful_forced", false)), "after the first reward, weighted+pity selection resumes")


func _test_closed_management_clocks() -> void:
	_reset_fresh()
	GameState.set_restaurant_state("closed")
	EconomyManager.clear_delivery_cart()
	var order_amount := mini(1, StorageManager.max_orderable_amount("tomato"))
	_expect(order_amount == 1 and EconomyManager.add_to_delivery_cart("tomato", order_amount) and EconomyManager.confirm_delivery_cart(false), "a normal delivery can be scheduled while closed")
	var before_delivery := float(EconomyManager.normal_batch_snapshot().remaining)
	EconomyManager.advance_delivery_time(10.0, 1.0)
	_expect(float(EconomyManager.normal_batch_snapshot().remaining) < before_delivery, "delivery time advances while the restaurant is closed")

	DayCycleManager.reset_event_history()
	DayCycleManager.set_clock(1, 1439.0)
	var money_before_payroll := GameState.money
	DayCycleManager.advance_seconds(3.0, 1.0, "closed")
	_expect(int(GameState.world_clock.day) == 2, "the authoritative management day advances while closed")
	_expect(GameState.money < money_before_payroll and int(GameState.progress.get("last_payroll_day", 0)) == 1, "daily operating payroll advances while closed")
	DayCycleManager.set_paused(true, false)
	var paused_clock := GameState.world_clock.duplicate(true)
	DayCycleManager.advance_seconds(30.0, 1.0, "closed")
	_expect(GameState.world_clock == paused_clock, "explicit pause freezes the management clock")
	DayCycleManager.set_paused(false, false)


func _test_existing_save_bypass() -> void:
	_reset_fresh()
	var legacy_v12 := GameState.serialize().duplicate(true)
	legacy_v12.progress.erase("onboarding_pacing")
	legacy_v12.money = 7777
	legacy_v12.world_clock = {"day": 6, "minute": 810.0}
	legacy_v12.reviews = [{"id":"preserved_review", "day":5, "stars":3}]
	GameState.deserialize(legacy_v12)
	OnboardingPacingService.reload_from_state()
	var state: Dictionary = GameState.progress.onboarding_pacing
	_expect(GameState.money == 7777 and int(GameState.world_clock.day) == 6 and GameState.reviews.size() == 1, "loading a pre-pacing v12 save preserves economy, clock and reviews")
	_expect(bool(state.legacy_bypassed) and bool(state.complete), "a pre-pacing save is not forced through new-player onboarding")
	CollectionManager.set_reward_seed(44, 0)
	var reward := CollectionManager.grant_weighted_reward("day_completed", 1)
	_expect(not bool(reward.get("first_config_useful_forced", false)), "legacy saves retain normal weighted+pity Album rewards")
	var round_trip := GameState.serialize()
	_expect(bool(round_trip.progress.onboarding_pacing.legacy_bypassed), "the compatibility bypass survives serialization")


func _reset_fresh() -> void:
	SimulationManager.close_immediately()
	GameState.reset_to_defaults(false)
	StorageManager.reset_runtime_reservations()
	StorageManager.recalculate_layout_capacity()
	EconomyManager.clear_delivery_cart()
	SimulationManager.reset_service_stats()
	DayCycleManager.set_paused(false, false)
	DayCycleManager.reset_event_history()
	DayCycleManager.set_clock(1, float(DataRegistry.balance_value("day_cycle.start_minute", 540.0)))
	OnboardingPacingService.reload_from_state()


func _active_requirement_ids() -> Array[String]:
	var result: Array[String] = []
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		for ingredient_id: String in DataRegistry.recipe_raw_requirements(String(recipe.id)):
			if not result.has(ingredient_id):
				result.append(ingredient_id)
	result.sort()
	return result


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
