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
var _operational_warning_label: Label3D
var _food_anchor: Node3D
var _food_model: Node3D
var _food_models: Array[Node3D] = []
var _food_visual_root: Node3D
var _steam: GPUParticles3D
var _last_progress_percent := -1
var _task_progress_ratio := 0.0
var _task_motion_time := 0.0
var _task_visual_phase := ""
var _task_visual_style := "assemble"
var _task_output_model_path := ""
var _completed_task_id := ""
var _mechanism_nodes: Array[Node3D] = []
var _mechanism_rest_rotations: Array[Vector3] = []
var _access_animation_time := -1.0
var _burner_glow: Node3D


func _process(delta: float) -> void:
	_update_access_animation(delta)
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
	_configure_equipment_feedback()
	_create_invisible_collision()
	if not station_id.is_empty():
		_create_station_feedback()
	if bool(definition.get("ventilation_required", false)):
		_create_operational_warning()
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


func is_operational() -> bool:
	var restaurant_world := _restaurant_world()
	return true if restaurant_world == null else restaurant_world.station_is_operational(self)


func refresh_operational_feedback() -> void:
	if _operational_warning_label == null:
		return
	_operational_warning_label.visible = not is_operational()


func _restaurant_world() -> RestaurantWorld:
	var ancestor: Node = get_parent()
	while ancestor != null:
		if ancestor is RestaurantWorld:
			return ancestor as RestaurantWorld
		ancestor = ancestor.get_parent()
	return null


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
	_completed_task_id = ""
	current_task = task
	_last_progress_percent = 0
	_task_progress_ratio = 0.0
	_task_motion_time = 0.0
	_task_visual_style = FoodVisualFactory.task_style(task, station_id)
	_task_output_model_path = FoodVisualFactory.primary_output_model(task)
	_task_visual_phase = "input"
	_status_label.visible = true
	_status_label.text = "%s  0%%" % task.recipe_step_id.capitalize()
	var input_parts := FoodVisualFactory.parts_for_task(task, "input")
	if input_parts.is_empty() and not _task_output_model_path.is_empty():
		input_parts = FoodVisualFactory.parts_for_task(task, "output")
		_task_visual_phase = "output"
	_set_food_parts(input_parts)
	if station_id in ["oven", "pizza_oven"]:
		play_access_animation()
	_set_burner_active(station_id in ["stove", "multi_stove"])
	if _steam:
		_steam.emitting = true


func update_task_progress(task: Dictionary) -> void:
	if current_task.is_empty() or current_task.id != task.id:
		show_task(task)
	var percent := int(round((1.0 - float(task.remaining) / maxf(float(task.duration), 0.01)) * 100.0))
	_task_progress_ratio = clampf(float(percent) / 100.0, 0.0, 1.0)
	# Every operation has three readable stages: ingredients arrive, the active
	# preparation appears in/on the correct container, then the semilavorato or
	# finished dish settles before the task completes.
	var process_threshold := 0.18 if _task_visual_style in ["bake", "cook", "fry", "sear", "simmer", "roast"] else 0.24
	var output_threshold := 0.80 if _task_visual_style in ["bake", "cook", "fry", "sear", "simmer", "roast"] else 0.72
	if _task_visual_phase == "input" and _task_progress_ratio >= process_threshold:
		_task_visual_phase = "process"
		_set_food_parts(FoodVisualFactory.parts_for_task(task, "process"))
	if _task_visual_phase == "process" and _task_progress_ratio >= output_threshold and not _task_output_model_path.is_empty():
		_task_visual_phase = "output"
		_set_food_parts(FoodVisualFactory.parts_for_task(task, "output"))
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
	_set_burner_active(false)
	if _steam:
		_steam.emitting = false


func complete_task_visual(task: Dictionary) -> void:
	current_task = {}
	_completed_task_id = String(task.get("id", ""))
	_task_visual_phase = "output"
	_task_progress_ratio = 1.0
	_status_label.visible = false
	_set_food_parts(FoodVisualFactory.parts_for_task(task, "output"))
	_set_burner_active(false)
	if station_id in ["oven", "pizza_oven"]:
		play_access_animation()
	if _steam:
		_steam.emitting = false


func take_completed_output(task_id: String) -> void:
	if task_id.is_empty() or _completed_task_id != task_id:
		return
	_completed_task_id = ""
	if station_id in ["oven", "pizza_oven", "fridge"]:
		play_access_animation()
	_clear_food_models()


func play_access_animation() -> void:
	if _mechanism_nodes.is_empty():
		return
	_access_animation_time = 0.0


func _configure_equipment_feedback() -> void:
	if station_id in ["fridge", "oven", "pizza_oven"]:
		for value: Node in visual_model.find_children("*door*", "Node3D", true, false):
			var mechanism := value as Node3D
			if mechanism == null:
				continue
			_mechanism_nodes.append(mechanism)
			_mechanism_rest_rotations.append(mechanism.rotation)
	if station_id in ["stove", "multi_stove"]:
		_create_burner_glow()


func _update_access_animation(delta: float) -> void:
	if _access_animation_time < 0.0 or _mechanism_nodes.is_empty():
		return
	_access_animation_time += delta * SimulationManager.simulation_speed
	var progress := clampf(_access_animation_time / 1.15, 0.0, 1.0)
	var open_weight := sin(progress * PI)
	open_weight = smoothstep(0.0, 1.0, open_weight)
	for index: int in _mechanism_nodes.size():
		var rest := _mechanism_rest_rotations[index]
		if station_id == "fridge":
			_mechanism_nodes[index].rotation = rest + Vector3(0.0, -PI * 0.48 * open_weight, 0.0)
		else:
			_mechanism_nodes[index].rotation = rest + Vector3(PI * 0.46 * open_weight, 0.0, 0.0)
	if progress >= 1.0:
		for index: int in _mechanism_nodes.size():
			_mechanism_nodes[index].rotation = _mechanism_rest_rotations[index]
		_access_animation_time = -1.0


func _create_burner_glow() -> void:
	_burner_glow = Node3D.new()
	_burner_glow.name = "BurnerGlow"
	var anchor_y := float(definition.get("work_anchor", [0.0, 1.22, 0.0])[1]) + 0.015
	var positions: Array[Vector3] = [Vector3.ZERO]
	if station_id == "multi_stove":
		positions = [Vector3(-0.34, 0.0, -0.28), Vector3(0.34, 0.0, -0.28), Vector3(-0.34, 0.0, 0.28), Vector3(0.34, 0.0, 0.28)]
	for offset: Vector3 in positions:
		var burner := MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = 0.13
		disc.bottom_radius = 0.13
		disc.height = 0.018
		disc.radial_segments = 16
		burner.mesh = disc
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color("ff6d2e")
		material.emission_enabled = true
		material.emission = Color("ff9a32")
		material.emission_energy_multiplier = 1.7
		burner.material_override = material
		burner.position = Vector3(offset.x, anchor_y, offset.z)
		_burner_glow.add_child(burner)
	add_child(_burner_glow)
	_burner_glow.visible = false


func _set_burner_active(active: bool) -> void:
	if _burner_glow != null:
		_burner_glow.visible = active


func _set_food_parts(parts: Array) -> void:
	_clear_food_models()
	_food_visual_root = FoodVisualFactory.instantiate_parts(parts, 1.0)
	_food_visual_root.name = "TaskFoodVisual"
	_food_anchor.add_child(_food_visual_root)
	for child: Node in _food_visual_root.get_children():
		if child is Node3D:
			_food_models.append(child as Node3D)
	_food_model = _food_models[0] if not _food_models.is_empty() else null
	_animate_task_food()


func _clear_food_models() -> void:
	if _food_visual_root != null and is_instance_valid(_food_visual_root):
		_food_visual_root.queue_free()
	_food_visual_root = null
	_food_models.clear()
	_food_model = null


func _animate_task_food() -> void:
	var count := _food_models.size()
	if count == 0:
		return
	for index: int in count:
		var model := _food_models[index]
		if not is_instance_valid(model):
			continue
		var phase := float(index) * TAU / maxf(float(count), 1.0)
		var base: Vector3 = model.get_meta("base_position", model.position)
		var base_rotation: Vector3 = model.get_meta("base_rotation", model.rotation)
		var role := String(model.get_meta("visual_role", "food"))
		model.scale = Vector3.ONE
		model.position = base
		model.rotation = base_rotation
		if role == "container" or _task_visual_phase == "output":
			continue
		match _task_visual_style:
			"chop", "slice", "grate":
				var impact := pow(absf(sin(_task_motion_time * 7.5 + phase)), 9.0)
				model.position = base + Vector3(impact * 0.018, impact * 0.009, 0.0)
				model.rotation.y = base_rotation.y + impact * 0.035
			"knead", "mix", "sauce", "toss":
				model.position = base + Vector3(cos(_task_motion_time * 2.4 + phase) * 0.022, 0.0, sin(_task_motion_time * 2.4 + phase) * 0.022)
				model.rotation.y = base_rotation.y + sin(_task_motion_time * 1.8 + phase) * 0.045
			"cook", "fry", "sear", "simmer", "bake", "roast":
				model.position = base + Vector3(0.0, sin(_task_motion_time * 2.6 + phase) * 0.006, 0.0)
				model.rotation.y = base_rotation.y + sin(_task_motion_time * 1.3 + phase) * 0.018
			"scoop":
				model.position = base + Vector3(0.0, absf(sin(_task_motion_time * 3.6 + phase)) * 0.018, sin(_task_motion_time * 2.0 + phase) * 0.012)
			_:
				var convergence := clampf(1.0 - _task_progress_ratio * 0.55, 0.55, 1.0)
				model.position = base * convergence
				model.rotation.y = base_rotation.y + sin(_task_motion_time * 1.6 + phase) * 0.018


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
	elif placement in ["seat", "surface", "wall_mount", "overhead"]:
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
	var work_surface_y := clampf(bounds.end.y + 0.025, 0.18, 1.30) if not bounds.size.is_zero_approx() else 1.08
	var anchor_position := Vector3(0.0, work_surface_y, 0.0)
	var raw_anchor: Variant = definition.get("work_anchor", [])
	if raw_anchor is Array and raw_anchor.size() >= 3:
		anchor_position = Vector3(float(raw_anchor[0]), float(raw_anchor[1]), float(raw_anchor[2]))
	_food_anchor = Node3D.new()
	_food_anchor.name = "TaskFoodAnchor"
	_food_anchor.position = anchor_position
	add_child(_food_anchor)
	_status_label = Label3D.new()
	_status_label.font = GameFonts.bold()
	_status_label.position = Vector3(anchor_position.x, maxf(anchor_position.y + 0.62, 1.55), anchor_position.z)
	_status_label.font_size = 28
	_status_label.outline_size = 8
	_status_label.modulate = Color("f7d774")
	_status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_status_label.no_depth_test = true
	_status_label.visible = false
	add_child(_status_label)


func _create_operational_warning() -> void:
	var bounds := ModelFactory.calculate_visual_bounds(visual_model, true)
	_operational_warning_label = Label3D.new()
	_operational_warning_label.name = "OperationalWarning"
	_operational_warning_label.text = "CAPPA MANCANTE"
	_operational_warning_label.font = GameFonts.bold()
	_operational_warning_label.position = Vector3(0.0, maxf(bounds.end.y + 0.44, 1.58), 0.0)
	_operational_warning_label.font_size = 25
	_operational_warning_label.outline_size = 9
	_operational_warning_label.modulate = Color("ff5a67")
	_operational_warning_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_operational_warning_label.no_depth_test = true
	_operational_warning_label.visible = false
	add_child(_operational_warning_label)


func _create_heat_particles() -> void:
	_steam = GPUParticles3D.new()
	_steam.amount = 3 if WebPlatformProfile.low_memory_mode() else 6
	_steam.lifetime = 1.6
	_steam.randomness = 0.45
	_steam.emitting = false
	_steam.position = (_food_anchor.position if _food_anchor != null else Vector3(0, 1.15, 0)) + Vector3.UP * 0.14
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
