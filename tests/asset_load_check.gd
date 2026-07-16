extends Node


func _ready() -> void:
	SaveManager.writes_enabled = false
	var paths: Dictionary = {}
	for ingredient: Dictionary in DataRegistry.ingredients:
		paths[String(ingredient.model)] = true
	for preparation: Dictionary in DataRegistry.preparations:
		paths[String(preparation.model)] = true
	for recipe: Dictionary in DataRegistry.recipes:
		paths[String(recipe.dish_model)] = true
		for step: Dictionary in recipe.steps:
			var step_model := String(step.get("model", ""))
			if not step_model.is_empty():
				paths[step_model] = true
	for station: Dictionary in DataRegistry.stations:
		paths[String(station.model)] = true
	for item: Dictionary in DataRegistry.build_catalog:
		paths[String(item.model)] = true
		var embedded_model := String(item.get("embedded_model", ""))
		if not embedded_model.is_empty():
			paths[embedded_model] = true
	for collection: String in ["hired", "candidates"]:
		for employee: Dictionary in DataRegistry.employee_data.get(collection, []):
			paths["res://assets/characters/%s.gltf" % employee.appearance] = true
	for appearance: String in CustomerAgent.CUSTOMER_APPEARANCES:
		paths["res://assets/characters/%s.gltf" % appearance] = true
	var failures: Array[String] = []
	var report := FileAccess.open("res://tests/asset-load-result.txt", FileAccess.WRITE)
	for path: String in paths:
		var exists := ResourceLoader.exists(path)
		var resource := load(path) if exists else null
		var valid := resource is PackedScene
		report.store_line("%s | exists=%s | packed_scene=%s" % [path, exists, valid])
		if not valid:
			failures.append(path)
	report.store_line("ASSET CHECK: %d unique paths, %d failures" % [paths.size(), failures.size()])
	print("ASSET CHECK: %d unique paths, %d failures" % [paths.size(), failures.size()])
	get_tree().quit(0 if failures.is_empty() else 2)
