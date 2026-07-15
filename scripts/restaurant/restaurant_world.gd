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
var grid_overlay: MeshInstance3D
var debug_paths_root: Node3D
var _queue_labels: Dictionary = {}
var _debug_refresh_clock := 0.0
var _temporary_blocked_edge_keys: Dictionary = {}
var _validation_ignored_edge_uid := ""


func _ready() -> void:
	name = "RestaurantWorld"
	_create_environment()
	_create_roots()
	_create_grid()
	_create_floor_and_walls()
	load_layout()
	spawn_staff()
	SimulationManager.bind_world(self)


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
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 55.0
	add_child(sun)


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
	for y: int in GRID_SIZE.y:
		for x: int in GRID_SIZE.x:
			set_floor_style(Vector2i(x, y), "floor_dining" if y < 8 else "floor_kitchen")
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
	if not support_uid.is_empty():
		var support := placed_objects.get(support_uid) as PlacedObject
		if support != null and is_instance_valid(support):
			return attachment_world_position(definition, support, attachment_slot)
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


func attachment_world_position(definition: Dictionary, support: PlacedObject, attachment_slot: int) -> Vector3:
	var placement := String(definition.get("placement", "cell"))
	if placement == "seat":
		var directions := [Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)]
		var offset := directions[posmod(attachment_slot, 4)] * float(support.definition.get("seat_offset", 1.35))
		return support.position + offset.rotated(Vector3.UP, -support.rotation_steps * PI * 0.5)
	if placement == "surface":
		var raw: Array = support.definition.get("footprint", [1, 1])
		var width := maxi(int(raw[0]), 1)
		var height := maxi(int(raw[1]), 1)
		var slot := clampi(attachment_slot, 0, width * height - 1)
		var slot_x := slot % width
		var slot_y := slot / width
		var local_offset := Vector3((float(slot_x) - float(width - 1) * 0.5) * CELL_SIZE, 0, (float(slot_y) - float(height - 1) * 0.5) * CELL_SIZE)
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
	return posmod([2, 1, 0, 3][posmod(attachment_slot, 4)] + table_rotation, 4)


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
		slot = slot_y * width + slot_x
	return {"cell": best_support.grid_cell, "rotation": rotation, "support_uid": best_support.uid, "attachment_slot": slot}


func attachment_occupant_at(support_uid: String, attachment_slot: int, ignored: PlacedObject = null) -> PlacedObject:
	for object: PlacedObject in placed_objects.values():
		if object != ignored and is_instance_valid(object) and object.support_uid == support_uid and object.attachment_slot == attachment_slot:
			return object
	return null


func _refresh_all_attachments() -> void:
	for object: PlacedObject in placed_objects.values():
		_refresh_attachment(object)


func _refresh_attachment(object: PlacedObject) -> void:
	if object == null or object.support_uid.is_empty():
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
	object.position = attachment_world_position(object.definition, support, object.attachment_slot)


func attachment_interaction_position(object: PlacedObject) -> Vector3:
	var support := placed_objects.get(object.support_uid) as PlacedObject
	if support == null or not is_instance_valid(support):
		return object.global_position
	var distance := CELL_SIZE * 1.05
	if String(object.definition.get("placement", "cell")) == "wall_mount":
		distance = CELL_SIZE * 0.72
	return object.global_transform * Vector3(0, 0, distance)


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
		if attachment_occupant_at(support.uid, attachment_slot, ignored) != null:
			return {"valid": false, "reason": "Questo punto di aggancio è già occupato"}
		if placement == "seat" and rotation_steps != seat_rotation_for_slot(attachment_slot, support.rotation_steps):
			return {"valid": false, "reason": "La sedia deve essere rivolta verso il tavolo"}
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
		if is_edge_placement(definition):
			_temporary_blocked_edge_keys[edge_key(cell, rotation_steps)] = true
			_validation_ignored_edge_uid = ignored.uid if ignored != null else ""
		else:
			for occupied_cell: Vector2i in cells:
				astar.set_point_solid(occupied_cell, true)
		var access_error := _operational_access_error(definition, cells, ignored)
		if is_edge_placement(definition):
			_temporary_blocked_edge_keys.erase(edge_key(cell, rotation_steps))
			_validation_ignored_edge_uid = ""
		else:
			for occupied_cell: Vector2i in cells:
				astar.set_point_solid(occupied_cell, static_blocked.has(occupied_cell) or occupancy.has(occupied_cell))
		if not access_error.is_empty():
			return {"valid": false, "reason": access_error}
	return {"valid": true, "reason": "Posizionamento valido"}


func _operational_access_error(new_definition: Dictionary, new_cells: Array[Vector2i], ignored: PlacedObject) -> String:
	if _grid_path(entrance_cell, _nearest_open_cell(Vector2i(9, 8))).is_empty():
		return "Bloccherebbe il passaggio tra ingresso e cucina"
	for object: PlacedObject in placed_objects.values():
		if object == ignored or not is_instance_valid(object):
			continue
		if object.station_id.is_empty() and not object.item_id.begins_with("table"):
			continue
		var target_position := object.get_interaction_position() if not object.station_id.is_empty() else _service_position_for_table(object)
		var target_cell := _nearest_open_cell(world_to_cell(target_position))
		if _grid_path(entrance_cell, target_cell).is_empty():
			return "Bloccherebbe l'accesso a %s" % object.definition.name
	var new_id := String(new_definition.get("id", ""))
	if not String(new_definition.get("station", "")).is_empty() or new_id.begins_with("table"):
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
	return ""


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


func _grid_path(from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if not astar.is_in_boundsv(from_cell) or not astar.is_in_boundsv(to_cell) or astar.is_point_solid(from_cell) or astar.is_point_solid(to_cell):
		return empty
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
		return empty
	var result: Array[Vector2i] = []
	var cursor := to_cell
	while cursor != from_cell:
		result.append(cursor)
		cursor = came_from[cursor]
	result.append(from_cell)
	result.reverse()
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
	for object: PlacedObject in placed_objects.values():
		if not is_instance_valid(object) or object.uid == _validation_ignored_edge_uid or not is_edge_placement(object.definition) or not bool(object.definition.get("blocking", true)):
			continue
		if edge_key(object.grid_cell, object.rotation_steps) == key:
			return true
	return false


func find_path(from_world: Vector3, to_world: Vector3) -> PackedVector3Array:
	var from_cell := _nearest_open_cell(world_to_cell(from_world))
	var to_cell := _nearest_open_cell(world_to_cell(to_world))
	var ids := _grid_path(from_cell, to_cell)
	var result := PackedVector3Array()
	for id: Vector2i in ids:
		result.append(cell_to_world(id))
	if result.is_empty() or result[result.size() - 1].distance_to(to_world) > 0.2:
		result.append(Vector3(to_world.x, 0, to_world.z))
	if show_paths:
		_draw_debug_path(result)
	return result


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
		child.queue_free()
	staff_agents.clear()
	var spawn_cells := [Vector2i(7, 10), Vector2i(9, 10), Vector2i(12, 10), Vector2i(7, 5), Vector2i(10, 5), Vector2i(14, 10), Vector2i(5, 10)]
	for index: int in GameState.employees.size():
		if index >= 8:
			break
		var agent := EmployeeAgent.new()
		agent.add_to_group("staff_agent")
		add_child(agent)
		agent.global_position = cell_to_world(spawn_cells[index % spawn_cells.size()])
		agent.setup(GameState.employees[index], self)
		staff_agents[String(GameState.employees[index].id)] = agent


func spawn_customer_group() -> void:
	if GameState.restaurant_state != "open":
		return
	var customer := CustomerAgent.new()
	customer_root.add_child(customer)
	customer.global_position = cell_to_world(entrance_cell)
	customer.setup(self, randi_range(1, 4))


func request_table(customer: Node, group_size: int) -> Dictionary:
	for uid: String in table_occupants:
		if table_occupants[uid] != null:
			continue
		var table_object: PlacedObject = placed_objects.get(uid)
		if table_object == null:
			continue
		var seats := _seat_positions_for_table(table_object)
		var capacity := seats.size()
		if capacity < group_size:
			continue
		table_occupants[uid] = customer
		var base := table_object.global_position
		return {"uid": uid, "seat_position": seats[0], "seat_positions": seats.slice(0, group_size), "table_center": base, "service_position": _service_position_for_table(table_object), "capacity": capacity}
	return {}


func release_table(customer: Node) -> void:
	for uid: String in table_occupants:
		if table_occupants[uid] == customer:
			table_occupants[uid] = null


func set_rush_mode(enabled: bool) -> void:
	rush_mode = enabled
	if enabled:
		_spawn_clock = 0.0


func waiting_position(customer: Node) -> Vector3:
	var index := maxi(SimulationManager.customers.find(customer), 0)
	var slots := [Vector2i(7, 2), Vector2i(9, 2), Vector2i(6, 2), Vector2i(10, 2), Vector2i(8, 1)]
	return cell_to_world(slots[index % slots.size()])


func _seat_positions_for_table(table_object: PlacedObject) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var table_cells := occupied_cells(table_object.definition, table_object.grid_cell, table_object.rotation_steps)
	for object: PlacedObject in placed_objects.values():
		if object.item_id not in ["chair", "stool"]:
			continue
		var nearest := 999
		for table_cell: Vector2i in table_cells:
			nearest = mini(nearest, absi(object.grid_cell.x - table_cell.x) + absi(object.grid_cell.y - table_cell.y))
		if nearest == 1:
			result.append(object.global_position)
	result.sort_custom(func(a: Vector3, b: Vector3): return a.angle_to(Vector3.FORWARD) < b.angle_to(Vector3.FORWARD))
	return result


func _service_position_for_table(table_object: PlacedObject) -> Vector3:
	var cells := occupied_cells(table_object.definition, table_object.grid_cell, table_object.rotation_steps)
	for cell: Vector2i in cells:
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var candidate := cell + offset
			if astar.is_in_boundsv(candidate) and not astar.is_point_solid(candidate):
				return cell_to_world(candidate)
	return table_object.global_position + Vector3(-CELL_SIZE, 0, 0)


func set_floor_style(cell: Vector2i, item_id: String) -> void:
	if not Rect2i(Vector2i.ZERO, GRID_SIZE).has_point(cell) or floor_root == null:
		return
	if floor_tiles.has(cell) and is_instance_valid(floor_tiles[cell]):
		floor_tiles[cell].queue_free()
	var path := "res://assets/environment/floor_kitchen.gltf" if item_id == "floor_kitchen" else "res://assets/environment/floor_kitchen_styleB.gltf"
	var tile := ModelFactory.instantiate_model(path)
	tile.scale = Vector3.ONE * 0.5
	tile.position = cell_to_world(cell)
	floor_root.add_child(tile)
	floor_tiles[cell] = tile


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
