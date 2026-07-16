class_name FoodVisualFactory
extends RefCounted

## Central resolver for every edible visual. Recipe steps, carried food,
## workstation feedback and table dishes all use the same descriptors, so a
## semilavorato cannot silently turn into a placeholder between two systems.


static func parts_for_id(food_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var visual: Dictionary = DataRegistry.food_visuals_by_id.get(food_id, {})
	if not visual.is_empty():
		for value: Variant in visual.get("models", []):
			var part := _normalized_part(value, 0.42)
			if not part.is_empty():
				result.append(part)
		return result
	var preparation: Dictionary = DataRegistry.preparations_by_id.get(food_id, {})
	var preparation_model := String(preparation.get("model", ""))
	if not preparation_model.is_empty():
		result.append({"model": preparation_model, "scale": 0.40, "role": "food"})
		return result
	var ingredient: Dictionary = DataRegistry.ingredients_by_id.get(food_id, {})
	var ingredient_model := String(ingredient.get("model", ""))
	if not ingredient_model.is_empty():
		result.append({"model": ingredient_model, "scale": 0.36, "role": "food"})
		return result
	var recipe: Dictionary = DataRegistry.recipes_by_id.get(food_id, {})
	var dish_model := String(recipe.get("dish_model", ""))
	if not dish_model.is_empty():
		result.append({"model": dish_model, "scale": 0.50, "role": "food"})
	return result


static func parts_for_task(task: Dictionary, phase: String) -> Array[Dictionary]:
	if task.is_empty():
		return []
	var visual: Dictionary = task.get("visual", {})
	var explicit_key := "%s_models" % phase
	if visual.has(explicit_key):
		return _normalize_parts(visual.get(explicit_key, []), 0.40)
	match phase:
		"input":
			return _input_parts(task)
		"process":
			var process_id := String(visual.get("process_id", ""))
			if not process_id.is_empty():
				return parts_for_id(process_id)
			return _process_parts(task)
		_:
			var result := parts_for_id(String(task.get("output", "")))
			if result.is_empty():
				var model_path := String(task.get("model", ""))
				if not model_path.is_empty():
					result.append({"model": model_path, "scale": 0.50, "role": "food"})
			return result


static func instantiate_parts(parts: Array, scale_multiplier: float = 1.0, maximum_override: int = -1) -> Node3D:
	var root := Node3D.new()
	root.name = "FoodVisual"
	var maximum := maximum_override
	if maximum < 0:
		maximum = 6 if WebPlatformProfile.low_memory_mode() else 10
	var created := 0
	for part_index: int in parts.size():
		if created >= maximum:
			break
		var part := _normalized_part(parts[part_index], 0.40)
		if part.is_empty():
			continue
		var model_path := String(part.get("model", ""))
		var primitive := String(part.get("primitive", ""))
		if primitive.is_empty() and (model_path.is_empty() or not ResourceLoader.exists(model_path)):
			continue
		var quantity := clampi(int(part.get("quantity", 1)), 1, 4)
		for copy_index: int in quantity:
			if created >= maximum:
				break
			var holder := Node3D.new()
			holder.name = "FoodPart_%02d" % created
			var scale_factor := float(part.get("scale", 0.40)) * scale_multiplier
			var model := _instantiate_part_visual(part, scale_factor)
			ModelFactory.set_shadow_casting(model, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
			holder.add_child(model)
			var offset := _vector3(part.get("offset", []), Vector3.ZERO)
			if not part.has("offset"):
				var angle := float(part_index) * TAU / maxf(float(parts.size()), 1.0)
				var layout_radius := 0.0 if parts.size() <= 1 else 0.16 + maxf(float(parts.size() - 2), 0.0) * 0.03
				offset = Vector3(cos(angle), 0.0, sin(angle)) * layout_radius
			if quantity > 1:
				var spacing := float(part.get("spacing", 0.13))
				var column := copy_index % 2
				var row := copy_index / 2
				offset += Vector3((float(column) - 0.5) * spacing, 0.006 * copy_index, (float(row) - 0.5) * spacing)
			holder.position = offset
			holder.rotation = _vector3(part.get("rotation", []), Vector3.ZERO)
			holder.set_meta("base_position", holder.position)
			holder.set_meta("base_rotation", holder.rotation)
			holder.set_meta("visual_role", String(part.get("role", "food")))
			holder.set_meta("source_model", model_path)
			root.add_child(holder)
			created += 1
	return root


static func instantiate_food(food_id: String, scale_multiplier: float = 1.0) -> Node3D:
	return instantiate_parts(parts_for_id(food_id), scale_multiplier)


static func instantiate_recipe_dish(recipe_id: String, scale_multiplier: float = 1.0) -> Node3D:
	var recipe: Dictionary = DataRegistry.recipes_by_id.get(recipe_id, {})
	var explicit: Array = recipe.get("dish_visual", [])
	if not explicit.is_empty():
		return instantiate_parts(explicit, scale_multiplier)
	var parts := parts_for_id(recipe_id)
	if parts.is_empty():
		var model_path := String(recipe.get("dish_model", ""))
		if not model_path.is_empty():
			parts.append({"model": model_path, "scale": 0.50, "role": "food"})
	return instantiate_parts(parts, scale_multiplier)


static func instantiate_recipe_serving_food(recipe_id: String) -> Node3D:
	var visual: Dictionary = DataRegistry.food_visuals_by_id.get(recipe_id, {})
	var serving_parts := _normalize_parts(visual.get("serving_models", []), 0.40)
	if serving_parts.is_empty():
		return instantiate_recipe_dish(recipe_id, 1.0)
	return instantiate_parts(serving_parts, 1.0)


static func consumption_container(recipe_id: String) -> String:
	var visual: Dictionary = DataRegistry.food_visuals_by_id.get(recipe_id, {})
	return String(visual.get("consumption_container", "plate"))


static func consumption_parts(recipe_id: String, stage: int) -> Array[Dictionary]:
	var visual: Dictionary = DataRegistry.food_visuals_by_id.get(recipe_id, {})
	var key := "partial_models" if stage <= 1 else "leftover_models"
	return _normalize_parts(visual.get(key, []), 0.32)


static func support_visible_with_full_dish(recipe_id: String) -> bool:
	var visual: Dictionary = DataRegistry.food_visuals_by_id.get(recipe_id, {})
	return bool(visual.get("support_visible_full", false))


static func primary_output_model(task: Dictionary) -> String:
	for part: Dictionary in parts_for_task(task, "output"):
		var path := String(part.get("model", ""))
		if not path.is_empty() and ResourceLoader.exists(path):
			return path
	return ""


static func task_style(task: Dictionary, fallback_station: String = "") -> String:
	var visual: Dictionary = task.get("visual", {})
	var explicit := String(visual.get("style", ""))
	if not explicit.is_empty():
		return explicit
	var station := String(task.get("station", fallback_station))
	var step := String(task.get("recipe_step_id", "")).to_lower()
	if station == "cutting_board" or step in ["cut", "chop", "grate", "veg", "side", "toppings"]:
		return "chop"
	if station == "dough":
		return "knead"
	if station in ["stove", "multi_stove"]:
		return "cook"
	if station in ["oven", "pizza_oven"]:
		return "bake"
	if station == "dessert":
		return "scoop"
	if station == "pass":
		return "plate"
	return "assemble"


static func task_tool_model(task: Dictionary) -> String:
	var visual: Dictionary = task.get("visual", {})
	var explicit := String(visual.get("tool_model", ""))
	if not explicit.is_empty():
		return explicit
	match task_style(task):
		"chop", "slice", "grate": return "res://assets/equipment/tool_knife_chopping.glb"
		"knead", "mix", "sauce", "toss": return "res://assets/equipment/tool_whisk.glb"
		"cook", "sear", "fry": return "res://assets/equipment/tool_spatula.glb"
		"simmer": return "res://assets/equipment/tool_cooking_spoon.glb"
		"scoop": return "res://assets/equipment/utensil_spoon.glb"
	return ""


static func all_declared_model_paths() -> Array[String]:
	var result: Array[String] = []
	for visual: Dictionary in DataRegistry.food_visuals:
		for key: String in ["models", "serving_models", "partial_models", "leftover_models"]:
			for part: Dictionary in _normalize_parts(visual.get(key, []), 0.4):
				var path := String(part.get("model", ""))
				if not path.is_empty() and not result.has(path):
					result.append(path)
	return result


static func _input_parts(task: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for ingredient_id: String in task.get("inputs", {}):
		var ingredient_parts := parts_for_id(ingredient_id)
		var amount := clampi(int(task.inputs[ingredient_id]), 1, 3)
		for part: Dictionary in ingredient_parts:
			var copy := part.duplicate(true)
			copy.quantity = amount
			result.append(copy)
	# Direct ingredients and dependency outputs can coexist (for example the
	# vegetable burger), so dependencies are never hidden by a non-empty input.
	for dependency_id: String in task.get("dependencies", []):
		var dependency: Dictionary = SimulationManager.tasks.get(dependency_id, {})
		for part: Dictionary in parts_for_task(dependency, "output"):
			result.append(part.duplicate(true))
	return result


static func _process_parts(task: Dictionary) -> Array[Dictionary]:
	var input := _input_parts(task)
	var result: Array[Dictionary] = []
	var visual: Dictionary = task.get("visual", {})
	var container_model := String(visual.get("container_model", ""))
	if container_model.is_empty():
		match task_style(task):
			"cook", "sear", "fry", "roast": container_model = "res://assets/equipment/pan_A.gltf"
			"simmer": container_model = "res://assets/equipment/pot_A_stew.gltf"
			"sauce", "mix", "toss": container_model = "res://assets/equipment/bowl.gltf"
			"plate": container_model = "res://assets/equipment/plate.gltf"
	if not container_model.is_empty():
		result.append({"model": container_model, "scale": 0.58, "role": "container", "offset": [0.0, 0.0, 0.0]})
	for part: Dictionary in input:
		var copy := part.duplicate(true)
		copy.scale = float(copy.get("scale", 0.4)) * (0.72 if not container_model.is_empty() else 0.88)
		var offset := _vector3(copy.get("offset", []), Vector3.ZERO)
		if not container_model.is_empty():
			offset.y += 0.12
		copy.offset = [offset.x, offset.y, offset.z]
		result.append(copy)
	return result


static func _normalize_parts(values: Array, default_scale: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value: Variant in values:
		var part := _normalized_part(value, default_scale)
		if not part.is_empty():
			result.append(part)
	return result


static func _normalized_part(value: Variant, default_scale: float) -> Dictionary:
	var result: Dictionary = {}
	if value is String:
		result = {"model": String(value)}
	elif value is Dictionary:
		result = (value as Dictionary).duplicate(true)
	var path := String(result.get("model", ""))
	if path.is_empty() and String(result.get("primitive", "")).is_empty():
		return {}
	result.scale = float(result.get("scale", default_scale))
	result.role = String(result.get("role", "food"))
	return result


static func _instantiate_part_visual(part: Dictionary, scale_factor: float) -> Node3D:
	var model_path := String(part.get("model", ""))
	if not model_path.is_empty():
		var model := ModelFactory.instantiate_model(model_path, scale_factor)
		ModelFactory.align_visual_to_grid_origin(model)
		return model
	var mesh_instance := MeshInstance3D.new()
	match String(part.get("primitive", "sphere")):
		"disc":
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = 0.5
			cylinder.bottom_radius = 0.5
			cylinder.height = 0.08
			cylinder.radial_segments = 16
			mesh_instance.mesh = cylinder
		_:
			var sphere := SphereMesh.new()
			sphere.radius = 0.5
			sphere.height = 1.0
			sphere.radial_segments = 12
			sphere.rings = 6
			mesh_instance.mesh = sphere
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_string(String(part.get("color", "#f4d58a")), Color.WHITE)
	material.roughness = 0.78
	mesh_instance.material_override = material
	mesh_instance.scale = Vector3.ONE * scale_factor
	return mesh_instance


static func _vector3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback
