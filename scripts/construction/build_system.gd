class_name BuildSystem
extends Node

signal mode_changed(active: bool)
signal preview_changed(valid: bool, reason: String, cost: int)
signal selection_changed(object: PlacedObject)

var world: RestaurantWorld
var camera: Camera3D
var active := false
var current_definition: Dictionary = {}
var preview: Node3D
var preview_visual: Node3D
var preview_access_marker: MeshInstance3D
var preview_replaced_edge: PlacedObject
var preview_cell := Vector2i(-1, -1)
var rotation_steps := 0
var preview_support_uid := ""
var preview_attachment_slot := -1
var preview_pinned := false
var selected_object: PlacedObject
var move_source: PlacedObject
var reason := ""
var placement_valid := false
var selection_marker: MeshInstance3D
var move_origin_marker: MeshInstance3D
var _preview_target_position := Vector3.ZERO
var _preview_target_rotation := 0.0
var _preview_transform_initialized := false
var _moving_dependents: Array[PlacedObject] = []


func setup(value_world: RestaurantWorld, value_camera: Camera3D) -> void:
	world = value_world
	camera = value_camera
	set_process(true)


func _process(delta: float) -> void:
	if preview == null or not is_instance_valid(preview) or not _preview_transform_initialized:
		return
	# Edge pieces must communicate one exact grid segment. Interpolating a wall
	# between two sides made the cursor feel imprecise and the selected edge
	# visually ambiguous, especially on touch screens.
	if world.is_edge_placement(current_definition) or String(current_definition.get("placement", "cell")) == "wall_mount":
		preview.position = _preview_target_position
		preview.rotation.y = _preview_target_rotation
		return
	var response := 1.0 - exp(-delta * (26.0 if preview_pinned else 18.0))
	preview.position = preview.position.lerp(_preview_target_position, response)
	preview.rotation.y = lerp_angle(preview.rotation.y, _preview_target_rotation, response)


func start_place(item_id: String) -> void:
	var definition: Dictionary = DataRegistry.build_by_id.get(item_id, {})
	if definition.is_empty():
		return
	if not can_edit_definition(definition):
		GameState.toast_requested.emit("Durante il servizio puoi modificare solo piante e decorazioni", "warning")
		return
	cancel_preview()
	current_definition = definition.duplicate(true)
	active = true
	rotation_steps = 0
	preview_support_uid = ""
	preview_attachment_slot = -1
	preview_pinned = false
	preview_cell = world.world_to_cell(world.camera_rig.target)
	_create_preview()
	_sync_preview_transform()
	_clear_selection(false)
	world.set_grid_visible(true)
	mode_changed.emit(true)


func move_selected() -> void:
	if selected_object == null or not is_instance_valid(selected_object) or not can_edit_definition(selected_object.definition):
		return
	_clear_preview_only()
	move_source = selected_object
	current_definition = move_source.definition.duplicate(true)
	preview_cell = move_source.grid_cell
	rotation_steps = move_source.rotation_steps
	preview_support_uid = move_source.support_uid
	preview_attachment_slot = move_source.attachment_slot
	preview_pinned = false
	world.set_object_occupancy(move_source, false)
	_moving_dependents = world.attached_objects(move_source.uid)
	active = true
	_create_preview()
	_create_move_origin_marker()
	_sync_preview_transform()
	_clear_selection(false)
	world.set_grid_visible(true)
	mode_changed.emit(true)


func sell_selected() -> bool:
	if selected_object == null or not is_instance_valid(selected_object) or not can_edit_definition(selected_object.definition):
		return false
	var attached := world.attached_objects(selected_object.uid)
	var removal_cost := maxi(int(selected_object.definition.get("removal_cost", 0)), 0)
	if removal_cost > 0:
		if not GameState.spend(removal_cost, "Rimozione %s" % selected_object.definition.name):
			GameState.toast_requested.emit("Monete insufficienti per la rimozione", "warning")
			return false
	else:
		var refund := int(round(float(selected_object.definition.get("price", 0)) * 0.6))
		for dependent: PlacedObject in attached:
			refund += int(round(float(dependent.definition.get("price", 0)) * 0.6))
		GameState.earn(refund, "Vendita %s%s" % [selected_object.definition.name, " con %d agganci" % attached.size() if not attached.is_empty() else ""])
	world.remove_placed_object(selected_object)
	_clear_selection()
	SaveManager.save_game()
	return true


func confirm() -> bool:
	if not active or current_definition.is_empty():
		return false
	if not can_edit_definition(current_definition):
		GameState.toast_requested.emit("Elemento operativo bloccato durante il servizio", "warning")
		return false
	var validation := world.validate_placement(current_definition, preview_cell, rotation_steps, move_source, preview_support_uid, preview_attachment_slot)
	if not bool(validation.valid):
		GameState.toast_requested.emit(String(validation.reason), "warning")
		return false
	var is_move := move_source != null and is_instance_valid(move_source)
	var replaced_wall: PlacedObject = world.structural_edge_at(preview_cell, rotation_steps, move_source) if world.is_edge_placement(current_definition) else null
	var cost := 0 if is_move else int(current_definition.price)
	if cost > 0 and not GameState.spend(cost, current_definition.name):
		GameState.toast_requested.emit("Monete insufficienti", "warning")
		return false
	if replaced_wall != null:
		preview_cell = replaced_wall.grid_cell
		rotation_steps = replaced_wall.rotation_steps
	var placed: PlacedObject
	if is_move:
		var old_source := move_source
		move_source = null
		world.move_layout_object(old_source, preview_cell, rotation_steps, preview_support_uid, preview_attachment_slot)
		placed = old_source
	if replaced_wall != null and is_instance_valid(replaced_wall):
		world.remove_placed_object(replaced_wall, true)
	if not is_move:
		placed = world.add_layout_object(String(current_definition.id), preview_cell, rotation_steps, preview_support_uid, preview_attachment_slot)
	_finish_preview()
	select_object(placed)
	SaveManager.save_game()
	return true


func cancel_preview() -> void:
	_clear_preview_only()
	if move_source and is_instance_valid(move_source):
		world.set_object_occupancy(move_source, true)
		select_object(move_source)
	move_source = null
	_moving_dependents.clear()
	active = false
	current_definition = {}
	preview_support_uid = ""
	preview_attachment_slot = -1
	preview_pinned = false
	placement_valid = false
	reason = ""
	if world:
		world.set_grid_visible(world.show_grid)
	mode_changed.emit(false)


func rotate_preview() -> void:
	if not active:
		return
	if String(current_definition.get("placement", "cell")) == "seat" and not preview_support_uid.is_empty():
		preview_attachment_slot = posmod(preview_attachment_slot + 1, 4)
		var support := world.placed_objects.get(preview_support_uid) as PlacedObject
		if support != null:
			rotation_steps = world.seat_rotation_for_slot(preview_attachment_slot, support.rotation_steps)
	else:
		rotation_steps = (rotation_steps + 1) % 4
	_sync_preview_transform()


func rotate_preview_back() -> void:
	if not active:
		return
	if String(current_definition.get("placement", "cell")) == "seat" and not preview_support_uid.is_empty():
		preview_attachment_slot = posmod(preview_attachment_slot - 1, 4)
		var support := world.placed_objects.get(preview_support_uid) as PlacedObject
		if support != null:
			rotation_steps = world.seat_rotation_for_slot(preview_attachment_slot, support.rotation_steps)
	else:
		rotation_steps = posmod(rotation_steps - 1, 4)
	_sync_preview_transform()


func select_object(object: PlacedObject) -> void:
	selected_object = object if object != null and is_instance_valid(object) else null
	_update_selection_marker()
	selection_changed.emit(selected_object)


func select_cell(cell: Vector2i) -> void:
	select_object(world.object_at_cell(cell))


func clear_selection() -> void:
	_clear_selection()


func pointer_moved(screen_position: Vector2) -> void:
	if not active or preview_pinned:
		return
	var target := _screen_to_placement_target(screen_position)
	if _target_changed(target):
		_apply_target(target)
		_sync_preview_transform()


func pointer_pressed(screen_position: Vector2) -> void:
	if active:
		var target := _screen_to_placement_target(screen_position)
		_apply_target(target)
		preview_pinned = true
		_sync_preview_transform()
	elif GameState.restaurant_state in ["closed", "open"]:
		var cell := _screen_to_cell(screen_position)
		var hit_object := _object_from_screen(screen_position)
		if hit_object == null:
			var edge_target := _nearest_edge_target(screen_position, null)
			hit_object = world.structural_edge_at(Vector2i(edge_target.cell), int(edge_target.rotation))
		select_object(hit_object if hit_object else world.object_at_cell(cell))


func can_edit_definition(definition: Dictionary) -> bool:
	if GameState.restaurant_state == "closed":
		return true
	return GameState.restaurant_state == "open" and String(definition.get("id", "")) in ["decoration", "plant"]


func _screen_to_cell(screen_position: Vector2) -> Vector2i:
	var hit: Variant = _screen_to_floor(screen_position)
	if hit == null:
		return Vector2i(-1, -1)
	return world.world_to_cell(hit)


func _screen_to_placement_target(screen_position: Vector2) -> Dictionary:
	var hit: Variant = _screen_to_floor(screen_position)
	if hit == null:
		return {"cell": Vector2i(-1, -1), "rotation": rotation_steps, "support_uid": "", "attachment_slot": -1}
	var world_hit := Vector3(hit)
	if String(current_definition.get("placement", "cell")) in ["seat", "surface"]:
		var ray_hit := _raycast_screen(screen_position)
		if not ray_hit.is_empty():
			world_hit = Vector3(ray_hit.get("position", world_hit))
		return world.attachment_target_at(current_definition, world_hit, rotation_steps, move_source)
	var cell := world.world_to_cell(world_hit)
	var target_rotation := rotation_steps
	if world.is_edge_placement(current_definition) or String(current_definition.get("placement", "cell")) == "wall_mount":
		var edge_target := _nearest_edge_target(screen_position, world_hit)
		cell = Vector2i(edge_target.cell)
		target_rotation = int(edge_target.rotation)
	var support_uid := ""
	var attachment_slot := -1
	if String(current_definition.get("placement", "cell")) == "wall_mount":
		var wall := world.structural_edge_at(cell, target_rotation, move_source)
		if wall != null:
			support_uid = wall.uid
			attachment_slot = 0
			cell = wall.grid_cell
			target_rotation = wall.rotation_steps
	return {"cell": cell, "rotation": target_rotation, "support_uid": support_uid, "attachment_slot": attachment_slot}


func _nearest_edge_target(screen_position: Vector2, known_world_hit: Variant) -> Dictionary:
	var world_hit: Variant = known_world_hit
	if world_hit == null:
		world_hit = _screen_to_floor(screen_position)
	if world_hit == null:
		return {"cell": Vector2i(-1, -1), "rotation": rotation_steps, "key": ""}
	var center_cell := world.world_to_cell(Vector3(world_hit))
	var candidates: Dictionary = {}
	for offset: Vector2i in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var candidate_cell := center_cell + offset
		if not RestaurantWorld.LOT_REGION.has_point(candidate_cell):
			continue
		for candidate_rotation: int in 4:
			var key := world.edge_key(candidate_cell, candidate_rotation)
			if candidates.has(key):
				continue
			var canonical := _canonical_edge_target(key)
			if Vector2i(canonical.cell) == Vector2i(-1, -1):
				continue
			var segment := _edge_screen_segment(Vector2i(canonical.cell), int(canonical.rotation))
			var nearest := Geometry2D.get_closest_point_to_segment(screen_position, Vector2(segment[0]), Vector2(segment[1]))
			canonical.distance = screen_position.distance_to(nearest)
			candidates[key] = canonical
	var best: Dictionary = {}
	for candidate: Dictionary in candidates.values():
		if best.is_empty() or float(candidate.distance) < float(best.distance):
			best = candidate
	# Twelve pixels of hysteresis keeps the chosen side stable around corners;
	# rotating/cycling still lets the player deliberately choose the neighbour.
	if preview_cell != Vector2i(-1, -1):
		var current_key := world.edge_key(preview_cell, rotation_steps)
		if candidates.has(current_key):
			var current: Dictionary = candidates[current_key]
			if best.is_empty() or float(current.distance) <= float(best.distance) + 12.0:
				best = current
	return best if not best.is_empty() else {"cell": center_cell, "rotation": rotation_steps, "key": world.edge_key(center_cell, rotation_steps)}


func _canonical_edge_target(key: String) -> Dictionary:
	var parts := key.split(":")
	if parts.size() != 3:
		return {"cell": Vector2i(-1, -1), "rotation": 0, "key": key}
	var axis := String(parts[0])
	var first := int(parts[1])
	var second := int(parts[2])
	if axis == "h":
		var north_cell := Vector2i(first, second)
		if RestaurantWorld.LOT_REGION.has_point(north_cell):
			return {"cell": north_cell, "rotation": 0, "key": key}
		var south_cell := Vector2i(first, second - 1)
		if RestaurantWorld.LOT_REGION.has_point(south_cell):
			return {"cell": south_cell, "rotation": 2, "key": key}
	else:
		var west_cell := Vector2i(first, second)
		if RestaurantWorld.LOT_REGION.has_point(west_cell):
			return {"cell": west_cell, "rotation": 1, "key": key}
		var east_cell := Vector2i(first - 1, second)
		if RestaurantWorld.LOT_REGION.has_point(east_cell):
			return {"cell": east_cell, "rotation": 3, "key": key}
	return {"cell": Vector2i(-1, -1), "rotation": 0, "key": key}


func _edge_screen_segment(cell: Vector2i, edge_rotation: int) -> Array[Vector2]:
	var center := world.cell_to_world(cell)
	var half := RestaurantWorld.CELL_SIZE * 0.5
	var first: Vector3
	var second: Vector3
	match posmod(edge_rotation, 4):
		0:
			first = center + Vector3(-half, 0.12, -half)
			second = center + Vector3(half, 0.12, -half)
		1:
			first = center + Vector3(-half, 0.12, -half)
			second = center + Vector3(-half, 0.12, half)
		2:
			first = center + Vector3(-half, 0.12, half)
			second = center + Vector3(half, 0.12, half)
		_:
			first = center + Vector3(half, 0.12, -half)
			second = center + Vector3(half, 0.12, half)
	return [camera.unproject_position(first), camera.unproject_position(second)]


func _target_changed(target: Dictionary) -> bool:
	return Vector2i(target.get("cell", Vector2i(-1, -1))) != preview_cell \
		or int(target.get("rotation", rotation_steps)) != rotation_steps \
		or String(target.get("support_uid", "")) != preview_support_uid \
		or int(target.get("attachment_slot", -1)) != preview_attachment_slot


func _apply_target(target: Dictionary) -> void:
	preview_cell = Vector2i(target.get("cell", Vector2i(-1, -1)))
	rotation_steps = int(target.get("rotation", rotation_steps))
	preview_support_uid = String(target.get("support_uid", ""))
	preview_attachment_slot = int(target.get("attachment_slot", -1))


func _screen_to_floor(screen_position: Vector2) -> Variant:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
	return hit


func _object_from_screen(screen_position: Vector2) -> PlacedObject:
	var origin := camera.project_ray_origin(screen_position)
	var ray_end := origin + camera.project_ray_normal(screen_position) * 250.0
	var excluded: Array[RID] = []
	var first_object: PlacedObject
	for _hit_index: int in 10:
		var query := PhysicsRayQueryParameters3D.create(origin, ray_end)
		query.exclude = excluded
		var result := world.get_world_3d().direct_space_state.intersect_ray(query)
		if result.is_empty():
			break
		var rid := RID(result.get("rid", RID()))
		if rid.is_valid():
			excluded.append(rid)
		var node := result.get("collider") as Node
		while node and not node is PlacedObject:
			node = node.get_parent()
		var object := node as PlacedObject
		if object == null:
			continue
		if first_object == null:
			first_object = object
		if world.is_attachment_placement(object.definition):
			return object
	return first_object


func _raycast_screen(screen_position: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(screen_position) * 250.0)
	var result := world.get_world_3d().direct_space_state.intersect_ray(query)
	return result


func _create_preview() -> void:
	preview = Node3D.new()
	preview.name = "PlacementPreview"
	_preview_transform_initialized = false
	preview_visual = ModelFactory.instantiate_build_visual(current_definition, not String(current_definition.id).begins_with("floor_"))
	preview_visual.name = "VisualModel"
	ModelFactory.align_visual_to_grid_origin(preview_visual, not String(current_definition.id).begins_with("floor_"))
	var preview_tint := String(current_definition.get("preview_tint", ""))
	if not preview_tint.is_empty():
		var tint_material := StandardMaterial3D.new()
		tint_material.albedo_color = Color(preview_tint)
		tint_material.roughness = 0.94
		for geometry: Node in preview_visual.find_children("*", "GeometryInstance3D", true, false):
			(geometry as GeometryInstance3D).material_override = tint_material
	preview.add_child(preview_visual)
	var raw: Array = current_definition.get("footprint", [1, 1])
	var footprint_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	if world.is_edge_placement(current_definition):
		box.size = Vector3(float(raw[0]) * RestaurantWorld.CELL_SIZE * 0.94, 0.035, 0.18)
	else:
		box.size = Vector3(float(raw[0]) * RestaurantWorld.CELL_SIZE * 0.94, 0.035, float(raw[1]) * RestaurantWorld.CELL_SIZE * 0.94)
	footprint_mesh.mesh = box
	footprint_mesh.position.y = 0.075
	preview.add_child(footprint_mesh)
	if move_source != null and is_instance_valid(move_source):
		for dependent: PlacedObject in _moving_dependents:
			if not is_instance_valid(dependent):
				continue
			var ghost := ModelFactory.instantiate_build_visual(dependent.definition)
			ModelFactory.align_visual_to_grid_origin(ghost)
			ghost.position = move_source.to_local(dependent.global_position)
			ghost.rotation.y = dependent.rotation.y - move_source.rotation.y
			preview.add_child(ghost)
	world.preview_root.add_child(preview)
	if not String(current_definition.get("station", "")).is_empty():
		preview_access_marker = MeshInstance3D.new()
		preview_access_marker.name = "FrontAccessMarker"
		var access_mesh := BoxMesh.new()
		access_mesh.size = Vector3(0.78, 0.035, 0.78)
		preview_access_marker.mesh = access_mesh
		var access_material := StandardMaterial3D.new()
		access_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		access_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		access_material.albedo_color = Color(0.2, 0.86, 0.92, 0.52)
		preview_access_marker.material_override = access_material
		world.preview_root.add_child(preview_access_marker)


func _create_move_origin_marker() -> void:
	if move_source == null or not is_instance_valid(move_source):
		return
	move_origin_marker = MeshInstance3D.new()
	move_origin_marker.name = "MoveOriginMarker"
	var mesh := BoxMesh.new()
	var edge_placement := world.is_edge_placement(move_source.definition)
	var attachment_placement := world.is_attachment_placement(move_source.definition)
	if edge_placement:
		mesh.size = Vector3(RestaurantWorld.CELL_SIZE * 0.96, 0.04, 0.2)
	elif attachment_placement:
		var bounds := ModelFactory.calculate_visual_bounds(move_source.visual_model, true)
		mesh.size = Vector3(maxf(bounds.size.x * 1.08, 0.58), 0.04, maxf(bounds.size.z * 1.08, 0.58))
	else:
		mesh.size = Vector3(move_source.footprint.x * RestaurantWorld.CELL_SIZE * 0.96, 0.04, move_source.footprint.y * RestaurantWorld.CELL_SIZE * 0.96)
	move_origin_marker.mesh = mesh
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.66, 0.1, 0.46)
	move_origin_marker.material_override = material
	move_origin_marker.position = move_source.position + Vector3(0.0, 0.09, 0.0)
	if edge_placement:
		move_origin_marker.rotation.y = move_source.rotation.y
	world.preview_root.add_child(move_origin_marker)


func _sync_preview_transform() -> void:
	if preview == null:
		return
	_preview_target_position = world.placement_world_position(current_definition, preview_cell, rotation_steps, preview_support_uid, preview_attachment_slot)
	_preview_target_rotation = -rotation_steps * PI * 0.5
	var exact_edge_snap := world.is_edge_placement(current_definition) or String(current_definition.get("placement", "cell")) == "wall_mount"
	if not _preview_transform_initialized or exact_edge_snap:
		preview.position = _preview_target_position
		preview.rotation.y = _preview_target_rotation
		_preview_transform_initialized = true
	if preview_access_marker != null:
		var access_cells := world.station_access_cells(current_definition, preview_cell, rotation_steps, preview_support_uid, preview_attachment_slot)
		preview_access_marker.visible = not access_cells.is_empty()
		if not access_cells.is_empty():
			preview_access_marker.position = world.cell_to_world(access_cells[0]) + Vector3.UP * 0.11
	_update_validation()


func _update_validation() -> void:
	_update_replacement_preview()
	var validation := world.validate_placement(current_definition, preview_cell, rotation_steps, move_source, preview_support_uid, preview_attachment_slot)
	placement_valid = bool(validation.valid)
	reason = String(validation.reason)
	if world.is_edge_placement(current_definition):
		reason = "Bordo %s \u00b7 %s" % [world.edge_name(rotation_steps), reason]
	elif String(current_definition.get("placement", "cell")) == "wall_mount":
		reason = "Parete %s \u00b7 %s" % [world.edge_name(rotation_steps), reason]
	if not String(current_definition.get("station", "")).is_empty():
		reason = "Fronte %s \u00b7 %s" % [world.station_front_name(rotation_steps), reason]
	if preview_pinned:
		reason += " \u00b7 posizione fissata"
	ModelFactory.set_preview_tint(preview, Color(0.16, 0.95, 0.48, 0.42) if placement_valid else Color(1.0, 0.2, 0.22, 0.5))
	if preview_access_marker != null:
		(preview_access_marker.material_override as StandardMaterial3D).albedo_color = Color(0.2, 0.9, 0.64, 0.58) if placement_valid else Color(1.0, 0.25, 0.28, 0.62)
	preview_changed.emit(placement_valid, reason, 0 if move_source else int(current_definition.get("price", 0)))


func _update_replacement_preview() -> void:
	if preview_replaced_edge != null and is_instance_valid(preview_replaced_edge) and preview_replaced_edge != move_source:
		preview_replaced_edge.visible = true
		world.refresh_shell_cutaway()
	preview_replaced_edge = null
	if not world.is_edge_placement(current_definition):
		return
	preview_replaced_edge = world.structural_edge_at(preview_cell, rotation_steps, move_source)
	if preview_replaced_edge != null:
		preview_replaced_edge.visible = false


func _finish_preview() -> void:
	_clear_preview_only()
	move_source = null
	_moving_dependents.clear()
	active = false
	current_definition = {}
	preview_support_uid = ""
	preview_attachment_slot = -1
	preview_pinned = false
	placement_valid = false
	reason = ""
	world.set_grid_visible(world.show_grid)
	mode_changed.emit(false)


func _clear_preview_only() -> void:
	if preview_replaced_edge != null and is_instance_valid(preview_replaced_edge) and not preview_replaced_edge.is_queued_for_deletion() and preview_replaced_edge != move_source:
		preview_replaced_edge.visible = true
		world.refresh_shell_cutaway()
	preview_replaced_edge = null
	if preview and is_instance_valid(preview):
		preview.queue_free()
	if preview_access_marker and is_instance_valid(preview_access_marker):
		preview_access_marker.queue_free()
	if move_origin_marker and is_instance_valid(move_origin_marker):
		move_origin_marker.queue_free()
	preview = null
	preview_visual = null
	preview_access_marker = null
	move_origin_marker = null
	_preview_transform_initialized = false


func _clear_selection(emit_signal: bool = true) -> void:
	selected_object = null
	if selection_marker and is_instance_valid(selection_marker):
		selection_marker.queue_free()
	selection_marker = null
	if emit_signal:
		selection_changed.emit(null)


func _update_selection_marker() -> void:
	if selection_marker and is_instance_valid(selection_marker):
		selection_marker.queue_free()
	selection_marker = null
	if selected_object == null:
		return
	selection_marker = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	var edge_placement := world.is_edge_placement(selected_object.definition)
	var attachment_placement := world.is_attachment_placement(selected_object.definition)
	if edge_placement:
		mesh.size = Vector3(RestaurantWorld.CELL_SIZE * 0.96, 0.035, 0.18)
	elif attachment_placement:
		var bounds := ModelFactory.calculate_visual_bounds(selected_object.visual_model, true)
		mesh.size = Vector3(maxf(bounds.size.x * 1.05, 0.55), 0.035, maxf(bounds.size.z * 1.05, 0.55))
	else:
		mesh.size = Vector3(selected_object.footprint.x * RestaurantWorld.CELL_SIZE * 0.96, 0.035, selected_object.footprint.y * RestaurantWorld.CELL_SIZE * 0.96)
	selection_marker.mesh = mesh
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.76, 0.16, 0.34)
	selection_marker.material_override = material
	selection_marker.position = selected_object.position + Vector3(0, 0.085, 0)
	if edge_placement:
		selection_marker.rotation.y = selected_object.rotation.y
	world.preview_root.add_child(selection_marker)
