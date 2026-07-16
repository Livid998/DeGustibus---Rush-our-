class_name PlacedObject
extends Node3D

var uid: String
var item_id: String
var station_id: String = ""
var grid_cell: Vector2i
var footprint: Vector2i = Vector2i.ONE
var rotation_steps: int = 0
var support_uid: String = ""
var attachment_slot: int = -1
var definition: Dictionary = {}
var current_task: Dictionary = {}
var visual_model: Node3D

var _status_label: Label3D
var _food_anchor: Node3D
var _food_model: Node3D
var _food_models: Array[Node3D] = []
var _steam: GPUParticles3D
var _last_progress_percent := -1
var _task_progress_ratio := 0.0
var _task_motion_time := 0.0
var _task_visual_phase := ""
var _task_visual_style := "assemble"
var _task_output_model_path := ""


func _process(delta: float) -> void:
	if current_task.is_empty() or _food_models.is_empty():
		return
	_task_motion_time += delta * SimulationManager.simulation_speed
	_animate_task_food()


func setup(value_uid: String, item: Dictionary, cell: Vector2i, rotation_value: int, value_support_uid: String = "", value_attachment_slot: int = -1) -> void:
	uid = value_uid
	item_id = String(item.id)
	definition = item
	set_layout_state(cell, rotation_value, value_support_uid, value_attachment_slot)
	station_id = String(item.get("station", ""))
	visual_model = ModelFactory.instantiate_build_visual(item)
	visual_model.name = "VisualModel"
	ModelFactory.align_visual_to_grid_origin(visual_model)
	add_child(visual_model)
	_create_invisible_collision()
	if not station_id.is_empty():
		_create_station_feedback()
	if station_id in ["stove", "multi_stove", "oven", "pizza_oven"]:
		_create_heat_particles()


func set_layout_state(cell: Vector2i, rotation_value: int, value_support_uid: String = "", value_attachment_slot: int = -1) -> void:
	grid_cell = cell
	rotation_steps = posmod(rotation_value, 4)
	support_uid = value_support_uid
	attachment_slot = value_attachment_slot
	var raw_footprint: Array = definition.get("footprint", [1, 1])
	footprint = Vector2i(int(raw_footprint[0]), int(raw_footprint[1]))
	if rotation_steps % 2 == 1:
		footprint = Vector2i(footprint.y, footprint.x)
	rotation.y = -rotation_steps * PI * 0.5


func register_station() -> void:
	if station_id.is_empty():
		return
	var station: Dictionary = DataRegistry.stations_by_id.get(station_id, {})
	SimulationManager.register_station(station_id, self, int(station.get("capacity", 1)))


func get_interaction_position() -> Vector3:
	if get_parent() != null and get_parent().get_parent() is RestaurantWorld:
		return (get_parent().get_parent() as RestaurantWorld).station_interaction_position(self)
	var local_offset := Vector3(0.0, 0.0, (float(footprint.y) * 0.5 + 0.65) * RestaurantWorld.CELL_SIZE)
	return global_transform * local_offset


func get_interaction_positions() -> Array[Vector3]:
	var result: Array[Vector3] = []
	if get_parent() != null and get_parent().get_parent() is RestaurantWorld:
		var restaurant_world := get_parent().get_parent() as RestaurantWorld
		for cell: Vector2i in restaurant_world.station_access_cells(definition, grid_cell, rotation_steps, support_uid, attachment_slot):
			if restaurant_world.astar.is_in_boundsv(cell) and not restaurant_world.astar.is_point_solid(cell) and not restaurant_world._grid_path(restaurant_world.entrance_cell, cell).is_empty():
				var position := restaurant_world.cell_to_world(cell)
				if not result.has(position):
					result.append(position)
	if result.is_empty():
		result.append(get_interaction_position())
	return result


func show_task(task: Dictionary) -> void:
	current_task = task
	_last_progress_percent = 0
	_task_progress_ratio = 0.0
	_task_motion_time = 0.0
	_task_visual_style = _visual_style_for_task(task)
	_task_output_model_path = _output_model_path(task)
	_task_visual_phase = "input"
	_status_label.visible = true
	_status_label.text = "%s  0%%" % task.recipe_step_id.capitalize()
	var input_paths := _input_model_paths(task)
	if input_paths.is_empty() and not _task_output_model_path.is_empty():
		input_paths.append(_task_output_model_path)
		_task_visual_phase = "output"
	_set_food_models(input_paths)
	if _steam:
		_steam.emitting = true


func update_task_progress(task: Dictionary) -> void:
	if current_task.is_empty() or current_task.id != task.id:
		show_task(task)
	var percent := int(round((1.0 - float(task.remaining) / maxf(float(task.duration), 0.01)) * 100.0))
	_task_progress_ratio = clampf(float(percent) / 100.0, 0.0, 1.0)
	# Ingredients visibly become the preparation/dish near the end instead of
	# popping into existence only after the invisible simulation has finished.
	var output_threshold := 0.72 if _task_visual_style == "cook" else 0.58
	if _task_visual_phase == "input" and _task_progress_ratio >= output_threshold and not _task_output_model_path.is_empty():
		_task_visual_phase = "output"
		_set_food_models([_task_output_model_path])
	var displayed_percent := clampi((percent / 5) * 5, 0, 100)
	if displayed_percent == _last_progress_percent:
		return
	_last_progress_percent = displayed_percent
	_status_label.text = "%s  %d%%" % [String(task.recipe_step_id).capitalize(), displayed_percent]


func clear_task() -> void:
	# Keep SimulationManager's shared task dictionary intact.
	current_task = {}
	_last_progress_percent = -1
	if _status_label:
		_status_label.visible = false
	_clear_food_models()
	if _steam:
		_steam.emitting = false


func _set_food_models(model_paths: Array) -> void:
	_clear_food_models()
	var maximum := 1 if WebPlatformProfile.low_memory_mode() else 3
	for value: Variant in model_paths:
		if _food_models.size() >= maximum:
			break
		var model_path := String(value)
		if model_path.is_empty() or not ResourceLoader.exists(model_path):
			continue
		# The holder receives the cheap procedural motion while the imported model
		# stays correctly grounded and centred inside it.
		var holder := Node3D.new()
		holder.name = "TaskFood_%d" % _food_models.size()
		var model := ModelFactory.instantiate_model(model_path, 0.58 if _task_visual_phase == "input" else 0.64)
		ModelFactory.align_visual_to_grid_origin(model)
		ModelFactory.set_shadow_casting(model, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		holder.add_child(model)
		_food_anchor.add_child(holder)
		_food_models.append(holder)
	_food_model = _food_models[0] if not _food_models.is_empty() else null
	_animate_task_food()


func _clear_food_models() -> void:
	for model: Node3D in _food_models:
		if is_instance_valid(model):
			model.queue_free()
	_food_models.clear()
	_food_model = null


func _input_model_paths(task: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for ingredient_id: String in task.get("inputs", {}):
		var ingredient: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
		_append_unique_model(result, String(ingredient.get("model", "")))
	# Assembly steps usually have no raw stock of their own. Show the actual
	# semilavorati produced by their dependencies instead.
	if result.is_empty():
		for dependency_id: String in task.get("dependencies", []):
			var dependency: Dictionary = SimulationManager.tasks.get(dependency_id, {})
			var dependency_path := _output_model_path(dependency)
			if not dependency_path.is_empty():
				_append_unique_model(result, dependency_path)
			else:
				for nested_path: String in _direct_input_model_paths(dependency):
					_append_unique_model(result, nested_path)
	return result


func _direct_input_model_paths(task: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for ingredient_id: String in task.get("inputs", {}):
		var ingredient: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
		_append_unique_model(result, String(ingredient.get("model", "")))
	return result


func _output_model_path(task: Dictionary) -> String:
	if task.is_empty():
		return ""
	var explicit := String(task.get("model", ""))
	if not explicit.is_empty() and ResourceLoader.exists(explicit):
		return explicit
	var output_id := String(task.get("output", ""))
	var preparation: Dictionary = DataRegistry.preparations_by_id.get(output_id, {})
	var preparation_model := String(preparation.get("model", ""))
	if not preparation_model.is_empty() and ResourceLoader.exists(preparation_model):
		return preparation_model
	var ingredient: Dictionary = DataRegistry.ingredients_by_id.get(output_id, {})
	var ingredient_model := String(ingredient.get("model", ""))
	if not ingredient_model.is_empty() and ResourceLoader.exists(ingredient_model):
		return ingredient_model
	return ""


func _append_unique_model(target: Array[String], model_path: String) -> void:
	if not model_path.is_empty() and ResourceLoader.exists(model_path) and not target.has(model_path):
		target.append(model_path)


func _visual_style_for_task(task: Dictionary) -> String:
	var station := String(task.get("station", station_id))
	var step := String(task.get("recipe_step_id", "")).to_lower()
	if station == "cutting_board" or step in ["cut", "chop", "grate", "veg", "side", "toppings"]:
		return "chop"
	if station == "dough" or step in ["base", "sauce"]:
		return "mix"
	if station in ["stove", "multi_stove", "oven", "pizza_oven"] or step in ["cook", "bake", "sear", "simmer", "hot", "patty"]:
		return "cook"
	if station == "dessert":
		return "scoop"
	return "assemble"


func _animate_task_food() -> void:
	var count := _food_models.size()
	if count == 0:
		return
	for index: int in count:
		var model := _food_models[index]
		if not is_instance_valid(model):
			continue
		var phase := float(index) * TAU / maxf(float(count), 1.0)
		var spread := 0.0 if count == 1 else 0.16
		var base := Vector3(cos(phase) * spread, 0.0, sin(phase) * spread)
		model.scale = Vector3.ONE
		match _task_visual_style:
			"chop":
				model.position = base + Vector3(sin(_task_motion_time * 11.0 + phase) * 0.025, absf(sin(_task_motion_time * 11.0 + phase)) * 0.025, 0.0)
				model.rotation = Vector3(0.0, sin(_task_motion_time * 5.5 + phase) * 0.09, 0.0)
			"mix":
				model.position = Vector3(cos(_task_motion_time * 2.7 + phase) * maxf(spread, 0.055), absf(sin(_task_motion_time * 4.0 + phase)) * 0.018, sin(_task_motion_time * 2.7 + phase) * maxf(spread, 0.055))
				model.rotation = Vector3(0.0, _task_motion_time * 0.7 + phase, 0.0)
			"cook":
				model.position = base + Vector3(0.0, sin(_task_motion_time * 3.2 + phase) * 0.012, 0.0)
				model.rotation = Vector3(0.0, sin(_task_motion_time * 1.4 + phase) * 0.05, 0.0)
			"scoop":
				model.position = base + Vector3(0.0, absf(sin(_task_motion_time * 4.5 + phase)) * 0.04, sin(_task_motion_time * 2.2 + phase) * 0.018)
				model.rotation = Vector3(sin(_task_motion_time * 2.2 + phase) * 0.06, 0.0, 0.0)
			_:
				# Components converge as the assembly progresses, then the finished
				# dish settles with only a tiny readable idle motion.
				var convergence := 1.0 - _task_progress_ratio if _task_visual_phase == "input" else 0.0
				model.position = base * convergence + Vector3(0.0, absf(sin(_task_motion_time * 3.0 + phase)) * 0.015, 0.0)
				model.rotation = Vector3(0.0, sin(_task_motion_time * 1.8 + phase) * 0.04, 0.0)


func _create_invisible_collision() -> void:
	var placement := String(definition.get("placement", "cell"))
	# Openings replace a wall edge in the navigation graph. Giving them the
	# generic full-width selection collider silently closes that same opening
	# for CharacterBody3D movement, so agents plan a valid route and then hit an
	# invisible wall at the threshold. The visible doorway/door meshes remain
	# selectable through the builder's placed-object lookup.
	if placement == "edge" and not bool(definition.get("blocking", true)):
		return
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	if placement == "edge":
		var bounds := ModelFactory.calculate_visual_bounds(visual_model, true)
		box.size = Vector3(maxf(bounds.size.x * 0.96, 0.5), maxf(bounds.size.y, 1.0), maxf(bounds.size.z, 0.85))
		shape.position = bounds.get_center()
	elif placement in ["seat", "surface", "wall_mount"]:
		var bounds := ModelFactory.calculate_visual_bounds(visual_model, true)
		box.size = Vector3(maxf(bounds.size.x * 0.9, 0.45), maxf(bounds.size.y, 0.35), maxf(bounds.size.z * 0.9, 0.45))
		shape.position = bounds.get_center()
	else:
		var bounds := ModelFactory.calculate_visual_bounds(visual_model, true)
		box.size = Vector3(
			maxf(bounds.size.x * 0.92, 0.55),
			maxf(bounds.size.y * 0.96, 0.4),
			maxf(bounds.size.z * 0.92, 0.55)
		)
		shape.position = bounds.get_center()
	shape.shape = box
	body.add_child(shape)
	add_child(body)


func _create_station_feedback() -> void:
	var bounds := ModelFactory.calculate_visual_bounds(visual_model, true)
	var work_surface_y := clampf(bounds.end.y + 0.025, 0.72, 1.24) if not bounds.size.is_zero_approx() else 1.08
	_food_anchor = Node3D.new()
	_food_anchor.name = "TaskFoodAnchor"
	_food_anchor.position = Vector3(0, work_surface_y, 0)
	add_child(_food_anchor)
	_status_label = Label3D.new()
	_status_label.font = GameFonts.bold()
	_status_label.position = Vector3(0, maxf(work_surface_y + 0.62, 1.55), 0)
	_status_label.font_size = 28
	_status_label.outline_size = 8
	_status_label.modulate = Color("f7d774")
	_status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_status_label.no_depth_test = true
	_status_label.visible = false
	add_child(_status_label)


func _create_heat_particles() -> void:
	_steam = GPUParticles3D.new()
	_steam.amount = 3 if WebPlatformProfile.low_memory_mode() else 6
	_steam.lifetime = 1.6
	_steam.randomness = 0.45
	_steam.emitting = false
	_steam.position = Vector3(0, 1.25, 0)
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.22
	process.direction = Vector3.UP
	process.spread = 16.0
	process.initial_velocity_min = 0.3
	process.initial_velocity_max = 0.55
	process.gravity = Vector3(0, 0.08, 0)
	process.scale_min = 0.45
	process.scale_max = 1.0
	process.color = Color(0.94, 0.98, 1.0, 0.28)
	_steam.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.16, 0.16)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.albedo_color = Color(0.95, 0.99, 1.0, 0.32)
	quad.material = material
	_steam.draw_pass_1 = quad
	add_child(_steam)
