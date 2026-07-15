class_name RestaurantWorld
extends Node3D

const GRID_SIZE := Vector2i(18, 14)
const CELL_SIZE := 2.0

var entrance_cell := Vector2i(8, 0)
var astar := AStarGrid2D.new()
var occupancy: Dictionary = {}
var static_blocked: Dictionary = {}
var placed_objects: Dictionary = {}
var table_occupants: Dictionary = {}
var staff_agents: Dictionary = {}
var navigation_agents: Array[AnimatedAgent] = []
var navigation_revision := 0
var waiting_reservations: Dictionary = {}
var staff_standby_reservations: Dictionary = {}
var corridor_reservations: Dictionary = {}
var agent_corridor_reservations: Dictionary = {}
var customer_root: Node3D
var object_root: Node3D
var preview_root: Node3D
var build_system: BuildSystem
var camera_rig: RestaurantCamera
var rush_mode := false
var show_grid := false
var show_paths := false
var show_station_queues := false
var _spawn_clock := 0.0
var floor_root: Node3D
var floor_tiles: Dictionary = {}
var floor_batches: Dictionary = {}
var grid_overlay: MeshInstance3D
var debug_paths_root: Node3D
var _queue_labels: Dictionary = {}
var _debug_refresh_clock := 0.0
var _temporary_blocked_edge_keys: Dictionary = {}
var _validation_ignored_edge_uid := ""
var _loading_layout := false
var _blocked_edge_uids: Dictionary = {}
var _grid_path_cache: Dictionary = {}
var _path_cache_suspended := false


func _ready() -> void:
	name = "RestaurantWorld"
	_create_environment()
	_create_roots()
	_create_grid()
	_create_floor_and_walls()
	load_layout()
	spawn_staff()
	SimulationManager.bind_world(self)
	if not WebPlatformProfile.quality_changed.is_connected(apply_graphics_quality):
		WebPlatformProfile.quality_changed.connect(apply_graphics_quality)


func _process(delta: float) -> void:
	if camera_rig:
		var long_press: Variant = camera_rig.consume_long_press()
		if long_press != null:
			var main := get_parent()
			if main and main.get("ui") is RestaurantUI:
				main.ui.open_builder()
			build_system.pointer_pressed(Vector2(long_press))
	if show_station_queues:
		_debug_refresh_clock -= delta
		if _debug_refresh_clock <= 0.0:
			_debug_refresh_clock = 0.25
			_update_station_queue_labels()
	if GameState.restaurant_state != "open":
		return
	_spawn_clock -= delta * SimulationManager.simulation_speed
	var maximum := 8 if rush_mode else 5
	if _spawn_clock <= 0.0 and SimulationManager.customers.size() < maximum:
		spawn_customer_group()
		_spawn_clock = randf_range(1.8, 3.2) if rush_mode else randf_range(4.2, 6.5)


func _unhandled_input(event: InputEvent) -> void:
	var placing := build_system != null and build_system.active
	var camera_consumed := camera_rig != null and camera_rig.handle_input(event, not placing)
	if placing:
		if not camera_consumed and event is InputEventMouseMotion:
			build_system.pointer_moved(event.position)
			get_viewport().set_input_as_handled()
		elif not camera_consumed and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			build_system.pointer_pressed(event.position)
			get_viewport().set_input_as_handled()
		elif not camera_consumed and event is InputEventScreenDrag:
			build_system.pointer_moved(event.position)
			get_viewport().set_input_as_handled()
		elif not camera_consumed and event is InputEventScreenTouch and not event.pressed:
			build_system.pointer_pressed(event.position)
			get_viewport().set_input_as_handled()
		if event.is_action_pressed("rotate_build"):
			build_system.rotate_preview()
		if event.is_action_pressed("cancel_action"):
			build_system.cancel_preview()
		if camera_consumed:
			get_viewport().set_input_as_handled()
		return
	if camera_consumed:
		var tap: Variant = camera_rig.consume_tap()
		if tap != null:
			build_system.pointer_pressed(Vector2(tap))
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("cancel_action"):
		build_system.clear_selection()


func configure_build_system() -> void:
	build_system = BuildSystem.new()
	add_child(build_system)
	build_system.setup(self, camera_rig.camera)


func _create_roots() -> void:
	object_root = Node3D.new()
	object_root.name = "PlacedObjects"
	add_child(object_root)
	preview_root = Node3D.new()
	preview_root.name = "BuildPreview"
	add_child(preview_root)
	debug_paths_root = Node3D.new()
	debug_paths_root.name = "DebugPaths"
	add_child(debug_paths_root)
	customer_root = Node3D.new()
	customer_root.name = "Customers"
	add_child(customer_root)
	camera_rig = RestaurantCamera.new()
	camera_rig.name = "IsometricCamera"
	add_child(camera_rig)
	configure_build_system()


func _create_environment() -> void:
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("91bdc1")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("dce3e2")
	environment.ambient_light_energy = 0.38
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.fog_enabled = false
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-58, -35, 0)
	sun.light_color = Color("fff7e8")
	sun.light_energy = 0.84
	sun.shadow_enabled = WebPlatformProfile.shadows_enabled()
	sun.directional_shadow_max_distance = WebPlatformProfile.shadow_distance()
	add_child(sun)


func apply_graphics_quality(_preset: String = "auto") -> void:
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = WebPlatformProfile.shadows_enabled()
		sun.directional_shadow_max_distance = WebPlatformProfile.shadow_distance()


func _create_grid() -> void:
	astar.region = Rect2i(Vector2i.ZERO, GRID_SIZE)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar.update()


func _create_floor_and_walls() -> void:
	floor_root = Node3D.new()
	floor_root.name = "KayKitFloor"
	add_child(floor_root)
	_create_grid_overlay()
	_rebuild_astar()


func _add_wall(root: Node3D, cell: Vector2i, rotation_steps: int, model_path: String) -> void:
	var wall := ModelFactory.instantiate_model(model_path)
	wall.scale.x = 0.5
	ModelFactory.align_visual_to_grid_origin(wall)
	wall.position = cell_to_world(cell)
	wall.rotation.y = -rotation_steps * PI * 0.5
	root.add_child(wall)
	if cell != entrance_cell:
		static_blocked[cell] = true


func load_layout() -> void:
	SimulationManager.unregister_world_stations()
	for child: Node in object_root.get_children():
		child.queue_free()
	placed_objects.clear()
	occupancy.clear()
	table_occupants.clear()
	waiting_reservations.clear()
	staff_standby_reservations.clear()
	corridor_reservations.clear()
	agent_corridor_reservations.clear()
	_loading_layout = true
	floor_tiles.clear()
	for y: int in GRID_SIZE.y:
		for x: int in GRID_SIZE.x:
			set_floor_style(Vector2i(x, y), "floor_dining" if y < 8 else "floor_kitchen")
	for record: Dictionary in GameState.layout:
		var cell_data: Array = record.get("cell", [0, 0])
		instantiate_layout_object(
			String(record.uid),
			String(record.item),
			Vector2i(int(cell_data[0]), int(cell_data[1])),
			int(record.get("rotation", 0)),
			String(record.get("support_uid", "")),
			int(record.get("attachment_slot", -1))
		)
	_loading_layout = false
	_rebuild_floor_batches()
	_refresh_all_attachments()
	_rebuild_astar()


func instantiate_layout_object(uid: String, item_id: String, cell: Vector2i, rotation_steps: int, support_uid: String = "", attachment_slot: int = -1) -> PlacedObject:
	var definition: Dictionary = DataRegistry.build_by_id.get(item_id, {})
	if definition.is_empty():
		push_warning("Unknown layout item: %s" % item_id)
		return null
	if item_id.begins_with("floor_"):
		set_floor_style(cell, item_id)
		return null
	var object := PlacedObject.new()
	object.setup(uid, definition, cell, rotation_steps, support_uid, attachment_slot)
	object.position = placement_world_position(definition, cell, rotation_steps, support_uid, attachment_slot)
	object_root.add_child(object)
	placed_objects[uid] = object
	set_object_occupancy(object, true)
	object.register_station()
	if item_id.begins_with("table"):
		table_occupants[uid] = null
	return object


func add_layout_object(item_id: String, cell: Vector2i, rotation_steps: int, support_uid: String = "", attachment_slot: int = -1) -> PlacedObject:
	if item_id.begins_with("floor_"):
		for existing: Dictionary in GameState.layout.duplicate():
			var existing_cell: Array = existing.get("cell", [-1, -1])
			if String(existing.get("item", "")).begins_with("floor_") and Vector2i(int(existing_cell[0]), int(existing_cell[1])) == cell:
				GameState.layout.erase(existing)
		var floor_record := {"uid": "floor_%d_%d" % [cell.x, cell.y], "item": item_id, "cell": [cell.x, cell.y], "rotation": 0}
		GameState.layout.append(floor_record)
		set_floor_style(cell, item_id)
		GameState.layout_changed.emit()
		return null
	var uid := "%s_%d" % [item_id, Time.get_ticks_msec()]
	var record := {"uid": uid, "item": item_id, "cell": [cell.x, cell.y], "rotation": rotation_steps}
	if not support_uid.is_empty():
		record.support_uid = support_uid
		record.attachment_slot = attachment_slot
	GameState.layout.append(record)
	var object := instantiate_layout_object(uid, item_id, cell, rotation_steps, support_uid, attachment_slot)
	_refresh_attachment(object)
	_rebuild_astar()
	GameState.layout_changed.emit()
	return object


func remove_placed_object(object: PlacedObject, remove_record: bool = true) -> void:
	for attached: PlacedObject in attached_objects(object.uid):
		remove_placed_object(attached, remove_record)
	set_object_occupancy(object, false)
	placed_objects.erase(object.uid)
	table_occupants.erase(object.uid)
	if remove_record:
		for record: Dictionary in GameState.layout.duplicate():
			if String(record.uid) == object.uid:
				GameState.layout.erase(record)
				break
	object.queue_free()
	_rebuild_astar()
	GameState.layout_changed.emit()


func move_layout_object(object: PlacedObject, cell: Vector2i, rotation_steps: int, support_uid: String = "", attachment_slot: int = -1) -> void:
	if object == null or not is_instance_valid(object):
		return
	var rotation_delta := posmod(rotation_steps - object.rotation_steps, 4)
	set_object_occupancy(object, false)
	object.set_layout_state(cell, rotation_steps, support_uid, attachment_slot)
	object.position = placement_world_position(object.definition, cell, rotation_steps, support_uid, attachment_slot)
	set_object_occupancy(object, true)
	_update_layout_record(object)
	for attached: PlacedObject in attached_objects(object.uid):
		var child_rotation := posmod(attached.rotation_steps + rotation_delta, 4)
		if String(attached.definition.get("placement", "cell")) == "seat":
			child_rotation = seat_rotation_for_slot(attached.attachment_slot, rotation_steps)
		attached.set_layout_state(cell, child_rotation, object.uid, attached.attachment_slot)
		_refresh_attachment(attached)
		_update_layout_record(attached)
	_rebuild_astar()
	GameState.layout_changed.emit()


func _update_layout_record(object: PlacedObject) -> void:
	for record: Dictionary in GameState.layout:
		if String(record.get("uid", "")) != object.uid:
			continue
		record.cell = [object.grid_cell.x, object.grid_cell.y]
		record.rotation = object.rotation_steps
		if object.support_uid.is_empty():
			record.erase("support_uid")
			record.erase("attachment_slot")
		else:
			record.support_uid = object.support_uid
			record.attachment_slot = object.attachment_slot
		return


func attached_objects(support_uid: String) -> Array[PlacedObject]:
	var result: Array[PlacedObject] = []
	for object: PlacedObject in placed_objects.values():
		if is_instance_valid(object) and object.support_uid == support_uid:
			result.append(object)
	result.sort_custom(func(a: PlacedObject, b: PlacedObject): return a.attachment_slot < b.attachment_slot if a.attachment_slot != b.attachment_slot else a.uid < b.uid)
	return result


func set_object_occupancy(object: PlacedObject, occupied: bool) -> void:
	if is_edge_placement(object.definition) or not bool(object.definition.get("blocking", true)):
		return
	for cell: Vector2i in occupied_cells(object.definition, object.grid_cell, object.rotation_steps):
		if occupied:
			occupancy[cell] = object.uid
		else:
			occupancy.erase(cell)
	_rebuild_astar()


func occupied_cells(definition: Dictionary, origin: Vector2i, rotation_steps: int) -> Array[Vector2i]:
	var raw: Array = definition.get("footprint", [1, 1])
	var size := Vector2i(int(raw[0]), int(raw[1]))
	if rotation_steps % 2 == 1:
		size = Vector2i(size.y, size.x)
	var result: Array[Vector2i] = []
	for y: int in size.y:
		for x: int in size.x:
			result.append(origin + Vector2i(x, y))
	return result


func placement_world_position(definition: Dictionary, cell: Vector2i, rotation_steps: int, support_uid: String = "", attachment_slot: int = -1) -> Vector3:
	if not support_uid.is_empty() and is_attachment_placement(definition):
		var support := placed_objects.get(support_uid) as PlacedObject
		if support != null and is_instance_valid(support):
			return attachment_world_position(definition, support, attachment_slot, rotation_steps)
	var raw: Array = definition.get("footprint", [1, 1])
	var size := Vector2i(int(raw[0]), int(raw[1]))
	if rotation_steps % 2 == 1:
		size = Vector2i(size.y, size.x)
	var position := cell_to_world(cell) + Vector3(float(size.x - 1) * CELL_SIZE * 0.5, 0, float(size.y - 1) * CELL_SIZE * 0.5)
	if is_edge_placement(definition):
		position += edge_offset(definition, rotation_steps)
	elif String(definition.get("placement", "cell")) == "wall_mount":
		position += wall_mount_offset(definition, rotation_steps)
		position.y = float(definition.get("mount_height", 1.25))
	return position


func is_edge_placement(definition: Dictionary) -> bool:
	return String(definition.get("placement", "cell")) == "edge"


func is_attachment_placement(definition: Dictionary) -> bool:
	return String(definition.get("placement", "cell")) in ["seat", "surface", "wall_mount"]


func attachment_world_position(definition: Dictionary, support: PlacedObject, attachment_slot: int, rotation_steps: int = 0) -> Vector3:
	var placement := String(definition.get("placement", "cell"))
	if placement == "seat":
		var directions := [Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)]
		var offset: Vector3 = directions[posmod(attachment_slot, 4)] * float(support.definition.get("seat_offset", 1.35))
		return support.position + offset.rotated(Vector3.UP, -support.rotation_steps * PI * 0.5)
	if placement == "surface":
		var raw: Array = support.definition.get("footprint", [1, 1])
		var width := maxi(int(raw[0]), 1)
		var height := maxi(int(raw[1]), 1)
		var slots := attachment_slots_for(definition, support, attachment_slot, rotation_steps)
		if slots.is_empty():
			slots = [clampi(attachment_slot, 0, width * height - 1)]
		var local_offset := Vector3.ZERO
		for slot: int in slots:
			var slot_x := slot % width
			var slot_y := slot / width
			local_offset += Vector3((float(slot_x) - float(width - 1) * 0.5) * CELL_SIZE, 0, (float(slot_y) - float(height - 1) * 0.5) * CELL_SIZE)
		local_offset /= float(slots.size())
		local_offset = local_offset.rotated(Vector3.UP, -support.rotation_steps * PI * 0.5)
		return support.position + local_offset + Vector3.UP * float(support.definition.get("surface_height", 1.02))
	if placement == "wall_mount":
		var result := cell_to_world(support.grid_cell) + wall_mount_offset(definition, support.rotation_steps)
		result.y = float(definition.get("mount_height", 1.25))
		return result
	return support.position


func wall_mount_offset(definition: Dictionary, rotation_steps: int) -> Vector3:
	var distance := CELL_SIZE * 0.5 - float(definition.get("mount_depth", 0.5)) * 0.5
	match posmod(rotation_steps, 4):
		0:
			return Vector3(0, 0, -distance)
		1:
			return Vector3(-distance, 0, 0)
		2:
			return Vector3(0, 0, distance)
		_:
			return Vector3(distance, 0, 0)


func seat_rotation_for_slot(attachment_slot: int, table_rotation: int) -> int:
	return posmod([0, 3, 2, 1][posmod(attachment_slot, 4)] + table_rotation, 4)


func attachment_target_at(definition: Dictionary, world_hit: Vector3, requested_rotation: int, ignored: PlacedObject = null) -> Dictionary:
	var required_kind := String(definition.get("requires_support", ""))
	var best_support: PlacedObject
	var best_distance := INF
	for candidate: PlacedObject in placed_objects.values():
		if candidate == ignored or not is_instance_valid(candidate):
			continue
		if String(candidate.definition.get("support_kind", "")) != required_kind:
			continue
		var raw: Array = candidate.definition.get("footprint", [1, 1])
		var local_hit := candidate.to_local(world_hit)
		var half_x := float(raw[0]) * CELL_SIZE * 0.5
		var half_z := float(raw[1]) * CELL_SIZE * 0.5
		if absf(local_hit.x) > half_x or absf(local_hit.z) > half_z:
			continue
		var distance := Vector2(local_hit.x, local_hit.z).length()
		if distance < best_distance:
			best_distance = distance
			best_support = candidate
	if best_support == null:
		return {"cell": world_to_cell(world_hit), "rotation": requested_rotation, "support_uid": "", "attachment_slot": -1}
	var raw: Array = best_support.definition.get("footprint", [1, 1])
	var local_hit := best_support.to_local(world_hit)
	var slot := 0
	var rotation := requested_rotation
	if String(definition.get("placement", "cell")) == "seat":
		var nx := local_hit.x / maxf(float(raw[0]) * CELL_SIZE * 0.5, 0.01)
		var nz := local_hit.z / maxf(float(raw[1]) * CELL_SIZE * 0.5, 0.01)
		if absf(nx) > absf(nz):
			slot = 1 if nx < 0.0 else 3
		else:
			slot = 0 if nz < 0.0 else 2
		rotation = seat_rotation_for_slot(slot, best_support.rotation_steps)
	else:
		var width := maxi(int(raw[0]), 1)
		var height := maxi(int(raw[1]), 1)
		var slot_x := clampi(int(floor((local_hit.x + float(width) * CELL_SIZE * 0.5) / CELL_SIZE)), 0, width - 1)
		var slot_y := clampi(int(floor((local_hit.z + float(height) * CELL_SIZE * 0.5) / CELL_SIZE)), 0, height - 1)
		var item_raw: Array = definition.get("footprint", [1, 1])
		var item_width := maxi(int(item_raw[0]), 1)
		var item_height := maxi(int(item_raw[1]), 1)
		if posmod(requested_rotation - best_support.rotation_steps, 2) == 1:
			var swap := item_width
			item_width = item_height
			item_height = swap
		slot_x = clampi(slot_x, 0, maxi(width - item_width, 0))
		slot_y = clampi(slot_y, 0, maxi(height - item_height, 0))
		slot = slot_y * width + slot_x
	return {"cell": best_support.grid_cell, "rotation": rotation, "support_uid": best_support.uid, "attachment_slot": slot}


func attachment_occupant_at(support_uid: String, attachment_slot: int, ignored: PlacedObject = null) -> PlacedObject:
	for object: PlacedObject in placed_objects.values():
		if object != ignored and is_instance_valid(object) and object.support_uid == support_uid and object.attachment_slot == attachment_slot:
			return object
	return null


func attachment_slots_for(definition: Dictionary, support: PlacedObject, attachment_slot: int, rotation_steps: int) -> Array[int]:
	var result: Array[int] = []
	if String(definition.get("placement", "cell")) != "surface":
		if attachment_slot >= 0:
			result.append(attachment_slot)
		return result
	var support_raw: Array = support.definition.get("footprint", [1, 1])
	var support_width := maxi(int(support_raw[0]), 1)
	var support_height := maxi(int(support_raw[1]), 1)
	var item_raw: Array = definition.get("footprint", [1, 1])
	var item_width := maxi(int(item_raw[0]), 1)
	var item_height := maxi(int(item_raw[1]), 1)
	if posmod(rotation_steps - support.rotation_steps, 2) == 1:
		var swap := item_width
		item_width = item_height
		item_height = swap
	var start_x := attachment_slot % support_width
	var start_y := attachment_slot / support_width
	if attachment_slot < 0 or start_x + item_width > support_width or start_y + item_height > support_height:
		return result
	for y: int in item_height:
		for x: int in item_width:
			result.append((start_y + y) * support_width + start_x + x)
	return result


func _refresh_all_attachments() -> void:
	for object: PlacedObject in placed_objects.values():
		_refresh_attachment(object)


func _refresh_attachment(object: PlacedObject) -> void:
	if object == null or object.support_uid.is_empty():
		return
	if not is_attachment_placement(object.definition):
		object.support_uid = ""
		object.attachment_slot = -1
		_update_layout_record(object)
		return
	var support := placed_objects.get(object.support_uid) as PlacedObject
	if support == null or not is_instance_valid(support):
		return
	var rotation := object.rotation_steps
	var placement := String(object.definition.get("placement", "cell"))
	if placement == "seat":
		rotation = seat_rotation_for_slot(object.attachment_slot, support.rotation_steps)
	elif placement == "wall_mount":
		rotation = support.rotation_steps
	object.set_layout_state(support.grid_cell, rotation, support.uid, object.attachment_slot)
	object.position = attachment_world_position(object.definition, support, object.attachment_slot, object.rotation_steps)
	_update_layout_record(object)


func station_interaction_position(object: PlacedObject) -> Vector3:
	var candidates := station_access_cells(object.definition, object.grid_cell, object.rotation_steps, object.support_uid, object.attachment_slot)
	for candidate: Vector2i in candidates:
		if _station_front_connection_open(object.definition, candidate, object.rotation_steps) and astar.is_in_boundsv(candidate) and not astar.is_point_solid(candidate) and not _grid_path(entrance_cell, candidate).is_empty():
			return cell_to_world(candidate)
	for candidate: Vector2i in candidates:
		if _station_front_connection_open(object.definition, candidate, object.rotation_steps) and astar.is_in_boundsv(candidate) and not astar.is_point_solid(candidate):
			return cell_to_world(candidate)
	return object.global_position


func edge_offset(definition: Dictionary, rotation_steps: int) -> Vector3:
	var distance := CELL_SIZE * 0.5 + float(definition.get("edge_depth", 0.5)) * 0.5
	match posmod(rotation_steps, 4):
		0:
			return Vector3(0, 0, -distance)
		1:
			return Vector3(-distance, 0, 0)
		2:
			return Vector3(0, 0, distance)
		_:
			return Vector3(distance, 0, 0)


func edge_key(cell: Vector2i, rotation_steps: int) -> String:
	match posmod(rotation_steps, 4):
		0:
			return "h:%d:%d" % [cell.x, cell.y]
		1:
			return "v:%d:%d" % [cell.x, cell.y]
		2:
			return "h:%d:%d" % [cell.x, cell.y + 1]
		_:
			return "v:%d:%d" % [cell.x + 1, cell.y]


func edge_name(rotation_steps: int) -> String:
	return ["Nord", "Ovest", "Sud", "Est"][posmod(rotation_steps, 4)]


func structural_edge_at(cell: Vector2i, rotation_steps: int, ignored: PlacedObject = null) -> PlacedObject:
	var target_key := edge_key(cell, rotation_steps)
	for object: PlacedObject in placed_objects.values():
		if object == ignored or not is_instance_valid(object) or not is_edge_placement(object.definition):
			continue
		if edge_key(object.grid_cell, object.rotation_steps) == target_key:
			return object
	return null


func validate_placement(definition: Dictionary, cell: Vector2i, rotation_steps: int, ignored: PlacedObject = null, support_uid: String = "", attachment_slot: int = -1) -> Dictionary:
	if cell.x < 0 or cell.y < 0:
		return {"valid": false, "reason": "Fuori dall'area costruibile"}
	var placement := String(definition.get("placement", "cell"))
	if is_attachment_placement(definition):
		var support := placed_objects.get(support_uid) as PlacedObject
		if support == null or not is_instance_valid(support):
			match placement:
				"seat":
					return {"valid": false, "reason": "Porta la sedia sopra un tavolo e scegli uno dei quattro lati"}
				"surface":
					return {"valid": false, "reason": "Questa attrezzatura deve essere appoggiata su un banco da lavoro"}
				_:
					return {"valid": false, "reason": "La mensola deve essere agganciata a un muro pieno"}
		if placement == "wall_mount":
			if String(support.item_id) != "wall" or edge_key(support.grid_cell, support.rotation_steps) != edge_key(cell, rotation_steps):
				return {"valid": false, "reason": "La mensola può essere agganciata soltanto a un muro pieno"}
		elif String(support.definition.get("support_kind", "")) != String(definition.get("requires_support", "")):
			return {"valid": false, "reason": "Supporto non compatibile"}
		if attachment_slot < 0:
			return {"valid": false, "reason": "Punto di aggancio non valido"}
		var requested_slots := attachment_slots_for(definition, support, attachment_slot, rotation_steps)
		if requested_slots.is_empty():
			return {"valid": false, "reason": "L'attrezzatura non entra sul banco con questo orientamento"}
		for existing: PlacedObject in attached_objects(support.uid):
			if existing == ignored:
				continue
			var occupied_slots := attachment_slots_for(existing.definition, support, existing.attachment_slot, existing.rotation_steps)
			for requested_slot: int in requested_slots:
				if requested_slot in occupied_slots:
					return {"valid": false, "reason": "Questo punto di aggancio è già occupato"}
		if placement == "seat" and rotation_steps != seat_rotation_for_slot(attachment_slot, support.rotation_steps):
			return {"valid": false, "reason": "La sedia deve essere rivolta verso il tavolo"}
		if not String(definition.get("station", "")).is_empty():
			var access_error := _new_station_access_error(definition, cell, rotation_steps, support.uid, attachment_slot)
			if not access_error.is_empty():
				return {"valid": false, "reason": access_error}
		return {"valid": true, "reason": "Aggancio valido a %s" % String(support.definition.name)}
	var replaced_wall: PlacedObject = structural_edge_at(cell, rotation_steps, ignored) if is_edge_placement(definition) else null
	if is_edge_placement(definition) and replaced_wall != null and not bool(definition.get("replaces_wall", false)):
		return {"valid": false, "reason": "Questo bordo è già occupato"}
	if bool(definition.get("replaces_wall", false)):
		if replaced_wall == null:
			return {"valid": false, "reason": "Porte e finestre sostituiscono un tratto di muro"}
		if not attached_objects(replaced_wall.uid).is_empty():
			return {"valid": false, "reason": "Rimuovi prima gli elementi agganciati a questo muro"}
	var cells := occupied_cells(definition, cell, rotation_steps)
	if not is_edge_placement(definition) and not String(definition.get("id", "")).begins_with("floor_") and entrance_cell in cells:
		return {"valid": false, "reason": "La cella di ingresso deve restare libera"}
	for occupied_cell: Vector2i in cells:
		if not astar.is_in_boundsv(occupied_cell):
			return {"valid": false, "reason": "Fuori dalla griglia"}
		if static_blocked.has(occupied_cell):
			return {"valid": false, "reason": "Cella strutturale occupata"}
		if occupancy.has(occupied_cell) and (ignored == null or occupancy[occupied_cell] != ignored.uid) and (replaced_wall == null or occupancy[occupied_cell] != replaced_wall.uid):
			return {"valid": false, "reason": "Spazio già occupato"}
	if bool(definition.get("blocking", true)):
		var baseline_access := _accessibility_snapshot(ignored)
		if is_edge_placement(definition):
			_temporary_blocked_edge_keys[edge_key(cell, rotation_steps)] = true
			_validation_ignored_edge_uid = ignored.uid if ignored != null else ""
		else:
			_path_cache_suspended = true
			for occupied_cell: Vector2i in cells:
				astar.set_point_solid(occupied_cell, true)
		var access_error := _operational_access_error(definition, cells, rotation_steps, ignored, support_uid, baseline_access)
		if is_edge_placement(definition):
			_temporary_blocked_edge_keys.erase(edge_key(cell, rotation_steps))
			_validation_ignored_edge_uid = ""
		else:
			for occupied_cell: Vector2i in cells:
				astar.set_point_solid(occupied_cell, static_blocked.has(occupied_cell) or occupancy.has(occupied_cell))
			_path_cache_suspended = false
		if not access_error.is_empty():
			return {"valid": false, "reason": access_error}
	return {"valid": true, "reason": "Posizionamento valido"}


func _operational_access_error(new_definition: Dictionary, new_cells: Array[Vector2i], rotation_steps: int, ignored: PlacedObject, support_uid: String = "", baseline_access: Dictionary = {}) -> String:
	if bool(baseline_access.get("__kitchen", true)) and _grid_path(entrance_cell, _nearest_open_cell(Vector2i(9, 8))).is_empty():
		return "Bloccherebbe il passaggio tra ingresso e cucina"
	for object: PlacedObject in placed_objects.values():
		if object == ignored or not is_instance_valid(object):
			continue
		if ignored != null and object.support_uid == ignored.uid:
			continue
		if object.station_id.is_empty() and not object.item_id.begins_with("table"):
			continue
		if bool(baseline_access.get(object.uid, false)) and not _object_has_operational_access(object):
			return "Bloccherebbe l'accesso a %s" % object.definition.name
	var new_id := String(new_definition.get("id", ""))
	if not String(new_definition.get("station", "")).is_empty():
		var station_error := _new_station_access_error(new_definition, new_cells[0] if not new_cells.is_empty() else Vector2i(-1, -1), rotation_steps, support_uid)
		if not station_error.is_empty():
			return station_error
	elif new_id.begins_with("table"):
		var reachable_neighbor := false
		for cell: Vector2i in new_cells:
			for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var neighbor := cell + offset
				if astar.is_in_boundsv(neighbor) and not astar.is_point_solid(neighbor) and not _grid_path(entrance_cell, neighbor).is_empty():
					reachable_neighbor = true
					break
			if reachable_neighbor:
				break
		if not reachable_neighbor:
			return "La nuova postazione non avrebbe un punto di accesso"
	if ignored != null and not attached_objects(ignored.uid).is_empty() and not new_cells.is_empty():
		var group_error := _attached_group_access_error(ignored, new_cells[0], rotation_steps)
		if not group_error.is_empty():
			return group_error
	return ""


func _accessibility_snapshot(ignored: PlacedObject = null) -> Dictionary:
	var result := {"__kitchen": not _grid_path(entrance_cell, _nearest_open_cell(Vector2i(9, 8))).is_empty()}
	for object: PlacedObject in placed_objects.values():
		if object == ignored or not is_instance_valid(object):
			continue
		if ignored != null and object.support_uid == ignored.uid:
			continue
		if object.station_id.is_empty() and not object.item_id.begins_with("table"):
			continue
		result[object.uid] = _object_has_operational_access(object)
	return result


func _object_has_operational_access(object: PlacedObject) -> bool:
	if not object.station_id.is_empty():
		for candidate: Vector2i in station_access_cells(object.definition, object.grid_cell, object.rotation_steps, object.support_uid, object.attachment_slot):
			if not _station_front_connection_open(object.definition, candidate, object.rotation_steps):
				continue
			if astar.is_in_boundsv(candidate) and not astar.is_point_solid(candidate) and not _grid_path(entrance_cell, candidate).is_empty():
				return true
		return false
	var service_cell := _nearest_open_cell(world_to_cell(_service_position_for_table(object)))
	return not _grid_path(entrance_cell, service_cell).is_empty()


func _attached_group_access_error(support: PlacedObject, candidate_cell: Vector2i, candidate_rotation: int) -> String:
	var old_cell := support.grid_cell
	var old_rotation := support.rotation_steps
	var old_position := support.position
	var rotation_delta := posmod(candidate_rotation - old_rotation, 4)
	support.set_layout_state(candidate_cell, candidate_rotation, support.support_uid, support.attachment_slot)
	support.position = placement_world_position(support.definition, candidate_cell, candidate_rotation, support.support_uid, support.attachment_slot)
	var result := ""
	for attached: PlacedObject in attached_objects(support.uid):
		if attached.station_id.is_empty():
			continue
		var child_rotation := posmod(attached.rotation_steps + rotation_delta, 4)
		var access_error := _new_station_access_error(attached.definition, candidate_cell, child_rotation, support.uid, attached.attachment_slot)
		if not access_error.is_empty():
			result = "%s: %s" % [attached.definition.name, access_error]
			break
	support.set_layout_state(old_cell, old_rotation, support.support_uid, support.attachment_slot)
	support.position = old_position
	return result


func station_front_name(rotation_steps: int) -> String:
	return ["Sud", "Ovest", "Nord", "Est"][posmod(rotation_steps, 4)]


func _front_offset(rotation_steps: int) -> Vector2i:
	return [Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP, Vector2i.RIGHT][posmod(rotation_steps, 4)]


func station_access_cells(definition: Dictionary, cell: Vector2i, rotation_steps: int, support_uid: String = "", attachment_slot: int = -1) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var placement := String(definition.get("placement", "cell"))
	var offset := _front_offset(rotation_steps)
	if placement == "wall_mount":
		var wall := placed_objects.get(support_uid) as PlacedObject
		if wall == null:
			return result
		var inward: Vector2i = [Vector2i.DOWN, Vector2i.RIGHT, Vector2i.UP, Vector2i.LEFT][posmod(wall.rotation_steps, 4)]
		result.append(wall.grid_cell)
		result.append(wall.grid_cell + inward)
		return result
	if placement == "surface":
		var support := placed_objects.get(support_uid) as PlacedObject
		if support == null:
			return result
		var support_raw: Array = support.definition.get("footprint", [1, 1])
		var width := maxi(int(support_raw[0]), 1)
		var height := maxi(int(support_raw[1]), 1)
		for slot: int in attachment_slots_for(definition, support, attachment_slot, rotation_steps):
			var slot_x := slot % width
			var slot_y := slot / width
			var local_offset := Vector3((float(slot_x) - float(width - 1) * 0.5) * CELL_SIZE, 0, (float(slot_y) - float(height - 1) * 0.5) * CELL_SIZE)
			local_offset = local_offset.rotated(Vector3.UP, -support.rotation_steps * PI * 0.5)
			result.append(world_to_cell(support.position + local_offset) + offset)
		return result
	var cells := occupied_cells(definition, cell, rotation_steps)
	if cells.is_empty():
		return result
	var extreme := cells[0].y if offset.y != 0 else cells[0].x
	for occupied_cell: Vector2i in cells:
		var coordinate := occupied_cell.y if offset.y != 0 else occupied_cell.x
		if (offset.y > 0 or offset.x > 0) and coordinate > extreme:
			extreme = coordinate
		elif (offset.y < 0 or offset.x < 0) and coordinate < extreme:
			extreme = coordinate
	for occupied_cell: Vector2i in cells:
		var coordinate := occupied_cell.y if offset.y != 0 else occupied_cell.x
		if coordinate == extreme:
			result.append(occupied_cell + offset)
	return result


func _new_station_access_error(definition: Dictionary, cell: Vector2i, rotation_steps: int, support_uid: String = "", attachment_slot: int = -1) -> String:
	if attachment_slot < 0 and not support_uid.is_empty():
		for object: PlacedObject in placed_objects.values():
			if object.support_uid == support_uid and object.definition == definition:
				attachment_slot = object.attachment_slot
				break
	var candidates := station_access_cells(definition, cell, rotation_steps, support_uid, attachment_slot)
	for candidate: Vector2i in candidates:
		if not _station_front_connection_open(definition, candidate, rotation_steps):
			continue
		if not astar.is_in_boundsv(candidate) or astar.is_point_solid(candidate):
			continue
		if not _grid_path(entrance_cell, candidate).is_empty():
			return ""
	return "Il fronte operativo (%s) deve affacciarsi su una cella libera e raggiungibile" % station_front_name(rotation_steps)


func _station_front_connection_open(definition: Dictionary, candidate: Vector2i, rotation_steps: int) -> bool:
	if String(definition.get("placement", "cell")) == "wall_mount":
		return true
	return not _wall_blocks_step(candidate - _front_offset(rotation_steps), candidate)


func object_at_cell(cell: Vector2i) -> PlacedObject:
	var uid: String = occupancy.get(cell, "")
	return placed_objects.get(uid)


func _rebuild_astar() -> void:
	if astar.region.size == Vector2i.ZERO:
		return
	astar.fill_solid_region(astar.region, false)
	for cell: Vector2i in static_blocked:
		if astar.is_in_boundsv(cell):
			astar.set_point_solid(cell, true)
	for cell: Vector2i in occupancy:
		if astar.is_in_boundsv(cell):
			astar.set_point_solid(cell, true)
	astar.set_point_solid(entrance_cell, false)
	_blocked_edge_uids.clear()
	for object: PlacedObject in placed_objects.values():
		if is_instance_valid(object) and is_edge_placement(object.definition) and bool(object.definition.get("blocking", true)):
			_blocked_edge_uids[edge_key(object.grid_cell, object.rotation_steps)] = object.uid
	_grid_path_cache.clear()
	navigation_revision += 1
	for agent: AnimatedAgent in navigation_agents.duplicate():
		if not is_instance_valid(agent) or agent.is_queued_for_deletion() or not agent.is_collision_enabled():
			continue
		if not _agent_point_is_open(agent.global_position, agent.agent_radius * 0.72):
			agent.global_position = find_safe_agent_position(agent.global_position, agent)
			if agent.navigation_active:
				agent.call_deferred("_repath")


func _grid_path(from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if not astar.is_in_boundsv(from_cell) or not astar.is_in_boundsv(to_cell) or astar.is_point_solid(from_cell) or astar.is_point_solid(to_cell):
		return empty
	var cache_key := "%d,%d>%d,%d" % [from_cell.x, from_cell.y, to_cell.x, to_cell.y]
	if not _path_cache_suspended and _temporary_blocked_edge_keys.is_empty() and _validation_ignored_edge_uid.is_empty() and _grid_path_cache.has(cache_key):
		var cached: Array[Vector2i] = []
		cached.assign(_grid_path_cache[cache_key])
		return cached
	var frontier: Array[Vector2i] = [from_cell]
	var came_from: Dictionary = {from_cell: from_cell}
	var head := 0
	while head < frontier.size():
		var current := frontier[head]
		head += 1
		if current == to_cell:
			break
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor := current + offset
			if not astar.is_in_boundsv(neighbor) or astar.is_point_solid(neighbor) or came_from.has(neighbor) or _wall_blocks_step(current, neighbor):
				continue
			came_from[neighbor] = current
			frontier.append(neighbor)
	if not came_from.has(to_cell):
		if not _path_cache_suspended and _temporary_blocked_edge_keys.is_empty() and _validation_ignored_edge_uid.is_empty():
			_grid_path_cache[cache_key] = empty
		return empty
	var result: Array[Vector2i] = []
	var cursor := to_cell
	while cursor != from_cell:
		result.append(cursor)
		cursor = came_from[cursor]
	result.append(from_cell)
	result.reverse()
	if not _path_cache_suspended and _temporary_blocked_edge_keys.is_empty() and _validation_ignored_edge_uid.is_empty():
		_grid_path_cache[cache_key] = result.duplicate()
	return result


func _wall_blocks_step(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	var key := ""
	var delta := to_cell - from_cell
	if delta == Vector2i.UP:
		key = edge_key(from_cell, 0)
	elif delta == Vector2i.LEFT:
		key = edge_key(from_cell, 1)
	elif delta == Vector2i.DOWN:
		key = edge_key(from_cell, 2)
	elif delta == Vector2i.RIGHT:
		key = edge_key(from_cell, 3)
	if key.is_empty():
		return false
	if _temporary_blocked_edge_keys.has(key):
		return true
	var blocking_uid := String(_blocked_edge_uids.get(key, ""))
	return not blocking_uid.is_empty() and blocking_uid != _validation_ignored_edge_uid


func _traffic_grid_path(from_cell: Vector2i, to_cell: Vector2i, agent: AnimatedAgent) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if from_cell == to_cell:
		var same_cell: Array[Vector2i] = [from_cell]
		return same_cell
	var traffic := _traffic_cell_costs(agent)
	traffic.erase(from_cell)
	traffic.erase(to_cell)
	var frontier: Array[Vector2i] = [from_cell]
	var came_from: Dictionary = {from_cell: from_cell}
	var distance: Dictionary = {from_cell: 0.0}
	var closed: Dictionary = {}
	while not frontier.is_empty():
		var best_index := 0
		var best_score := INF
		for index: int in frontier.size():
			var candidate := frontier[index]
			var heuristic := absi(candidate.x - to_cell.x) + absi(candidate.y - to_cell.y)
			var score := float(distance.get(candidate, INF)) + float(heuristic)
			if score < best_score:
				best_score = score
				best_index = index
		var current := frontier[best_index]
		frontier.remove_at(best_index)
		if current == to_cell:
			break
		if closed.has(current):
			continue
		closed[current] = true
		var offsets: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
		if posmod(agent.get_instance_id(), 2) == 1:
			offsets.reverse()
		for offset: Vector2i in offsets:
			var neighbor := current + offset
			if not astar.is_in_boundsv(neighbor) or astar.is_point_solid(neighbor) or _wall_blocks_step(current, neighbor):
				continue
			var step_cost := 1.0 + float(traffic.get(neighbor, 0.0))
			if came_from.has(current):
				var previous := Vector2i(came_from[current])
				if current - previous != offset:
					step_cost += 0.08
			var proposed := float(distance[current]) + step_cost
			if proposed + 0.001 >= float(distance.get(neighbor, INF)):
				continue
			distance[neighbor] = proposed
			came_from[neighbor] = current
			if not frontier.has(neighbor):
				frontier.append(neighbor)
	if not came_from.has(to_cell):
		return empty
	var result: Array[Vector2i] = []
	var cursor := to_cell
	while cursor != from_cell:
		result.append(cursor)
		cursor = Vector2i(came_from[cursor])
	result.append(from_cell)
	result.reverse()
	return result


func _traffic_cell_costs(requesting_agent: AnimatedAgent) -> Dictionary:
	var costs: Dictionary = {}
	for key: String in corridor_reservations:
		if int(corridor_reservations.get(key, 0)) == requesting_agent.get_instance_id():
			continue
		for encoded_cell: String in key.split(";", false):
			var coordinates := encoded_cell.split(",", false)
			if coordinates.size() == 2:
				_add_traffic_cost(costs, Vector2i(int(coordinates[0]), int(coordinates[1])), 18.0)
	for other: AnimatedAgent in navigation_agents:
		if other == requesting_agent or not is_instance_valid(other) or other.is_queued_for_deletion() or not other.is_collision_enabled():
			continue
		for point: Vector3 in other.get_avoidance_points():
			_add_traffic_cost(costs, world_to_cell(point), 9.0)
			for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				_add_traffic_cost(costs, world_to_cell(point) + offset, 2.6)
		if other.navigation_active:
			_add_traffic_cost(costs, world_to_cell(other.destination), 4.5)
			for path_index: int in range(other.path_index, other.path.size()):
				_add_traffic_cost(costs, world_to_cell(other.path[path_index]), 1.15)
	return costs


func _add_traffic_cost(costs: Dictionary, cell: Vector2i, amount: float) -> void:
	if astar.is_in_boundsv(cell):
		costs[cell] = float(costs.get(cell, 0.0)) + amount


func find_path(from_world: Vector3, to_world: Vector3, agent: AnimatedAgent = null) -> PackedVector3Array:
	var from_cell := _nearest_open_cell(world_to_cell(from_world))
	var requested_cell := world_to_cell(to_world)
	var to_cell := _nearest_open_cell(requested_cell)
	var ids := _traffic_grid_path(from_cell, to_cell, agent) if agent != null else _grid_path(from_cell, to_cell)
	if ids.is_empty():
		to_cell = _nearest_reachable_cell(requested_cell, from_cell)
		ids = _traffic_grid_path(from_cell, to_cell, agent) if agent != null else _grid_path(from_cell, to_cell)
	var result := PackedVector3Array()
	if ids.is_empty():
		return result
	for id: Vector2i in ids:
		result.append(cell_to_world(id))
	var exact_target := Vector3(to_world.x, 0.0, to_world.z)
	if requested_cell == to_cell and result[result.size() - 1].distance_to(exact_target) > 0.12 and can_agent_move(result[result.size() - 1], exact_target, 0.25):
		result.append(exact_target)
	elif result[result.size() - 1].distance_to(exact_target) <= 0.12:
		result[result.size() - 1] = exact_target
	# The first grid node is the centre of the cell containing the agent.  It is
	# a graph implementation detail, not a place a moving character should be
	# forced to visit.  Skipping it when the next segment is clear prevents
	# workers already beside a station from walking away and immediately back.
	var actual_start := Vector3(from_world.x, 0.0, from_world.z)
	if result.size() > 1 and can_agent_move(actual_start, result[1], 0.25):
		result.remove_at(0)
	elif result.size() == 1 and can_agent_move(actual_start, result[0], 0.25) and actual_start.distance_to(result[0]) <= 0.12:
		result[0] = actual_start
	# Moving agents retain every grid cell. Besides making turns predictable in
	# tight kitchens, these waypoints let the corridor arbiter reserve the whole
	# one-person passage before an agent enters it.
	if agent == null:
		result = _simplify_world_path(result)
	if show_paths:
		_draw_debug_path(result)
	return result


func _nearest_reachable_cell(requested: Vector2i, from_cell: Vector2i) -> Vector2i:
	var best := from_cell
	var best_score := INF
	var distances := _reachable_cell_distances(from_cell)
	for radius: int in range(0, 7):
		for y: int in range(-radius, radius + 1):
			for x: int in range(-radius, radius + 1):
				if radius > 0 and absi(x) != radius and absi(y) != radius:
					continue
				var candidate := requested + Vector2i(x, y)
				if not astar.is_in_boundsv(candidate) or astar.is_point_solid(candidate):
					continue
				if not distances.has(candidate):
					continue
				var score := float(distances[candidate]) + candidate.distance_to(requested) * 2.0
				if score < best_score:
					best_score = score
					best = candidate
		if best_score < INF:
			break
	return best


func _reachable_cell_distances(from_cell: Vector2i) -> Dictionary:
	var distances: Dictionary = {}
	if not astar.is_in_boundsv(from_cell) or astar.is_point_solid(from_cell):
		return distances
	var frontier: Array[Vector2i] = [from_cell]
	distances[from_cell] = 0
	var head := 0
	while head < frontier.size():
		var current := frontier[head]
		head += 1
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor := current + offset
			if not astar.is_in_boundsv(neighbor) or astar.is_point_solid(neighbor) or distances.has(neighbor) or _wall_blocks_step(current, neighbor):
				continue
			distances[neighbor] = int(distances[current]) + 1
			frontier.append(neighbor)
	return distances


func _simplify_world_path(points: PackedVector3Array) -> PackedVector3Array:
	if points.size() <= 2:
		return points
	var result := PackedVector3Array([points[0]])
	for index: int in range(1, points.size() - 1):
		var previous_direction := Vector2(points[index].x - points[index - 1].x, points[index].z - points[index - 1].z).normalized()
		var next_direction := Vector2(points[index + 1].x - points[index].x, points[index + 1].z - points[index].z).normalized()
		if previous_direction.dot(next_direction) < 0.999:
			result.append(points[index])
	result.append(points[points.size() - 1])
	return result


func register_navigation_agent(agent: AnimatedAgent) -> void:
	if not navigation_agents.has(agent):
		navigation_agents.append(agent)


func unregister_navigation_agent(agent: AnimatedAgent) -> void:
	navigation_agents.erase(agent)
	release_waiting_position(agent)
	staff_standby_reservations.erase(agent.get_instance_id())
	_release_agent_corridor(agent)


func can_agent_advance_route(agent: AnimatedAgent, route: PackedVector3Array, route_index: int) -> bool:
	_cleanup_corridor_reservations()
	var requested_key := _upcoming_corridor_key(agent, route, route_index)
	var agent_id := agent.get_instance_id()
	var previous_key := String(agent_corridor_reservations.get(agent_id, ""))
	if requested_key.is_empty():
		if not previous_key.is_empty() and not _agent_is_inside_corridor(agent, previous_key):
			_release_agent_corridor(agent)
		return true
	if not previous_key.is_empty() and previous_key != requested_key and not _agent_is_inside_corridor(agent, previous_key):
		_release_agent_corridor(agent)
	var contenders: Array[AnimatedAgent] = []
	var inside: Array[AnimatedAgent] = []
	for other: AnimatedAgent in navigation_agents:
		if not is_instance_valid(other) or other.is_queued_for_deletion() or not other.is_collision_enabled():
			continue
		if _agent_is_inside_corridor(other, requested_key):
			inside.append(other)
			contenders.append(other)
		elif other.navigation_active and _upcoming_corridor_key(other, other.path, other.path_index) == requested_key:
			contenders.append(other)
	var candidates := inside if not inside.is_empty() else contenders
	if candidates.is_empty():
		candidates = [agent]
	var winner: AnimatedAgent = candidates[0]
	for candidate: AnimatedAgent in candidates:
		if candidate.navigation_priority < winner.navigation_priority or (candidate.navigation_priority == winner.navigation_priority and candidate.get_instance_id() < winner.get_instance_id()):
			winner = candidate
	var owner_id := int(corridor_reservations.get(requested_key, 0))
	var owner := instance_from_id(owner_id) as AnimatedAgent if owner_id != 0 else null
	if owner != null and is_instance_valid(owner) and _agent_is_inside_corridor(owner, requested_key):
		winner = owner
	if winner != agent:
		return false
	corridor_reservations[requested_key] = agent_id
	agent_corridor_reservations[agent_id] = requested_key
	return true


func _upcoming_corridor_key(agent: AnimatedAgent, route: PackedVector3Array, route_index: int) -> String:
	for point: Vector3 in agent.get_avoidance_points():
		var current_key := _corridor_key(world_to_cell(point))
		if not current_key.is_empty():
			return current_key
	for index: int in range(route_index, mini(route_index + 4, route.size())):
		var key := _corridor_key(world_to_cell(route[index]))
		if not key.is_empty():
			return key
	return ""


func _corridor_key(start: Vector2i) -> String:
	if not _is_narrow_corridor_cell(start):
		return ""
	var cells: Array[Vector2i] = [start]
	var visited: Dictionary = {start: true}
	var head := 0
	while head < cells.size():
		var current := cells[head]
		head += 1
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor := current + offset
			if visited.has(neighbor) or not _is_narrow_corridor_cell(neighbor) or _wall_blocks_step(current, neighbor):
				continue
			visited[neighbor] = true
			cells.append(neighbor)
	cells.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	var parts: PackedStringArray = []
	for cell: Vector2i in cells:
		parts.append("%d,%d" % [cell.x, cell.y])
	return ";".join(parts)


func _is_narrow_corridor_cell(cell: Vector2i) -> bool:
	return astar.is_in_boundsv(cell) and not astar.is_point_solid(cell) and _open_neighbor_count(cell) <= 2


func _agent_is_inside_corridor(agent: AnimatedAgent, key: String) -> bool:
	if key.is_empty():
		return false
	for point: Vector3 in agent.get_avoidance_points():
		if _corridor_key(world_to_cell(point)) == key:
			return true
	return false


func _release_agent_corridor(agent: AnimatedAgent) -> void:
	var agent_id := agent.get_instance_id()
	var key := String(agent_corridor_reservations.get(agent_id, ""))
	if not key.is_empty() and int(corridor_reservations.get(key, 0)) == agent_id:
		corridor_reservations.erase(key)
	agent_corridor_reservations.erase(agent_id)


func _cleanup_corridor_reservations() -> void:
	for key: String in corridor_reservations.keys():
		var owner_id := int(corridor_reservations.get(key, 0))
		var owner := instance_from_id(owner_id) as AnimatedAgent if owner_id != 0 else null
		if owner == null or not is_instance_valid(owner) or owner.is_queued_for_deletion():
			corridor_reservations.erase(key)
			agent_corridor_reservations.erase(owner_id)


func can_agent_move(from_position: Vector3, to_position: Vector3, radius: float = 0.34) -> bool:
	var distance := Vector2(from_position.x, from_position.z).distance_to(Vector2(to_position.x, to_position.z))
	var checks := maxi(ceili(distance / 0.18), 1)
	var previous_cell := world_to_cell(from_position)
	for index: int in range(1, checks + 1):
		var point := from_position.lerp(to_position, float(index) / float(checks))
		if not _agent_point_is_open(point, radius):
			return false
		var cell := world_to_cell(point)
		if cell != previous_cell:
			var horizontal := Vector2i(cell.x, previous_cell.y)
			if horizontal != previous_cell and _wall_blocks_step(previous_cell, horizontal):
				return false
			if cell != horizontal and _wall_blocks_step(horizontal, cell):
				return false
			previous_cell = cell
	return true


func can_agent_step(agent: AnimatedAgent, from_position: Vector3, to_position: Vector3) -> bool:
	if not can_agent_move(from_position, to_position, agent.agent_radius):
		return false
	var movement_delta := to_position - from_position
	var own_points := agent.get_avoidance_points()
	if own_points.is_empty():
		own_points.append(from_position)
	for other: AnimatedAgent in navigation_agents:
		if other == agent or not is_instance_valid(other) or other.is_queued_for_deletion() or not other.is_collision_enabled():
			continue
		var minimum := agent.agent_radius + other.agent_radius + 0.08
		for own_point: Vector3 in own_points:
			var candidate_point := own_point + movement_delta
			for other_point: Vector3 in other.get_avoidance_points():
				var current_distance := Vector2(own_point.x, own_point.z).distance_to(Vector2(other_point.x, other_point.z))
				var candidate_distance := Vector2(candidate_point.x, candidate_point.z).distance_to(Vector2(other_point.x, other_point.z))
				if candidate_distance < minimum and candidate_distance <= current_distance + 0.005:
					return false
	return true


func _agent_point_is_open(point: Vector3, radius: float) -> bool:
	var samples := [
		Vector2.ZERO,
		Vector2(radius, 0.0), Vector2(-radius, 0.0),
		Vector2(0.0, radius), Vector2(0.0, -radius),
		Vector2(radius * 0.7, radius * 0.7), Vector2(-radius * 0.7, radius * 0.7),
		Vector2(radius * 0.7, -radius * 0.7), Vector2(-radius * 0.7, -radius * 0.7)
	]
	for sample: Vector2 in samples:
		var cell := world_to_cell(Vector3(point.x + sample.x, 0.0, point.z + sample.y))
		if not astar.is_in_boundsv(cell) or astar.is_point_solid(cell):
			return false
	return true


func compute_agent_velocity(agent: AnimatedAgent, desired_velocity: Vector3) -> Vector3:
	if desired_velocity.length_squared() <= 0.0001:
		return Vector3.ZERO
	var result := desired_velocity
	for other: AnimatedAgent in navigation_agents.duplicate():
		if other == agent or not is_instance_valid(other) or other.is_queued_for_deletion() or not other.is_collision_enabled():
			continue
		var offset := Vector3.ZERO
		var distance := INF
		for own_point: Vector3 in agent.get_avoidance_points():
			for other_point: Vector3 in other.get_avoidance_points():
				var candidate := own_point - other_point
				candidate.y = 0.0
				if candidate.length() < distance:
					distance = candidate.length()
					offset = candidate
		if distance == INF:
			continue
		var separation := agent.agent_radius + other.agent_radius + 0.14
		if distance > separation * 3.2:
			continue
		var away := offset.normalized() if distance > 0.01 else Vector3.RIGHT.rotated(Vector3.UP, float(agent.get_instance_id() % 4) * PI * 0.5)
		if agent is EmployeeAgent and other is CustomerAgent and String(other.get("state")) in ["walking_to_table", "retrying_table_route", "seating"]:
			result += away * agent.movement_speed * 1.8
		if distance < separation * 1.35:
			result += away * agent.movement_speed * (separation * 1.35 - distance) / maxf(separation, 0.01) * 2.2
		var desired_direction := desired_velocity.normalized()
		var toward_other := -away
		if desired_direction.dot(toward_other) > 0.45 and distance < separation * 2.8:
			var side_sign := -1.0 if agent.get_instance_id() < other.get_instance_id() else 1.0
			var passing_side := Vector3(desired_direction.z, 0.0, -desired_direction.x) * side_sign
			result += passing_side * agent.movement_speed * 0.82
			var agent_yields := agent.navigation_priority > other.navigation_priority or (agent.navigation_priority == other.navigation_priority and agent.get_instance_id() > other.get_instance_id())
			if agent_yields or not other.navigation_active:
				result *= 0.42
	return result.limit_length(agent.movement_speed)


func find_safe_agent_position(preferred: Vector3, agent: AnimatedAgent = null) -> Vector3:
	var preferred_cell := _nearest_open_cell(world_to_cell(preferred))
	var candidates: Array[Vector2i] = [preferred_cell]
	var own_offsets: Array[Vector3] = [Vector3.ZERO]
	if agent != null:
		var own_points := agent.get_avoidance_points()
		if not own_points.is_empty():
			own_offsets.clear()
			for own_point: Vector3 in own_points:
				own_offsets.append(own_point - agent.global_position)
	for radius: int in range(1, 7):
		for y: int in range(-radius, radius + 1):
			for x: int in range(-radius, radius + 1):
				if absi(x) != radius and absi(y) != radius:
					continue
				candidates.append(preferred_cell + Vector2i(x, y))
	for cell: Vector2i in candidates:
		if not astar.is_in_boundsv(cell) or astar.is_point_solid(cell):
			continue
		var position := cell_to_world(cell)
		var free := true
		for own_offset: Vector3 in own_offsets:
			if not _agent_point_is_open(position + own_offset, (agent.agent_radius if agent != null else 0.34) * 0.72):
				free = false
				break
		if not free:
			continue
		for other: AnimatedAgent in navigation_agents:
			if other == agent or not is_instance_valid(other) or not other.is_collision_enabled():
				continue
			var required := (agent.agent_radius if agent != null else 0.34) + other.agent_radius + 0.18
			for own_offset: Vector3 in own_offsets:
				for other_point: Vector3 in other.get_avoidance_points():
					var own_position := position + own_offset
					if Vector2(own_position.x, own_position.z).distance_to(Vector2(other_point.x, other_point.z)) < required:
						free = false
						break
				if not free:
					break
			if not free:
				break
		if free:
			return position
	return cell_to_world(preferred_cell)


func staff_standby_position(agent: AnimatedAgent, role: String, force_refresh: bool = false) -> Vector3:
	var key := agent.get_instance_id()
	if force_refresh:
		staff_standby_reservations.erase(key)
	if staff_standby_reservations.has(key):
		var reserved_cell := Vector2i(staff_standby_reservations[key])
		if astar.is_in_boundsv(reserved_cell) and not astar.is_point_solid(reserved_cell):
			return cell_to_world(reserved_cell)
		staff_standby_reservations.erase(key)
	var service_cells := _staff_service_cells()
	var best_cell := _nearest_open_cell(world_to_cell(agent.global_position))
	var best_score := INF
	# First prefer open room cells. If the player's layout is extremely dense,
	# allow a two-neighbour cell but never a one-cell doorway/dead end.
	for minimum_neighbors: int in [3, 2]:
		for y: int in GRID_SIZE.y:
			for x: int in GRID_SIZE.x:
				var cell := Vector2i(x, y)
				if astar.is_point_solid(cell) or _open_neighbor_count(cell) < minimum_neighbors:
					continue
				if cell.distance_to(entrance_cell) < 3.0 or _grid_path(world_to_cell(agent.global_position), cell).is_empty():
					continue
				var too_close_to_work := false
				for service_cell: Vector2i in service_cells:
					if cell.distance_to(service_cell) <= 1.15:
						too_close_to_work = true
						break
				if too_close_to_work:
					continue
				var reserved := false
				for other_key: int in staff_standby_reservations:
					if other_key != key and cell.distance_to(Vector2i(staff_standby_reservations[other_key])) < 1.5:
						reserved = true
						break
				if reserved:
					continue
				var zone_y := 5.0 if role == "waiter" else 11.0
				var wrong_zone := (role == "waiter" and y >= 8) or (role != "waiter" and y < 8)
				var score := absf(float(y) - zone_y) * 2.0 + cell.distance_to(world_to_cell(agent.global_position)) * 0.12
				if wrong_zone:
					score += 30.0
				# Stable per-worker horizontal preference spreads the brigade instead
				# of selecting the first equally good tile for everyone.
				var preferred_x := 2 + posmod(String(agent.name).hash(), GRID_SIZE.x - 4)
				score += absf(float(x - preferred_x)) * 0.18
				if score < best_score:
					best_score = score
					best_cell = cell
		if best_score < INF:
			break
	staff_standby_reservations[key] = best_cell
	return cell_to_world(best_cell)


func _staff_service_cells() -> Array[Vector2i]:
	var result: Array[Vector2i] = [entrance_cell]
	for slot: Vector2i in [Vector2i(8, 1), Vector2i(7, 2), Vector2i(9, 2), Vector2i(6, 2), Vector2i(10, 2), Vector2i(8, 2)]:
		if not result.has(slot):
			result.append(slot)
	for object: PlacedObject in placed_objects.values():
		if not is_instance_valid(object):
			continue
		if not object.station_id.is_empty():
			for cell: Vector2i in station_access_cells(object.definition, object.grid_cell, object.rotation_steps, object.support_uid, object.attachment_slot):
				if not result.has(cell):
					result.append(cell)
		if String(object.definition.get("support_kind", "")) == "dining_table":
			for position: Vector3 in _table_access_positions(object):
				var cell := world_to_cell(position)
				if not result.has(cell):
					result.append(cell)
	return result


func _open_neighbor_count(cell: Vector2i) -> int:
	var count := 0
	for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var neighbor := cell + offset
		if astar.is_in_boundsv(neighbor) and not astar.is_point_solid(neighbor) and not _wall_blocks_step(cell, neighbor):
			count += 1
	return count


func is_work_position_available(position: Vector3, employee_id: String) -> bool:
	# A station reservation is not enough: the previous worker may still be
	# physically leaving, or another station can expose the same access cell.
	for other: AnimatedAgent in navigation_agents:
		if not (other is EmployeeAgent) or not is_instance_valid(other) or other.is_queued_for_deletion():
			continue
		var worker := other as EmployeeAgent
		if String(worker.employee.get("id", "")) == employee_id:
			continue
		var required := worker.agent_radius + 0.48
		for other_point: Vector3 in worker.get_avoidance_points():
			if Vector2(position.x, position.z).distance_to(Vector2(other_point.x, other_point.z)) < required:
				return false
		if worker.navigation_active and Vector2(position.x, position.z).distance_to(Vector2(worker.destination.x, worker.destination.z)) < required:
			return false
	return true


func can_visual_person_step(owner: AnimatedAgent, from_position: Vector3, to_position: Vector3, radius: float) -> bool:
	if not _agent_point_is_open(to_position, radius * 0.72):
		return false
	var skipped_self := false
	for sibling_point: Vector3 in owner.get_avoidance_points():
		if not skipped_self and sibling_point.distance_to(from_position) < 0.015:
			skipped_self = true
			continue
		var sibling_required := radius * 2.0 + 0.05
		var sibling_current := Vector2(from_position.x, from_position.z).distance_to(Vector2(sibling_point.x, sibling_point.z))
		var sibling_candidate := Vector2(to_position.x, to_position.z).distance_to(Vector2(sibling_point.x, sibling_point.z))
		if sibling_candidate < sibling_required and sibling_candidate <= sibling_current + 0.004:
			return false
	for other: AnimatedAgent in navigation_agents:
		if other == owner or not is_instance_valid(other) or other.is_queued_for_deletion() or not other.is_collision_enabled():
			continue
		var required := radius + other.agent_radius + 0.06
		for other_point: Vector3 in other.get_avoidance_points():
			var current_distance := Vector2(from_position.x, from_position.z).distance_to(Vector2(other_point.x, other_point.z))
			var candidate_distance := Vector2(to_position.x, to_position.z).distance_to(Vector2(other_point.x, other_point.z))
			if candidate_distance < required and candidate_distance <= current_distance + 0.004:
				return false
	return true


func _nearest_open_cell(cell: Vector2i) -> Vector2i:
	cell.x = clampi(cell.x, 0, GRID_SIZE.x - 1)
	cell.y = clampi(cell.y, 0, GRID_SIZE.y - 1)
	if not astar.is_point_solid(cell):
		return cell
	for radius: int in range(1, 5):
		for y: int in range(-radius, radius + 1):
			for x: int in range(-radius, radius + 1):
				var candidate := cell + Vector2i(x, y)
				if astar.is_in_boundsv(candidate) and not astar.is_point_solid(candidate):
					return candidate
	return entrance_cell


func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3((cell.x - GRID_SIZE.x * 0.5 + 0.5) * CELL_SIZE, 0, (cell.y - GRID_SIZE.y * 0.5 + 0.5) * CELL_SIZE)


func world_to_cell(value: Vector3) -> Vector2i:
	return Vector2i(roundi(value.x / CELL_SIZE + GRID_SIZE.x * 0.5 - 0.5), roundi(value.z / CELL_SIZE + GRID_SIZE.y * 0.5 - 0.5))


func spawn_staff() -> void:
	for child: Node in get_tree().get_nodes_in_group("staff_agent"):
		if child is AnimatedAgent:
			(child as AnimatedAgent).shutdown_navigation()
		child.queue_free()
	staff_agents.clear()
	var spawn_cells := [Vector2i(7, 10), Vector2i(9, 10), Vector2i(12, 10), Vector2i(7, 5), Vector2i(10, 5), Vector2i(14, 10), Vector2i(5, 10)]
	for index: int in GameState.employees.size():
		if index >= 8:
			break
		var agent := EmployeeAgent.new()
		agent.add_to_group("staff_agent")
		add_child(agent)
		agent.global_position = find_safe_agent_position(cell_to_world(spawn_cells[index % spawn_cells.size()]), agent)
		agent.setup(GameState.employees[index], self)
		agent.global_position = find_safe_agent_position(agent.global_position, agent)
		staff_agents[String(GameState.employees[index].id)] = agent


func spawn_customer_group() -> void:
	if GameState.restaurant_state != "open":
		return
	var customer := CustomerAgent.new()
	customer_root.add_child(customer)
	customer.global_position = find_safe_agent_position(cell_to_world(entrance_cell), customer)
	customer.setup(self, _random_customer_group_size())


func _random_customer_group_size() -> int:
	# Parties of one or two are the norm; larger groups remain special events
	# instead of filling the room with four-character blocks every few seconds.
	var roll := randf()
	if roll < 0.34:
		return 1
	if roll < 0.76:
		return 2
	if roll < 0.93:
		return 3
	return 4


func request_table(customer: Node, group_size: int) -> Dictionary:
	var candidates: Array[Dictionary] = []
	for uid: String in table_occupants:
		if table_occupants[uid] != null and not is_instance_valid(table_occupants[uid]):
			table_occupants[uid] = null
		if table_occupants[uid] != null:
			continue
		var table_object: PlacedObject = placed_objects.get(uid)
		if table_object == null or not is_instance_valid(table_object):
			continue
		var seat_assignments := _seat_assignments_for_table(table_object)
		var capacity := seat_assignments.size()
		if capacity < group_size:
			continue
		var access_positions := _table_access_positions(table_object)
		if access_positions.is_empty():
			continue
		var approach: Vector3 = access_positions[0]
		var best_distance := INF
		var customer_position := Vector3(customer.global_position)
		for position: Vector3 in access_positions:
			var route := find_path(customer_position, position)
			if route.is_empty():
				continue
			var distance: float = customer_position.distance_to(position)
			if distance < best_distance:
				best_distance = distance
				approach = position
		if best_distance == INF:
			continue
		candidates.append({
			"uid": uid,
			"object": table_object,
			"seats": seat_assignments,
			"capacity": capacity,
			"approach": approach,
			"score": float(capacity - group_size) * 4.0 + best_distance
		})
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a: Dictionary, b: Dictionary): return float(a.score) < float(b.score))
	var chosen: Dictionary = candidates[0]
	table_occupants[String(chosen.uid)] = customer
	var table_object: PlacedObject = chosen.object
	var chosen_seats: Array = (chosen.seats as Array).slice(0, group_size)
	var seat_positions: Array[Vector3] = []
	for seat: Dictionary in chosen_seats:
		seat_positions.append(Vector3(seat.position))
	var table_bounds := ModelFactory.calculate_visual_bounds(table_object.visual_model, true)
	return {
		"uid": String(chosen.uid),
		"seat_position": Vector3(chosen.approach),
		"approach_position": Vector3(chosen.approach),
		"seat_positions": seat_positions,
		"seat_assignments": chosen_seats,
		"table_center": table_object.global_position,
		"table_surface_y": table_object.global_position.y + table_bounds.end.y + 0.035,
		"service_position": Vector3(chosen.approach),
		"capacity": int(chosen.capacity)
	}


func customer_owns_table(customer: Node, table_uid: String) -> bool:
	return not table_uid.is_empty() and table_occupants.get(table_uid) == customer and is_instance_valid(placed_objects.get(table_uid))


func release_table(customer: Node) -> void:
	for uid: String in table_occupants:
		if table_occupants[uid] == customer:
			table_occupants[uid] = null
	release_waiting_position(customer)


func set_rush_mode(enabled: bool) -> void:
	rush_mode = enabled
	if enabled:
		_spawn_clock = 0.0


func waiting_position(customer: Node) -> Vector3:
	var key := customer.get_instance_id()
	if waiting_reservations.has(key):
		return Vector3(waiting_reservations[key])
	var slots := [Vector2i(8, 1), Vector2i(7, 2), Vector2i(9, 2), Vector2i(6, 2), Vector2i(10, 2), Vector2i(8, 2)]
	for slot: Vector2i in slots:
		if not astar.is_in_boundsv(slot) or astar.is_point_solid(slot):
			continue
		var position := cell_to_world(slot)
		var reserved := false
		for existing: Vector3 in waiting_reservations.values():
			if existing.distance_to(position) < 0.5:
				reserved = true
				break
		if not reserved and not find_path(customer.global_position, position).is_empty():
			waiting_reservations[key] = position
			return position
	var fallback := find_safe_agent_position(cell_to_world(entrance_cell), customer as AnimatedAgent)
	waiting_reservations[key] = fallback
	return fallback


func release_waiting_position(customer: Node) -> void:
	if customer != null:
		waiting_reservations.erase(customer.get_instance_id())


func _seat_positions_for_table(table_object: PlacedObject) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for assignment: Dictionary in _seat_assignments_for_table(table_object):
		result.append(Vector3(assignment.position))
	return result


func _seat_assignments_for_table(table_object: PlacedObject) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var candidates: Array[PlacedObject] = []
	for object: PlacedObject in placed_objects.values():
		if object.item_id not in ["chair", "stool"]:
			continue
		if object.support_uid != table_object.uid or object.attachment_slot < 0 or object.attachment_slot > 3:
			continue
		if object.rotation_steps != seat_rotation_for_slot(object.attachment_slot, table_object.rotation_steps):
			continue
		candidates.append(object)
	candidates.sort_custom(func(a: PlacedObject, b: PlacedObject): return a.attachment_slot < b.attachment_slot)
	for chair: PlacedObject in candidates:
		var occupant_position := chair.global_position
		var toward_table := chair.global_position.direction_to(table_object.global_position)
		occupant_position += toward_table * float(table_object.definition.get("occupant_inset", 0.0))
		result.append({
			"chair_uid": chair.uid,
			"slot": chair.attachment_slot,
			"chair_position": chair.global_position,
			"position": occupant_position,
			"rotation": chair.rotation.y
		})
	return result


func _table_access_positions(table_object: PlacedObject) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var seen: Dictionary = {}
	for table_cell: Vector2i in occupied_cells(table_object.definition, table_object.grid_cell, table_object.rotation_steps):
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var candidate := table_cell + offset
			if seen.has(candidate) or not astar.is_in_boundsv(candidate) or astar.is_point_solid(candidate) or _wall_blocks_step(table_cell, candidate):
				continue
			seen[candidate] = true
			if not _grid_path(entrance_cell, candidate).is_empty():
				result.append(cell_to_world(candidate))
	result.sort_custom(func(a: Vector3, b: Vector3): return a.distance_to(table_object.global_position) < b.distance_to(table_object.global_position))
	return result


func _service_position_for_table(table_object: PlacedObject) -> Vector3:
	var positions := _table_access_positions(table_object)
	if not positions.is_empty():
		return positions[0]
	return table_object.global_position + Vector3(-CELL_SIZE, 0, 0)


func set_floor_style(cell: Vector2i, item_id: String) -> void:
	if not Rect2i(Vector2i.ZERO, GRID_SIZE).has_point(cell) or floor_root == null:
		return
	floor_tiles[cell] = item_id
	if not _loading_layout:
		_rebuild_floor_batches()


func _rebuild_floor_batches() -> void:
	if floor_root == null:
		return
	for child: Node in floor_root.get_children():
		child.queue_free()
	floor_batches.clear()
	var cells_by_style: Dictionary = {}
	for cell: Vector2i in floor_tiles:
		var style := String(floor_tiles[cell])
		if not cells_by_style.has(style):
			cells_by_style[style] = []
		cells_by_style[style].append(cell)
	for style: String in cells_by_style:
		var path := "res://assets/environment/floor_kitchen.gltf" if style == "floor_kitchen" else "res://assets/environment/floor_kitchen_styleB.gltf"
		var source := ModelFactory.instantiate_model(path)
		var mesh_data: Dictionary = {}
		_find_first_floor_mesh(source, Transform3D.IDENTITY, mesh_data)
		if mesh_data.is_empty():
			source.free()
			continue
		var cells: Array = cells_by_style[style]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh_data.mesh
		multimesh.instance_count = cells.size()
		var mesh_transform: Transform3D = mesh_data.transform
		for index: int in cells.size():
			var cell: Vector2i = cells[index]
			var tile_transform := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.5), cell_to_world(cell))
			multimesh.set_instance_transform(index, tile_transform * mesh_transform)
		var batch := MultiMeshInstance3D.new()
		batch.name = "FloorBatch_%s" % style
		batch.multimesh = multimesh
		batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		floor_root.add_child(batch)
		floor_batches[style] = batch
		source.free()


func _find_first_floor_mesh(node: Node, parent_transform: Transform3D, result: Dictionary) -> void:
	if not result.is_empty():
		return
	var current_transform := parent_transform
	if node is Node3D:
		current_transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		result.mesh = (node as MeshInstance3D).mesh
		result.transform = current_transform
		return
	for child: Node in node.get_children():
		_find_first_floor_mesh(child, current_transform, result)
		if not result.is_empty():
			return


func _create_grid_overlay() -> void:
	grid_overlay = MeshInstance3D.new()
	grid_overlay.name = "BuildGrid"
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.1, 0.55, 0.62, 0.34)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var left := cell_to_world(Vector2i(0, 0)).x - CELL_SIZE * 0.5
	var right := cell_to_world(Vector2i(GRID_SIZE.x - 1, 0)).x + CELL_SIZE * 0.5
	var top := cell_to_world(Vector2i(0, 0)).z - CELL_SIZE * 0.5
	var bottom := cell_to_world(Vector2i(0, GRID_SIZE.y - 1)).z + CELL_SIZE * 0.5
	for x: int in range(GRID_SIZE.x + 1):
		var world_x := left + x * CELL_SIZE
		mesh.surface_add_vertex(Vector3(world_x, 0.09, top))
		mesh.surface_add_vertex(Vector3(world_x, 0.09, bottom))
	for y: int in range(GRID_SIZE.y + 1):
		var world_z := top + y * CELL_SIZE
		mesh.surface_add_vertex(Vector3(left, 0.09, world_z))
		mesh.surface_add_vertex(Vector3(right, 0.09, world_z))
	mesh.surface_end()
	grid_overlay.mesh = mesh
	grid_overlay.visible = false
	add_child(grid_overlay)


func set_grid_visible(value: bool) -> void:
	if grid_overlay:
		grid_overlay.visible = value


func toggle_debug_grid() -> void:
	show_grid = not show_grid
	set_grid_visible(show_grid or (build_system != null and build_system.active))


func toggle_debug_paths() -> void:
	show_paths = not show_paths
	if not show_paths:
		_clear_debug_paths()


func toggle_station_queue_labels() -> void:
	show_station_queues = not show_station_queues
	if show_station_queues:
		_update_station_queue_labels()
	else:
		for label: Label3D in _queue_labels.values():
			if is_instance_valid(label):
				label.queue_free()
		_queue_labels.clear()


func _draw_debug_path(path: PackedVector3Array) -> void:
	if debug_paths_root == null or path.size() < 2:
		return
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("ffb13bee")
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for index: int in range(path.size() - 1):
		mesh.surface_add_vertex(path[index] + Vector3.UP * 0.18)
		mesh.surface_add_vertex(path[index + 1] + Vector3.UP * 0.18)
	mesh.surface_end()
	var line := MeshInstance3D.new()
	line.mesh = mesh
	debug_paths_root.add_child(line)
	while debug_paths_root.get_child_count() > 24:
		var oldest := debug_paths_root.get_child(0)
		debug_paths_root.remove_child(oldest)
		oldest.queue_free()


func _clear_debug_paths() -> void:
	if debug_paths_root == null:
		return
	for child: Node in debug_paths_root.get_children():
		debug_paths_root.remove_child(child)
		child.queue_free()


func _update_station_queue_labels() -> void:
	var metrics: Dictionary = {}
	for metric: Dictionary in SimulationManager.station_metrics():
		metrics[String(metric.id)] = metric
	var active_uids: Dictionary = {}
	for object: PlacedObject in placed_objects.values():
		if object.station_id.is_empty():
			continue
		active_uids[object.uid] = true
		var label: Label3D = _queue_labels.get(object.uid)
		if label == null or not is_instance_valid(label):
			label = Label3D.new()
			label.font = GameFonts.semibold()
			label.position = Vector3(0, 2.7, 0)
			label.font_size = 18
			label.outline_size = 7
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			object.add_child(label)
			_queue_labels[object.uid] = label
		var metric: Dictionary = metrics.get(object.station_id, {})
		label.text = "%s\nCODA %d · %d/%d" % [object.station_id.capitalize(), int(metric.get("queue", 0)), int(metric.get("busy", 0)), int(metric.get("capacity", 0))]
		label.modulate = Color("ff8f78") if int(metric.get("queue", 0)) > 0 else Color("a9f3c1")
	for uid: String in _queue_labels.keys():
		if not active_uids.has(uid):
			var stale: Label3D = _queue_labels[uid]
			if is_instance_valid(stale):
				stale.queue_free()
			_queue_labels.erase(uid)
