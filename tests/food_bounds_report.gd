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
		"res://assets/equipment/plate.gltf",
		"res://assets/equipment/plate_dirty.gltf",
		"res://assets/equipment/bowl.gltf",
		"res://assets/equipment/bowl_dirty.gltf",
		"res://assets/equipment/utensil_fork.glb",
		"res://assets/equipment/utensil_spoon.glb",
		"res://assets/equipment/tool_knife_chopping.glb",
		"res://assets/equipment/tool_whisk.glb",
		"res://assets/equipment/tool_spatula.glb",
		"res://assets/equipment/tool_cooking_spoon.glb"
	]
	for path: String in paths:
		var model := ModelFactory.instantiate_model(path)
		add_child(model)
		var raw_bounds := ModelFactory.calculate_visual_bounds(model, true)
		ModelFactory.align_visual_to_grid_origin(model)
		var bounds := ModelFactory.calculate_visual_bounds(model, true)
		print("FOOD_BOUNDS | %s | raw_pos=(%.3f, %.3f, %.3f) size=(%.3f, %.3f, %.3f)" % [path.get_file(), raw_bounds.position.x, raw_bounds.position.y, raw_bounds.position.z, bounds.size.x, bounds.size.y, bounds.size.z])
		model.queue_free()
	get_tree().quit()
