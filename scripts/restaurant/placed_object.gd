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
var _steam: GPUParticles3D
var _last_progress_percent := -1


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
	_status_label.visible = true
	_status_label.text = "%s  0%%" % task.recipe_step_id.capitalize()
	if _food_model:
		_food_model.queue_free()
	var model_path := String(task.get("model", ""))
	if model_path.is_empty():
		var output_id := String(task.get("output", ""))
		if DataRegistry.preparations_by_id.has(output_id):
			model_path = String(DataRegistry.preparations_by_id[output_id].model)
	if not model_path.is_empty():
		_food_model = ModelFactory.instantiate_model(model_path, 0.65)
		_food_anchor.add_child(_food_model)
	if _steam:
		_steam.emitting = true


func update_task_progress(task: Dictionary) -> void:
	if current_task.is_empty() or current_task.id != task.id:
		show_task(task)
	var percent := int(round((1.0 - float(task.remaining) / maxf(float(task.duration), 0.01)) * 100.0))
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
	if _food_model:
		_food_model.queue_free()
		_food_model = null
	if _steam:
		_steam.emitting = false


func _create_invisible_collision() -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var placement := String(definition.get("placement", "cell"))
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
	_food_anchor = Node3D.new()
	_food_anchor.position = Vector3(0, 1.08, 0)
	add_child(_food_anchor)
	_status_label = Label3D.new()
	_status_label.font = GameFonts.bold()
	_status_label.position = Vector3(0, 1.75, 0)
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
