extends Node

const INGREDIENT_UNLOCK_RULE_TYPES := [
	"album_purchase",
	"customers_served",
	"desserts_served",
	"services_started",
	"reputation",
	"build_count",
]

signal registry_loaded
signal data_validation_failed(errors: Array)

var gameplay_balance: Dictionary = {}
var gameplay_balance_valid := false
var balance_validation_errors: Array[String] = []
var ingredients: Array = []
var preparations: Array = []
var food_visuals: Array = []
var recipes: Array = []
var stations: Array = []
var suppliers: Array = []
var build_catalog: Array = []
var employee_data: Dictionary = {}

var ingredients_by_id: Dictionary = {}
var preparations_by_id: Dictionary = {}
var food_visuals_by_id: Dictionary = {}
var recipes_by_id: Dictionary = {}
var stations_by_id: Dictionary = {}
var suppliers_by_id: Dictionary = {}
var build_by_id: Dictionary = {}
var _market_preparation_ids: Array[String] = []


func _ready() -> void:
	gameplay_balance = _load_json_dictionary("res://data/gameplay_balance.json")
	ingredients = _load_json_array("res://data/ingredients.json")
	preparations = _load_json_array("res://data/preparations.json")
	food_visuals = _load_json_array("res://data/food_visuals.json")
	recipes = _load_json_array("res://data/recipes.json")
	stations = _load_json_array("res://data/stations.json")
	suppliers = _load_json_array("res://data/suppliers.json")
	build_catalog = _load_json_array("res://data/build_catalog.json")
	employee_data = _load_json_dictionary("res://data/employees.json")
	ingredients_by_id = _index(ingredients)
	preparations_by_id = _index(preparations)
	food_visuals_by_id = _index(food_visuals)
	recipes_by_id = _index(recipes)
	stations_by_id = _index(stations)
	suppliers_by_id = _index(suppliers)
	build_by_id = _index(build_catalog)
	_market_preparation_ids = _derive_market_preparation_ids()
	gameplay_balance_valid = _validate_gameplay_balance()
	if not gameplay_balance_valid:
		data_validation_failed.emit(balance_validation_errors.duplicate())
	registry_loaded.emit()


func _load_json_array(path: String) -> Array:
	var value: Variant = _load_json(path)
	if value is Array:
		return value
	push_error("Data file must contain an array: %s" % path)
	return []


func _load_json_dictionary(path: String) -> Dictionary:
	var value: Variant = _load_json(path)
	if value is Dictionary:
		return value
	push_error("Data file must contain an object: %s" % path)
	return {}


func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("Missing data file: %s" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		push_error("Invalid JSON data: %s" % path)
	return parsed


func _index(items: Array) -> Dictionary:
	var result: Dictionary = {}
	for item: Dictionary in items:
		result[String(item.get("id", ""))] = item
	return result


func active_recipes(menu_state: Dictionary) -> Array:
	var result: Array = []
	for recipe: Dictionary in recipes:
		var state: Dictionary = menu_state.get(recipe.id, {})
		if bool(state.get("unlocked", recipe.get("unlocked", false))) and bool(state.get("active", recipe.get("active", false))):
			result.append(recipe)
	return result


func estimate_recipe_cost(recipe: Dictionary) -> float:
	var result := 0.0
	for step: Dictionary in recipe.get("steps", []):
		for ingredient_id: String in step.get("inputs", {}):
			var ingredient: Dictionary = ingredients_by_id.get(ingredient_id, {})
			result += float(ingredient.get("cost", 0.0)) * float(step.inputs[ingredient_id])
	return result


func required_station_ids(recipe: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for step: Dictionary in recipe.get("steps", []):
		var station_id := String(step.get("station", ""))
		if not result.has(station_id):
			result.append(station_id)
	return result


func balance_value(path: String, fallback: Variant = null) -> Variant:
	var current: Variant = gameplay_balance
	for key: String in path.split("."):
		if not current is Dictionary or not (current as Dictionary).has(key):
			return fallback
		current = (current as Dictionary)[key]
	return current


func balance_section(section_id: String) -> Dictionary:
	var value: Variant = balance_value(section_id, {})
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


func album_starter_inventory() -> Dictionary:
	var configured: Variant = balance_value("album.starter_inventory", {})
	var result: Dictionary = {}
	if not configured is Dictionary:
		return result
	for ingredient_id: String in configured:
		if ingredients_by_id.has(ingredient_id):
			result[ingredient_id] = maxi(int(configured[ingredient_id]), 0)
	return result


func storage_metadata_for_ingredient(ingredient_or_id: Variant) -> Dictionary:
	var ingredient: Dictionary = {}
	if ingredient_or_id is Dictionary:
		ingredient = ingredient_or_id
	else:
		ingredient = ingredients_by_id.get(String(ingredient_or_id), {})
	var default_type := String(balance_value("storage.default_type", "ambient"))
	var storage_type := String(ingredient.get("storage_type", default_type))
	var allowed: Variant = balance_value("storage.allowed_types", ["ambient", "refrigerated"])
	if not allowed is Array or not (allowed as Array).has(storage_type):
		storage_type = default_type
	return {
		"storage_type": storage_type,
		"storage_units": maxi(int(ingredient.get("storage_units", balance_value("storage.default_units", 1))), 1)
	}


func recipe_raw_requirements(recipe_or_id: Variant) -> Dictionary:
	var recipe: Dictionary = {}
	if recipe_or_id is Dictionary:
		recipe = recipe_or_id
	else:
		recipe = recipes_by_id.get(String(recipe_or_id), {})
	var requirements: Dictionary = {}
	for step: Dictionary in recipe.get("steps", []):
		for ingredient_id: String in step.get("inputs", {}):
			requirements[ingredient_id] = int(requirements.get(ingredient_id, 0)) + maxi(int(step.inputs[ingredient_id]), 0)
	return requirements


func ingredient_unlock_rule(ingredient_or_id: Variant) -> Dictionary:
	var ingredient: Dictionary = ingredient_or_id if ingredient_or_id is Dictionary else ingredients_by_id.get(String(ingredient_or_id), {})
	var rule: Variant = ingredient.get("unlock_rule", {})
	return (rule as Dictionary).duplicate(true) if rule is Dictionary else {}


func ingredient_unlock_requirements(recipe_or_id: Variant) -> Array[String]:
	var recipe: Dictionary = recipe_or_id if recipe_or_id is Dictionary else recipes_by_id.get(String(recipe_or_id), {})
	var result: Array[String] = []
	var configured: Variant = recipe.get("ingredient_unlock_requirements", [])
	if not configured is Array:
		return result
	for ingredient_id: Variant in configured:
		var normalized := String(ingredient_id)
		if not normalized.is_empty() and not result.has(normalized):
			result.append(normalized)
	return result


func market_preparation_ids() -> Array[String]:
	return _market_preparation_ids.duplicate()


func is_market_preparation(preparation_id: String) -> bool:
	return _market_preparation_ids.has(preparation_id)


func preparation_consumers(preparation_id: String) -> Array[String]:
	var result: Array[String] = []
	for recipe: Dictionary in recipes:
		for step: Dictionary in recipe.get("steps", []):
			if bool(step.get("preppable", false)) and String(step.get("output", "")) == preparation_id:
				result.append(String(recipe.get("id", "")))
				break
	return result


func sanitize_purchased_preparations(inventory: Variant, refund_legacy: bool = false) -> Dictionary:
	var source: Dictionary = inventory if inventory is Dictionary else {}
	var kept: Dictionary = {}
	var removed: Dictionary = {}
	var refund := 0
	for preparation_id: String in source:
		var amount := maxi(int(source[preparation_id]), 0)
		if amount <= 0:
			continue
		if is_market_preparation(preparation_id):
			kept[preparation_id] = amount
			continue
		removed[preparation_id] = amount
		if refund_legacy:
			var definition: Dictionary = preparations_by_id.get(preparation_id, {})
			refund += int(ceil(float(definition.get("market_price", 0.0)) * amount))
	return {"kept": kept, "removed": removed, "refund": refund}


func _derive_market_preparation_ids() -> Array[String]:
	var result: Array[String] = []
	for recipe: Dictionary in recipes:
		for step: Dictionary in recipe.get("steps", []):
			if not bool(step.get("preppable", false)):
				continue
			var output_id := String(step.get("output", ""))
			if preparations_by_id.has(output_id) and not result.has(output_id):
				result.append(output_id)
	result.sort()
	return result


func _validate_gameplay_balance() -> bool:
	balance_validation_errors.clear()
	_require_balance_number("schema_version", 1.0)
	_require_balance_number("save.autosave_debounce_seconds", 0.05)
	_require_balance_number("day_cycle.real_seconds_at_1x", 1.0)
	_require_balance_number("day_cycle.start_minute", 0.0, 1439.0)
	_require_balance_number("day_cycle.rush_warning_seconds", 0.0)
	_require_balance_number("traffic.base_spawn_interval", 0.1)
	_require_balance_number("traffic.reputation_multiplier_min", 0.01)
	_require_balance_number("traffic.reputation_multiplier_max", 0.01)
	_require_balance_number("traffic.night_multiplier", 0.0)
	_require_balance_number("traffic.queue_buffer_groups", 0.0)
	_require_balance_number("traffic.absolute_group_cap", 1.0)
	_require_balance_number("delivery.batch_interval_seconds", 1.0)
	_require_balance_number("delivery.urgent_delivery_seconds", 1.0)
	_require_balance_number("reviews.history_limit", 1.0)
	_require_balance_number("reviews.reputation_ema_alpha", 0.0001, 1.0)
	_require_balance_number("reviews.positive_reviews_for_album_reward", 1.0)
	_require_balance_number("cleanliness.dirty_threshold", 0.0, 100.0)
	_require_balance_number("cleanliness.very_dirty_threshold", 0.0, 100.0)
	_require_balance_number("cleanliness.pest_threshold", 0.0, 100.0)
	_require_balance_number("cleanliness.pest_delay_seconds", 0.0)
	_require_balance_number("album.reward_quantity_min", 1.0)
	_require_balance_number("album.reward_quantity_max", 1.0)
	_require_balance_number("album.pity_interval", 1.0)
	_require_balance_number("album.positive_reviews_per_reward", 1.0)
	_require_balance_number("album.five_star_gift_chance", 0.0, 1.0)
	_require_balance_number("album.reputation_threshold_reward", 0.0)
	_require_balance_number("album.day_completion_reward", 0.0)
	if float(balance_value("traffic.reputation_multiplier_min", 0.0)) > float(balance_value("traffic.reputation_multiplier_max", 0.0)):
		balance_validation_errors.append("traffic reputation multiplier min cannot exceed max")
	if (
		float(balance_value("cleanliness.pest_threshold", 0.0)) > float(balance_value("cleanliness.very_dirty_threshold", 0.0))
		or float(balance_value("cleanliness.very_dirty_threshold", 0.0)) > float(balance_value("cleanliness.dirty_threshold", 0.0))
	):
		balance_validation_errors.append("cleanliness thresholds must be ordered pest <= very_dirty <= dirty")
	if int(balance_value("album.reward_quantity_min", 1)) > int(balance_value("album.reward_quantity_max", 1)):
		balance_validation_errors.append("album reward quantity min cannot exceed max")
	var rush_windows: Variant = balance_value("day_cycle.rush_windows", null)
	if not rush_windows is Array or (rush_windows as Array).is_empty():
		balance_validation_errors.append("day_cycle.rush_windows must be a non-empty array")
	else:
		for index: int in (rush_windows as Array).size():
			var window: Variant = (rush_windows as Array)[index]
			if not window is Dictionary:
				balance_validation_errors.append("day_cycle.rush_windows[%d] must be an object" % index)
				continue
			for field: String in ["start", "end", "traffic_multiplier"]:
				if not (window as Dictionary).has(field) or not ((window as Dictionary)[field] is int or (window as Dictionary)[field] is float):
					balance_validation_errors.append("day_cycle.rush_windows[%d].%s must be numeric" % [index, field])
			var start := float((window as Dictionary).get("start", 0.0))
			var end := float((window as Dictionary).get("end", 0.0))
			if start < 0.0 or end > 1440.0:
				balance_validation_errors.append("day_cycle.rush_windows[%d] must stay inside the day" % index)
			if start >= end:
				balance_validation_errors.append("day_cycle.rush_windows[%d] must end after it starts" % index)
			if float((window as Dictionary).get("traffic_multiplier", 0.0)) <= 0.0:
				balance_validation_errors.append("day_cycle.rush_windows[%d].traffic_multiplier must be positive" % index)
	var allowed_types: Variant = balance_value("storage.allowed_types", null)
	if not allowed_types is Array or not (allowed_types as Array).has("ambient") or not (allowed_types as Array).has("refrigerated"):
		balance_validation_errors.append("storage.allowed_types must include ambient and refrigerated")
	for ingredient: Dictionary in ingredients:
		var metadata := storage_metadata_for_ingredient(ingredient)
		if int(metadata.storage_units) <= 0:
			balance_validation_errors.append("ingredient %s has invalid storage_units" % ingredient.get("id", ""))
		if not bool(ingredient.get("unlocked", false)):
			_validate_ingredient_unlock_rule(ingredient)
	for recipe: Dictionary in recipes:
		var configured_requirements: Variant = recipe.get("ingredient_unlock_requirements", [])
		if not configured_requirements is Array:
			balance_validation_errors.append("recipe %s ingredient_unlock_requirements must be an array" % recipe.get("id", ""))
			continue
		for ingredient_id: Variant in configured_requirements:
			if not ingredients_by_id.has(String(ingredient_id)):
				balance_validation_errors.append("recipe %s requires unknown ingredient unlock %s" % [recipe.get("id", ""), ingredient_id])
	for preparation_id: String in _market_preparation_ids:
		var preparation: Dictionary = preparations_by_id.get(preparation_id, {})
		if float(preparation.get("market_price", 0.0)) <= 0.0:
			balance_validation_errors.append("market preparation %s needs a positive market_price" % preparation_id)
		if preparation_consumers(preparation_id).is_empty():
			balance_validation_errors.append("market preparation %s is not consumed by a preppable step" % preparation_id)
	var starter: Variant = balance_value("album.starter_inventory", {})
	if not starter is Dictionary:
		balance_validation_errors.append("album.starter_inventory must be an object")
	else:
		for ingredient_id: String in starter:
			if not ingredients_by_id.has(ingredient_id):
				balance_validation_errors.append("album starter references unknown ingredient %s" % ingredient_id)
			elif int(starter[ingredient_id]) < 0:
				balance_validation_errors.append("album starter amount cannot be negative for %s" % ingredient_id)
	for error: String in balance_validation_errors:
		push_error("Gameplay balance validation: %s" % error)
	return balance_validation_errors.is_empty()


func _validate_ingredient_unlock_rule(ingredient: Dictionary) -> void:
	var ingredient_id := String(ingredient.get("id", ""))
	var rule := ingredient_unlock_rule(ingredient)
	var rule_type := String(rule.get("type", ""))
	if rule_type.is_empty() or not INGREDIENT_UNLOCK_RULE_TYPES.has(rule_type):
		balance_validation_errors.append("ingredient %s has an invalid unlock_rule type" % ingredient_id)
		return
	if rule_type == "album_purchase":
		if int(rule.get("cost", 0)) <= 0:
			balance_validation_errors.append("ingredient %s album_purchase needs a positive cost" % ingredient_id)
		return
	if int(rule.get("value", 0)) <= 0:
		balance_validation_errors.append("ingredient %s unlock_rule needs a positive value" % ingredient_id)
	if rule_type == "build_count" and not build_by_id.has(String(rule.get("item", ""))):
		balance_validation_errors.append("ingredient %s build_count references an unknown item" % ingredient_id)


func _require_balance_number(path: String, minimum: float, maximum: float = INF) -> void:
	var value: Variant = balance_value(path, null)
	if not (value is int or value is float):
		balance_validation_errors.append("%s must be numeric" % path)
		return
	var numeric := float(value)
	if numeric < minimum or numeric > maximum:
		balance_validation_errors.append("%s must be in %.3f..%.3f" % [path, minimum, maximum])
