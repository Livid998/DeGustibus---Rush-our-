class_name RestaurantWorld
extends Node3D

signal ambience_changed(snapshot: Dictionary)
signal pest_warning_changed(active: bool, context: Dictionary)
signal storage_fill_visuals_changed(snapshot: Dictionary)

const GRID_SIZE := Vector2i(18, 14)
const CELL_SIZE := 2.0
## The legacy dining-room transform deliberately keeps using GRID_SIZE.  The
## larger region only extends the build/navigation graph, so old saves keep
## exactly the same world coordinates.
const LOT_REGION := Rect2i(Vector2i(-4, -7), Vector2i(32, 25))
const SIDEWALK_Y := -2
const SIDEWALK_ROWS: Array[int] = [-2, -1]
const QUEUE_ROW := -2
const EXIT_ROW := -1
const ROAD_ROWS: Array[int] = [-6, -5, -4, -3]
const CUSTOMER_QUEUE_SPACING := 1.12

var entrance_cell := Vector2i(8, 0)
var astar := AStarGrid2D.new()
var occupancy: Dictionary = {}
var static_blocked: Dictionary = {}
var placed_objects: Dictionary = {}
var table_occupants: Dictionary = {}
var table_dirty_records: Dictionary = {}
var customer_queue: Array[Node] = []
var door_owner: Node
var exiting_customers: Dictionary = {}
var exit_wait_queue: Array[Node] = []
var staff_agents: Dictionary = {}
var navigation_agents: Array[AnimatedAgent] = []
var navigation_revision := 0
var waiting_reservations: Dictionary = {}
var staff_standby_reservations: Dictionary = {}
var corridor_reservations: Dictionary = {}
var agent_corridor_reservations: Dictionary = {}
var agent_motion_intents: Dictionary = {}
var agent_avoidance_memory: Dictionary = {}
var customer_root: Node3D
var object_root: Node3D
var preview_root: Node3D
var build_system: BuildSystem
var camera_rig: RestaurantCamera
var show_grid := false
var show_paths := false
var show_station_queues := false
var _spawn_clock := 0.0
var _day_cycle_manager: Node
var _world_environment: WorldEnvironment
var _sun_light: DirectionalLight3D
var _last_lighting_minute := -1
var _traffic_recipe_warning := false
var _debug_force_rush_fallback := false
## Legacy/debug compatibility for smoke tests and old call sites.  Natural rush
## scheduling still comes exclusively from DayCycleManager.
var rush_mode: bool:
	get:
		return is_rush_active()
	set(enabled):
		set_rush_mode(enabled)
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
var _corridor_key_cache: Dictionary = {}
var _traffic_epoch := 0
var _path_cache_suspended := false
var cleanup_root: Node3D
var storage_fill_visualizer: StorageFillVisualizer
var spill_records: Dictionary = {}
var wash_batches: Dictionary = {}
var ambience_system: RestaurantAmbienceSystem
var kitchen_dirt := 0.0
var kitchen_dirt_visuals: Array[Node3D] = []
var pest_visuals: Dictionary = {}
var _spill_serial := 0
var _spill_clock := 18.0
var _ambience_tick_accumulator := 0.0
var reduced_walls := false


func _ready() -> void:
	name = "RestaurantWorld"
	reduced_walls = bool(GameState.settings.get("walls_reduced", false))
	_create_environment()
	_create_roots()
	_create_grid()
	_create_floor_and_walls()
	load_layout()
	_setup_storage_fill_visuals()
	spawn_staff()
	SimulationManager.bind_world(self)
	_setup_ambience()
	_bind_day_cycle()
	if not GameState.layout_changed.is_connected(refresh_shell_cutaway):
		GameState.layout_changed.connect(refresh_shell_cutaway)
	if not GameState.layout_changed.is_connected(_on_ambience_layout_changed):
		GameState.layout_changed.connect(_on_ambience_layout_changed)
	if not WebPlatformProfile.quality_changed.is_connected(apply_graphics_quality):
		WebPlatformProfile.quality_changed.connect(apply_graphics_quality)


func _process(delta: float) -> void:
	_traffic_epoch += 1
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
	if GameState.restaurant_state in ["open", "closing"] and ambience_system != null:
		var ambience_scaled := delta * SimulationManager.simulation_speed
		_ambience_tick_accumulator += ambience_scaled
		var ambience_ticks := 0
		while _ambience_tick_accumulator >= 0.5 and ambience_ticks < 4:
			ambience_system.advance_pest_risk(0.5)
			_ambience_tick_accumulator -= 0.5
			ambience_ticks += 1
		if ambience_ticks == 4:
			_ambience_tick_accumulator = minf(_ambience_tick_accumulator, 0.5)
	if GameState.restaurant_state != "open":
		return
	var scaled := delta * SimulationManager.simulation_speed
	_spawn_clock -= scaled
	_spill_clock -= scaled
	if _spill_clock <= 0.0:
		_spill_clock = randf_range(22.0, 34.0)
		_spawn_service_spill()
	var has_producible_recipe := has_producible_active_recipe()
	_traffic_recipe_warning = not has_producible_recipe
	if _spawn_clock <= 0.0:
		var spawnable_group_size := _spawnable_customer_group_size()
		if spawnable_group_size > 0:
			spawn_customer_group(spawnable_group_size)
		_spawn_clock = effective_customer_spawn_interval(has_producible_recipe)


func _setup_ambience() -> void:
	kitchen_dirt = maxf(float(GameState.cleanliness_state.get("kitchen_dirt", 0.0)), 0.0)
	ambience_system = RestaurantAmbienceSystem.new()
	ambience_system.name = "RestaurantAmbienceSystem"
	add_child(ambience_system)
	ambience_system.ambience_changed.connect(_on_ambience_changed)
	ambience_system.pest_warning_changed.connect(_on_pest_warning_changed)
	ambience_system.pest_spawn_requested.connect(_on_pest_spawn_requested)
	ambience_system.pest_resolved.connect(_on_pest_resolved)
	ambience_system.configure(self, {}, true)
	ambience_system.refresh_from_world()
	_restore_ambience_pest_visuals()
	_refresh_kitchen_dirt_visuals()
	_ensure_kitchen_cleaning_task()


func ambience_snapshot() -> Dictionary:
	if ambience_system == null:
		return {
			"beauty_score": 0.0,
			"cleanliness_score": float(GameState.cleanliness_state.get("score", 100.0)),
			"cleanliness_level": "clean",
			"pest": {"active": [], "visible_kinds": []},
		}
	return ambience_system.current_snapshot()


func visible_pest_incidents() -> Array:
	var snapshot := ambience_snapshot()
	var pest: Dictionary = snapshot.get("pest", {})
	var result: Array = []
	for value: Variant in pest.get("active", []):
		if value is Dictionary and bool((value as Dictionary).get("visible", true)):
			result.append((value as Dictionary).duplicate(true))
	return result


func beauty_preview(
	definition: Dictionary,
	cell: Vector2i,
	move_source: PlacedObject = null
) -> Dictionary:
	var current := ambience_snapshot()
	var current_score := float(current.get("beauty_score", 0.0))
	if ambience_system == null or definition.is_empty():
		return {"before": current_score, "after": current_score, "delta": 0.0, "item_beauty": 0.0}
	var entries: Array = []
	for object: PlacedObject in placed_objects.values():
		if not is_instance_valid(object) or object == move_source:
			continue
		entries.append(object)
	entries.append({"definition": definition, "cell": [cell.x, cell.y]})
	var context := ambience_system.dining_context_from_world(self)
	var calculated := ambience_system.calculate_beauty(entries, context)
	var multiplier := float(current.get("beauty_cleanliness_multiplier", 1.0))
	var after_score := clampf(float(calculated.get("base_score", 0.0)) * multiplier, 0.0, 100.0)
	return {
		"before": current_score,
		"after": after_score,
		"delta": after_score - current_score,
		"item_beauty": float(definition.get("beauty", 0.0)),
	}


func register_kitchen_work_dirt(task: Dictionary = {}) -> void:
	if task.is_empty():
		return
	var station := String(task.get("station", ""))
	if station.is_empty() or station in ["pass", "sink"]:
		return
	var addition := float(DataRegistry.balance_value("cleanliness.kitchen_dirt_per_task", 0.45))
	kitchen_dirt = clampf(kitchen_dirt + maxf(addition, 0.0), 0.0, 100.0)
	_refresh_kitchen_dirt_visuals()
	_refresh_ambience()
	_ensure_kitchen_cleaning_task()


func _refresh_ambience() -> void:
	if ambience_system == null:
		return
	ambience_system.refresh_from_world()


func _on_ambience_layout_changed() -> void:
	_refresh_ambience()


func _on_ambience_changed(snapshot: Dictionary) -> void:
	ambience_changed.emit(snapshot.duplicate(true))


func _on_pest_warning_changed(active: bool, context: Dictionary) -> void:
	pest_warning_changed.emit(active, context.duplicate(true))
	if not active or GameState.restaurant_state not in ["open", "closing"]:
		return
	var message := String(context.get("message", "Rischio infestazione: intervieni sulla pulizia."))
	GameState.toast_requested.emit(message, "warning")


func _on_pest_spawn_requested(kind: String, context: Dictionary) -> void:
	var incident_id := String(context.get("incident_id", ""))
	if incident_id.is_empty() or pest_visuals.has(incident_id):
		return
	if _spawn_pest_incident(kind, incident_id, false):
		GameState.toast_requested.emit(
			"%s visibile: priorità emergenza al tuttofare." % ("Topo" if kind == "mouse" else "Insetti"),
			"warning"
		)


func _restore_ambience_pest_visuals() -> void:
	if ambience_system == null:
		return
	for record_value: Variant in visible_pest_incidents():
		if not record_value is Dictionary:
			continue
		var record := record_value as Dictionary
		var incident_id := String(record.get("id", ""))
		var kind := String(record.get("kind", "insect"))
		if not incident_id.is_empty() and not pest_visuals.has(incident_id):
			_spawn_pest_incident(kind, incident_id, true)


func _spawn_pest_incident(kind: String, incident_id: String, already_confirmed: bool) -> bool:
	if cleanup_root == null:
		return false
	var spawn_cell := _pest_spawn_cell(kind, incident_id)
	var visual := _create_pest_visual(kind, incident_id)
	cleanup_root.add_child(visual)
	visual.global_position = cell_to_world(spawn_cell) + Vector3.UP * 0.04
	pest_visuals[incident_id] = {
		"id": incident_id,
		"kind": kind,
		"cell": spawn_cell,
		"node": visual,
		"state": "visible",
	}
	var task := SimulationManager.request_maintenance_task(self, "remove_pest", visual.global_position, {
		"incident_id": incident_id,
		"incident_kind": kind,
		"pest_type": kind,
		"reservation_key": "pest:%s" % incident_id,
		"maintenance_category": "emergency",
		"animation": "PickUp",
	}, 5, 2.4 if kind == "insect" else 3.2, "res://assets/cleaning/Tool_Mop.glb")
	if task.is_empty():
		visual.queue_free()
		pest_visuals.erase(incident_id)
		return false
	pest_visuals[incident_id].task_id = String(task.get("id", ""))
	if not already_confirmed:
		ambience_system.confirm_pest_spawn(kind, incident_id)
	return true


func _pest_spawn_cell(kind: String, incident_id: String) -> Vector2i:
	var candidates: Array[Vector2i] = []
	for cell: Vector2i in floor_tiles:
		var floor_style := String(floor_tiles.get(cell, ""))
		if floor_style not in ["floor_dining", "floor_kitchen"]:
			continue
		if kind == "mouse" and floor_style != "floor_kitchen":
			continue
		if not astar.is_in_boundsv(cell) or astar.is_point_solid(cell):
			continue
		if cell.distance_to(entrance_cell) < 2.0:
			continue
		candidates.append(cell)
	if candidates.is_empty() and kind == "mouse":
		return _pest_spawn_cell("insect", incident_id)
	if candidates.is_empty():
		return _nearest_open_cell(Vector2i(10, 9))
	candidates.sort_custom(func(a: Vector2i, b: Vector2i):
		var a_key: int = absi(a.x * 31 + a.y * 17 + incident_id.hash())
		var b_key: int = absi(b.x * 31 + b.y * 17 + incident_id.hash())
		return a_key < b_key
	)
	return candidates[0]


func _create_pest_visual(kind: String, incident_id: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Pest_%s" % incident_id
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color("302925")
	dark.roughness = 0.82
	var accent := StandardMaterial3D.new()
	accent.albedo_color = Color("76594a") if kind == "mouse" else Color("8d493d")
	accent.roughness = 0.78
	if kind == "mouse":
		var body := MeshInstance3D.new()
		var body_mesh := SphereMesh.new()
		body_mesh.radius = 0.25
		body_mesh.height = 0.42
		body_mesh.radial_segments = 8
		body_mesh.rings = 4
		body_mesh.material = accent
		body.mesh = body_mesh
		body.scale = Vector3(1.0, 0.72, 1.35)
		body.position = Vector3(0.0, 0.22, 0.0)
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(body)
		var head := MeshInstance3D.new()
		var head_mesh := SphereMesh.new()
		head_mesh.radius = 0.16
		head_mesh.height = 0.28
		head_mesh.radial_segments = 8
		head_mesh.rings = 4
		head_mesh.material = dark
		head.mesh = head_mesh
		head.position = Vector3(0.0, 0.23, -0.31)
		head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(head)
		for x_offset: float in [-0.11, 0.11]:
			var ear := MeshInstance3D.new()
			var ear_mesh := SphereMesh.new()
			ear_mesh.radius = 0.07
			ear_mesh.height = 0.06
			ear_mesh.radial_segments = 7
			ear_mesh.rings = 3
			ear_mesh.material = accent
			ear.mesh = ear_mesh
			ear.position = Vector3(x_offset, 0.36, -0.28)
			ear.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(ear)
		var tail := MeshInstance3D.new()
		var tail_mesh := CylinderMesh.new()
		tail_mesh.top_radius = 0.025
		tail_mesh.bottom_radius = 0.025
		tail_mesh.height = 0.42
		tail_mesh.radial_segments = 6
		tail_mesh.material = dark
		tail.mesh = tail_mesh
		tail.rotation_degrees.x = 76.0
		tail.position = Vector3(0.0, 0.11, 0.40)
		tail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(tail)
	else:
		var body := MeshInstance3D.new()
		var body_mesh := SphereMesh.new()
		body_mesh.radius = 0.15
		body_mesh.height = 0.28
		body_mesh.radial_segments = 8
		body_mesh.rings = 4
		body_mesh.material = accent
		body.mesh = body_mesh
		body.scale = Vector3(0.78, 0.48, 1.35)
		body.position.y = 0.10
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(body)
		for leg_index: int in 3:
			var legs := MeshInstance3D.new()
			var leg_mesh := BoxMesh.new()
			leg_mesh.size = Vector3(0.54, 0.025, 0.035)
			leg_mesh.material = dark
			legs.mesh = leg_mesh
			legs.position = Vector3(0.0, 0.08, -0.11 + float(leg_index) * 0.11)
			legs.rotation_degrees.y = -18.0 + float(leg_index) * 18.0
			legs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(legs)
	root.rotation.y = float(posmod(incident_id.hash(), 360)) * PI / 180.0
	return root


func _on_pest_resolved(_kind: String, context: Dictionary) -> void:
	var incident_id := String(context.get("id", ""))
	if not pest_visuals.has(incident_id):
		return
	var visual := pest_visuals[incident_id].get("node") as Node3D
	if visual != null and is_instance_valid(visual):
		visual.queue_free()
	pest_visuals.erase(incident_id)
	_refresh_ambience()


func _ensure_kitchen_cleaning_task() -> void:
	var threshold := float(DataRegistry.balance_value("cleanliness.kitchen_clean_task_threshold", 8.0))
	if kitchen_dirt < threshold:
		return
	var target := _sink_interaction_position()
	SimulationManager.request_maintenance_task(self, "clean_kitchen", target, {
		"reservation_key": "clean:kitchen",
		"maintenance_category": "kitchen",
		"animation": "PickUp",
	}, 2 if kitchen_dirt >= threshold * 2.0 else 1, 2.8, "res://assets/cleaning/Cleaning_Sponge.glb")


func _refresh_kitchen_dirt_visuals() -> void:
	if cleanup_root == null:
		return
	var units_per_mark := maxf(float(DataRegistry.balance_value("cleanliness.kitchen_dirt_visual_step", 6.0)), 0.1)
	var desired := clampi(floori(kitchen_dirt / units_per_mark), 0, 5)
	while kitchen_dirt_visuals.size() > desired:
		var removed: Node3D = kitchen_dirt_visuals.pop_back() as Node3D
		if removed != null and is_instance_valid(removed):
			removed.queue_free()
	while kitchen_dirt_visuals.size() < desired:
		var index := kitchen_dirt_visuals.size()
		var visual := _create_spill_visual("KitchenGrime_%02d" % index)
		visual.name = "KitchenGrime_%02d" % index
		visual.scale = Vector3.ONE * 0.72
		cleanup_root.add_child(visual)
		visual.global_position = cell_to_world(_kitchen_grime_cell(index)) + Vector3.UP * 0.025
		kitchen_dirt_visuals.append(visual)


func _kitchen_grime_cell(index: int) -> Vector2i:
	var candidates: Array[Vector2i] = []
	for cell: Vector2i in floor_tiles:
		if String(floor_tiles.get(cell, "")) != "floor_kitchen":
			continue
		if astar.is_in_boundsv(cell) and not astar.is_point_solid(cell):
			candidates.append(cell)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i):
		var a_key: int = absi(a.x * 19 + a.y * 29)
		var b_key: int = absi(b.x * 19 + b.y * 29)
		return a_key < b_key
	)
	return candidates[index % candidates.size()] if not candidates.is_empty() else _nearest_open_cell(Vector2i(9, 10))


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
	cleanup_root = Node3D.new()
	cleanup_root.name = "CleanupObjects"
	add_child(cleanup_root)
	camera_rig = RestaurantCamera.new()
	camera_rig.name = "IsometricCamera"
	add_child(camera_rig)
	if camera_rig.has_signal("view_changed"):
		camera_rig.connect("view_changed", Callable(self, "_on_camera_view_changed"))
	if camera_rig.has_signal("view_transform_changed"):
		camera_rig.connect("view_transform_changed", Callable(self, "refresh_shell_cutaway"))
	configure_build_system()


func _setup_storage_fill_visuals() -> void:
	storage_fill_visualizer = StorageFillVisualizer.new()
	add_child(storage_fill_visualizer)
	storage_fill_visualizer.visuals_changed.connect(
		func(snapshot: Dictionary): storage_fill_visuals_changed.emit(snapshot.duplicate(true))
	)
	storage_fill_visualizer.setup(self)


func storage_fill_snapshot() -> Dictionary:
	if storage_fill_visualizer == null:
		return {}
	return storage_fill_visualizer.snapshot()


func _create_environment() -> void:
	_world_environment = WorldEnvironment.new()
	_world_environment.name = "WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("91bdc1")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("dce3e2")
	environment.ambient_light_energy = 0.38
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.fog_enabled = false
	_world_environment.environment = environment
	add_child(_world_environment)
	_sun_light = DirectionalLight3D.new()
	_sun_light.name = "Sun"
	_sun_light.rotation_degrees = Vector3(-58, -35, 0)
	_sun_light.light_color = Color("fff7e8")
	_sun_light.light_energy = 0.84
	_sun_light.shadow_enabled = WebPlatformProfile.shadows_enabled()
	_sun_light.directional_shadow_max_distance = WebPlatformProfile.shadow_distance()
	add_child(_sun_light)


func apply_graphics_quality(_preset: String = "auto") -> void:
	var sun := _sun_light if _sun_light != null else get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = WebPlatformProfile.shadows_enabled()
		sun.directional_shadow_max_distance = WebPlatformProfile.shadow_distance()


func _bind_day_cycle() -> void:
	_day_cycle_manager = get_tree().root.get_node_or_null("DayCycleManager")
	if _day_cycle_manager != null and _day_cycle_manager.has_signal("minute_changed"):
		var callback := Callable(self, "_on_day_cycle_minute_changed")
		if not _day_cycle_manager.is_connected("minute_changed", callback):
			_day_cycle_manager.connect("minute_changed", callback)
	_apply_day_cycle_lighting()


func _on_day_cycle_minute_changed(_day: int, current_minute: int) -> void:
	if current_minute == _last_lighting_minute:
		return
	_last_lighting_minute = current_minute
	_apply_day_cycle_lighting()


func _apply_day_cycle_lighting() -> void:
	if _day_cycle_manager == null or not _day_cycle_manager.has_method("lighting_profile_for_minute"):
		return
	var profile: Dictionary = _day_cycle_manager.call("lighting_profile_for_minute", float(_day_cycle_manager.get("minute")))
	if _world_environment != null and _world_environment.environment != null:
		_world_environment.environment.background_color = Color(profile.get("background_color", Color("91bdc1")))
		_world_environment.environment.ambient_light_color = Color(profile.get("ambient_color", Color("dce3e2")))
		_world_environment.environment.ambient_light_energy = float(profile.get("ambient_energy", 0.38))
	if _sun_light != null:
		_sun_light.light_color = Color(profile.get("sun_color", Color("fff7e8")))
		_sun_light.light_energy = float(profile.get("sun_energy", 0.84))
	var lamp_energy := float(profile.get("lamp_energy", 0.0))
	for lamp_node: Node in get_tree().get_nodes_in_group("day_cycle_lamp"):
		if lamp_node is Light3D:
			var lamp := lamp_node as Light3D
			lamp.visible = lamp_energy > 0.02
			lamp.light_energy = lamp_energy


func _attach_day_cycle_lamp(object: PlacedObject) -> void:
	if object == null or object.item_id != "exterior_streetlight" or object.get_node_or_null("NightLight") != null:
		return
	var lamp := OmniLight3D.new()
	lamp.name = "NightLight"
	lamp.position = Vector3(0.0, 3.3, 0.0)
	lamp.light_color = Color("ffd598")
	lamp.light_energy = 0.0
	lamp.omni_range = 6.0
	lamp.shadow_enabled = false
	lamp.distance_fade_enabled = true
	lamp.distance_fade_begin = 18.0
	lamp.distance_fade_length = 8.0
	lamp.add_to_group("day_cycle_lamp")
	object.add_child(lamp)


func _on_camera_view_changed(_quadrant: int) -> void:
	refresh_shell_cutaway()


func toggle_reduced_walls() -> void:
	reduced_walls = not reduced_walls
	GameState.settings.walls_reduced = reduced_walls
	SaveManager.save_game()
	refresh_shell_cutaway()


func refresh_shell_cutaway() -> void:
	if camera_rig == null or camera_rig.camera == null or placed_objects.is_empty():
		return
	var camera_direction := camera_rig.camera.global_position - camera_rig.global_position
	camera_direction.y = 0.0
	if camera_direction.length_squared() <= 0.001:
		camera_direction = Vector3(1.0, 0.0, 1.0)
	camera_direction = camera_direction.normalized()
	for object: PlacedObject in placed_objects.values():
		if object == null or not is_instance_valid(object) or not is_edge_placement(object.definition):
			continue
		var shell_side := shell_side_for_edge(object.grid_cell, object.rotation_steps)
		var outward := _shell_outward_normal(shell_side)
		var camera_facing := not shell_side.is_empty() and outward.dot(camera_direction) > 0.2
		_set_structural_visibility(object, not camera_facing, reduced_walls)


func shell_side_for_edge(cell: Vector2i, rotation_steps: int) -> String:
	var parts := edge_key(cell, rotation_steps).split(":")
	if parts.size() != 3:
		return ""
	var axis := String(parts[0])
	var first := int(parts[1])
	var second := int(parts[2])
	if axis == "h" and first >= 0 and first < GRID_SIZE.x:
		if second == 0: return "north"
		if second == GRID_SIZE.y: return "south"
	if axis == "v" and second >= 0 and second < GRID_SIZE.y:
		if first == 0: return "west"
		if first == GRID_SIZE.x: return "east"
	return ""


func _shell_outward_normal(side: String) -> Vector3:
	match side:
		"north": return Vector3.FORWARD
		"south": return Vector3.BACK
		"west": return Vector3.LEFT
		"east": return Vector3.RIGHT
	return Vector3.ZERO


func _set_structural_visibility(object: PlacedObject, visible_value: bool, use_stub: bool) -> void:
	object.visible = visible_value
	if object.visual_model != null:
		if not object.has_meta("cutaway_original_visual_scale"):
			object.set_meta("cutaway_original_visual_scale", object.visual_model.scale)
		var original_scale := Vector3(object.get_meta("cutaway_original_visual_scale", Vector3.ONE))
		object.visual_model.scale = original_scale
		if use_stub:
			object.visual_model.scale.y = original_scale.y * 0.28
	for geometry: Node in object.find_children("*", "GeometryInstance3D", true, false):
		(geometry as GeometryInstance3D).transparency = 0.0
	for attached: PlacedObject in attached_objects(object.uid):
		# Wall-mounted shelves would otherwise float above a reduced stub.
		attached.visible = visible_value and not use_stub
		for geometry: Node in attached.find_children("*", "GeometryInstance3D", true, false):
			(geometry as GeometryInstance3D).transparency = 0.0


func _create_grid() -> void:
	astar.region = LOT_REGION
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar.update()
	# The road is scenery and a despawn boundary, not an indoor walking route.
	for road_y: int in ROAD_ROWS:
		for x: int in range(LOT_REGION.position.x, LOT_REGION.end.x):
			static_blocked[Vector2i(x, road_y)] = true


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
	table_dirty_records.clear()
	customer_queue.clear()
	door_owner = null
	exiting_customers.clear()
	exit_wait_queue.clear()
	waiting_reservations.clear()
	staff_standby_reservations.clear()
	corridor_reservations.clear()
	agent_corridor_reservations.clear()
	agent_motion_intents.clear()
	_loading_layout = true
	floor_tiles.clear()
	for y: int in range(LOT_REGION.position.y, LOT_REGION.end.y):
		for x: int in range(LOT_REGION.position.x, LOT_REGION.end.x):
			var cell := Vector2i(x, y)
			var style := "floor_grass"
			if Rect2i(Vector2i.ZERO, GRID_SIZE).has_point(cell):
				style = "floor_dining" if y < 8 else "floor_kitchen"
			elif y in SIDEWALK_ROWS:
				style = "floor_sidewalk"
			elif y in ROAD_ROWS:
				style = "floor_road"
			set_floor_style(cell, style)
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
	_refresh_operational_stations()
	_rebuild_astar()
	refresh_shell_cutaway()
	if ambience_system != null:
		_refresh_ambience()
		_restore_ambience_pest_visuals()
	if storage_fill_visualizer != null:
		# Direct layout reloads rebuild provider nodes without necessarily
		# changing their aggregate capacity, so refresh their attached visuals.
		storage_fill_visualizer.refresh()


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
	object.refresh_operational_feedback()
	_attach_day_cycle_lamp(object)
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
	_refresh_operational_stations()
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
	_refresh_operational_stations()
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
	SimulationManager.refresh_station(object)
	for attached: PlacedObject in attached_objects(object.uid):
		var child_rotation := posmod(attached.rotation_steps + rotation_delta, 4)
		var child_placement := String(attached.definition.get("placement", "cell"))
		if child_placement == "seat":
			child_rotation = seat_rotation_for_slot(attached.attachment_slot, rotation_steps)
		elif child_placement == "overhead":
			child_rotation = rotation_steps
		attached.set_layout_state(cell, child_rotation, object.uid, attached.attachment_slot)
		_refresh_attachment(attached)
		_update_layout_record(attached)
	_refresh_operational_stations()
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
	return String(definition.get("placement", "cell")) in ["seat", "surface", "wall_mount", "overhead"]


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
	if placement == "overhead":
		return support.position + Vector3.UP * float(definition.get("overhead_height", 1.55))
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
	elif String(definition.get("placement", "cell")) == "overhead":
		slot = 0
		rotation = best_support.rotation_steps
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
	elif placement in ["wall_mount", "overhead"]:
		rotation = support.rotation_steps
	object.set_layout_state(support.grid_cell, rotation, support.uid, object.attachment_slot)
	object.position = attachment_world_position(object.definition, support, object.attachment_slot, object.rotation_steps)
	_update_layout_record(object)
	SimulationManager.refresh_station(object)


func ventilation_hood_for(station: PlacedObject) -> PlacedObject:
	if station == null or not is_instance_valid(station):
		return null
	var required_kind := String(station.definition.get("support_kind", ""))
	for candidate: PlacedObject in attached_objects(station.uid):
		if String(candidate.definition.get("placement", "cell")) != "overhead":
			continue
		if bool(candidate.definition.get("provides_ventilation", false)) and String(candidate.definition.get("requires_support", "")) == required_kind:
			return candidate
	return null


func station_is_operational(station: PlacedObject) -> bool:
	if station == null or not is_instance_valid(station):
		return false
	if not bool(station.definition.get("ventilation_required", false)):
		return true
	return ventilation_hood_for(station) != null


func unventilated_heat_stations() -> Array[PlacedObject]:
	var result: Array[PlacedObject] = []
	for object: PlacedObject in placed_objects.values():
		if is_instance_valid(object) and bool(object.definition.get("ventilation_required", false)) and not station_is_operational(object):
			result.append(object)
	result.sort_custom(func(a: PlacedObject, b: PlacedObject): return a.uid < b.uid)
	return result


func restaurant_opening_blockers() -> Array[String]:
	var result: Array[String] = []
	for station: PlacedObject in unventilated_heat_stations():
		result.append("%s in cella %d,%d: manca una cappa aspirante" % [String(station.definition.get("name", station.item_id)), station.grid_cell.x, station.grid_cell.y])
	return result


func _refresh_operational_stations() -> void:
	for object: PlacedObject in placed_objects.values():
		if is_instance_valid(object):
			object.refresh_operational_feedback()


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
	if not LOT_REGION.has_point(cell):
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
				"overhead":
					return {"valid": false, "reason": "La cappa deve essere agganciata sopra un fornello compatibile"}
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
		if placement == "overhead" and rotation_steps != support.rotation_steps:
			return {"valid": false, "reason": "La cappa deve essere allineata al fornello"}
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
	if bool(baseline_access.get("__kitchen", true)) and _interior_grid_path(entrance_cell, _nearest_open_cell(Vector2i(9, 8))).is_empty():
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
	var result := {"__kitchen": not _interior_grid_path(entrance_cell, _nearest_open_cell(Vector2i(9, 8))).is_empty()}
	for object: PlacedObject in placed_objects.values():
		if object == ignored or not is_instance_valid(object):
			continue
		if ignored != null and object.support_uid == ignored.uid:
			continue
		if object.station_id.is_empty() and not object.item_id.begins_with("table"):
			continue
		result[object.uid] = _object_has_operational_access(object)
	return result


func _interior_grid_path(from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
	var interior := Rect2i(Vector2i.ZERO, GRID_SIZE)
	var empty: Array[Vector2i] = []
	if not interior.has_point(from_cell) or not interior.has_point(to_cell) or astar.is_point_solid(from_cell) or astar.is_point_solid(to_cell):
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
			if not interior.has_point(neighbor) or astar.is_point_solid(neighbor) or came_from.has(neighbor) or _wall_blocks_step(current, neighbor):
				continue
			came_from[neighbor] = current
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
	_corridor_key_cache.clear()
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
		if other._traffic_pullout_active:
			var pullout_cell := world_to_cell(other._traffic_pullout_position)
			_add_traffic_cost(costs, pullout_cell, 22.0)
			for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				_add_traffic_cost(costs, pullout_cell + offset, 3.2)
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
	agent_motion_intents.erase(agent.get_instance_id())
	agent_avoidance_memory.erase(agent.get_instance_id())
	release_waiting_position(agent)
	staff_standby_reservations.erase(agent.get_instance_id())
	_release_agent_corridor(agent)


func finish_agent_navigation(agent: AnimatedAgent) -> void:
	var key := String(agent_corridor_reservations.get(agent.get_instance_id(), ""))
	if key.is_empty() or not _agent_is_inside_corridor(agent, key):
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
		if _agent_has_right_of_way(candidate, winner, requested_key):
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


func can_agent_skip_open_waypoint(agent: AnimatedAgent, route: PackedVector3Array, route_index: int) -> bool:
	if route_index < 0 or route_index + 1 >= route.size():
		return false
	var waypoint := route[route_index]
	# Never skip the cells which define an exclusive doorway/corridor: those
	# waypoints are the topology used by the FIFO reservation system.
	if not _corridor_key(world_to_cell(waypoint)).is_empty():
		return false
	if Vector2(agent.global_position.x, agent.global_position.z).distance_to(Vector2(waypoint.x, waypoint.z)) > CELL_SIZE * 0.72:
		return false
	var next_waypoint := route[route_index + 1]
	return can_agent_move(agent.global_position, next_waypoint, agent.agent_radius * 0.92)


func _agent_has_right_of_way(candidate: AnimatedAgent, incumbent: AnimatedAgent, corridor_key: String = "") -> bool:
	if candidate == incumbent:
		return false
	var candidate_inside := not corridor_key.is_empty() and _agent_is_inside_corridor(candidate, corridor_key)
	var incumbent_inside := not corridor_key.is_empty() and _agent_is_inside_corridor(incumbent, corridor_key)
	if candidate_inside != incumbent_inside:
		return candidate_inside
	# When two bodies somehow start inside the same passage (for example after a
	# layout reload), let the one nearest its forward exit clear first.
	if candidate_inside:
		var candidate_remaining := _remaining_corridor_steps(candidate, corridor_key)
		var incumbent_remaining := _remaining_corridor_steps(incumbent, corridor_key)
		if candidate_remaining != incumbent_remaining:
			return candidate_remaining < incumbent_remaining
	if candidate.navigation_priority != incumbent.navigation_priority:
		return candidate.navigation_priority < incumbent.navigation_priority
	# Route tickets are monotonically assigned by move_to(). FIFO is stable
	# across frame/process order and prevents the same low instance id from
	# winning every successive bottleneck forever.
	if candidate.route_ticket != incumbent.route_ticket:
		return candidate.route_ticket < incumbent.route_ticket
	return candidate.get_instance_id() < incumbent.get_instance_id()


func _remaining_corridor_steps(agent: AnimatedAgent, corridor_key: String) -> int:
	var remaining := 0
	for index: int in range(agent.path_index, agent.path.size()):
		if _corridor_key(world_to_cell(agent.path[index])) != corridor_key:
			if remaining > 0:
				break
			continue
		remaining += 1
	return remaining


func _upcoming_corridor_key(agent: AnimatedAgent, route: PackedVector3Array, route_index: int) -> String:
	for point: Vector3 in agent.get_avoidance_points():
		var current_key := _corridor_key(world_to_cell(point))
		if not current_key.is_empty():
			return current_key
	var lookahead_end := route.size() if agent._traffic_pullout_active else mini(route_index + 6, route.size())
	for index: int in range(route_index, lookahead_end):
		var key := _corridor_key(world_to_cell(route[index]))
		if not key.is_empty():
			return key
	return ""


func _corridor_key(start: Vector2i) -> String:
	if _corridor_key_cache.has(start):
		return String(_corridor_key_cache[start])
	if not _is_narrow_corridor_cell(start):
		_corridor_key_cache[start] = ""
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
	var key := ";".join(parts)
	# Corridor topology only changes when the navigation graph is rebuilt.
	# Caching the connected component avoids a flood-fill for every agent, on
	# every rendered frame -- a particularly expensive hot path in WebGL.
	for cell: Vector2i in cells:
		_corridor_key_cache[cell] = key
	return key


func _is_narrow_corridor_cell(cell: Vector2i) -> bool:
	# The pavement is intentionally a FIFO waiting lane.  Treating the whole
	# long sidewalk as one exclusive indoor corridor lets the first queued body
	# reserve it forever and deadlocks everybody behind it.
	if cell.y < 0:
		return false
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


func agent_is_inside_contested_corridor(agent: AnimatedAgent) -> bool:
	var key := _corridor_key(world_to_cell(agent.global_position))
	if key.is_empty():
		return false
	for other: AnimatedAgent in navigation_agents:
		if other == agent or not is_instance_valid(other) or other.is_queued_for_deletion() or not other.is_collision_enabled():
			continue
		if _agent_is_inside_corridor(other, key) or (other.navigation_active and _upcoming_corridor_key(other, other.path, other.path_index) == key):
			return true
	return false


func find_agent_recovery_detour(agent: AnimatedAgent, final_destination: Vector3) -> Dictionary:
	var blocker := _nearest_conflicting_agent(agent)
	if blocker == null:
		return {}
	var corridor_key := _corridor_key(world_to_cell(agent.global_position))
	if corridor_key.is_empty():
		corridor_key = _upcoming_corridor_key(agent, agent.path, agent.path_index)
	# Only the yielding participant leaves the main route. The winner remains
	# predictable, so two agents never mirror one another into the same alcove.
	var forward := agent.global_position.direction_to(agent.path[agent.path_index]) if agent.path_index < agent.path.size() else agent.global_position.direction_to(final_destination)
	if not _agent_should_yield(agent, blocker, forward, corridor_key):
		return {}
	var from_cell := _nearest_open_cell(world_to_cell(agent.global_position))
	var candidates: Array[Vector2i] = []
	if not corridor_key.is_empty() and _agent_is_inside_corridor(agent, corridor_key):
		var corridor_cells := _decode_corridor_cells(corridor_key)
		var corridor_lookup: Dictionary = {}
		for cell: Vector2i in corridor_cells:
			corridor_lookup[cell] = true
		for cell: Vector2i in corridor_cells:
			for offset: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
				var candidate := cell + offset
				if corridor_lookup.has(candidate) or candidates.has(candidate):
					continue
				if astar.is_in_boundsv(candidate) and not astar.is_point_solid(candidate) and not _wall_blocks_step(cell, candidate):
					candidates.append(candidate)
	else:
		for radius: int in range(1, 4):
			for y: int in range(-radius, radius + 1):
				for x: int in range(-radius, radius + 1):
					if absi(x) != radius and absi(y) != radius:
						continue
					candidates.append(from_cell + Vector2i(x, y))
	var best_cell := Vector2i(99999, 99999)
	var best_score := INF
	var blocker_cell := world_to_cell(blocker.global_position)
	for candidate: Vector2i in candidates:
		if not astar.is_in_boundsv(candidate) or astar.is_point_solid(candidate) or _is_narrow_corridor_cell(candidate):
			continue
		if _open_neighbor_count(candidate) < 3:
			continue
		var candidate_world := cell_to_world(candidate)
		if not _agent_point_is_open(candidate_world, agent.agent_radius * 0.9):
			continue
		if not _traffic_holding_position_is_free(agent, candidate_world):
			continue
		var first_leg := _grid_path(from_cell, candidate)
		if first_leg.is_empty() or _grid_path(candidate, _nearest_open_cell(world_to_cell(final_destination))).is_empty():
			continue
		var blocker_clearance := candidate.distance_to(blocker_cell)
		if blocker_clearance < 1.5:
			continue
		var score := float(first_leg.size()) * 2.4 + candidate.distance_to(world_to_cell(final_destination)) * 0.08 - blocker_clearance * 0.75 - float(_open_neighbor_count(candidate)) * 0.3
		if score < best_score:
			best_score = score
			best_cell = candidate
	if best_cell.x == 99999:
		return {}
	var first_cells := _grid_path(from_cell, best_cell)
	var first_world := PackedVector3Array()
	for cell: Vector2i in first_cells:
		first_world.append(cell_to_world(cell))
	var actual_start := Vector3(agent.global_position.x, 0.0, agent.global_position.z)
	if first_world.size() > 1 and can_agent_move(actual_start, first_world[1], agent.agent_radius * 0.9):
		first_world.remove_at(0)
	var continuation := find_path(cell_to_world(best_cell), final_destination, agent)
	if continuation.is_empty():
		return {}
	while not continuation.is_empty() and not first_world.is_empty() and continuation[0].distance_to(first_world[first_world.size() - 1]) <= 0.05:
		continuation.remove_at(0)
	var release_index := first_world.size()
	for point: Vector3 in continuation:
		first_world.append(point)
	return {"path": first_world, "release_index": release_index, "pullout": cell_to_world(best_cell)}


func _traffic_holding_position_is_free(agent: AnimatedAgent, candidate: Vector3) -> bool:
	for other: AnimatedAgent in navigation_agents:
		if other == agent or not is_instance_valid(other) or other.is_queued_for_deletion() or not other.is_collision_enabled():
			continue
		var required := agent.agent_radius + other.agent_radius + 0.32
		for other_point: Vector3 in other.get_avoidance_points():
			if Vector2(candidate.x, candidate.z).distance_to(Vector2(other_point.x, other_point.z)) < required:
				return false
		# Reserve a recovery bay as soon as it is assigned, not only when its owner
		# physically reaches it. This is what prevents four corridor losers from
		# independently selecting the same apparently-empty tile in one frame.
		if other._traffic_pullout_active:
			var pullout := other._traffic_pullout_position
			if Vector2(candidate.x, candidate.z).distance_to(Vector2(pullout.x, pullout.z)) < required + 0.24:
				return false
		if other.navigation_active and _agent_has_right_of_way(other, agent):
			var path_clearance := maxf(required + 0.24, 1.18)
			for path_index: int in range(other.path_index, mini(other.path_index + 6, other.path.size())):
				var route_point := other.path[path_index]
				if Vector2(candidate.x, candidate.z).distance_to(Vector2(route_point.x, route_point.z)) < path_clearance:
					return false
	return true


func _nearest_conflicting_agent(agent: AnimatedAgent) -> AnimatedAgent:
	var own_corridor := _corridor_key(world_to_cell(agent.global_position))
	if own_corridor.is_empty():
		own_corridor = _upcoming_corridor_key(agent, agent.path, agent.path_index)
	var best: AnimatedAgent
	var best_score := INF
	var forward := Vector3.ZERO
	if agent.path_index < agent.path.size():
		forward = agent.global_position.direction_to(agent.path[agent.path_index])
	for other: AnimatedAgent in navigation_agents:
		if other == agent or not is_instance_valid(other) or other.is_queued_for_deletion() or not other.is_collision_enabled():
			continue
		var other_corridor := _corridor_key(world_to_cell(other.global_position))
		if other_corridor.is_empty() and other.navigation_active:
			other_corridor = _upcoming_corridor_key(other, other.path, other.path_index)
		var same_corridor := not own_corridor.is_empty() and own_corridor == other_corridor
		# Recovery is only useful against a participant this agent must yield to.
		# Previously the nearest body could be another waiter in the same queue;
		# the actual winner was then ignored and every loser stayed on the merge
		# point instead of taking a different holding bay.
		if other.navigation_active and not _agent_should_yield(agent, other, forward, own_corridor if same_corridor else ""):
			continue
		var distance := Vector2(agent.global_position.x, agent.global_position.z).distance_to(Vector2(other.global_position.x, other.global_position.z))
		if not same_corridor and distance > (agent.agent_radius + other.agent_radius) * 4.2:
			continue
		if not same_corridor and forward.length_squared() > 0.001:
			var toward := agent.global_position.direction_to(other.global_position)
			if forward.dot(toward) < 0.15:
				continue
		var score := distance - (12.0 if same_corridor else 0.0)
		if score < best_score:
			best_score = score
			best = other
	return best


func _decode_corridor_cells(key: String) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for encoded_cell: String in key.split(";", false):
		var coordinates := encoded_cell.split(",", false)
		if coordinates.size() == 2:
			result.append(Vector2i(int(coordinates[0]), int(coordinates[1])))
	return result


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
		var other_velocity := other.velocity
		var other_intent: Dictionary = agent_motion_intents.get(other.get_instance_id(), {})
		if int(other_intent.get("epoch", -99)) >= _traffic_epoch - 2:
			other_velocity = Vector3(other_intent.get("velocity", other_velocity))
		other_velocity.y = 0.0
		var step_time := clampf(movement_delta.length() / maxf(agent.movement_speed, 0.01), 0.0, 0.18)
		var predicts_conflict := _agent_should_yield(agent, other, movement_delta.normalized())
		for own_point: Vector3 in own_points:
			var candidate_point := own_point + movement_delta
			for other_point: Vector3 in other.get_avoidance_points():
				var current_distance := Vector2(own_point.x, own_point.z).distance_to(Vector2(other_point.x, other_point.z))
				var candidate_distance := Vector2(candidate_point.x, candidate_point.z).distance_to(Vector2(other_point.x, other_point.z))
				if candidate_distance < minimum and candidate_distance <= current_distance + 0.005:
					return false
				var predicted_other := other_point + other_velocity * step_time
				var predicted_distance := Vector2(candidate_point.x, candidate_point.z).distance_to(Vector2(predicted_other.x, predicted_other.z))
				if predicts_conflict and predicted_distance < minimum + 0.04 and predicted_distance <= current_distance + 0.01:
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
		agent_motion_intents[agent.get_instance_id()] = {"velocity": Vector3.ZERO, "epoch": _traffic_epoch}
		return Vector3.ZERO
	var desired_direction := desired_velocity.normalized()
	var neighbors: Array[Dictionary] = []
	var imminent_conflict := false
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
		var separation := agent.agent_radius + other.agent_radius + 0.16
		if distance > separation * 4.0:
			continue
		var other_intent: Dictionary = agent_motion_intents.get(other.get_instance_id(), {})
		var other_velocity := other.velocity
		if int(other_intent.get("epoch", -99)) >= _traffic_epoch - 2:
			other_velocity = Vector3(other_intent.get("velocity", other_velocity))
		other_velocity.y = 0.0
		var relative_velocity := desired_velocity - other_velocity
		var closest_time := 0.0
		if relative_velocity.length_squared() > 0.0001:
			closest_time = clampf(-offset.dot(relative_velocity) / relative_velocity.length_squared(), 0.0, 0.82)
		var predicted_offset := offset + relative_velocity * closest_time
		var predicted_distance := predicted_offset.length()
		var away := offset.normalized() if distance > 0.01 else Vector3.RIGHT.rotated(Vector3.UP, float(agent.get_instance_id() % 4) * PI * 0.5)
		var toward_other := -away
		var approaching := desired_direction.dot(toward_other) > 0.12
		var collision_risk := predicted_distance < separation * 1.22 and (approaching or distance < separation * 1.45)
		if not collision_risk and distance >= separation * 1.5:
			continue
		var shared_corridor := _corridor_key(world_to_cell(agent.global_position))
		if shared_corridor.is_empty() or not _agent_is_inside_corridor(other, shared_corridor):
			shared_corridor = ""
		var agent_yields := _agent_should_yield(agent, other, desired_direction, shared_corridor)
		var other_direction := other_velocity.normalized() if other_velocity.length_squared() > 0.01 else Vector3.ZERO
		neighbors.append({
			"offset": offset, "distance": distance,
			"velocity": other_velocity, "separation": separation,
			"yields": agent_yields, "approaching": approaching,
			"same_direction": other_direction.length_squared() > 0.0 and desired_direction.dot(other_direction) > 0.55
		})
		imminent_conflict = imminent_conflict or collision_risk or distance < separation * 1.55
	if neighbors.is_empty() or not imminent_conflict:
		agent_motion_intents[agent.get_instance_id()] = {"velocity": desired_velocity, "epoch": _traffic_epoch}
		return desired_velocity
	var candidates := _avoidance_velocity_candidates(agent, desired_velocity)
	var best_velocity := Vector3.ZERO
	var best_score := -INF
	for candidate: Vector3 in candidates:
		if not _avoidance_candidate_is_static_safe(agent, candidate):
			continue
		var score := _score_avoidance_candidate(agent, candidate, desired_velocity, neighbors)
		if score > best_score:
			best_score = score
			best_velocity = candidate
	if best_score == -INF:
		best_velocity = Vector3.ZERO
	best_velocity = best_velocity.limit_length(agent.movement_speed)
	agent_motion_intents[agent.get_instance_id()] = {"velocity": best_velocity, "epoch": _traffic_epoch}
	agent_avoidance_memory[agent.get_instance_id()] = {"velocity": best_velocity, "epoch": _traffic_epoch}
	return best_velocity


func _agent_should_yield(agent: AnimatedAgent, other: AnimatedAgent, forward: Vector3, corridor_key: String = "") -> bool:
	if not other.navigation_active:
		return true
	var other_direction := other.velocity.normalized() if other.velocity.length_squared() > 0.01 else Vector3.ZERO
	var toward_other := agent.global_position.direction_to(other.global_position)
	# A body already ahead in the same lane always keeps its place. Route-ticket
	# priority alone could otherwise make the follower try to overtake exactly at
	# a doorway and generate the visible accordion collision.
	if forward.length_squared() > 0.001 and other_direction.length_squared() > 0.001:
		if forward.dot(other_direction) > 0.58 and forward.dot(toward_other) > 0.48:
			return true
	if agent is EmployeeAgent and other is CustomerPersonAgent:
		var party := (other as CustomerPersonAgent).party
		if party != null and String(party.get("state")) in ["admitting", "walking_to_table", "seating", "leaving"]:
			return true
	return _agent_has_right_of_way(other, agent, corridor_key)


func _avoidance_velocity_candidates(agent: AnimatedAgent, desired_velocity: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var forward := desired_velocity.normalized()
	var desired_speed := minf(desired_velocity.length(), agent.movement_speed)
	# Deterministic right-first sampling gives reciprocal agents opposite
	# world-space sides while retaining enough alternatives for walls/furniture.
	var angles: Array[float] = [
		0.0, PI / 7.0, -PI / 7.0, PI / 3.5, -PI / 3.5,
		PI * 0.43, -PI * 0.43, PI * 0.5, -PI * 0.5,
		PI * 0.62, -PI * 0.62, PI
	]
	for speed_factor: float in [1.0, 0.62]:
		for angle: float in angles:
			result.append(forward.rotated(Vector3.UP, angle) * desired_speed * speed_factor)
	result.append(Vector3.ZERO)
	return result


func _avoidance_candidate_is_static_safe(agent: AnimatedAgent, candidate: Vector3) -> bool:
	if candidate.length_squared() <= 0.0001:
		return true
	var probe_time := minf(0.48, 1.05 / maxf(candidate.length(), 0.01))
	var target := agent.global_position + candidate * probe_time
	return can_agent_move(agent.global_position, target, agent.agent_radius * 0.92)


func _score_avoidance_candidate(agent: AnimatedAgent, candidate: Vector3, desired_velocity: Vector3, neighbors: Array[Dictionary]) -> float:
	var forward := desired_velocity.normalized()
	var speed_ratio := candidate.length() / maxf(agent.movement_speed, 0.01)
	var candidate_direction := candidate.normalized() if candidate.length_squared() > 0.0001 else Vector3.ZERO
	var alignment := forward.dot(candidate_direction)
	var right := Vector3(forward.z, 0.0, -forward.x).normalized()
	var score := alignment * 4.4 + speed_ratio * 1.35 + right.dot(candidate_direction) * 0.16
	if candidate.length_squared() <= 0.0001:
		score = -1.4
	var memory: Dictionary = agent_avoidance_memory.get(agent.get_instance_id(), {})
	if int(memory.get("epoch", -99)) >= _traffic_epoch - 18:
		var previous := Vector3(memory.get("velocity", Vector3.ZERO))
		if previous.length_squared() > 0.001 and candidate_direction.length_squared() > 0.001:
			score += previous.normalized().dot(candidate_direction) * 0.48
	for neighbor: Dictionary in neighbors:
		var offset := Vector3(neighbor.offset)
		var other_velocity := Vector3(neighbor.velocity)
		var relative_velocity := candidate - other_velocity
		var closest_time := 0.0
		if relative_velocity.length_squared() > 0.0001:
			closest_time = clampf(-offset.dot(relative_velocity) / relative_velocity.length_squared(), 0.0, 0.95)
		var predicted_distance := (offset + relative_velocity * closest_time).length()
		var current_distance := float(neighbor.distance)
		var separation := float(neighbor.separation)
		var yields := bool(neighbor.yields)
		var physical_limit := separation - 0.08
		# Priority decides who alters course, never who may overlap. The previous
		# scorer let the winner select a velocity that the physical step validator
		# would immediately reject, leaving it to push forever against a stopped
		# loser. Both sides now choose an actually executable velocity.
		if current_distance >= physical_limit and predicted_distance < physical_limit:
			return -INF
		if current_distance < physical_limit and predicted_distance + 0.01 < current_distance:
			return -INF
		# A yielding agent may not reserve a future disc that intersects the
		# winner. When bodies already touch, only candidates which increase their
		# separation remain legal, providing deterministic deadlock recovery.
		if yields:
			if current_distance >= separation and predicted_distance < separation:
				return -INF
			if current_distance < separation and predicted_distance + 0.015 < current_distance:
				return -INF
		elif predicted_distance < separation * 0.88 and current_distance >= separation:
			score -= 5.5
		var clearance := predicted_distance - separation
		score += clampf(clearance, -0.8, 1.5) * (1.15 if yields else 0.45)
		if bool(neighbor.same_direction) and bool(neighbor.approaching) and yields:
			var safe_follow_speed := Vector3(neighbor.velocity).length()
			if candidate.length() > safe_follow_speed + 0.12:
				score -= (candidate.length() - safe_follow_speed) * 1.8
	return score


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
	var employee_record: Dictionary = {}
	if agent is EmployeeAgent:
		employee_record = (agent as EmployeeAgent).employee
	var employee_id := String(employee_record.get("id", ""))
	var preference := StaffPreferences.for_employee_id(employee_id, role, employee_record)
	var waiter_zone := (
		String(preference.get("standby_zone", "automatic"))
		if role == "waiter"
		else "automatic"
	)
	var target_cell := _staff_standby_target(agent, role, waiter_zone)
	# First prefer open room cells. If the player's layout is extremely dense,
	# allow a two-neighbour cell but never a one-cell doorway/dead end.
	for minimum_neighbors: int in [3, 2]:
		for y: int in GRID_SIZE.y:
			for x: int in GRID_SIZE.x:
				var cell := Vector2i(x, y)
				if astar.is_point_solid(cell) or _open_neighbor_count(cell) < minimum_neighbors:
					continue
				var entrance_clearance := 2.5 if waiter_zone == "entrance" else 3.0
				if (
					cell.distance_to(entrance_cell) < entrance_clearance
					or _grid_path(world_to_cell(agent.global_position), cell).is_empty()
				):
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
				var wrong_zone := false
				if role == "waiter" and waiter_zone != "pass":
					wrong_zone = y >= 8
				elif role != "waiter":
					wrong_zone = y < 8
				var score := (
					cell.distance_to(target_cell) * 2.0
					+ cell.distance_to(world_to_cell(agent.global_position)) * 0.12
				)
				if wrong_zone:
					score += 30.0
				# Stable per-worker horizontal preference spreads the brigade instead
				# of selecting the first equally good tile for everyone.
				if waiter_zone in ["automatic", "dining"] or role != "waiter":
					var preferred_x := 2 + posmod(String(agent.name).hash(), GRID_SIZE.x - 4)
					score += absf(float(x - preferred_x)) * 0.18
				if score < best_score:
					best_score = score
					best_cell = cell
		if best_score < INF:
			break
	staff_standby_reservations[key] = best_cell
	return cell_to_world(best_cell)


func _staff_standby_target(
	agent: AnimatedAgent,
	role: String,
	waiter_zone: String = "automatic"
) -> Vector2i:
	var stable_x := 2 + posmod(String(agent.name).hash(), GRID_SIZE.x - 4)
	if role != "waiter":
		return Vector2i(stable_x, 11)
	match waiter_zone:
		"entrance":
			return Vector2i(entrance_cell.x, mini(entrance_cell.y + 3, GRID_SIZE.y - 2))
		"pass":
			for object: PlacedObject in placed_objects.values():
				if is_instance_valid(object) and object.station_id == "pass":
					return object.grid_cell
			return Vector2i(stable_x, 7)
		_:
			return Vector2i(stable_x, 5)


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
	cell.x = clampi(cell.x, LOT_REGION.position.x, LOT_REGION.end.x - 1)
	cell.y = clampi(cell.y, LOT_REGION.position.y, LOT_REGION.end.y - 1)
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


func spawn_customer_group(requested_group_size: int = -1) -> bool:
	if GameState.restaurant_state != "open":
		return false
	var group_size := requested_group_size
	if group_size <= 0:
		group_size = _spawnable_customer_group_size()
	if group_size <= 0 or not can_accept_customer_group(group_size):
		return false
	var customer := CustomerAgent.new()
	customer_root.add_child(customer)
	customer.global_position = customer_spawn_position(customer)
	customer.setup(self, group_size)
	return true


func enqueue_customer(customer: Node) -> void:
	_cleanup_customer_flow()
	if customer != null and is_instance_valid(customer) and not customer_queue.has(customer):
		customer_queue.append(customer)


func dequeue_customer(customer: Node) -> void:
	customer_queue.erase(customer)
	release_waiting_position(customer)


func customer_is_queue_head(customer: Node) -> bool:
	_cleanup_customer_flow()
	return not customer_queue.is_empty() and customer_queue[0] == customer


func customer_can_request_table(customer: Node, group_size: int) -> bool:
	# FIFO remains the default, but a party that cannot fit any currently free
	# table no longer blocks smaller compatible parties behind it. This mirrors
	# the first-fit host logic used by restaurant management games while keeping
	# visual queue order stable.
	_cleanup_customer_flow()
	for queued: Node in customer_queue:
		if queued == null or not is_instance_valid(queued):
			continue
		if queued == customer:
			return not _table_candidates(customer, group_size).is_empty()
		var reserved: Variant = queued.get("table")
		if reserved is Dictionary and not (reserved as Dictionary).is_empty():
			var reserved_uid := String((reserved as Dictionary).get("uid", ""))
			if customer_owns_table(queued, reserved_uid):
				return false
		var earlier_size := int(queued.get("group_size"))
		if not _table_candidates(queued, earlier_size).is_empty():
			return false
	return false


func customer_queue_positions(customer: Node) -> Array[Vector3]:
	_cleanup_customer_flow()
	var result: Array[Vector3] = []
	var ordinal := 0
	for queued: Node in customer_queue:
		if queued == customer:
			break
		ordinal += int(queued.get("group_size"))
	var size := int(customer.get("group_size")) if customer != null and is_instance_valid(customer) else 1
	# Keep the pavement directly in front of the door free. Human-scale spacing
	# lets the maximum eight four-person parties fit on the straight sidewalk
	# without ever sharing a destination at the far end of the lot.
	var queue_origin := cell_to_world(Vector2i(entrance_cell.x + 1, QUEUE_ROW))
	var queue_end_x := cell_to_world(Vector2i(LOT_REGION.end.x - 1, QUEUE_ROW)).x
	for member_index: int in size:
		var queue_x := minf(queue_origin.x + float(ordinal + member_index) * CUSTOMER_QUEUE_SPACING, queue_end_x)
		result.append(Vector3(queue_x, 0.0, queue_origin.z))
	return result


func customer_spawn_position(_customer: Node = null) -> Vector3:
	return cell_to_world(Vector2i(LOT_REGION.end.x - 1, QUEUE_ROW))


func customer_inside_door_position(member_index: int = 0) -> Vector3:
	var base := cell_to_world(entrance_cell)
	return base + Vector3((float(member_index % 2) - 0.5) * 0.16, 0.0, 0.18)


func customer_outside_door_position(member_index: int = 0) -> Vector3:
	var base := cell_to_world(Vector2i(entrance_cell.x, EXIT_ROW))
	return base + Vector3((float(member_index % 2) - 0.5) * 0.16, 0.0, 0.0)


func customer_despawn_position(member_index: int = 0) -> Vector3:
	return cell_to_world(Vector2i(LOT_REGION.position.x, EXIT_ROW)) + Vector3(0.0, 0.0, float(member_index % 2) * 0.16)


func position_is_inside_restaurant(position: Vector3) -> bool:
	return world_to_cell(position).y >= 0


func try_begin_customer_entry(customer: Node) -> bool:
	_cleanup_customer_flow()
	if customer == null or not is_instance_valid(customer) or not exit_wait_queue.is_empty():
		return false
	var next_reserved: Node
	for queued: Node in customer_queue:
		if queued == null or not is_instance_valid(queued):
			continue
		var reservation: Variant = queued.get("table")
		if reservation is Dictionary and not (reservation as Dictionary).is_empty() and customer_owns_table(queued, String((reservation as Dictionary).get("uid", ""))):
			next_reserved = queued
			break
	if next_reserved != customer:
		return false
	if door_owner == null:
		door_owner = customer
	return door_owner == customer


func finish_customer_entry(customer: Node) -> void:
	if door_owner == customer:
		door_owner = null


func register_customer_exit(customer: Node) -> void:
	if customer != null and is_instance_valid(customer):
		exiting_customers[customer.get_instance_id()] = customer
		if not exit_wait_queue.has(customer):
			exit_wait_queue.append(customer)


func try_begin_customer_exit(customer: Node) -> bool:
	register_customer_exit(customer)
	_cleanup_customer_flow()
	if door_owner == null and not exit_wait_queue.is_empty() and exit_wait_queue[0] == customer:
		door_owner = customer
	return door_owner == customer


func finish_customer_exit(customer: Node) -> void:
	if customer != null:
		exiting_customers.erase(customer.get_instance_id())
		exit_wait_queue.erase(customer)
	if door_owner == customer:
		door_owner = null


func _cleanup_customer_flow() -> void:
	for queued: Node in customer_queue.duplicate():
		if queued == null or not is_instance_valid(queued) or queued.is_queued_for_deletion():
			customer_queue.erase(queued)
	for key: int in exiting_customers.keys():
		var candidate := exiting_customers.get(key) as Node
		if candidate == null or not is_instance_valid(candidate) or candidate.is_queued_for_deletion():
			exiting_customers.erase(key)
	for candidate: Node in exit_wait_queue.duplicate():
		if candidate == null or not is_instance_valid(candidate) or candidate.is_queued_for_deletion() or not exiting_customers.has(candidate.get_instance_id()):
			exit_wait_queue.erase(candidate)
	if door_owner != null and (not is_instance_valid(door_owner) or door_owner.is_queued_for_deletion()):
		door_owner = null


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


func _spawnable_customer_group_size() -> int:
	return CustomerCapacityPlanner.spawnable_group_size(self)


func request_table(customer: Node, group_size: int) -> Dictionary:
	var candidates := _table_candidates(customer, group_size)
	if candidates.is_empty():
		return {}
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


func _table_candidates(customer: Node, group_size: int) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for uid: String in table_occupants:
		if table_occupants[uid] != null and not is_instance_valid(table_occupants[uid]):
			table_occupants[uid] = null
		if table_occupants[uid] != null:
			continue
		if table_dirty_records.has(uid):
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
	candidates.sort_custom(func(a: Dictionary, b: Dictionary): return float(a.score) < float(b.score))
	return candidates


func customer_owns_table(customer: Node, table_uid: String) -> bool:
	return not table_uid.is_empty() and table_occupants.get(table_uid) == customer and is_instance_valid(placed_objects.get(table_uid))


func release_table(customer: Node) -> void:
	for uid: String in table_occupants:
		if table_occupants[uid] == customer:
			table_occupants[uid] = null
	release_waiting_position(customer)


func day_cycle_manager() -> Node:
	if _day_cycle_manager == null or not is_instance_valid(_day_cycle_manager):
		_day_cycle_manager = get_tree().root.get_node_or_null("DayCycleManager")
	return _day_cycle_manager


func set_rush_mode(enabled: bool) -> void:
	# Backward-compatible debug entry point. Normal rush state is exclusively
	# derived from the configured world clock.
	_debug_force_rush_fallback = enabled
	var manager := day_cycle_manager()
	if manager != null and manager.has_method("force_rush_debug"):
		manager.call("force_rush_debug", enabled)
	if enabled:
		_spawn_clock = 0.0


func is_rush_active() -> bool:
	var manager := day_cycle_manager()
	if manager != null:
		return bool(manager.get("rush_active"))
	return _debug_force_rush_fallback


func customer_seat_count() -> int:
	return CustomerCapacityPlanner.seat_count(self)


func customer_table_count() -> int:
	return CustomerCapacityPlanner.table_count(self)


func customer_group_cap() -> int:
	var manager := day_cycle_manager()
	if manager != null and manager.has_method("group_cap"):
		return int(manager.call("group_cap", customer_table_count()))
	if customer_table_count() <= 0:
		return 0
	var queue_buffer := maxi(int(DataRegistry.balance_value("traffic.queue_buffer_groups", 0)), 0)
	var configured_cap := maxi(int(DataRegistry.balance_value("traffic.absolute_group_cap", 1)), 1)
	return mini(customer_table_count() + queue_buffer, configured_cap)


func can_accept_customer_group(group_size: int) -> bool:
	if group_size <= 0:
		return false
	return bool(customer_capacity_snapshot(group_size).get("accepts_proposed", false))


func customer_capacity_snapshot(proposed_group_size: int = 0) -> Dictionary:
	return CustomerCapacityPlanner.snapshot(self, proposed_group_size)


func effective_customer_spawn_interval(has_producible_recipe: bool = true) -> float:
	var manager := day_cycle_manager()
	if manager != null and manager.has_method("effective_spawn_interval"):
		return maxf(float(manager.call("effective_spawn_interval", GameState.reputation, has_producible_recipe, -1.0)), 0.05)
	return maxf(float(DataRegistry.balance_value("traffic.base_spawn_interval", 1.0)), 0.05)


func has_producible_active_recipe() -> bool:
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		var recipe_id := String(recipe.get("id", ""))
		if GameState.is_recipe_sold_out(recipe_id):
			continue
		var requirements := DataRegistry.recipe_raw_requirements(recipe)
		var available := true
		for ingredient_id: String in requirements:
			if not GameState.stock.has(ingredient_id):
				continue
			var stock_entry: Dictionary = GameState.stock.get(ingredient_id, {})
			var free_amount := int(stock_entry.get("amount", 0)) - int(stock_entry.get("reserved", 0))
			if free_amount < int(requirements[ingredient_id]):
				available = false
				break
		if available:
			return true
	return false


func traffic_flow_status() -> Dictionary:
	var producible := has_producible_active_recipe()
	var capacity := customer_capacity_snapshot()
	return {
		"has_producible_recipe": producible,
		"warning": "Nessuna ricetta producibile: afflusso ridotto" if not producible else "",
		"interval": effective_customer_spawn_interval(producible),
		"group_cap": customer_group_cap(),
		"active_groups": SimulationManager.customers.size(),
		"capacity": capacity,
	}


func waiting_position(customer: Node) -> Vector3:
	var positions := customer_queue_positions(customer)
	return positions[0] if not positions.is_empty() else customer_spawn_position(customer)


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
		var away := table_object.global_position.direction_to(chair.global_position)
		away.y = 0.0
		if away.length_squared() <= 0.001:
			away = Vector3.FORWARD
		var staging_position := chair.global_position + away.normalized() * 0.82
		staging_position.y = 0.0
		result.append({
			"chair_uid": chair.uid,
			"slot": chair.attachment_slot,
			"chair_position": chair.global_position,
			"position": occupant_position,
			"staging_position": staging_position,
			"exit_staging_position": staging_position,
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


func adopt_dirty_table(_customer: Node, table_uid: String, source_dishes: Array) -> void:
	if table_uid.is_empty() or not placed_objects.has(table_uid):
		return
	var dirty_nodes: Array[Node3D] = []
	var container_kinds: Array[String] = []
	for source: Node3D in source_dishes:
		if source == null or not is_instance_valid(source):
			continue
		var source_position := source.global_position
		var source_rotation := source.global_rotation
		var kind := String(source.get_meta("consumption_container", "plate"))
		source.queue_free()
		var dirty := FoodVisualFactory.instantiate_canonical_container(kind, true)
		dirty.name = "DirtyContainer_%02d" % dirty_nodes.size()
		cleanup_root.add_child(dirty)
		dirty.global_position = source_position
		dirty.global_rotation = source_rotation
		dirty_nodes.append(dirty)
		container_kinds.append(String(dirty.get_meta("canonical_container_kind", "plate")))
	if dirty_nodes.is_empty():
		return
	var table_object := placed_objects.get(table_uid) as PlacedObject
	var service_position := _service_position_for_table(table_object) if table_object != null else cell_to_world(entrance_cell)
	var sink_position := _sink_interaction_position()
	table_dirty_records[table_uid] = {
		"table_uid": table_uid,
		"nodes": dirty_nodes,
		"container_kinds": container_kinds,
		"state": "dirty",
		"service_position": service_position
	}
	var task := SimulationManager.request_service(self, "collect_dishes", service_position, {
		"table_uid": table_uid,
		"reservation_key": "dirty:%s" % table_uid,
		"secondary_target": sink_position,
		"carry_model": FoodVisualFactory.canonical_container_path(container_kinds[0], true),
		"container_kinds": container_kinds
	})
	if not task.is_empty():
		table_dirty_records[table_uid].task_id = String(task.id)
	_refresh_ambience()


func accepts_service_action(action: String, payload: Dictionary = {}) -> bool:
	if action != "collect_dishes":
		return false
	var table_uid := String(payload.get("table_uid", ""))
	if not table_dirty_records.has(table_uid):
		return false
	return String(table_dirty_records[table_uid].get("state", "")) in ["dirty", "busing"]


func service_task_stage(action: String, payload: Dictionary, stage: String) -> void:
	if action != "collect_dishes" or stage != "pickup":
		return
	var table_uid := String(payload.get("table_uid", ""))
	if not table_dirty_records.has(table_uid):
		return
	var record: Dictionary = table_dirty_records[table_uid]
	record.state = "busing"
	for node: Node3D in record.get("nodes", []):
		if is_instance_valid(node):
			node.visible = false


func service_completed(action: String, payload: Dictionary) -> void:
	if action != "collect_dishes":
		return
	var table_uid := String(payload.get("table_uid", ""))
	if not table_dirty_records.has(table_uid):
		return
	var record: Dictionary = table_dirty_records[table_uid]
	for node: Node3D in record.get("nodes", []):
		if is_instance_valid(node):
			node.queue_free()
	table_dirty_records.erase(table_uid)
	wash_batches[table_uid] = {
		"table_uid": table_uid,
		"dish_count": maxi((record.get("container_kinds", []) as Array).size(), 1),
		"state": "waiting",
	}
	var station_available := SimulationManager.stations.has("sink") and not (SimulationManager.stations.get("sink", []) as Array).is_empty()
	SimulationManager.request_maintenance_task(self, "wash_dishes", _sink_interaction_position(), {
		"table_uid": table_uid,
		"reservation_key": "wash:%s" % table_uid,
		"station_id": "sink" if station_available else "",
		"animation": "PickUp"
	}, 2, 2.4, "res://assets/cleaning/Cleaning_Sponge.glb")
	_refresh_ambience()


func _sink_interaction_position() -> Vector3:
	for runtime: Dictionary in SimulationManager.stations.get("sink", []):
		var positions: Array = runtime.get("interaction_positions", [])
		if not positions.is_empty():
			return Vector3(positions[0])
	return cell_to_world(Vector2i(7, 11))


func _spawn_service_spill() -> void:
	if spill_records.size() >= 3 or cleanup_root == null:
		return
	var candidates: Array[Vector2i] = []
	for y: int in range(1, GRID_SIZE.y - 1):
		for x: int in range(1, GRID_SIZE.x - 1):
			var cell := Vector2i(x, y)
			if astar.is_point_solid(cell) or _grid_path(entrance_cell, cell).is_empty():
				continue
			var occupied_by_spill := false
			for record: Dictionary in spill_records.values():
				if Vector2i(record.get("cell", Vector2i(-99, -99))).distance_to(cell) < 2.0:
					occupied_by_spill = true
					break
			if not occupied_by_spill:
				candidates.append(cell)
	if candidates.is_empty():
		return
	candidates.shuffle()
	_spill_serial += 1
	var spill_id := "spill_%04d" % _spill_serial
	var cell := candidates[0]
	var visual := _create_spill_visual(spill_id)
	cleanup_root.add_child(visual)
	visual.global_position = cell_to_world(cell) + Vector3.UP * 0.035
	spill_records[spill_id] = {"id": spill_id, "cell": cell, "node": visual, "state": "dirty"}
	var task := SimulationManager.request_maintenance_task(self, "clean_spill", visual.global_position, {
		"spill_id": spill_id,
		"reservation_key": spill_id,
		"animation": "PickUp"
	}, 2, 1.8, "res://assets/cleaning/Tool_Mop.glb")
	if not task.is_empty():
		spill_records[spill_id].task_id = String(task.id)
	_refresh_ambience()


func _create_spill_visual(spill_id: String) -> Node3D:
	var root := Node3D.new()
	root.name = spill_id
	var material := StandardMaterial3D.new()
	material.albedo_color = [Color("79533acb"), Color("b58a45c9"), Color("778b4dcc")].pick_random()
	material.roughness = 0.88
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for index: int in 3:
		var blob := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.22 + float(index) * 0.06
		mesh.bottom_radius = mesh.top_radius
		mesh.height = 0.012
		mesh.radial_segments = 14
		mesh.material = material
		blob.mesh = mesh
		blob.scale = Vector3(randf_range(0.75, 1.4), 1.0, randf_range(0.55, 1.05))
		blob.position = Vector3(randf_range(-0.24, 0.24), float(index) * 0.004, randf_range(-0.18, 0.18))
		blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(blob)
	return root


func accepts_maintenance_action(action: String, payload: Dictionary = {}) -> bool:
	match action:
		"clean_spill":
			var spill_id := String(payload.get("spill_id", ""))
			return spill_records.has(spill_id) and String(spill_records[spill_id].get("state", "")) != "clean"
		"wash_dishes":
			return wash_batches.has(String(payload.get("table_uid", "")))
		"clean_kitchen":
			return kitchen_dirt > 0.01
		"remove_pest":
			var incident_id := String(payload.get("incident_id", ""))
			return pest_visuals.has(incident_id) and String(pest_visuals[incident_id].get("state", "visible")) != "resolved"
	return false


func maintenance_started(action: String, payload: Dictionary, _employee_id: String) -> void:
	if action == "clean_spill":
		var spill_id := String(payload.get("spill_id", ""))
		if spill_records.has(spill_id):
			spill_records[spill_id].state = "cleaning"
	elif action == "remove_pest":
		var incident_id := String(payload.get("incident_id", ""))
		if pest_visuals.has(incident_id):
			pest_visuals[incident_id].state = "cleaning"


func maintenance_completed(action: String, payload: Dictionary) -> void:
	match action:
		"clean_spill":
			var spill_id := String(payload.get("spill_id", ""))
			if spill_records.has(spill_id):
				var node := spill_records[spill_id].get("node") as Node3D
				if node != null and is_instance_valid(node):
					node.queue_free()
				spill_records.erase(spill_id)
		"wash_dishes":
			wash_batches.erase(String(payload.get("table_uid", "")))
		"clean_kitchen":
			var cleaning_amount := float(DataRegistry.balance_value("cleanliness.kitchen_clean_amount", 18.0))
			kitchen_dirt = maxf(kitchen_dirt - maxf(cleaning_amount, 0.0), 0.0)
			_refresh_kitchen_dirt_visuals()
			_ensure_kitchen_cleaning_task()
		"remove_pest":
			var incident_id := String(payload.get("incident_id", ""))
			if pest_visuals.has(incident_id):
				var pest_node := pest_visuals[incident_id].get("node") as Node3D
				if pest_node != null and is_instance_valid(pest_node):
					pest_node.queue_free()
				pest_visuals.erase(incident_id)
			if ambience_system != null:
				ambience_system.resolve_pest(incident_id, "removed_by_handyman")
	_refresh_ambience()


func set_floor_style(cell: Vector2i, item_id: String) -> void:
	if not LOT_REGION.has_point(cell) or floor_root == null:
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
		var source := _floor_source(style)
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
		var tile_scale := 1.0 if style in ["floor_grass", "floor_road", "floor_sidewalk"] else 0.5
		for index: int in cells.size():
			var cell: Vector2i = cells[index]
			var tile_basis := Basis.IDENTITY.scaled(Vector3.ONE * tile_scale)
			var tile_transform := Transform3D(tile_basis, cell_to_world(cell))
			multimesh.set_instance_transform(index, tile_transform * mesh_transform)
		var batch := MultiMeshInstance3D.new()
		batch.name = "FloorBatch_%s" % style
		batch.multimesh = multimesh
		batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		floor_root.add_child(batch)
		floor_batches[style] = batch
		source.free()
	_create_road_markings()


func _floor_source(style: String) -> Node3D:
	if style in ["floor_sidewalk", "floor_grass", "floor_road"]:
		var root := Node3D.new()
		var mesh_instance := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(CELL_SIZE, 0.10, CELL_SIZE)
		var material := StandardMaterial3D.new()
		match style:
			"floor_sidewalk": material.albedo_color = Color("d8c8a7")
			"floor_road": material.albedo_color = Color("41474a")
			_: material.albedo_color = Color("78ad55")
		material.roughness = 0.92
		box.material = material
		mesh_instance.mesh = box
		mesh_instance.position.y = -0.045
		root.add_child(mesh_instance)
		return root
	var path := "res://assets/environment/floor_kitchen_styleB.gltf"
	match style:
		"floor_kitchen": path = "res://assets/environment/floor_kitchen.gltf"
	return ModelFactory.instantiate_model(path)


func _create_road_markings() -> void:
	if ROAD_ROWS.is_empty() or floor_root == null:
		return
	var left := cell_to_world(Vector2i(LOT_REGION.position.x, ROAD_ROWS[0])).x - CELL_SIZE * 0.5
	var right := cell_to_world(Vector2i(LOT_REGION.end.x - 1, ROAD_ROWS[0])).x + CELL_SIZE * 0.5
	var first_z := cell_to_world(Vector2i(entrance_cell.x, ROAD_ROWS[0])).z
	var last_z := cell_to_world(Vector2i(entrance_cell.x, ROAD_ROWS.back())).z
	var road_min_z := minf(first_z, last_z) - CELL_SIZE * 0.5
	var road_max_z := maxf(first_z, last_z) + CELL_SIZE * 0.5
	var center_z := (road_min_z + road_max_z) * 0.5
	var mesh := ImmediateMesh.new()
	var edge_material := StandardMaterial3D.new()
	edge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge_material.albedo_color = Color("f2eee3")
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, edge_material)
	_add_road_quad(mesh, left, right, road_min_z + 0.24, road_min_z + 0.36)
	_add_road_quad(mesh, left, right, road_max_z - 0.36, road_max_z - 0.24)
	mesh.surface_end()
	var center_material := StandardMaterial3D.new()
	center_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	center_material.albedo_color = Color("f3bd3b")
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, center_material)
	var dash_x := left + 0.8
	while dash_x < right - 0.4:
		var dash_end := minf(dash_x + 2.25, right - 0.4)
		_add_road_quad(mesh, dash_x, dash_end, center_z - 0.19, center_z - 0.08)
		_add_road_quad(mesh, dash_x, dash_end, center_z + 0.08, center_z + 0.19)
		dash_x += 4.0
	mesh.surface_end()
	var markings := MeshInstance3D.new()
	markings.name = "RoadMarkings"
	markings.mesh = mesh
	markings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	floor_root.add_child(markings)


func _add_road_quad(mesh: ImmediateMesh, x_min: float, x_max: float, z_min: float, z_max: float) -> void:
	var height := 0.018
	mesh.surface_add_vertex(Vector3(x_min, height, z_min))
	mesh.surface_add_vertex(Vector3(x_max, height, z_min))
	mesh.surface_add_vertex(Vector3(x_max, height, z_max))
	mesh.surface_add_vertex(Vector3(x_min, height, z_min))
	mesh.surface_add_vertex(Vector3(x_max, height, z_max))
	mesh.surface_add_vertex(Vector3(x_min, height, z_max))


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
	var left := cell_to_world(LOT_REGION.position).x - CELL_SIZE * 0.5
	var right := cell_to_world(Vector2i(LOT_REGION.end.x - 1, LOT_REGION.position.y)).x + CELL_SIZE * 0.5
	var top := cell_to_world(LOT_REGION.position).z - CELL_SIZE * 0.5
	var bottom := cell_to_world(Vector2i(LOT_REGION.position.x, LOT_REGION.end.y - 1)).z + CELL_SIZE * 0.5
	for x: int in range(LOT_REGION.size.x + 1):
		var world_x := left + x * CELL_SIZE
		mesh.surface_add_vertex(Vector3(world_x, 0.09, top))
		mesh.surface_add_vertex(Vector3(world_x, 0.09, bottom))
	for y: int in range(LOT_REGION.size.y + 1):
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
