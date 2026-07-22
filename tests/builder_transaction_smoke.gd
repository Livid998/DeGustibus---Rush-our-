extends Node

var failures: Array[String] = []
var checks := 0
var world: RestaurantWorld


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	SimulationManager.close_immediately()
	GameState.reset_to_defaults(false)
	GameState.money = 10000
	GameState.employees = []
	GameState.layout = [
		{"uid":"tx_table", "item":"table_small", "cell":[4, 4], "rotation":0},
		{"uid":"tx_chair", "item":"chair", "cell":[4, 4], "rotation":0, "support_uid":"tx_table", "attachment_slot":0},
		{"uid":"tx_worktop", "item":"prep_counter", "cell":[6, 10], "rotation":2},
		{"uid":"tx_board", "item":"cutting_board", "cell":[6, 10], "rotation":2, "support_uid":"tx_worktop", "attachment_slot":0},
		{"uid":"tx_wall", "item":"wall", "cell":[10, 6], "rotation":0},
	]
	GameState.set_restaurant_state("closed")
	world = RestaurantWorld.new()
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame

	_test_cancel_is_non_mutating()
	_test_purchase_undo_redo_in_two_attempts()
	_test_move_rotate_and_attachments()
	_test_sale_and_attachment_restore()
	_test_wall_opening_replacement()
	_test_floor_transaction()
	await _test_catalog_ux()
	_test_existing_structure_controls()

	var result := "BUILDER TRANSACTION SMOKE: %s | checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()]
	print(result)
	for failure: String in failures:
		print(failure)
	var output := FileAccess.open("res://tests/builder-transaction-result.txt", FileAccess.WRITE)
	if output != null:
		output.store_line(result)
		for failure: String in failures:
			output.store_line(failure)
	world.queue_free()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_cancel_is_non_mutating() -> void:
	var build := world.build_system
	var table := world.placed_objects.get("tx_table") as PlacedObject
	var chair := world.placed_objects.get("tx_chair") as PlacedObject
	var layout_before := GameState.layout.duplicate(true)
	var money_before := GameState.money
	var table_position := table.position
	var chair_position := chair.position
	build.select_object(table)
	build.move_selected()
	_pin_preview(Vector2i(7, 4), 1)
	build.cancel_preview()
	_expect(GameState.layout == layout_before and GameState.money == money_before, "cancelling a move changes neither authoritative layout nor money")
	_expect(table.position.is_equal_approx(table_position) and chair.position.is_equal_approx(chair_position) and chair.support_uid == table.uid, "cancelling keeps the real support and its attachment exactly at their origin")
	_expect(world.occupancy.get(table.grid_cell, "") == table.uid, "cancelling restores the source occupancy atomically")


func _test_purchase_undo_redo_in_two_attempts() -> void:
	var build := world.build_system
	var money_before := GameState.money
	build.start_place("plant")
	_pin_preview(world.entrance_cell, 0)
	var first_attempt := build.confirm()
	var first_reason := build.reason
	_pin_preview(Vector2i(14, 4), 0)
	var second_attempt := build.confirm()
	var plant := build.selected_object
	var plant_uid := plant.uid if plant != null else ""
	_expect(not first_attempt and not first_reason.is_empty() and second_attempt, "an invalid purchase explains itself and succeeds after one correction (two attempts maximum)")
	_expect(not plant_uid.is_empty() and GameState.money == money_before - int(DataRegistry.build_by_id.plant.price), "purchase creates one paid object")
	GameState.earn(17)
	_expect(build.can_undo() and build.undo(), "purchase can be undone")
	_expect(not world.placed_objects.has(plant_uid) and GameState.money == money_before + 17, "undo purchase removes the object, refunds its price and preserves later income")
	_expect(build.can_redo() and build.redo(), "purchase can be redone")
	_expect(world.placed_objects.has(plant_uid) and GameState.money == money_before + 17 - int(DataRegistry.build_by_id.plant.price), "redo purchase restores the exact UID and charge without losing later income")


func _test_move_rotate_and_attachments() -> void:
	var build := world.build_system
	var table := world.placed_objects.get("tx_table") as PlacedObject
	var chair := world.placed_objects.get("tx_chair") as PlacedObject
	var origin_cell := table.grid_cell
	var origin_rotation := table.rotation_steps
	var origin_money := GameState.money
	build.select_object(table)
	build.move_selected()
	_pin_preview(Vector2i(7, 4), 1)
	_expect(build.placement_valid and build.confirm(), "support group move confirms on the first valid attempt")
	_expect(table.grid_cell == Vector2i(7, 4) and table.rotation_steps == 1 and chair.support_uid == table.uid and chair.grid_cell == table.grid_cell, "moving a support preserves and moves its chair attachment")
	_expect(chair.position.is_equal_approx(world.attachment_world_position(chair.definition, table, chair.attachment_slot, chair.rotation_steps)), "attached chair is refreshed at its deterministic anchor")
	_expect(build.undo(), "group move can be undone")
	table = world.placed_objects.get("tx_table") as PlacedObject
	chair = world.placed_objects.get("tx_chair") as PlacedObject
	_expect(table.grid_cell == origin_cell and table.rotation_steps == origin_rotation and chair.support_uid == table.uid and GameState.money == origin_money, "undo group move restores transform, attachment and money")
	_expect(build.redo(), "group move can be redone")
	table = world.placed_objects.get("tx_table") as PlacedObject
	chair = world.placed_objects.get("tx_chair") as PlacedObject
	_expect(table.uid == "tx_table" and chair.uid == "tx_chair" and table.grid_cell == Vector2i(7, 4), "redo group move preserves every UID")

	build.select_object(table)
	build.rotate_selected()
	build.preview_pinned = true
	build._sync_preview_transform()
	var rotated_to := build.rotation_steps
	_expect(build.placement_valid and build.confirm(), "selected-object rotation uses the same fixed-preview transaction")
	_expect(table.rotation_steps == rotated_to and chair.rotation_steps == world.seat_rotation_for_slot(chair.attachment_slot, table.rotation_steps), "rotation keeps the chair facing the table")
	_expect(build.undo(), "rotation can be undone independently")
	table = world.placed_objects.get("tx_table") as PlacedObject
	_expect(table.rotation_steps != rotated_to, "undo restores the previous support rotation")
	_expect(build.redo(), "rotation can be redone independently")


func _test_sale_and_attachment_restore() -> void:
	var build := world.build_system
	var support := world.placed_objects.get("tx_worktop") as PlacedObject
	var expected_refund := int(round(float(support.definition.price) * 0.6)) + int(round(float(DataRegistry.build_by_id.cutting_board.price) * 0.6))
	var money_before := GameState.money
	build.select_object(support)
	_expect(build.sell_selected(), "selling a support and its attachment succeeds")
	_expect(not world.placed_objects.has("tx_worktop") and not world.placed_objects.has("tx_board") and GameState.money == money_before + expected_refund, "sale removes the whole group and credits its exact combined refund")
	_expect(build.undo(), "support-group sale can be undone")
	support = world.placed_objects.get("tx_worktop") as PlacedObject
	var board := world.placed_objects.get("tx_board") as PlacedObject
	_expect(support != null and board != null and board.support_uid == support.uid and board.attachment_slot == 0 and GameState.money == money_before, "undo sale restores exact UIDs, attachment slot and money")
	_expect(build.redo(), "support-group sale can be redone")
	_expect(not world.placed_objects.has("tx_worktop") and not world.placed_objects.has("tx_board"), "redo sale removes the same group without ghost objects")
	_expect(build.undo(), "sale can be restored again for subsequent builder operations")


func _test_wall_opening_replacement() -> void:
	var build := world.build_system
	var money_before := GameState.money
	build.start_place("door")
	_pin_preview(Vector2i(10, 6), 0)
	var wall := world.structural_edge_at(Vector2i(10, 6), 0)
	_expect(wall != null and wall.uid == "tx_wall" and build.placement_valid, "door preview targets the existing structural wall edge")
	_expect(build.confirm(), "wall-to-door replacement confirms")
	var door := build.selected_object
	var door_uid := door.uid if door != null else ""
	_expect(not door_uid.is_empty() and not world.placed_objects.has("tx_wall") and world.structural_edge_at(Vector2i(10, 6), 0).uid == door_uid, "replacement swaps one edge without overlapping structures")
	_expect(build.undo(), "wall opening replacement can be undone")
	_expect(world.placed_objects.has("tx_wall") and not world.placed_objects.has(door_uid) and GameState.money == money_before, "undo replacement restores the original wall UID and money")
	_expect(build.redo(), "wall opening replacement can be redone")
	_expect(world.placed_objects.has(door_uid) and not world.placed_objects.has("tx_wall"), "redo replacement restores the exact opening UID")


func _test_floor_transaction() -> void:
	var build := world.build_system
	var cell := Vector2i(12, 4)
	var money_before := GameState.money
	_expect(String(world.floor_tiles.get(cell, "")) == "floor_dining", "floor test starts from the implicit dining style")
	build.start_place("floor_kitchen")
	_pin_preview(cell, 0)
	_expect(build.placement_valid and build.confirm(), "floor painting is a confirmed builder transaction")
	_expect(String(world.floor_tiles.get(cell, "")) == "floor_kitchen", "floor purchase updates the visible tile")
	_expect(build.undo(), "floor purchase can be undone")
	_expect(String(world.floor_tiles.get(cell, "")) == "floor_dining" and not _has_floor_record(cell), "undo floor restores the implicit base style without a ghost record")
	_expect(GameState.money == money_before, "undo floor refunds the exact tile cost")
	_expect(build.redo(), "floor purchase can be redone")
	_expect(String(world.floor_tiles.get(cell, "")) == "floor_kitchen" and _has_floor_record(cell), "redo floor restores both visible style and authoritative record")


func _test_catalog_ux() -> void:
	var ui := RestaurantUI.new()
	add_child(ui)
	await get_tree().process_frame
	ui.setup(world)
	ui.open_builder()
	var hud := ui.build_hud
	hud.current_category = "Cucina"
	hud.search_input.text = "forno"
	hud.filter_select.select(0)
	hud.refresh_catalog()
	await get_tree().process_frame
	await get_tree().process_frame
	var previews := hud.item_row.find_children("*", "ModelPreview", true, false)
	_expect(hud._filtered_definitions().size() == 2, "catalog search narrows kitchen models by name")
	_expect(previews.size() == 2 and previews.size() <= BuildHUD.PAGE_SIZE, "catalog creates budgeted ModelPreview thumbnails only for the visible page")
	var rendered := true
	for preview_value: Variant in previews:
		var preview := preview_value as ModelPreview
		rendered = rendered and preview.viewport_3d != null and preview.model_root != null and not preview.model_root.get_children().is_empty() and not preview.auto_rotate
	_expect(rendered, "every visible thumbnail is generated from its real model with one-shot rendering")
	hud.search_input.text = ""
	hud.filter_select.select(2)
	hud.refresh_catalog()
	var attachment_defs := hud._filtered_definitions()
	_expect(not attachment_defs.is_empty() and attachment_defs.all(func(definition: Dictionary): return String(definition.get("placement", "cell")) in ["seat", "surface", "wall_mount", "overhead"]), "catalog filters expose only compatible attachment families")
	var touch_targets_valid := hud.search_input.custom_minimum_size.y >= BuildHUD.MIN_TOUCH_TARGET and hud.filter_select.custom_minimum_size.y >= BuildHUD.MIN_TOUCH_TARGET
	for button_value: Variant in hud.find_children("*", "Button", true, false):
		var button := button_value as Button
		if button != null and button.visible:
			touch_targets_valid = touch_targets_valid and button.custom_minimum_size.y >= BuildHUD.MIN_TOUCH_TARGET
	_expect(touch_targets_valid, "all visible builder controls meet the 44 px touch target")
	_expect(hud.status_label != null and hud.undo_button.tooltip_text.contains("Annulla"), "builder exposes live placement status and named undo history")
	ui.queue_free()


func _test_existing_structure_controls() -> void:
	var reduced_before := world.reduced_walls
	world.toggle_reduced_walls()
	_expect(world.reduced_walls != reduced_before, "transactional builder preserves the wall-stub visibility control")
	world.toggle_reduced_walls()
	var quadrant_before := world.camera_rig.quadrant
	world.camera_rig.rotate_right()
	_expect(world.camera_rig.quadrant == posmod(quadrant_before + 1, 4), "transactional builder preserves four-way camera rotation")
	world.camera_rig.rotate_left()
	_expect(world.is_edge_placement(DataRegistry.build_by_id.wall) and bool(DataRegistry.build_by_id.door.replaces_wall), "edge walls and wall-opening semantics remain data-driven")


func _pin_preview(cell: Vector2i, rotation: int, support_uid: String = "", attachment_slot: int = -1) -> void:
	var build := world.build_system
	build._apply_target({"cell":cell, "rotation":rotation, "support_uid":support_uid, "attachment_slot":attachment_slot})
	build.preview_pinned = true
	build._sync_preview_transform()


func _has_floor_record(cell: Vector2i) -> bool:
	for record: Dictionary in GameState.layout:
		var cell_data: Array = record.get("cell", [-999, -999])
		if String(record.get("item", "")).begins_with("floor_") and Vector2i(int(cell_data[0]), int(cell_data[1])) == cell:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
