extends Node


func _ready() -> void:
	await get_tree().process_frame
	var paths := [
		"res://assets/food/food_pizza_cheese_plated.gltf",
		"res://assets/food/food_burger.gltf",
		"res://assets/food/food_cheeseburger.glb",
		"res://assets/food/food_vegetableburger.gltf",
		"res://assets/food/food_mixed_salad.glb",
		"res://assets/food/food_stew.gltf",
		"res://assets/food/food_dinner.gltf",
		"res://assets/food/icecream_bowl_decorated_A.gltf",
		"res://assets/food/food_ingredient_potato_chopped.gltf",
		"res://assets/equipment/plate.gltf"
	]
	for path: String in paths:
		var model := ModelFactory.instantiate_model(path)
		add_child(model)
		ModelFactory.align_visual_to_grid_origin(model)
		var bounds := ModelFactory.calculate_visual_bounds(model, true)
		print("FOOD_BOUNDS | %s | size=(%.3f, %.3f, %.3f)" % [path.get_file(), bounds.size.x, bounds.size.y, bounds.size.z])
		model.queue_free()
	get_tree().quit()
