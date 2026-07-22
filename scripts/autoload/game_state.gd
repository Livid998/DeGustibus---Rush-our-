extends Node

signal money_changed(value: int)
signal reputation_changed(value: float)
signal restaurant_state_changed(value: String)
signal stock_changed(ingredient_id: String, amount: int)
signal menu_changed
signal employees_changed
signal layout_changed
signal toast_requested(message: String, tone: String)
signal album_inventory_changed(ingredient_id: String, amount: int)
signal album_discovered_changed(ingredient_id: String, discovered: bool)
signal reviews_changed
signal review_reward_progress_changed(value: int)
signal world_clock_changed(value: Dictionary)
signal restaurant_profile_changed(value: Dictionary)
signal pending_delivery_batch_changed(value: Dictionary)
signal cleanliness_state_changed(value: Dictionary)
signal pest_state_changed(value: Dictionary)
signal staff_preferences_changed(employee_id: String, preference: Variant)

const SAVE_VERSION := 12
const DEFAULT_SETTINGS := {
	"music": true,
	"sound": true,
	"music_volume": 0.60,
	"ambience_volume": 0.72,
	"sfx_volume": 0.82,
	"ui_volume": 0.82,
	"camera_zoom": 24.0,
	"camera_quadrant": 0,
	"graphics_quality": "auto",
	"high_contrast": false,
	"reduced_motion": false,
}

var money: int = 1200
var reputation: float = 1.0
var restaurant_state: String = "closed"
var service_seconds: float = 0.0
var stock: Dictionary = {}
var menu: Dictionary = {}
var employees: Array = []
var candidates: Array = []
var layout: Array = []
var deliveries: Array = []
var purchased_preparations: Dictionary = {}
var progress: Dictionary = {
	"customers_served": 0,
	"desserts_served": 0,
	"services_started": 0,
	"onboarding_pacing": {},
}
var settings: Dictionary = DEFAULT_SETTINGS.duplicate(true)
var tutorial: Dictionary = {
	"version": 2,
	"current_step_id": "table_moved",
	"completed_ids": [],
	"step": 0,
	"skipped": false,
	"complete": false,
}
var album_inventory: Dictionary = {}
var album_discovered: Dictionary = {}
var reviews: Array = []
var review_reward_progress: int = 0
var reputation_weight: float = 0.0
var world_clock: Dictionary = {"day": 1, "minute": 540.0}
var restaurant_profile: Dictionary = {}
var pending_delivery_batch: Dictionary = {}
var cleanliness_state: Dictionary = {}
var pest_state: Dictionary = {}
var staff_preferences: Dictionary = {}


func _ready() -> void:
	reset_to_defaults(false)


func reset_to_defaults(emit_signals: bool = true) -> void:
	money = maxi(int(DataRegistry.balance_value("new_game.money", 1200)), 0)
	reputation = 1.0
	restaurant_state = "closed"
	service_seconds = 0.0
	stock.clear()
	for ingredient: Dictionary in DataRegistry.ingredients:
		stock[ingredient.id] = _default_stock_entry(ingredient)
	menu.clear()
	var starter_recipes := _configured_string_array("new_game.active_recipe_ids")
	for recipe: Dictionary in DataRegistry.recipes:
		menu[recipe.id] = {
			"active": starter_recipes.has(String(recipe.id)),
			"unlocked": bool(recipe.get("unlocked", false)),
			"price": int(recipe.get("price", 10)),
			"manual_paused": false,
			"auto_sold_out": false,
			"sold_out": false
		}
	employees = _default_employees()
	candidates = DataRegistry.employee_data.get("candidates", []).duplicate(true)
	layout = _default_layout()
	deliveries.clear()
	purchased_preparations.clear()
	progress = {
		"customers_served": 0,
		"desserts_served": 0,
		"services_started": 0,
		"onboarding_pacing": _default_onboarding_pacing_state(),
	}
	settings = DEFAULT_SETTINGS.duplicate(true)
	tutorial = _default_tutorial_state()
	album_inventory = _default_album_inventory()
	album_discovered = _default_album_discovered()
	reviews = []
	review_reward_progress = 0
	reputation_weight = 0.0
	world_clock = _default_world_clock()
	restaurant_profile = _default_restaurant_profile()
	pending_delivery_batch = _default_pending_delivery_batch()
	cleanliness_state = _default_cleanliness_state()
	pest_state = _default_pest_state()
	staff_preferences = {}
	if emit_signals:
		_emit_all()


func _default_stock_entry(ingredient: Dictionary) -> Dictionary:
	var storage := DataRegistry.storage_metadata_for_ingredient(ingredient)
	var ingredient_id := String(ingredient.get("id", ""))
	return {
		"amount": maxi(int(DataRegistry.balance_value("new_game.stock.%s" % ingredient_id, 0)), 0),
		"reserved": 0,
		"storage_type": String(storage.storage_type),
		"storage_units": int(storage.storage_units),
		"unlocked": bool(ingredient.get("unlocked", false)),
		"average_cost": float(ingredient.get("cost", 0.0)),
		"supplier": String(ingredient.get("supplier", "wholesale")),
		"auto_reorder": false,
		"threshold": int(ingredient.get("reorder_threshold", 10)),
		"target": int(ingredient.get("stock_target", 30)),
		"lot": int(ingredient.get("lot", 10)),
		"quality": int(ingredient.get("quality", 2))
	}


func _configured_string_array(path: String) -> Array[String]:
	var result: Array[String] = []
	var configured: Variant = DataRegistry.balance_value(path, [])
	if not configured is Array:
		return result
	for value: Variant in configured:
		var normalized := String(value)
		if not normalized.is_empty() and not result.has(normalized):
			result.append(normalized)
	return result


func _default_employees() -> Array:
	var available: Array = DataRegistry.employee_data.get("hired", [])
	var selected_ids := _configured_string_array("new_game.employee_ids")
	var result: Array = []
	for employee_id: String in selected_ids:
		for employee: Dictionary in available:
			if String(employee.get("id", "")) == employee_id:
				result.append(employee.duplicate(true))
				break
	return result


func _default_album_inventory() -> Dictionary:
	var result: Dictionary = {}
	for ingredient: Dictionary in DataRegistry.ingredients:
		result[String(ingredient.id)] = 0
	var starter := DataRegistry.album_starter_inventory()
	for ingredient_id: String in starter:
		result[ingredient_id] = int(starter[ingredient_id])
	return result


func _default_album_discovered() -> Dictionary:
	var result: Dictionary = {}
	for ingredient: Dictionary in DataRegistry.ingredients:
		result[String(ingredient.id)] = bool(ingredient.get("unlocked", false))
	return result


func _default_world_clock() -> Dictionary:
	return {
		"day": 1,
		"minute": float(DataRegistry.balance_value("day_cycle.start_minute", 540.0))
	}


func _default_onboarding_pacing_state() -> Dictionary:
	return {
		"version": maxi(int(DataRegistry.balance_value("onboarding_pacing.schema_version", 1)), 1),
		"legacy_bypassed": false,
		"elapsed_unpaused_seconds": 0.0,
		"milestones": {},
		"current_recommendation": {},
		"last_day_summary": {},
		"first_album_reward_pending": true,
		"first_album_reward_complete": false,
		"complete": false,
	}


func _legacy_onboarding_pacing_state() -> Dictionary:
	var state := _default_onboarding_pacing_state()
	state.legacy_bypassed = true
	state.first_album_reward_pending = false
	state.first_album_reward_complete = true
	state.complete = true
	return state


func _default_tutorial_state() -> Dictionary:
	return {
		"version": 2,
		"current_step_id": "table_moved",
		"completed_ids": [],
		"step": 0,
		"skipped": false,
		"complete": false,
	}


func _default_restaurant_profile() -> Dictionary:
	return {
		"player_name": "",
		"restaurant_name": String(DataRegistry.balance_value("restaurant_profile.default_restaurant_name", "DeGustibus")),
		"avatar_appearance": String(DataRegistry.balance_value("restaurant_profile.default_avatar_appearance", "Chef_Female")),
		"badge_id": String(DataRegistry.balance_value("restaurant_profile.default_badge_id", "starter")),
		"uniform_variant": int(DataRegistry.balance_value("restaurant_profile.default_uniform_variant", 0))
	}


func _default_pending_delivery_batch() -> Dictionary:
	return {
		"id": "",
		"items": {},
		"remaining": float(DataRegistry.balance_value("delivery.batch_interval_seconds", 300.0)),
		"paid": false
	}


func _default_cleanliness_state() -> Dictionary:
	return {
		"score": float(DataRegistry.balance_value("cleanliness.clean_score", 100.0)),
		"dirty_tables": 0,
		"dirty_dishes": 0,
		"spills": 0,
		"kitchen_dirt": 0.0,
		"below_pest_threshold_seconds": 0.0
	}


func _default_pest_state() -> Dictionary:
	return {
		"warning": false,
		"active": [],
		"last_spawn_day": 0
	}


func _default_layout() -> Array:
	var result := [
		{"uid":"door_1","item":"door","cell":[8,0],"rotation":0},
		{"uid":"table_1","item":"table_small","cell":[4,4],"rotation":0},
		{"uid":"chair_1","item":"chair","cell":[4,4],"rotation":0,"support_uid":"table_1","attachment_slot":0},
		{"uid":"chair_2","item":"chair","cell":[4,4],"rotation":2,"support_uid":"table_1","attachment_slot":2},
		{"uid":"fridge_1","item":"fridge","cell":[3,9],"rotation":0},
		{"uid":"storage_1","item":"storage","cell":[1,8],"rotation":0,"support_uid":"wall_divider_1","attachment_slot":0},
		{"uid":"prep_1","item":"prep_counter","cell":[5,9],"rotation":0},
		{"uid":"prep_bowl_1","item":"prep_bowl","cell":[5,9],"rotation":0,"support_uid":"prep_1","attachment_slot":0},
		{"uid":"support_cut_1","item":"prep_counter","cell":[8,9],"rotation":0},
		{"uid":"cut_1","item":"cutting_board","cell":[8,9],"rotation":0,"support_uid":"support_cut_1","attachment_slot":0},
		{"uid":"support_pizza_1","item":"prep_counter","cell":[12,9],"rotation":0},
		{"uid":"pizza_1","item":"pizza_oven","cell":[12,9],"rotation":0,"support_uid":"support_pizza_1","attachment_slot":0},
		{"uid":"support_dough_1","item":"worktable","cell":[15,9],"rotation":0},
		{"uid":"dough_1","item":"dough","cell":[15,9],"rotation":0,"support_uid":"support_dough_1","attachment_slot":0},
		{"uid":"sink_1","item":"sink","cell":[3,12],"rotation":2},
		{"uid":"pass_1","item":"pass","cell":[6,12],"rotation":2},
		{"uid":"pass_tray_1","item":"pass_tray","cell":[6,12],"rotation":2,"support_uid":"pass_1","attachment_slot":0}
	]
	result.append_array(_initial_wall_records())
	result.append_array(_initial_exterior_records())
	return result


func can_afford(amount: int) -> bool:
	return money >= amount


func spend(amount: int, reason: String = "") -> bool:
	if amount < 0 or money < amount:
		return false
	money -= amount
	money_changed.emit(money)
	if amount > 0:
		mark_save_dirty()
	if not reason.is_empty():
		toast_requested.emit("-%d · %s" % [amount, reason], "cost")
	return true


func earn(amount: int, reason: String = "") -> void:
	var earned := maxi(amount, 0)
	money += earned
	money_changed.emit(money)
	if earned > 0:
		mark_save_dirty()
	if not reason.is_empty():
		toast_requested.emit("+%d · %s" % [amount, reason], "income")


func set_reputation_value(value: float) -> void:
	var normalized := clampf(value, 1.0, 5.0)
	if is_equal_approx(reputation, normalized):
		return
	reputation = normalized
	reputation_changed.emit(reputation)
	mark_save_dirty()


func consume_stock(requirements: Dictionary) -> bool:
	for ingredient_id: String in requirements:
		if int(stock.get(ingredient_id, {}).get("amount", 0)) < int(requirements[ingredient_id]):
			return false
	for ingredient_id: String in requirements:
		stock[ingredient_id].amount -= int(requirements[ingredient_id])
		stock_changed.emit(ingredient_id, stock[ingredient_id].amount)
	if not requirements.is_empty():
		mark_save_dirty()
	return true


func add_stock(ingredient_id: String, amount: int, unit_cost: float = -1.0) -> void:
	if not stock.has(ingredient_id):
		return
	var entry: Dictionary = stock[ingredient_id]
	var old_amount := int(entry.amount)
	if unit_cost >= 0.0 and old_amount + amount > 0:
		entry.average_cost = ((float(entry.average_cost) * old_amount) + unit_cost * amount) / float(old_amount + amount)
	entry.amount = max(old_amount + amount, 0)
	stock_changed.emit(ingredient_id, int(entry.amount))
	if int(entry.amount) != old_amount:
		mark_save_dirty()


func set_recipe_price(recipe_id: String, value: int) -> bool:
	if not menu.has(recipe_id):
		return false
	var normalized := maxi(value, 0)
	if int(menu[recipe_id].get("price", 0)) != normalized:
		menu[recipe_id].price = normalized
		menu_changed.emit()
		mark_save_dirty()
	return true


func set_recipe_active(recipe_id: String, active: bool) -> bool:
	if not menu.has(recipe_id):
		return false
	if bool(menu[recipe_id].get("active", false)) != active:
		menu[recipe_id].active = active
		menu_changed.emit()
		mark_save_dirty()
	return true


func set_recipe_unlocked(recipe_id: String, unlocked: bool = true) -> bool:
	if not menu.has(recipe_id):
		return false
	if bool(menu[recipe_id].get("unlocked", false)) != unlocked:
		menu[recipe_id].unlocked = unlocked
		menu_changed.emit()
		mark_save_dirty()
	return true


func set_recipe_manual_paused(recipe_id: String, paused: bool) -> bool:
	if not menu.has(recipe_id):
		return false
	var entry: Dictionary = menu[recipe_id]
	if bool(entry.get("manual_paused", false)) != paused:
		entry.manual_paused = paused
		_sync_menu_sold_out_entry(entry)
		menu_changed.emit()
		mark_save_dirty()
	return true


func set_recipe_auto_sold_out(recipe_id: String, sold_out: bool) -> bool:
	if not menu.has(recipe_id):
		return false
	var entry: Dictionary = menu[recipe_id]
	if bool(entry.get("auto_sold_out", false)) != sold_out:
		entry.auto_sold_out = sold_out
		_sync_menu_sold_out_entry(entry)
		menu_changed.emit()
		mark_save_dirty()
	return true


func is_recipe_sold_out(recipe_id: String) -> bool:
	var entry: Dictionary = menu.get(recipe_id, {})
	return bool(entry.get("manual_paused", entry.get("sold_out", false))) or bool(entry.get("auto_sold_out", false))


func set_album_ingredient_amount(ingredient_id: String, amount: int) -> bool:
	if not DataRegistry.ingredients_by_id.has(ingredient_id):
		return false
	var normalized := maxi(amount, 0)
	if int(album_inventory.get(ingredient_id, 0)) != normalized:
		album_inventory[ingredient_id] = normalized
		album_inventory_changed.emit(ingredient_id, normalized)
		mark_save_dirty()
	return true


func add_album_ingredient(ingredient_id: String, delta: int) -> bool:
	if not DataRegistry.ingredients_by_id.has(ingredient_id):
		return false
	return set_album_ingredient_amount(ingredient_id, int(album_inventory.get(ingredient_id, 0)) + delta)


func set_album_discovered(ingredient_id: String, discovered: bool = true) -> bool:
	if not DataRegistry.ingredients_by_id.has(ingredient_id):
		return false
	if bool(album_discovered.get(ingredient_id, false)) != discovered:
		album_discovered[ingredient_id] = discovered
		album_discovered_changed.emit(ingredient_id, discovered)
		mark_save_dirty()
	return true


func append_review(review: Dictionary) -> bool:
	if review.is_empty():
		return false
	reviews.append(review.duplicate(true))
	var history_limit := maxi(int(DataRegistry.balance_value("reviews.history_limit", 100)), 1)
	while reviews.size() > history_limit:
		reviews.pop_front()
	reviews_changed.emit()
	mark_save_dirty()
	return true


func set_review_reward_progress(value: int) -> void:
	var normalized := maxi(value, 0)
	if review_reward_progress == normalized:
		return
	review_reward_progress = normalized
	review_reward_progress_changed.emit(review_reward_progress)
	mark_save_dirty()


func set_world_clock(value: Dictionary) -> void:
	var normalized := _normalize_world_clock(value)
	if world_clock == normalized:
		return
	world_clock = normalized
	world_clock_changed.emit(world_clock.duplicate(true))
	mark_save_dirty()


func set_restaurant_profile(value: Dictionary) -> void:
	var normalized := _default_restaurant_profile()
	normalized.merge(value, true)
	if restaurant_profile == normalized:
		return
	restaurant_profile = normalized
	restaurant_profile_changed.emit(restaurant_profile.duplicate(true))
	mark_save_dirty()


func set_pending_delivery_batch(value: Dictionary) -> void:
	var normalized := _normalize_pending_delivery_batch(value)
	if pending_delivery_batch == normalized:
		return
	pending_delivery_batch = normalized
	pending_delivery_batch_changed.emit(pending_delivery_batch.duplicate(true))
	mark_save_dirty()


func set_cleanliness_state(value: Dictionary) -> void:
	var normalized := _default_cleanliness_state()
	normalized.merge(value, true)
	if cleanliness_state == normalized:
		return
	cleanliness_state = normalized
	cleanliness_state_changed.emit(cleanliness_state.duplicate(true))
	mark_save_dirty()


func set_pest_state(value: Dictionary) -> void:
	var normalized := _default_pest_state()
	normalized.merge(value, true)
	if pest_state == normalized:
		return
	pest_state = normalized
	pest_state_changed.emit(pest_state.duplicate(true))
	mark_save_dirty()


func set_staff_preference(employee_id: String, preference: Variant) -> bool:
	if employee_id.is_empty():
		return false
	if staff_preferences.get(employee_id) == preference:
		return true
	staff_preferences[employee_id] = preference
	staff_preferences_changed.emit(employee_id, preference)
	mark_save_dirty()
	return true


func mark_save_dirty() -> void:
	var save_manager := get_node_or_null("/root/SaveManager")
	if save_manager != null and save_manager.has_method("request_autosave"):
		save_manager.request_autosave()


func _sync_menu_sold_out_entry(entry: Dictionary) -> void:
	entry.sold_out = bool(entry.get("manual_paused", false)) or bool(entry.get("auto_sold_out", false))


func set_restaurant_state(value: String) -> void:
	if restaurant_state == value:
		return
	restaurant_state = value
	restaurant_state_changed.emit(value)


func add_reputation(amount: float) -> void:
	var previous := reputation
	reputation = clampf(reputation + maxf(amount, 0.0), 1.0, 5.0)
	if not is_equal_approx(previous, reputation):
		reputation_changed.emit(reputation)
		mark_save_dirty()


func unlock_ingredient(ingredient_id: String, reason: String = "", persist: bool = true) -> bool:
	if not stock.has(ingredient_id) or bool(stock[ingredient_id].unlocked):
		return false
	stock[ingredient_id].unlocked = true
	album_discovered[ingredient_id] = true
	stock_changed.emit(ingredient_id, int(stock[ingredient_id].amount))
	album_discovered_changed.emit(ingredient_id, true)
	var definition: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
	toast_requested.emit("Nuovo ingrediente: %s%s" % [definition.get("name", ingredient_id), " · " + reason if not reason.is_empty() else ""], "income")
	_sync_recipe_unlocks()
	if persist:
		SaveManager.save_game()
	else:
		mark_save_dirty()
	return true


func purchase_ingredient_unlock(ingredient_id: String) -> bool:
	var definition: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
	var entry: Dictionary = stock.get(ingredient_id, {})
	var rule := DataRegistry.ingredient_unlock_rule(definition)
	var cost := int(rule.get("cost", 0))
	if definition.is_empty() or entry.is_empty() or bool(entry.get("unlocked", false)):
		return false
	if String(rule.get("type", "")) != "album_purchase" or cost <= 0 or money < cost:
		return false

	# Nothing below can fail after this validation, so the currency and unlock
	# state are committed as one transaction and emitted only once.
	money -= cost
	entry.unlocked = true
	album_discovered[ingredient_id] = true
	money_changed.emit(money)
	stock_changed.emit(ingredient_id, int(entry.get("amount", 0)))
	album_discovered_changed.emit(ingredient_id, true)
	_sync_recipe_unlocks()
	toast_requested.emit("Nuovo ingrediente: %s · acquisto Album" % String(definition.get("name", ingredient_id)), "income")
	mark_save_dirty()
	return true


func ingredient_unlock_status(ingredient_id: String) -> Dictionary:
	var definition: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
	var entry: Dictionary = stock.get(ingredient_id, {})
	var rule := DataRegistry.ingredient_unlock_rule(definition)
	var rule_type := String(rule.get("type", ""))
	var target := 0.0
	var current := 0.0
	match rule_type:
		"album_purchase":
			target = float(rule.get("cost", 0))
			current = minf(float(money), target)
		"customers_served":
			target = float(rule.get("value", 0))
			current = float(progress.get("customers_served", 0))
		"desserts_served":
			target = float(rule.get("value", 0))
			current = float(progress.get("desserts_served", 0))
		"services_started":
			target = float(rule.get("value", 0))
			current = float(progress.get("services_started", 0))
		"reputation":
			target = float(rule.get("value", 0))
			current = reputation
		"build_count":
			target = float(rule.get("value", 0))
			var item_id := String(rule.get("item", ""))
			for record: Dictionary in layout:
				if String(record.get("item", "")) == item_id:
					current += 1.0
	var unlocked := bool(entry.get("unlocked", false))
	return {
		"unlocked": unlocked,
		"rule": rule,
		"current": current,
		"target": target,
		"eligible": unlocked or (target > 0.0 and current >= target),
	}


func record_completed_order(recipe_id: String, _satisfaction: float) -> void:
	progress.customers_served = int(progress.get("customers_served", 0)) + 1
	if recipe_id in ["icecream_cone", "mixed_sundae"]:
		progress.desserts_served = int(progress.get("desserts_served", 0)) + 1
	# Reputation is exclusively driven by completed group reviews.  Keep this
	# method focused on counters/unlocks so an order cannot reward reputation a
	# second time.
	check_progression()
	mark_save_dirty()


func check_progression(persist: bool = true) -> Array[String]:
	var unlocked: Array[String] = []
	for ingredient: Dictionary in DataRegistry.ingredients:
		var ingredient_id := String(ingredient.get("id", ""))
		if bool(stock.get(ingredient_id, {}).get("unlocked", false)):
			continue
		var status := ingredient_unlock_status(ingredient_id)
		var rule: Dictionary = status.get("rule", {})
		if String(rule.get("type", "")) == "album_purchase" or not bool(status.get("eligible", false)):
			continue
		if unlock_ingredient(ingredient_id, _ingredient_unlock_reason(rule), false):
			unlocked.append(ingredient_id)
	if persist and not unlocked.is_empty():
		SaveManager.save_game()
	return unlocked


func _sync_recipe_unlocks() -> void:
	var collection_manager := get_node_or_null("/root/CollectionManager")
	if collection_manager != null and collection_manager.has_method("sync_recipe_unlocks"):
		collection_manager.sync_recipe_unlocks()


func _ingredient_unlock_reason(rule: Dictionary) -> String:
	match String(rule.get("type", "")):
		"customers_served":
			return "%d clienti serviti" % int(rule.get("value", 0))
		"desserts_served":
			return "%d dessert serviti" % int(rule.get("value", 0))
		"services_started":
			return "Primo servizio avviato" if int(rule.get("value", 0)) == 1 else "%d servizi avviati" % int(rule.get("value", 0))
		"reputation":
			return "Reputazione %s" % str(rule.get("value", 0))
		"build_count":
			var item_id := String(rule.get("item", ""))
			var item_name := String(DataRegistry.build_by_id.get(item_id, {}).get("name", item_id))
			return "%d x %s" % [int(rule.get("value", 0)), item_name]
	return "Obiettivo completato"


func serialize() -> Dictionary:
	return {
		"save_version": SAVE_VERSION,
		"money": money,
		"reputation": reputation,
		"stock": _serialize_stock(),
		"menu": _serialize_menu(),
		"employees": employees.duplicate(true),
		"candidates": candidates.duplicate(true),
		"layout": layout.duplicate(true),
		"settings": settings.duplicate(true),
		"tutorial": tutorial.duplicate(true),
		"purchased_preparations": purchased_preparations.duplicate(true),
		"progress": progress.duplicate(true),
		"album_inventory": album_inventory.duplicate(true),
		"album_discovered": album_discovered.duplicate(true),
		"reviews": reviews.duplicate(true),
		"review_reward_progress": review_reward_progress,
		"reputation_weight": reputation_weight,
		"world_clock": world_clock.duplicate(true),
		"restaurant_profile": restaurant_profile.duplicate(true),
		"pending_delivery_batch": pending_delivery_batch.duplicate(true),
		"cleanliness_state": cleanliness_state.duplicate(true),
		"pest_state": pest_state.duplicate(true),
		"staff_preferences": staff_preferences.duplicate(true)
	}


func deserialize(data: Dictionary) -> void:
	var loaded_version := int(data.get("save_version", 0))
	var progression_refund := 0
	if loaded_version > SAVE_VERSION:
		push_warning("Save file is from a newer version; loading known fields")
	reset_to_defaults(false)
	money = int(data.get("money", money))
	reputation = clampf(float(data.get("reputation", reputation)), 1.0, 5.0)
	stock = _normalize_stock_state(data.get("stock", {}))
	menu = _normalize_menu_state(data.get("menu", {}), loaded_version)
	if data.get("employees") is Array:
		employees = (data.employees as Array).duplicate(true)
	if data.get("candidates") is Array:
		candidates = (data.candidates as Array).duplicate(true)
	if data.get("layout") is Array:
		layout = (data.layout as Array).duplicate(true)
	if loaded_version < 2:
		_migrate_seating_v2()
	if loaded_version < 3:
		_migrate_editable_shell_v3()
	if loaded_version < 4:
		_migrate_kitchen_capacity_v4()
	if loaded_version < 5:
		_migrate_edge_walls_v5()
	if loaded_version < 6:
		_migrate_attachments_v6()
	if loaded_version < 7:
		_migrate_attachment_integrity_v7()
	if loaded_version < 8:
		_migrate_exterior_v8()
	if loaded_version < 9:
		_migrate_complete_shell_v9()
	if loaded_version < 11:
		_migrate_technical_kitchen_v11()
	if data.get("settings") is Dictionary:
		settings.merge(data.settings, true)
	_normalize_settings()
	if data.get("tutorial") is Dictionary:
		var loaded_tutorial: Dictionary = (data.tutorial as Dictionary).duplicate(true)
		# Preserve the original legacy shape until TutorialManager can translate
		# its numeric progress into canonical completed objective IDs.
		if int(loaded_tutorial.get("version", 0)) < 2:
			tutorial = loaded_tutorial
		else:
			tutorial.merge(loaded_tutorial, true)
	if data.get("purchased_preparations") is Dictionary:
		purchased_preparations.merge(data.purchased_preparations, true)
	if loaded_version < 12:
		progression_refund = _migrate_progression_v12()
	else:
		purchased_preparations = DataRegistry.sanitize_purchased_preparations(purchased_preparations, false).kept
	if data.get("progress") is Dictionary:
		var loaded_progress: Dictionary = data.progress
		progress.merge(loaded_progress, true)
		# M2 pacing is intentionally new-save-only. A v12 save created before this
		# subsystem has no marker, so it is preserved verbatim and bypasses the
		# introductory forcing/recommendations instead of being re-onboarded.
		if not loaded_progress.has("onboarding_pacing"):
			progress.onboarding_pacing = _legacy_onboarding_pacing_state()
	else:
		progress.onboarding_pacing = _legacy_onboarding_pacing_state()
	if loaded_version < 10:
		_migrate_casual_state_v10(data)
	else:
		_load_casual_state_v10(data)
	_sync_recipe_unlocks()
	var tutorial_manager := get_node_or_null("/root/TutorialManager")
	if tutorial_manager != null and tutorial_manager.has_method("ensure_schema"):
		tutorial_manager.ensure_schema()
	set_restaurant_state("closed")
	_emit_all()
	if progression_refund > 0:
		toast_requested.emit("Rimborso semilavorati non utilizzabili: +%d" % progression_refund, "income")


func _normalize_settings() -> void:
	for key: String in DEFAULT_SETTINGS:
		if not settings.has(key):
			settings[key] = DEFAULT_SETTINGS[key]
	var quality := String(settings.get("graphics_quality", "auto"))
	# Compatibility aliases from the pre-beta five-level selector.
	if quality == "balanced":
		quality = "medium"
	elif quality == "ultra":
		quality = "high"
	if quality not in ["auto", "low", "medium", "high"]:
		quality = "auto"
	settings.graphics_quality = quality
	settings.music = bool(settings.get("music", true))
	settings.sound = bool(settings.get("sound", true))
	settings.high_contrast = bool(settings.get("high_contrast", false))
	settings.reduced_motion = bool(settings.get("reduced_motion", false))
	for volume_key: String in ["music_volume", "ambience_volume", "sfx_volume", "ui_volume"]:
		settings[volume_key] = clampf(float(settings.get(volume_key, DEFAULT_SETTINGS[volume_key])), 0.0, 1.0)


func _serialize_stock() -> Dictionary:
	var result: Dictionary = {}
	for ingredient_id: String in stock:
		var entry: Variant = stock[ingredient_id]
		if not entry is Dictionary:
			continue
		var clean: Dictionary = (entry as Dictionary).duplicate(true)
		# Reservations belong to non-persisted orders and are always runtime-only.
		clean.reserved = 0
		result[ingredient_id] = clean
	return result


func _serialize_menu() -> Dictionary:
	var result: Dictionary = {}
	for recipe_id: String in menu:
		var entry: Variant = menu[recipe_id]
		if not entry is Dictionary:
			continue
		var clean: Dictionary = (entry as Dictionary).duplicate(true)
		_sync_menu_sold_out_entry(clean)
		result[recipe_id] = clean
	return result


func _normalize_stock_state(value: Variant) -> Dictionary:
	var source: Dictionary = value if value is Dictionary else {}
	var result: Dictionary = {}
	for ingredient: Dictionary in DataRegistry.ingredients:
		var ingredient_id := String(ingredient.id)
		var entry := _default_stock_entry(ingredient)
		var saved: Variant = source.get(ingredient_id, {})
		if saved is Dictionary:
			entry.merge(saved, true)
		var metadata := DataRegistry.storage_metadata_for_ingredient(ingredient)
		entry.amount = maxi(int(entry.get("amount", 0)), 0)
		entry.reserved = 0
		entry.storage_type = String(metadata.storage_type)
		entry.storage_units = int(metadata.storage_units)
		entry.unlocked = bool(entry.get("unlocked", false))
		result[ingredient_id] = entry
	for ingredient_id: String in source:
		if result.has(ingredient_id) or not source[ingredient_id] is Dictionary:
			continue
		var legacy_entry: Dictionary = (source[ingredient_id] as Dictionary).duplicate(true)
		legacy_entry.amount = maxi(int(legacy_entry.get("amount", 0)), 0)
		legacy_entry.reserved = 0
		legacy_entry.storage_type = String(legacy_entry.get("storage_type", DataRegistry.balance_value("storage.default_type", "ambient")))
		legacy_entry.storage_units = maxi(int(legacy_entry.get("storage_units", DataRegistry.balance_value("storage.default_units", 1))), 1)
		result[ingredient_id] = legacy_entry
	return result


func _normalize_menu_state(value: Variant, loaded_version: int) -> Dictionary:
	var source: Dictionary = value if value is Dictionary else {}
	var result: Dictionary = {}
	for recipe: Dictionary in DataRegistry.recipes:
		var recipe_id := String(recipe.id)
		var entry := {
			"active": bool(recipe.get("active", false)),
			"unlocked": bool(recipe.get("unlocked", false)),
			"price": int(recipe.get("price", 10)),
			"manual_paused": false,
			"auto_sold_out": false,
			"sold_out": false
		}
		var saved: Variant = source.get(recipe_id, {})
		if saved is Dictionary:
			entry.merge(saved, true)
		if loaded_version < 10:
			entry.manual_paused = bool(entry.get("sold_out", false))
			entry.auto_sold_out = false
		else:
			entry.manual_paused = bool(entry.get("manual_paused", entry.get("sold_out", false)))
			entry.auto_sold_out = bool(entry.get("auto_sold_out", false))
		_sync_menu_sold_out_entry(entry)
		result[recipe_id] = entry
	for recipe_id: String in source:
		if result.has(recipe_id) or not source[recipe_id] is Dictionary:
			continue
		var legacy_entry: Dictionary = (source[recipe_id] as Dictionary).duplicate(true)
		legacy_entry.manual_paused = bool(legacy_entry.get("sold_out", false)) if loaded_version < 10 else bool(legacy_entry.get("manual_paused", legacy_entry.get("sold_out", false)))
		legacy_entry.auto_sold_out = false if loaded_version < 10 else bool(legacy_entry.get("auto_sold_out", false))
		_sync_menu_sold_out_entry(legacy_entry)
		result[recipe_id] = legacy_entry
	return result


func _migrate_casual_state_v10(data: Dictionary) -> void:
	# v9 used stock.amount as the Album badge. The new collection starts only
	# from the configured starter pack (or explicit pre-release album data),
	# never by copying physical stock quantities.
	_load_casual_state_v10(data)
	for ingredient_id: String in stock:
		if bool(stock[ingredient_id].get("unlocked", false)):
			album_discovered[ingredient_id] = true


func _load_casual_state_v10(data: Dictionary) -> void:
	album_inventory = _normalize_album_inventory(data.get("album_inventory", {}))
	album_discovered = _normalize_album_discovered(data.get("album_discovered", {}))
	reviews = _normalize_reviews(data.get("reviews", []))
	review_reward_progress = maxi(int(data.get("review_reward_progress", 0)), 0)
	reputation_weight = maxf(float(data.get("reputation_weight", 0.0)), 0.0)
	world_clock = _normalize_world_clock(data.get("world_clock", {}))
	restaurant_profile = _default_restaurant_profile()
	if data.get("restaurant_profile") is Dictionary:
		restaurant_profile.merge(data.restaurant_profile, true)
	pending_delivery_batch = _normalize_pending_delivery_batch(data.get("pending_delivery_batch", {}))
	cleanliness_state = _default_cleanliness_state()
	if data.get("cleanliness_state") is Dictionary:
		cleanliness_state.merge(data.cleanliness_state, true)
	pest_state = _default_pest_state()
	if data.get("pest_state") is Dictionary:
		pest_state.merge(data.pest_state, true)
	staff_preferences = (data.staff_preferences as Dictionary).duplicate(true) if data.get("staff_preferences") is Dictionary else {}
	for ingredient_id: String in stock:
		if bool(stock[ingredient_id].get("unlocked", false)):
			album_discovered[ingredient_id] = true


func _normalize_album_inventory(value: Variant) -> Dictionary:
	var result := _default_album_inventory()
	if value is Dictionary:
		for ingredient_id: String in value:
			result[ingredient_id] = maxi(int(value[ingredient_id]), 0)
	return result


func _normalize_album_discovered(value: Variant) -> Dictionary:
	var result := _default_album_discovered()
	if value is Dictionary:
		for ingredient_id: String in value:
			result[ingredient_id] = bool(value[ingredient_id])
	return result


func _normalize_reviews(value: Variant) -> Array:
	var result: Array = []
	if value is Array:
		for review: Variant in value:
			if review is Dictionary:
				result.append((review as Dictionary).duplicate(true))
	var history_limit := maxi(int(DataRegistry.balance_value("reviews.history_limit", 100)), 1)
	while result.size() > history_limit:
		result.pop_front()
	return result


func _normalize_world_clock(value: Variant) -> Dictionary:
	var result := _default_world_clock()
	if value is Dictionary:
		result.merge(value, true)
	result.day = maxi(int(result.get("day", 1)), 1)
	result.minute = clampf(float(result.get("minute", 540.0)), 0.0, 1439.999)
	return result


func _normalize_pending_delivery_batch(value: Variant) -> Dictionary:
	var result := _default_pending_delivery_batch()
	if value is Dictionary:
		result.merge(value, true)
	result.id = String(result.get("id", ""))
	result.items = (result.items as Dictionary).duplicate(true) if result.get("items") is Dictionary else {}
	result.remaining = maxf(float(result.get("remaining", DataRegistry.balance_value("delivery.batch_interval_seconds", 300.0))), 0.0)
	result.paid = bool(result.get("paid", false))
	return result


func _migrate_progression_v12() -> int:
	var migration := DataRegistry.sanitize_purchased_preparations(purchased_preparations, true)
	purchased_preparations = (migration.get("kept", {}) as Dictionary).duplicate(true)
	var refund := maxi(int(migration.get("refund", 0)), 0)
	money += refund
	return refund


func _migrate_seating_v2() -> void:
	var records_by_uid: Dictionary = {}
	for record: Dictionary in layout:
		records_by_uid[String(record.get("uid", ""))] = record
	var additions := [
		{"table_uid":"table_1", "table_cell":[3, 3], "uid":"chair_5", "item":"chair", "cell":[3, 2], "rotation":2},
		{"table_uid":"table_1", "table_cell":[3, 3], "uid":"chair_6", "item":"chair", "cell":[4, 5], "rotation":0},
		{"table_uid":"table_2", "table_cell":[10, 3], "uid":"chair_7", "item":"chair", "cell":[10, 2], "rotation":2},
		{"table_uid":"table_2", "table_cell":[10, 3], "uid":"chair_8", "item":"chair", "cell":[11, 5], "rotation":0}
	]
	for addition: Dictionary in additions:
		if records_by_uid.has(addition.uid) or not records_by_uid.has(addition.table_uid):
			continue
		var table_record: Dictionary = records_by_uid[addition.table_uid]
		if table_record.get("cell", []) != addition.table_cell:
			continue
		var clean := addition.duplicate(true)
		clean.erase("table_uid")
		clean.erase("table_cell")
		layout.append(clean)


func _migrate_editable_shell_v3() -> void:
	var occupied_layout_cells: Dictionary = {}
	for record: Dictionary in layout:
		var cell: Array = record.get("cell", [-1, -1])
		occupied_layout_cells[Vector2i(int(cell[0]), int(cell[1]))] = true
	for wall_record: Dictionary in _initial_wall_records():
		var cell_data: Array = wall_record.cell
		var cell := Vector2i(int(cell_data[0]), int(cell_data[1]))
		if not occupied_layout_cells.has(cell):
			layout.append(wall_record)


func _migrate_kitchen_capacity_v4() -> void:
	for record: Dictionary in layout:
		if String(record.get("uid", "")) == "cut_2":
			return
	layout.append({"uid":"cut_2", "item":"cutting_board", "cell":[10, 9], "rotation":0})


func _migrate_edge_walls_v5() -> void:
	var has_divider_corner := false
	for record: Dictionary in layout:
		if String(record.get("uid", "")).begins_with("wall_divider_"):
			record.cell = [int(record.get("cell", [0, 7])[0]), 8]
			if String(record.get("uid", "")) == "wall_divider_0":
				has_divider_corner = true
	if not has_divider_corner:
		layout.append({"uid":"wall_divider_0", "item":"wall", "cell":[0, 8], "rotation":0})


func _migrate_attachments_v6() -> void:
	var records_by_uid: Dictionary = {}
	var tables: Array[Dictionary] = []
	var walls: Array[Dictionary] = []
	for record: Dictionary in layout:
		records_by_uid[String(record.get("uid", ""))] = record
		var item_id := String(record.get("item", ""))
		if item_id.begins_with("table"):
			tables.append(record)
		elif item_id == "wall":
			walls.append(record)
	var additions: Array[Dictionary] = []
	for record: Dictionary in layout:
		if not String(record.get("support_uid", "")).is_empty():
			continue
		var item_id := String(record.get("item", ""))
		var cell_data: Array = record.get("cell", [0, 0])
		var cell := Vector2(int(cell_data[0]), int(cell_data[1]))
		if item_id in ["chair", "stool"]:
			var best_table: Dictionary = {}
			var best_distance := INF
			for table: Dictionary in tables:
				var table_cell_data: Array = table.get("cell", [0, 0])
				var table_cell := Vector2(int(table_cell_data[0]), int(table_cell_data[1]))
				var table_definition: Dictionary = DataRegistry.build_by_id.get(String(table.get("item", "")), {})
				var raw: Array = table_definition.get("footprint", [1, 1])
				var size := Vector2(int(raw[0]), int(raw[1]))
				if int(table.get("rotation", 0)) % 2 == 1:
					size = Vector2(size.y, size.x)
				var center := table_cell + (size - Vector2.ONE) * 0.5
				var distance := cell.distance_to(center)
				if distance < best_distance:
					best_distance = distance
					best_table = table
			if not best_table.is_empty() and best_distance <= 3.0:
				var table_cell_data: Array = best_table.get("cell", [0, 0])
				var table_cell := Vector2(int(table_cell_data[0]), int(table_cell_data[1]))
				var definition: Dictionary = DataRegistry.build_by_id.get(String(best_table.get("item", "")), {})
				var raw: Array = definition.get("footprint", [1, 1])
				var size := Vector2(int(raw[0]), int(raw[1]))
				if int(best_table.get("rotation", 0)) % 2 == 1:
					size = Vector2(size.y, size.x)
				var delta := cell - (table_cell + (size - Vector2.ONE) * 0.5)
				var local_delta := delta.rotated(float(int(best_table.get("rotation", 0))) * PI * 0.5)
				var slot := (1 if local_delta.x < 0.0 else 3) if absf(local_delta.x) > absf(local_delta.y) else (0 if local_delta.y < 0.0 else 2)
				record.support_uid = String(best_table.uid)
				record.attachment_slot = slot
				record.cell = best_table.cell.duplicate()
				record.rotation = posmod([0, 3, 2, 1][slot] + int(best_table.get("rotation", 0)), 4)
		elif item_id in ["cutting_board", "dish_rack", "dough", "oven", "pizza_oven"]:
			var support_uid := "support_%s" % String(record.uid)
			var support_item := "prep_counter" if item_id in ["cutting_board", "pizza_oven"] else "worktable"
			var support_origin := _migration_find_surface_origin(Vector2i(int(cell.x), int(cell.y)), support_item, int(record.get("rotation", 0)), String(record.uid), additions)
			additions.append({"uid":support_uid, "item":support_item, "cell":[support_origin.x, support_origin.y], "rotation":int(record.get("rotation", 0))})
			record.support_uid = support_uid
			record.attachment_slot = 0
			record.cell = [support_origin.x, support_origin.y]
		elif item_id == "prep_counter":
			additions.append({"uid":"prep_tool_%s" % String(record.uid), "item":"prep_bowl", "cell":[int(cell.x), int(cell.y)], "rotation":int(record.get("rotation", 0)), "support_uid":String(record.uid), "attachment_slot":0})
		elif item_id == "pass":
			additions.append({"uid":"pass_tool_%s" % String(record.uid), "item":"pass_tray", "cell":[int(cell.x), int(cell.y)], "rotation":int(record.get("rotation", 0)), "support_uid":String(record.uid), "attachment_slot":0})
		elif item_id == "storage" and not walls.is_empty():
			var best_wall: Dictionary = walls[0]
			var best_distance := INF
			for wall: Dictionary in walls:
				var wall_cell_data: Array = wall.get("cell", [0, 0])
				var distance := cell.distance_to(Vector2(int(wall_cell_data[0]), int(wall_cell_data[1])))
				if distance < best_distance:
					best_distance = distance
					best_wall = wall
			record.support_uid = String(best_wall.uid)
			record.attachment_slot = 0
			record.cell = best_wall.cell.duplicate()
			record.rotation = int(best_wall.get("rotation", 0))
	layout.append_array(additions)


func _migration_find_surface_origin(preferred: Vector2i, support_item: String, rotation_steps: int, ignored_uid: String, additions: Array[Dictionary]) -> Vector2i:
	var candidates: Array[Vector2i] = []
	for x: int in range(preferred.x, 18):
		candidates.append(Vector2i(x, preferred.y))
	for x: int in range(0, preferred.x):
		candidates.append(Vector2i(x, preferred.y))
	for y: int in range(8, 14):
		if y == preferred.y:
			continue
		for x: int in range(0, 18):
			candidates.append(Vector2i(x, y))
	var support_definition: Dictionary = DataRegistry.build_by_id.get(support_item, {})
	var support_raw: Array = support_definition.get("footprint", [1, 1])
	var support_size := Vector2i(int(support_raw[0]), int(support_raw[1]))
	if rotation_steps % 2 == 1:
		support_size = Vector2i(support_size.y, support_size.x)
	for candidate: Vector2i in candidates:
		if candidate.x < 0 or candidate.y < 0 or candidate.x + support_size.x > 18 or candidate.y + support_size.y > 14:
			continue
		var free := true
		for other: Dictionary in layout + additions:
			if String(other.get("uid", "")) == ignored_uid:
				continue
			var other_definition: Dictionary = DataRegistry.build_by_id.get(String(other.get("item", "")), {})
			if other_definition.is_empty() or not bool(other_definition.get("blocking", true)) or String(other_definition.get("placement", "cell")) != "cell":
				continue
			var other_cell_data: Array = other.get("cell", [-99, -99])
			var other_origin := Vector2i(int(other_cell_data[0]), int(other_cell_data[1]))
			var other_raw: Array = other_definition.get("footprint", [1, 1])
			var other_size := Vector2i(int(other_raw[0]), int(other_raw[1]))
			if int(other.get("rotation", 0)) % 2 == 1:
				other_size = Vector2i(other_size.y, other_size.x)
			var candidate_rect := Rect2i(candidate, support_size)
			if candidate_rect.intersects(Rect2i(other_origin, other_size)):
				free = false
				break
		if free:
			return candidate
	return preferred


func _migrate_attachment_integrity_v7() -> void:
	var records_by_uid: Dictionary = {}
	for record: Dictionary in layout:
		records_by_uid[String(record.get("uid", ""))] = record
	var additions: Array[Dictionary] = []
	var used_slots: Dictionary = {}
	for record: Dictionary in layout:
		var definition: Dictionary = DataRegistry.build_by_id.get(String(record.get("item", "")), {})
		if definition.is_empty():
			continue
		var placement := String(definition.get("placement", "cell"))
		if placement == "cell" and record.has("support_uid"):
			record.erase("support_uid")
			record.erase("attachment_slot")
			continue
		if placement != "surface":
			continue
		var support_uid := String(record.get("support_uid", ""))
		var support: Dictionary = records_by_uid.get(support_uid, {})
		var slot := int(record.get("attachment_slot", 0))
		var slots := _layout_surface_slots(definition, support, slot, int(record.get("rotation", 0)))
		if not support.is_empty() and _layout_slots_available(support_uid, slots, used_slots):
			_layout_mark_slots(support_uid, slots, used_slots)
			record.cell = support.get("cell", record.get("cell", [0, 0])).duplicate()
			continue
		var record_cell_data: Array = record.get("cell", [0, 0])
		var record_cell := Vector2i(int(record_cell_data[0]), int(record_cell_data[1]))
		var found_support: Dictionary = {}
		var found_slot := -1
		for candidate: Dictionary in layout + additions:
			var candidate_definition: Dictionary = DataRegistry.build_by_id.get(String(candidate.get("item", "")), {})
			if String(candidate_definition.get("support_kind", "")) != "worktop" or candidate.get("cell", []) != record.get("cell", []):
				continue
			var capacity_raw: Array = candidate_definition.get("footprint", [1, 1])
			for candidate_slot: int in int(capacity_raw[0]) * int(capacity_raw[1]):
				var candidate_slots := _layout_surface_slots(definition, candidate, candidate_slot, int(record.get("rotation", 0)))
				var candidate_uid := String(candidate.get("uid", ""))
				if not candidate_slots.is_empty() and _layout_slots_available(candidate_uid, candidate_slots, used_slots):
					found_support = candidate
					found_slot = candidate_slot
					break
			if not found_support.is_empty():
				break
		if found_support.is_empty():
			var item_raw: Array = definition.get("footprint", [1, 1])
			var support_item := "prep_counter" if int(item_raw[0]) > 1 or int(item_raw[1]) > 1 else "worktable"
			var support_origin := _migration_find_surface_origin(record_cell, support_item, int(record.get("rotation", 0)), String(record.get("uid", "")), additions)
			support_uid = "auto_support_%s" % String(record.get("uid", "tool"))
			var suffix := 2
			while records_by_uid.has(support_uid):
				support_uid = "auto_support_%s_%d" % [String(record.get("uid", "tool")), suffix]
				suffix += 1
			found_support = {"uid":support_uid, "item":support_item, "cell":[support_origin.x, support_origin.y], "rotation":int(record.get("rotation", 0))}
			additions.append(found_support)
			records_by_uid[support_uid] = found_support
			found_slot = 0
		support_uid = String(found_support.uid)
		slots = _layout_surface_slots(definition, found_support, found_slot, int(record.get("rotation", 0)))
		record.support_uid = support_uid
		record.attachment_slot = found_slot
		record.cell = found_support.cell.duplicate()
		_layout_mark_slots(support_uid, slots, used_slots)
	layout.append_array(additions)


func _layout_surface_slots(definition: Dictionary, support_record: Dictionary, attachment_slot: int, rotation_steps: int) -> Array[int]:
	var result: Array[int] = []
	if support_record.is_empty():
		return result
	var support_definition: Dictionary = DataRegistry.build_by_id.get(String(support_record.get("item", "")), {})
	if String(support_definition.get("support_kind", "")) != String(definition.get("requires_support", "")):
		return result
	var support_raw: Array = support_definition.get("footprint", [1, 1])
	var support_width := maxi(int(support_raw[0]), 1)
	var support_height := maxi(int(support_raw[1]), 1)
	var item_raw: Array = definition.get("footprint", [1, 1])
	var item_width := maxi(int(item_raw[0]), 1)
	var item_height := maxi(int(item_raw[1]), 1)
	if posmod(rotation_steps - int(support_record.get("rotation", 0)), 2) == 1:
		var swap := item_width
		item_width = item_height
		item_height = swap
	if attachment_slot < 0:
		return result
	var start_x := attachment_slot % support_width
	var start_y := attachment_slot / support_width
	if start_x + item_width > support_width or start_y + item_height > support_height:
		return result
	for y: int in item_height:
		for x: int in item_width:
			result.append((start_y + y) * support_width + start_x + x)
	return result


func _layout_slots_available(support_uid: String, slots: Array[int], used_slots: Dictionary) -> bool:
	if slots.is_empty():
		return false
	var occupied: Dictionary = used_slots.get(support_uid, {})
	for slot: int in slots:
		if occupied.has(slot):
			return false
	return true


func _layout_mark_slots(support_uid: String, slots: Array[int], used_slots: Dictionary) -> void:
	if not used_slots.has(support_uid):
		used_slots[support_uid] = {}
	for slot: int in slots:
		used_slots[support_uid][slot] = true


func _migrate_exterior_v8() -> void:
	var existing_uids: Dictionary = {}
	for record: Dictionary in layout:
		existing_uids[String(record.get("uid", ""))] = true
	for exterior_record: Dictionary in _initial_exterior_records():
		var uid := String(exterior_record.get("uid", ""))
		if uid.is_empty() or existing_uids.has(uid):
			continue
		layout.append(exterior_record.duplicate(true))
		existing_uids[uid] = true


func _migrate_complete_shell_v9() -> void:
	# The old fixed isometric view only needed the north and west walls.  Once
	# the camera can rotate, every canonical outer edge must have a real layout
	# object. Preserve doors/windows and player-built replacements already on an
	# edge, and only fill genuinely missing shell segments.
	var occupied_edges: Dictionary = {}
	var used_uids: Dictionary = {}
	for record: Dictionary in layout:
		used_uids[String(record.get("uid", ""))] = true
		if String(record.get("item", "")) in ["wall", "wall_window", "door", "pass_opening"]:
			occupied_edges[_layout_edge_key(record)] = true
	for shell_record: Dictionary in _initial_shell_wall_records():
		var edge_key := _layout_edge_key(shell_record)
		if occupied_edges.has(edge_key):
			continue
		var migrated_record := shell_record.duplicate(true)
		var requested_uid := String(migrated_record.get("uid", "wall_shell"))
		var uid := requested_uid
		var suffix := 1
		while used_uids.has(uid):
			uid = "%s_v9_%d" % [requested_uid, suffix]
			suffix += 1
		migrated_record.uid = uid
		layout.append(migrated_record)
		occupied_edges[edge_key] = true
		used_uids[uid] = true


func _migrate_technical_kitchen_v11() -> void:
	# Dessert changed from a blocking floor station to a surface attachment.
	# Reuse the proven attachment repair pass: it keeps the machine UID and
	# authored scale intact, creates a deterministic free worktop only when
	# needed, and preserves the closest viable layout position.
	_migrate_attachment_integrity_v7()

	var used_uids: Dictionary = {}
	for record: Dictionary in layout:
		var uid := String(record.get("uid", ""))
		if not uid.is_empty():
			used_uids[uid] = true

	var additions: Array[Dictionary] = []
	for station: Dictionary in layout:
		var station_definition: Dictionary = DataRegistry.build_by_id.get(
			String(station.get("item", "")),
			{}
		)
		if not bool(station_definition.get("ventilation_required", false)):
			continue
		var station_uid := String(station.get("uid", ""))
		if station_uid.is_empty() or _layout_has_compatible_hood(station_uid):
			continue
		var station_cell: Array = station.get("cell", [0, 0])
		var hood_uid := _deterministic_migration_uid(
			"v11_hood_%s" % station_uid,
			used_uids
		)
		additions.append({
			"uid": hood_uid,
			"item": "extractor_hood",
			"cell": [int(station_cell[0]), int(station_cell[1])],
			"rotation": int(station.get("rotation", 0)),
			"support_uid": station_uid,
			"attachment_slot": 0
		})
		used_uids[hood_uid] = true
	layout.append_array(additions)


func _layout_has_compatible_hood(station_uid: String) -> bool:
	for record: Dictionary in layout:
		if String(record.get("support_uid", "")) != station_uid:
			continue
		var definition: Dictionary = DataRegistry.build_by_id.get(
			String(record.get("item", "")),
			{}
		)
		if (
			String(definition.get("placement", "cell")) == "overhead"
			and String(definition.get("requires_support", "")) == "heat_station"
		):
			return true
	return false


func _deterministic_migration_uid(base_uid: String, used_uids: Dictionary) -> String:
	if not used_uids.has(base_uid):
		return base_uid
	var suffix := 2
	while used_uids.has("%s_%d" % [base_uid, suffix]):
		suffix += 1
	return "%s_%d" % [base_uid, suffix]


func _layout_edge_key(record: Dictionary) -> String:
	var cell_data: Array = record.get("cell", [0, 0])
	var x := int(cell_data[0])
	var y := int(cell_data[1])
	match posmod(int(record.get("rotation", 0)), 4):
		0: return "h:%d:%d" % [x, y]
		1: return "v:%d:%d" % [x, y]
		2: return "h:%d:%d" % [x, y + 1]
		_: return "v:%d:%d" % [x + 1, y]


func _initial_exterior_records() -> Array:
	# The sidewalk and road occupy y=-1..-6. Keep the initial clearing work
	# around the other three sides of the lot so it never blocks the queue.
	return [
		{"uid":"exterior_obstacle_tree_1", "item":"exterior_obstacle_tree_a", "cell":[-3, 2], "rotation":0},
		{"uid":"exterior_obstacle_tree_2", "item":"exterior_obstacle_tree_b", "cell":[23, 2], "rotation":1},
		{"uid":"exterior_obstacle_tree_3", "item":"exterior_obstacle_tree_c", "cell":[-3, 14], "rotation":2},
		{"uid":"exterior_obstacle_bush_1", "item":"exterior_obstacle_bush_a", "cell":[23, 15], "rotation":0},
		{"uid":"exterior_obstacle_bush_2", "item":"exterior_obstacle_bush_b", "cell":[5, 16], "rotation":3},
		{"uid":"exterior_obstacle_rock_1", "item":"exterior_obstacle_rock", "cell":[17, 16], "rotation":0}
	]


func _initial_shell_wall_records() -> Array:
	var records: Array = []
	for x: int in 18:
		if x == 8:
			continue
		records.append({"uid":"wall_top_%d" % x, "item":"wall_window" if x in [3, 4, 13, 14] else "wall", "cell":[x, 0], "rotation":0})
	for y: int in range(0, 14):
		records.append({"uid":"wall_left_%d" % y, "item":"wall", "cell":[0, y], "rotation":1})
	for x: int in 18:
		records.append({"uid":"wall_bottom_%d" % x, "item":"wall_window" if x in [3, 4, 13, 14] else "wall", "cell":[x, 13], "rotation":2})
	for y: int in range(0, 14):
		records.append({"uid":"wall_right_%d" % y, "item":"wall_window" if y in [3, 4, 10, 11] else "wall", "cell":[17, y], "rotation":3})
	return records


func _initial_wall_records() -> Array:
	var records := _initial_shell_wall_records()
	for x: int in range(0, 18):
		if x in [8, 9, 10, 11]:
			continue
		records.append({"uid":"wall_divider_%d" % x, "item":"wall", "cell":[x, 8], "rotation":0})
	return records


func _emit_all() -> void:
	money_changed.emit(money)
	reputation_changed.emit(reputation)
	# The day-cycle manager keeps a runtime clock mirror and commits it when the
	# restaurant state changes. Refresh that mirror first while deserializing,
	# otherwise the following state signal can overwrite the just-loaded clock
	# with its stale pre-load value.
	world_clock_changed.emit(world_clock.duplicate(true))
	restaurant_state_changed.emit(restaurant_state)
	menu_changed.emit()
	employees_changed.emit()
	layout_changed.emit()
	for ingredient_id: String in album_inventory:
		album_inventory_changed.emit(ingredient_id, int(album_inventory[ingredient_id]))
	for ingredient_id: String in album_discovered:
		album_discovered_changed.emit(ingredient_id, bool(album_discovered[ingredient_id]))
	reviews_changed.emit()
	review_reward_progress_changed.emit(review_reward_progress)
	restaurant_profile_changed.emit(restaurant_profile.duplicate(true))
	pending_delivery_batch_changed.emit(pending_delivery_batch.duplicate(true))
	cleanliness_state_changed.emit(cleanliness_state.duplicate(true))
	pest_state_changed.emit(pest_state.duplicate(true))
	for employee_id: String in staff_preferences:
		staff_preferences_changed.emit(employee_id, staff_preferences[employee_id])
