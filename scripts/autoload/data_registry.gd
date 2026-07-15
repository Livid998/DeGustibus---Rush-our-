extends Node

signal registry_loaded

var ingredients: Array = []
var preparations: Array = []
var recipes: Array = []
var stations: Array = []
var suppliers: Array = []
var build_catalog: Array = []
var employee_data: Dictionary = {}

var ingredients_by_id: Dictionary = {}
var preparations_by_id: Dictionary = {}
var recipes_by_id: Dictionary = {}
var stations_by_id: Dictionary = {}
var suppliers_by_id: Dictionary = {}
var build_by_id: Dictionary = {}


func _ready() -> void:
	ingredients = _load_json_array("res://data/ingredients.json")
	preparations = _load_json_array("res://data/preparations.json")
	recipes = _load_json_array("res://data/recipes.json")
	stations = _load_json_array("res://data/stations.json")
	suppliers = _load_json_array("res://data/suppliers.json")
	build_catalog = _load_json_array("res://data/build_catalog.json")
	employee_data = _load_json_dictionary("res://data/employees.json")
	ingredients_by_id = _index(ingredients)
	preparations_by_id = _index(preparations)
	recipes_by_id = _index(recipes)
	stations_by_id = _index(stations)
	suppliers_by_id = _index(suppliers)
	build_by_id = _index(build_catalog)
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

