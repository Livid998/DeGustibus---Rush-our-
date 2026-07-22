extends Node

## Event-driven telemetry for the first playable loop. Nothing here grants
## progress because time passed: elapsed time is only attached to real gameplay
## milestones so the beta gate can distinguish a completed flow from an idle
## session.

signal milestone_completed(milestone_id: String, record: Dictionary)
signal recommendation_changed(recommendation: Dictionary)
signal day_summary_ready(summary: Dictionary)

const REQUIRED_MILESTONES: Array[String] = [
	"configuration_complete",
	"first_review",
	"useful_purchase_suggested",
	"useful_purchase_ordered",
	"first_rush",
	"first_day_summary",
]

const REAL_REWARD_SOURCES: Array[String] = [
	"positive_reviews",
	"five_star_gift",
	"reputation_threshold",
	"day_completed",
]

var _persist_clock := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_runtime_signals()
	reload_from_state()


func _process(delta: float) -> void:
	if delta <= 0.0 or get_tree().paused or bool(DayCycleManager.paused):
		return
	var state := _state()
	if bool(state.get("legacy_bypassed", false)) or bool(state.get("complete", false)):
		return
	state.elapsed_unpaused_seconds = maxf(float(state.get("elapsed_unpaused_seconds", 0.0)) + delta, 0.0)
	_persist_clock += delta
	if _persist_clock >= 5.0:
		_persist_clock = 0.0
		GameState.mark_save_dirty()


func reload_from_state() -> Dictionary:
	_persist_clock = 0.0
	var state := _state()
	# Be defensive with hand-authored/imported fixtures while retaining all
	# future keys that this version does not know yet.
	state.version = maxi(int(state.get("version", DataRegistry.balance_value("onboarding_pacing.schema_version", 1))), 1)
	state.legacy_bypassed = bool(state.get("legacy_bypassed", false))
	state.elapsed_unpaused_seconds = maxf(float(state.get("elapsed_unpaused_seconds", 0.0)), 0.0)
	state.milestones = (state.get("milestones", {}) as Dictionary).duplicate(true) if state.get("milestones", {}) is Dictionary else {}
	state.current_recommendation = (state.get("current_recommendation", {}) as Dictionary).duplicate(true) if state.get("current_recommendation", {}) is Dictionary else {}
	state.last_day_summary = (state.get("last_day_summary", {}) as Dictionary).duplicate(true) if state.get("last_day_summary", {}) is Dictionary else {}
	state.first_album_reward_pending = bool(state.get("first_album_reward_pending", not bool(state.legacy_bypassed)))
	state.first_album_reward_complete = bool(state.get("first_album_reward_complete", bool(state.legacy_bypassed)))
	state.complete = bool(state.get("complete", false)) or bool(state.legacy_bypassed) or _all_required_complete(state.milestones)
	GameState.progress.onboarding_pacing = state
	return snapshot()


func advance_unpaused_time_for_test(seconds: float) -> void:
	## Deterministic gate helper. Runtime progression uses _process().
	if seconds <= 0.0:
		return
	var state := _state()
	if bool(state.get("legacy_bypassed", false)) or bool(state.get("complete", false)):
		return
	state.elapsed_unpaused_seconds = maxf(float(state.get("elapsed_unpaused_seconds", 0.0)) + seconds, 0.0)


func snapshot() -> Dictionary:
	var state := _state()
	var result := state.duplicate(true)
	result["targets"] = {
		"first_review_seconds": float(DataRegistry.balance_value("onboarding_pacing.first_review_target_seconds", 720.0)),
		"useful_purchase_seconds": float(DataRegistry.balance_value("onboarding_pacing.useful_purchase_target_seconds", 1200.0)),
		"first_loop_min_seconds": float(DataRegistry.balance_value("onboarding_pacing.first_loop_min_seconds", 1800.0)),
		"first_loop_max_seconds": float(DataRegistry.balance_value("onboarding_pacing.first_loop_max_seconds", 2700.0)),
	}
	result["timing_health"] = timing_health()
	return result


func timing_health() -> Dictionary:
	var milestones: Dictionary = _state().get("milestones", {})
	var review_seconds := _milestone_seconds(milestones, "first_review")
	var purchase_seconds := _milestone_seconds(milestones, "useful_purchase_ordered")
	var loop_seconds := _milestone_seconds(milestones, "first_day_summary")
	var review_target := float(DataRegistry.balance_value("onboarding_pacing.first_review_target_seconds", 720.0))
	var purchase_target := float(DataRegistry.balance_value("onboarding_pacing.useful_purchase_target_seconds", 1200.0))
	var loop_min := float(DataRegistry.balance_value("onboarding_pacing.first_loop_min_seconds", 1800.0))
	var loop_max := float(DataRegistry.balance_value("onboarding_pacing.first_loop_max_seconds", 2700.0))
	return {
		"first_review_recorded": review_seconds >= 0.0,
		"first_review_on_target": review_seconds >= 0.0 and review_seconds <= review_target,
		"useful_purchase_recorded": purchase_seconds >= 0.0,
		"useful_purchase_on_target": purchase_seconds >= 0.0 and purchase_seconds <= purchase_target,
		"first_loop_recorded": loop_seconds >= 0.0,
		"first_loop_on_target": loop_seconds >= loop_min and loop_seconds <= loop_max,
	}


func current_recommendation() -> Dictionary:
	return (_state().get("current_recommendation", {}) as Dictionary).duplicate(true)


func notify_first_album_reward(reward: Dictionary) -> void:
	if reward.is_empty() or not bool(reward.get("first_config_useful_forced", false)):
		return
	_record_milestone("first_album_reward", {
		"ingredient_id": String(reward.get("ingredient_id", "")),
		"amount": int(reward.get("amount", 0)),
		"source": String(reward.get("source", "")),
	})


func first_reward_candidates() -> Array[String]:
	var candidates: Array[String] = []
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		for ingredient_id: String in DataRegistry.recipe_raw_requirements(String(recipe.get("id", ""))):
			if DataRegistry.ingredients_by_id.has(ingredient_id) and not candidates.has(ingredient_id):
				candidates.append(ingredient_id)
	candidates.sort()
	return candidates


func should_force_first_reward(source: String) -> bool:
	if source not in REAL_REWARD_SOURCES:
		return false
	var state := _state()
	return (
		not bool(state.get("legacy_bypassed", false))
		and bool(state.get("first_album_reward_pending", false))
		and not bool(state.get("first_album_reward_complete", false))
	)


func mark_first_reward_complete() -> void:
	var state := _state()
	state.first_album_reward_pending = false
	state.first_album_reward_complete = true
	GameState.mark_save_dirty()


func _connect_runtime_signals() -> void:
	if not GameState.restaurant_state_changed.is_connected(_on_restaurant_state_changed):
		GameState.restaurant_state_changed.connect(_on_restaurant_state_changed)
	if not SimulationManager.group_review_completed.is_connected(_on_group_review_completed):
		SimulationManager.group_review_completed.connect(_on_group_review_completed)
	if not EconomyManager.delivery_created.is_connected(_on_delivery_created):
		EconomyManager.delivery_created.connect(_on_delivery_created)
	if not DayCycleManager.rush_started.is_connected(_on_rush_started):
		DayCycleManager.rush_started.connect(_on_rush_started)
	if not DayCycleManager.day_completed.is_connected(_on_day_completed):
		DayCycleManager.day_completed.connect(_on_day_completed)


func _on_restaurant_state_changed(value: String) -> void:
	if value == "open":
		_record_milestone("configuration_complete", {
			"active_recipe_ids": _active_recipe_ids(),
			"employee_count": GameState.employees.size(),
		})


func _on_group_review_completed(review: Dictionary) -> void:
	if review.is_empty():
		return
	_record_milestone("first_review", {
		"review_id": String(review.get("id", "")),
		"stars": int(review.get("stars", 0)),
		"outcome": String(review.get("outcome", "")),
	})
	if current_recommendation().is_empty():
		var recommendation := _build_useful_purchase_recommendation()
		if not recommendation.is_empty():
			var state := _state()
			state.current_recommendation = recommendation.duplicate(true)
			_record_milestone("useful_purchase_suggested", recommendation)
			recommendation_changed.emit(recommendation.duplicate(true))
			GameState.toast_requested.emit(
				"PROSSIMO ACQUISTO - %s x%d nel Magazzino" % [String(recommendation.name), int(recommendation.amount)],
				"info"
			)


func _on_delivery_created(batch: Dictionary) -> void:
	var state := _state()
	if bool(state.get("legacy_bypassed", false)) or (state.get("milestones", {}) as Dictionary).has("useful_purchase_ordered"):
		return
	var useful_ids := _active_requirement_ids()
	var items: Dictionary = batch.get("items", {})
	for ingredient_id: String in items:
		var value: Variant = items[ingredient_id]
		var amount := int((value as Dictionary).get("amount", 0)) if value is Dictionary else int(value)
		if amount <= 0 or not useful_ids.has(ingredient_id):
			continue
		_record_milestone("useful_purchase_ordered", {
			"ingredient_id": ingredient_id,
			"amount": amount,
			"batch_id": String(batch.get("id", "")),
		})
		state.current_recommendation = {}
		recommendation_changed.emit({})
		return


func _on_rush_started(rush_id: String) -> void:
	_record_milestone("first_rush", {"rush_id": rush_id})


func _on_day_completed(completed_day: int) -> void:
	var summary := _build_day_summary(completed_day)
	var state := _state()
	state.last_day_summary = summary.duplicate(true)
	_record_milestone("first_day_summary", summary)
	day_summary_ready.emit(summary.duplicate(true))
	var headline := String((summary.get("causes", ["servizio concluso"]) as Array)[0])
	GameState.toast_requested.emit(
		"GIORNO %d - utile %d, serviti %d - %s" % [completed_day, int(summary.profit), int(summary.customers_served), headline],
		"income" if int(summary.profit) >= 0 else "warning"
	)
	GameState.mark_save_dirty()


func _build_useful_purchase_recommendation() -> Dictionary:
	var requirement_per_cover := _active_requirement_amounts()
	var best_id := ""
	var best_cover_ratio := INF
	for ingredient_id: String in requirement_per_cover:
		var entry: Dictionary = GameState.stock.get(ingredient_id, {})
		if entry.is_empty() or not bool(entry.get("unlocked", false)):
			continue
		var max_orderable := StorageManager.max_orderable_amount(ingredient_id)
		if max_orderable <= 0:
			continue
		var units_per_cover := maxi(int(requirement_per_cover[ingredient_id]), 1)
		var eventual := StorageManager.available_amount(ingredient_id) + StorageManager.pending_amount(ingredient_id, "all")
		var covers := float(eventual) / float(units_per_cover)
		if covers < best_cover_ratio or (is_equal_approx(covers, best_cover_ratio) and ingredient_id < best_id):
			best_cover_ratio = covers
			best_id = ingredient_id
	if best_id.is_empty():
		return {}
	var best_entry: Dictionary = GameState.stock[best_id]
	var cap := maxi(int(DataRegistry.balance_value("onboarding_pacing.recommendation_lot_cap", 8)), 1)
	var amount := mini(maxi(int(best_entry.get("lot", 1)), 1), cap)
	amount = mini(amount, StorageManager.max_orderable_amount(best_id))
	if amount <= 0:
		return {}
	var ingredient: Dictionary = DataRegistry.ingredients_by_id[best_id]
	return {
		"ingredient_id": best_id,
		"name": String(ingredient.get("name", best_id)),
		"amount": amount,
		"estimated_cost": int(ceil(float(ingredient.get("cost", 0.0)) * amount)),
		"reason": "Scorta con meno coperti residui nel menu attivo",
		"cta": {"screen": "Magazzino", "action": "open_delivery_cart"},
	}


func _build_day_summary(completed_day: int) -> Dictionary:
	var operational: Dictionary = SimulationManager.summary()
	var day_reviews: Array[Dictionary] = []
	for value: Variant in GameState.reviews:
		if value is Dictionary and int((value as Dictionary).get("day", 0)) == completed_day:
			day_reviews.append((value as Dictionary).duplicate(true))
	var star_sum := 0.0
	var negative_counts: Dictionary = {}
	var positive_counts: Dictionary = {}
	for review: Dictionary in day_reviews:
		star_sum += float(review.get("stars", 0))
		for tag: Variant in review.get("negative_tags", []):
			negative_counts[String(tag)] = int(negative_counts.get(String(tag), 0)) + 1
		for tag: Variant in review.get("positive_tags", []):
			positive_counts[String(tag)] = int(positive_counts.get(String(tag), 0)) + 1
	var causes: Array[String] = []
	var top_negative := _top_count_key(negative_counts)
	var top_positive := _top_count_key(positive_counts)
	if not top_negative.is_empty():
		causes.append("Da migliorare: %s" % top_negative.replace("_", " "))
	if not top_positive.is_empty():
		causes.append("Punto forte: %s" % top_positive.replace("_", " "))
	if int(operational.get("customers_lost", 0)) > 0:
		causes.append("%d clienti persi" % int(operational.customers_lost))
	if not (operational.get("ingredients_out", []) as Array).is_empty():
		causes.append("Scorte esaurite: %s" % ", ".join(operational.ingredients_out))
	if causes.is_empty():
		causes.append("Servizio regolare")
	return {
		"day": completed_day,
		"revenue": int(operational.get("revenue", 0)),
		"ingredient_cost": int(operational.get("ingredient_cost", 0)),
		"labor_cost": int(operational.get("labor_cost", 0)),
		"profit": int(operational.get("profit", 0)),
		"customers_served": int(operational.get("customers_served", 0)),
		"customers_lost": int(operational.get("customers_lost", 0)),
		"average_stars": 0.0 if day_reviews.is_empty() else star_sum / float(day_reviews.size()),
		"review_count": day_reviews.size(),
		"top_recipe": String(operational.get("top_recipe", "N/D")),
		"waste": int(operational.get("waste", 0)),
		"causes": causes,
	}


func _record_milestone(milestone_id: String, metadata: Dictionary = {}) -> bool:
	var state := _state()
	if bool(state.get("legacy_bypassed", false)):
		return false
	var milestones: Dictionary = state.get("milestones", {})
	if milestones.has(milestone_id):
		return false
	var record := {
		"elapsed_seconds": float(state.get("elapsed_unpaused_seconds", 0.0)),
		"day": int(GameState.world_clock.get("day", 1)),
		"minute": float(GameState.world_clock.get("minute", 0.0)),
		"recorded_at_utc": Time.get_datetime_string_from_system(true, true),
	}
	record.merge(metadata, true)
	milestones[milestone_id] = record
	state.milestones = milestones
	state.complete = _all_required_complete(milestones)
	GameState.mark_save_dirty()
	milestone_completed.emit(milestone_id, record.duplicate(true))
	return true


func _state() -> Dictionary:
	var value: Variant = GameState.progress.get("onboarding_pacing", {})
	if not value is Dictionary:
		GameState.progress.onboarding_pacing = {}
		value = GameState.progress.onboarding_pacing
	return value as Dictionary


func _all_required_complete(milestones: Dictionary) -> bool:
	for milestone_id: String in REQUIRED_MILESTONES:
		if not milestones.has(milestone_id):
			return false
	return true


func _milestone_seconds(milestones: Dictionary, milestone_id: String) -> float:
	var record: Variant = milestones.get(milestone_id, {})
	return float((record as Dictionary).get("elapsed_seconds", -1.0)) if record is Dictionary and not (record as Dictionary).is_empty() else -1.0


func _active_recipe_ids() -> Array[String]:
	var result: Array[String] = []
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		result.append(String(recipe.get("id", "")))
	result.sort()
	return result


func _active_requirement_ids() -> Array[String]:
	var result: Array[String] = []
	for ingredient_id: String in _active_requirement_amounts():
		result.append(ingredient_id)
	result.sort()
	return result


func _active_requirement_amounts() -> Dictionary:
	var result: Dictionary = {}
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		for ingredient_id: String in DataRegistry.recipe_raw_requirements(String(recipe.get("id", ""))):
			result[ingredient_id] = int(result.get(ingredient_id, 0)) + int(DataRegistry.recipe_raw_requirements(String(recipe.get("id", "")))[ingredient_id])
	return result


func _top_count_key(counts: Dictionary) -> String:
	var best := ""
	var best_count := -1
	for key: String in counts:
		var count := int(counts[key])
		if count > best_count or (count == best_count and key < best):
			best = key
			best_count = count
	return best
