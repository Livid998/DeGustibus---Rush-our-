extends Node

signal album_reward_granted(ingredient_id: String, amount: int, source: String)
signal recipe_unlocked(recipe_id: String)
signal recipe_unlock_failed(recipe_id: String, reason: String)

const DEFAULT_RARITY_WEIGHTS := {
	1: 8.0,
	2: 5.0,
	3: 3.0,
	4: 1.65,
	5: 0.85,
}

var _reward_rng := RandomNumberGenerator.new()
var _pity_progress := 0


func _ready() -> void:
	_reward_rng.randomize()
	_pity_progress = maxi(int(GameState.progress.get("album_reward_pity", 0)), 0)


func set_reward_seed(seed_value: int, pity_progress: int = 0) -> void:
	_reward_rng.seed = seed_value
	_set_pity_progress(pity_progress)


func inject_reward_rng(value: RandomNumberGenerator, pity_progress: int = 0) -> void:
	if value == null:
		return
	_reward_rng = value
	_set_pity_progress(pity_progress)


func reward_pity_progress() -> int:
	_sync_pity_from_state()
	return _pity_progress


func unlock_recipe(recipe_id: String) -> bool:
	var recipe: Dictionary = DataRegistry.recipes_by_id.get(recipe_id, {})
	var menu_state: Dictionary = GameState.menu.get(recipe_id, {})
	if recipe.is_empty() or menu_state.is_empty():
		return _fail_unlock(recipe_id, "Ricetta non valida")
	if bool(menu_state.get("unlocked", false)):
		return _fail_unlock(recipe_id, "Ricetta gia imparata")

	var unlock_cost: Dictionary = recipe.get("unlock_cost", {})
	if unlock_cost.is_empty():
		return _fail_unlock(recipe_id, "Costo album non configurato")
	var previous_amounts: Dictionary = {}
	for ingredient_id: String in unlock_cost:
		var required := int(unlock_cost[ingredient_id])
		if required <= 0 or not DataRegistry.ingredients_by_id.has(ingredient_id):
			return _fail_unlock(recipe_id, "Costo album non valido")
		var owned := int(GameState.album_inventory.get(ingredient_id, 0))
		if owned < required:
			var ingredient_name := String(DataRegistry.ingredients_by_id[ingredient_id].get("name", ingredient_id))
			return _fail_unlock(recipe_id, "Manca %s (%d/%d)" % [ingredient_name, owned, required])
		previous_amounts[ingredient_id] = owned

	# All validation happens before the first write. The rollback is defensive:
	# with valid registry IDs the GameState setters are expected to succeed.
	for ingredient_id: String in unlock_cost:
		var remaining := int(previous_amounts[ingredient_id]) - int(unlock_cost[ingredient_id])
		if not GameState.set_album_ingredient_amount(ingredient_id, remaining):
			_restore_album_amounts(previous_amounts)
			return _fail_unlock(recipe_id, "Inventario album non aggiornabile")
	if not GameState.set_recipe_unlocked(recipe_id, true):
		_restore_album_amounts(previous_amounts)
		return _fail_unlock(recipe_id, "Ricetta non aggiornabile")

	recipe_unlocked.emit(recipe_id)
	GameState.toast_requested.emit("Ricetta imparata: %s" % String(recipe.get("name", recipe_id)), "income")
	return true


func sync_recipe_unlocks() -> Array[String]:
	var unlocked: Array[String] = []
	for recipe: Dictionary in DataRegistry.recipes:
		var recipe_id := String(recipe.get("id", ""))
		if recipe_id.is_empty() or bool(GameState.menu.get(recipe_id, {}).get("unlocked", false)):
			continue
		var requirements := DataRegistry.ingredient_unlock_requirements(recipe)
		if requirements.is_empty():
			continue
		var ready := true
		for ingredient_id: String in requirements:
			if not bool(GameState.stock.get(ingredient_id, {}).get("unlocked", false)):
				ready = false
				break
		if ready and GameState.set_recipe_unlocked(recipe_id, true):
			unlocked.append(recipe_id)
			recipe_unlocked.emit(recipe_id)
	return unlocked


func add_album_ingredient(ingredient_id: String, amount: int, source: String = "debug") -> bool:
	if amount <= 0 or not DataRegistry.ingredients_by_id.has(ingredient_id):
		return false
	if not GameState.add_album_ingredient(ingredient_id, amount):
		return false
	GameState.set_album_discovered(ingredient_id, true)
	album_reward_granted.emit(ingredient_id, amount, source)
	return true


func remove_album_ingredient(ingredient_id: String, amount: int) -> bool:
	if amount <= 0 or not DataRegistry.ingredients_by_id.has(ingredient_id):
		return false
	var owned := int(GameState.album_inventory.get(ingredient_id, 0))
	if owned < amount:
		return false
	return GameState.set_album_ingredient_amount(ingredient_id, owned - amount)


func debug_add(ingredient_id: String, amount: int = 1) -> bool:
	return add_album_ingredient(ingredient_id, amount, "debug")


func debug_remove(ingredient_id: String, amount: int = 1) -> bool:
	return remove_album_ingredient(ingredient_id, amount)


func grant_weighted_reward(source: String, quantity_override: int = -1) -> Dictionary:
	_sync_pity_from_state()
	var all_candidates: Array[String] = []
	for ingredient: Dictionary in DataRegistry.ingredients:
		all_candidates.append(String(ingredient.id))
	if all_candidates.is_empty():
		return {}

	var useful := needed_album_ingredients()
	var pity_interval := maxi(int(_balance("album.pity_interval", 4)), 1)
	var force_useful := not useful.is_empty() and _pity_progress >= pity_interval - 1
	var candidates := useful if force_useful else all_candidates
	var ingredient_id := _pick_weighted(candidates, useful)
	if ingredient_id.is_empty():
		return {}

	var quantity := quantity_override
	if quantity <= 0:
		var quantity_min := maxi(int(_balance("album.reward_quantity_min", 1)), 1)
		var quantity_max := maxi(int(_balance("album.reward_quantity_max", quantity_min)), quantity_min)
		quantity = _reward_rng.randi_range(quantity_min, quantity_max)
	if not add_album_ingredient(ingredient_id, quantity, source):
		return {}

	if useful.has(ingredient_id):
		_set_pity_progress(0)
	else:
		_set_pity_progress(_pity_progress + 1)
	return {
		"ingredient_id": ingredient_id,
		"amount": quantity,
		"source": source,
		"pity_forced": force_useful,
	}


func needed_album_ingredients() -> Array[String]:
	var needed: Array[String] = []
	for recipe: Dictionary in DataRegistry.recipes:
		var recipe_id := String(recipe.id)
		if bool(GameState.menu.get(recipe_id, {}).get("unlocked", false)):
			continue
		if not bool(recipe.get("discovered", true)):
			continue
		for ingredient_id: String in recipe.get("unlock_cost", {}):
			var required := int(recipe.unlock_cost[ingredient_id])
			if int(GameState.album_inventory.get(ingredient_id, 0)) < required and not needed.has(ingredient_id):
				needed.append(ingredient_id)
	return needed


func handle_review_completed(stars: int) -> Array[Dictionary]:
	var rewards: Array[Dictionary] = []
	if stars >= 4:
		var threshold := maxi(int(_balance("album.positive_reviews_per_reward", 5)), 1)
		var progress := int(GameState.review_reward_progress) + 1
		while progress >= threshold:
			progress -= threshold
			var reward := grant_weighted_reward("positive_reviews")
			if not reward.is_empty():
				rewards.append(reward)
		_set_review_reward_progress(progress)
	if stars >= 5:
		var gift_chance := clampf(float(_balance("album.five_star_gift_chance", 0.08)), 0.0, 1.0)
		if _reward_rng.randf() < gift_chance:
			var gift := grant_weighted_reward("five_star_gift")
			if not gift.is_empty():
				rewards.append(gift)
	return rewards


func handle_day_completed(_day: int = 0) -> Array[Dictionary]:
	var rewards: Array[Dictionary] = []
	var reward_count := maxi(int(_balance("album.day_completion_reward", 1)), 0)
	for _index: int in reward_count:
		var reward := grant_weighted_reward("day_completed")
		if not reward.is_empty():
			rewards.append(reward)
	return rewards


func handle_reputation_changed(previous_value: float, current_value: float) -> Array[Dictionary]:
	var rewards: Array[Dictionary] = []
	var crossed_thresholds := maxi(int(floor(current_value)) - int(floor(previous_value)), 0)
	var rewards_per_threshold := maxi(int(_balance("album.reputation_threshold_reward", 1)), 0)
	for _threshold: int in crossed_thresholds:
		for _reward_index: int in rewards_per_threshold:
			var reward := grant_weighted_reward("reputation_threshold")
			if not reward.is_empty():
				rewards.append(reward)
	return rewards


func reward_sources_text(_ingredient_id: String = "") -> String:
	return "Recensioni positive, fine giornata, reputazione e regali da recensioni a 5 stelle"


func _pick_weighted(candidates: Array[String], useful: Array[String]) -> String:
	var weighted: Array[Dictionary] = []
	var total_weight := 0.0
	for ingredient_id: String in candidates:
		var ingredient: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
		if ingredient.is_empty():
			continue
		var rarity := clampi(int(ingredient.get("rarity", 1)), 1, 5)
		var weight := float(DEFAULT_RARITY_WEIGHTS.get(rarity, 1.0))
		var need_units := _missing_unlock_units(ingredient_id)
		if useful.has(ingredient_id):
			weight *= 2.1 + minf(float(need_units) * 0.45, 2.25)
		if not bool(GameState.album_discovered.get(ingredient_id, false)):
			weight *= 1.12
		total_weight += weight
		weighted.append({"id": ingredient_id, "limit": total_weight})
	if weighted.is_empty() or total_weight <= 0.0:
		return ""
	var roll := _reward_rng.randf_range(0.0, total_weight)
	for entry: Dictionary in weighted:
		if roll <= float(entry.limit):
			return String(entry.id)
	return String(weighted.back().id)


func _missing_unlock_units(ingredient_id: String) -> int:
	var result := 0
	var owned := int(GameState.album_inventory.get(ingredient_id, 0))
	for recipe: Dictionary in DataRegistry.recipes:
		var recipe_id := String(recipe.id)
		if bool(GameState.menu.get(recipe_id, {}).get("unlocked", false)):
			continue
		if not bool(recipe.get("discovered", true)):
			continue
		var required := int(recipe.get("unlock_cost", {}).get(ingredient_id, 0))
		result += maxi(required - owned, 0)
	return result


func _set_review_reward_progress(value: int) -> void:
	var sanitized := maxi(value, 0)
	if int(GameState.review_reward_progress) == sanitized:
		return
	GameState.review_reward_progress = sanitized
	GameState.review_reward_progress_changed.emit(sanitized)
	GameState.mark_save_dirty()


func _set_pity_progress(value: int) -> void:
	var sanitized := maxi(value, 0)
	_pity_progress = sanitized
	if int(GameState.progress.get("album_reward_pity", 0)) == sanitized:
		return
	GameState.progress["album_reward_pity"] = sanitized
	GameState.mark_save_dirty()


func _sync_pity_from_state() -> void:
	_pity_progress = maxi(int(GameState.progress.get("album_reward_pity", _pity_progress)), 0)


func _restore_album_amounts(previous_amounts: Dictionary) -> void:
	for ingredient_id: String in previous_amounts:
		GameState.set_album_ingredient_amount(ingredient_id, int(previous_amounts[ingredient_id]))


func _fail_unlock(recipe_id: String, reason: String) -> bool:
	recipe_unlock_failed.emit(recipe_id, reason)
	return false


func _balance(path: String, fallback: Variant) -> Variant:
	if DataRegistry.has_method("balance_value"):
		return DataRegistry.balance_value(path, fallback)
	return fallback
