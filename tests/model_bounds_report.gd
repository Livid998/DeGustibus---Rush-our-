extends Node


func _ready() -> void:
	await get_tree().process_frame
	for definition: Dictionary in DataRegistry.build_catalog:
		var model := ModelFactory.instantiate_model(String(definition.model))
		var raw_scale: Array = definition.get("model_scale", [1.0, 1.0, 1.0])
		model.scale = Vector3(float(raw_scale[0]), float(raw_scale[1]), float(raw_scale[2]))
		add_child(model)
		var bounds := ModelFactory.calculate_visual_bounds(model, true)
		var raw_footprint: Array = definition.get("footprint", [1, 1])
		var expected := Vector2(float(raw_footprint[0]) * RestaurantWorld.CELL_SIZE, float(raw_footprint[1]) * RestaurantWorld.CELL_SIZE)
		print("BOUNDS | %s | min=(%.3f, %.3f, %.3f) | max=(%.3f, %.3f, %.3f) | center=(%.3f, %.3f, %.3f) | size=(%.3f, %.3f, %.3f) | footprint=(%.1f, %.1f)" % [
			String(definition.id),
			bounds.position.x, bounds.position.y, bounds.position.z,
			bounds.end.x, bounds.end.y, bounds.end.z,
			bounds.get_center().x, bounds.get_center().y, bounds.get_center().z,
			bounds.size.x, bounds.size.y, bounds.size.z,
			expected.x, expected.y
		])
		model.queue_free()
	get_tree().quit()
