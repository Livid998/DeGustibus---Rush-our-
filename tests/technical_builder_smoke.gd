extends Node

var failures: Array[String] = []
var checks := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	SimulationManager.close_immediately()
	SimulationManager.reset_service_stats()
	GameState.reset_to_defaults(false)
	GameState.employees = []
	GameState.layout = [
		{"uid":"technical_stove", "item":"stove", "cell":[5, 9], "rotation":0},
		{"uid":"technical_worktop", "item":"worktable", "cell":[9, 9], "rotation":0},
		{"uid":"technical_dessert", "item":"dessert", "cell":[9, 9], "rotation":0, "support_uid":"technical_worktop", "attachment_slot":0}
	]
	GameState.set_restaurant_state("closed")

	var world := RestaurantWorld.new()
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame

	var stove := world.placed_objects.get("technical_stove") as PlacedObject
	var worktop := world.placed_objects.get("technical_worktop") as PlacedObject
	var dessert := world.placed_objects.get("technical_dessert") as PlacedObject
	var stove_definition: Dictionary = DataRegistry.build_by_id.get("stove", {})
	var hood_definition: Dictionary = DataRegistry.build_by_id.get("extractor_hood", {})
	var dessert_definition: Dictionary = DataRegistry.build_by_id.get("dessert", {})

	_expect(stove != null and worktop != null and dessert != null, "the custom technical layout loads without depending on a save migration")
	_expect(String(stove_definition.get("support_kind", "")) == "heat_station" and bool(stove_definition.get("ventilation_required", false)), "standalone cookers expose an explicit ventilation support")
	_expect(String(hood_definition.get("placement", "")) == "overhead" and String(hood_definition.get("requires_support", "")) == "heat_station" and bool(hood_definition.get("provides_ventilation", false)) and not bool(hood_definition.get("blocking", true)), "the extractor hood is an overhead, non-blocking heat-station attachment that explicitly provides ventilation")
	_expect(ResourceLoader.exists(String(hood_definition.get("model", ""))), "the Restaurant Bits extractor hood model is imported under a stable project path")
	_expect(String(dessert_definition.get("placement", "")) == "surface" and String(dessert_definition.get("requires_support", "")) == "worktop" and int(dessert_definition.get("surface_span", 0)) == 1 and not bool(dessert_definition.get("blocking", true)), "the ice-cream machine is a one-slot tabletop appliance")
	_expect(not dessert_definition.has("model_scale") and String(dessert_definition.get("model", "")) == "res://assets/equipment/icecream_machine.gltf", "the tabletop conversion leaves the exact existing ice-cream model and scale untouched")

	if stove != null:
		var stove_move_validation := world.validate_placement(stove_definition, stove.grid_cell, stove.rotation_steps, stove)
		_expect(bool(stove_move_validation.get("valid", false)), "a stove remains placeable without a hood")
		var blockers := world.restaurant_opening_blockers()
		var warning_label := stove.get_node_or_null("OperationalWarning") as Label3D
		_expect(blockers.size() == 1 and "Fornello singolo" in String(blockers[0]) and "cappa aspirante" in String(blockers[0]), "opening validation names the exact unventilated station and missing hood")
		_expect(not stove.is_operational() and warning_label != null and warning_label.visible and warning_label.modulate.r > warning_label.modulate.g, "an unventilated stove is visibly marked non-operational in red")
		var services_before := int(GameState.progress.get("services_started", 0))
		_expect(not SimulationManager.open_restaurant() and GameState.restaurant_state == "closed" and int(GameState.progress.get("services_started", 0)) == services_before, "an unventilated stove blocks opening without starting a service")

		var target := world.attachment_target_at(hood_definition, stove.global_position, 3)
		_expect(String(target.get("support_uid", "")) == stove.uid and int(target.get("attachment_slot", -1)) == 0 and int(target.get("rotation", -1)) == stove.rotation_steps, "hood snapping deterministically chooses the stove and inherits its orientation")
		var hood_validation := world.validate_placement(hood_definition, Vector2i(target.cell), int(target.rotation), null, String(target.support_uid), int(target.attachment_slot))
		_expect(bool(hood_validation.get("valid", false)), "a compatible hood can attach above the stove")
		var hood := world.add_layout_object("extractor_hood", Vector2i(target.cell), int(target.rotation), String(target.support_uid), int(target.attachment_slot))
		await get_tree().process_frame
		_expect(hood != null and stove.is_operational() and world.restaurant_opening_blockers().is_empty() and warning_label != null and not warning_label.visible, "attaching the hood enables the stove and clears its warning")
		_expect(SimulationManager.open_restaurant() and GameState.restaurant_state == "open", "the same custom restaurant opens once every heat station is ventilated")
		SimulationManager.close_immediately()

		if hood != null:
			var hood_colliders := hood.find_children("*", "CollisionShape3D", true, false)
			_expect(not world.occupancy.values().has(hood.uid) and not hood_colliders.is_empty(), "the hood reserves no walkable cell but retains a precise builder-selection collider")
			var expected_hood_position := world.attachment_world_position(hood.definition, stove, hood.attachment_slot, hood.rotation_steps)
			_expect(hood.position.is_equal_approx(expected_hood_position), "the hood uses its deterministic overhead anchor")

			world.build_system.select_object(hood)
			world.build_system.move_selected()
			_expect(world.build_system.move_source == hood and hood.visible and world.build_system.preview_support_uid == stove.uid and world.build_system.placement_valid, "moving an attached hood keeps the real object visible and reacquires its support")
			_expect(world.build_system.confirm() and world.build_system.selected_object == hood, "an overhead attachment can be selected and reconfirmed through the builder")

			var new_stove_cell := Vector2i(6, 9)
			var new_stove_rotation := 1
			world.build_system.select_object(stove)
			world.build_system.move_selected()
			world.build_system._apply_target({"cell":new_stove_cell, "rotation":new_stove_rotation, "support_uid":"", "attachment_slot":-1})
			world.build_system._sync_preview_transform()
			_expect(world.build_system.placement_valid and world.build_system.confirm(), "the stove and attached hood can be moved as one valid builder group (%s)" % world.build_system.reason)
			expected_hood_position = world.attachment_world_position(hood.definition, stove, hood.attachment_slot, hood.rotation_steps)
			_expect(hood.support_uid == stove.uid and hood.grid_cell == stove.grid_cell and hood.rotation_steps == stove.rotation_steps and hood.position.is_equal_approx(expected_hood_position), "the hood follows support position and rotation without drift")

			world.remove_placed_object(hood)
			await get_tree().process_frame
			_expect(world.placed_objects.has(stove.uid) and not stove.is_operational() and world.restaurant_opening_blockers().size() == 1, "removing a hood never auto-deletes its stove; it only makes the station non-operational")

	var unsupported_dessert := world.validate_placement(dessert_definition, Vector2i(12, 9), 0)
	_expect(not bool(unsupported_dessert.get("valid", true)) and "banco" in String(unsupported_dessert.get("reason", "")), "the ice-cream machine cannot be placed directly on the floor")
	if dessert != null and worktop != null:
		var dessert_bounds := ModelFactory.calculate_visual_bounds(dessert.visual_model, true)
		var dessert_base := dessert.visual_model.get_node_or_null("BaseModel") as Node3D
		var expected_current_size := Vector3(2.0, 2.404, 2.03)
		_expect(dessert.support_uid == worktop.uid and dessert.position.is_equal_approx(world.attachment_world_position(dessert.definition, worktop, dessert.attachment_slot, dessert.rotation_steps)), "the ice-cream machine sits on and follows its explicit worktop support")
		_expect(dessert_base != null and dessert_base.scale.is_equal_approx(Vector3.ONE) and _vector_approx(dessert_bounds.size, expected_current_size, 0.004), "the tabletop ice-cream machine preserves its previous 1:1 scale and exact visual dimensions")
		_expect(world.occupancy.get(worktop.grid_cell, "") == worktop.uid and not world.occupancy.values().has(dessert.uid), "the supported ice-cream machine adds no navigation blocker beyond its worktop")
		var dessert_runtime := _station_runtime_for("dessert", dessert)
		_expect(not dessert_runtime.is_empty() and dessert.is_operational(), "the supported ice-cream machine remains registered as an operational dessert station")

		var new_worktop_cell := Vector2i(11, 9)
		var new_worktop_rotation := 1
		var worktop_move_validation := world.validate_placement(worktop.definition, new_worktop_cell, new_worktop_rotation, worktop)
		_expect(bool(worktop_move_validation.get("valid", false)), "moving a worktop validates its attached tabletop station (%s)" % String(worktop_move_validation.get("reason", "")))
		world.move_layout_object(worktop, new_worktop_cell, new_worktop_rotation)
		var moved_bounds := ModelFactory.calculate_visual_bounds(dessert.visual_model, true)
		var expected_dessert_position := world.attachment_world_position(dessert.definition, worktop, dessert.attachment_slot, dessert.rotation_steps)
		dessert_runtime = _station_runtime_for("dessert", dessert)
		var current_positions: Array[Vector3] = dessert.get_interaction_positions()
		var registered_positions: Array = dessert_runtime.get("interaction_positions", [])
		_expect(dessert.grid_cell == worktop.grid_cell and dessert.rotation_steps == worktop.rotation_steps and dessert.position.is_equal_approx(expected_dessert_position), "the tabletop station follows worktop position and rotation")
		_expect(_vector_approx(moved_bounds.size, expected_current_size, 0.004), "moving the worktop cannot alter the ice-cream machine's visual bounds")
		_expect(not current_positions.is_empty() and not registered_positions.is_empty() and Vector3(registered_positions[0]).is_equal_approx(current_positions[0]), "moving the worktop refreshes the dessert station interaction anchor used by workers")

	var result := "TECHNICAL BUILDER SMOKE: %s | checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()]
	print(result)
	for failure: String in failures:
		print(failure)
	world.queue_free()
	get_tree().quit(0 if failures.is_empty() else 1)


func _station_runtime_for(station_id: String, node: Node) -> Dictionary:
	for runtime: Dictionary in SimulationManager.stations.get(station_id, []):
		if runtime.get("node") == node:
			return runtime
	return {}


func _vector_approx(actual: Vector3, expected: Vector3, tolerance: float) -> bool:
	return absf(actual.x - expected.x) <= tolerance and absf(actual.y - expected.y) <= tolerance and absf(actual.z - expected.z) <= tolerance


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
