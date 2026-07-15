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
var preview_replaced_edge: PlacedObject
var preview_cell := Vector2i(-1, -1)
var rotation_steps := 0
var selected_object: PlacedObject
var move_source: PlacedObject
var reason := ""
var placement_valid := false
var selection_marker: MeshInstance3D


func setup(value_world: RestaurantWorld, value_camera: Camera3D) -> void:
	world = value_world
	camera = value_camera


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
	world.set_object_occupancy(move_source, false)
	move_source.visible = false
	active = true
	_create_preview()
	_sync_preview_transform()
	_clear_selection(false)
	world.set_grid_visible(true)
	mode_changed.emit(true)


func sell_selected() -> bool:
	if selected_object == null or not is_instance_valid(selected_object) or not can_edit_definition(selected_object.definition):
		return false
	var refund := int(round(float(selected_object.definition.get("price", 0)) * 0.6))
	GameState.earn(refund, "Vendita %s" % selected_object.definition.name)
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
	var validation := world.validate_placement(current_definition, preview_cell, rotation_steps, move_source)
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
	if is_move:
		var old_source := move_source
		move_source = null
		world.remove_placed_object(old_source, true)
	if replaced_wall != null and is_instance_valid(replaced_wall):
		world.remove_placed_object(replaced_wall, true)
	var placed := world.add_layout_object(String(current_definition.id), preview_cell, rotation_steps)
	_finish_preview()
	select_object(placed)
	SaveManager.save_game()
	return true


func cancel_preview() -> void:
	_clear_preview_only()
	if move_source and is_instance_valid(move_source):
		move_source.visible = true
		world.set_object_occupancy(move_source, true)
		select_object(move_source)
	move_source = null
	active = false
	current_definition = {}
	placement_valid = false
	reason = ""
	if world:
		world.set_grid_visible(world.show_grid)
	mode_changed.emit(false)


func rotate_preview() -> void:
	if not active:
		return
	rotation_steps = (rotation_steps + 1) % 4
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
	if not active:
		return
	var target := _screen_to_placement_target(screen_position)
	var cell: Vector2i = target.cell
	var target_rotation := int(target.rotation)
	if cell != preview_cell or target_rotation != rotation_steps:
		preview_cell = cell
		rotation_steps = target_rotation
		_sync_preview_transform()


func pointer_pressed(screen_position: Vector2) -> void:
	if active:
		var target := _screen_to_placement_target(screen_position)
		preview_cell = target.cell
		rotation_steps = int(target.rotation)
		_sync_preview_transform()
	elif GameState.restaurant_state in ["closed", "open"]:
		var cell := _screen_to_cell(screen_position)
		var hit_object := _object_from_screen(screen_position)
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
		return {"cell": Vector2i(-1, -1), "rotation": rotation_steps}
	var world_hit := Vector3(hit)
	var cell := world.world_to_cell(world_hit)
	var target_rotation := rotation_steps
	if world.is_edge_placement(current_definition):
		var center := world.cell_to_world(cell)
		if rotation_steps % 2 == 0:
			target_rotation = 0 if world_hit.z < center.z else 2
		else:
			target_rotation = 1 if world_hit.x < center.x else 3
	return {"cell": cell, "rotation": target_rotation}


func _screen_to_floor(screen_position: Vector2) -> Variant:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
	return hit


func _object_from_screen(screen_position: Vector2) -> PlacedObject:
	var origin := camera.project_ray_origin(screen_position)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(screen_position) * 250.0)
	var result := world.get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return null
	var node := result.get("collider") as Node
	while node and not node is PlacedObject:
		node = node.get_parent()
	return node as PlacedObject


func _create_preview() -> void:
	preview = Node3D.new()
	preview.name = "PlacementPreview"
	preview_visual = ModelFactory.instantiate_build_visual(current_definition, not String(current_definition.id).begins_with("floor_"))
	preview_visual.name = "VisualModel"
	ModelFactory.align_visual_to_grid_origin(preview_visual, not String(current_definition.id).begins_with("floor_"))
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
	world.preview_root.add_child(preview)


func _sync_preview_transform() -> void:
	if preview == null:
		return
	preview.position = world.placement_world_position(current_definition, preview_cell, rotation_steps)
	preview.rotation.y = -rotation_steps * PI * 0.5
	_update_validation()


func _update_validation() -> void:
	_update_replacement_preview()
	var validation := world.validate_placement(current_definition, preview_cell, rotation_steps, move_source)
	placement_valid = bool(validation.valid)
	reason = String(validation.reason)
	if world.is_edge_placement(current_definition):
		reason = "Bordo %s \u00b7 %s" % [world.edge_name(rotation_steps), reason]
	ModelFactory.set_preview_tint(preview, Color(0.16, 0.95, 0.48, 0.42) if placement_valid else Color(1.0, 0.2, 0.22, 0.5))
	preview_changed.emit(placement_valid, reason, 0 if move_source else int(current_definition.get("price", 0)))


func _update_replacement_preview() -> void:
	if preview_replaced_edge != null and is_instance_valid(preview_replaced_edge) and preview_replaced_edge != move_source:
		preview_replaced_edge.visible = true
	preview_replaced_edge = null
	if not world.is_edge_placement(current_definition):
		return
	preview_replaced_edge = world.structural_edge_at(preview_cell, rotation_steps, move_source)
	if preview_replaced_edge != null:
		preview_replaced_edge.visible = false


func _finish_preview() -> void:
	_clear_preview_only()
	move_source = null
	active = false
	current_definition = {}
	placement_valid = false
	reason = ""
	world.set_grid_visible(world.show_grid)
	mode_changed.emit(false)


func _clear_preview_only() -> void:
	if preview_replaced_edge != null and is_instance_valid(preview_replaced_edge) and not preview_replaced_edge.is_queued_for_deletion() and preview_replaced_edge != move_source:
		preview_replaced_edge.visible = true
	preview_replaced_edge = null
	if preview and is_instance_valid(preview):
		preview.queue_free()
	preview = null
	preview_visual = null


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
	if edge_placement:
		mesh.size = Vector3(RestaurantWorld.CELL_SIZE * 0.96, 0.035, 0.18)
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
