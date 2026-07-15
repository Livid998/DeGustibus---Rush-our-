extends Node

var failures: Array[String] = []
var checks := 0


func _ready() -> void:
	_run()


func _run() -> void:
	await get_tree().process_frame
	_test_registry()
	_test_stock_consumption()
	_test_reorder()
	var world := RestaurantWorld.new()
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	_test_pathfinding_and_placement(world)
	_test_builder_and_seating(world)
	_test_agent_navigation_and_appearance(world)
	_test_camera_input(world)
	_test_progression_and_menu_load(world)
	_test_purchased_preparations()
	_test_recipe_tasks_and_station_reservation()
	_test_service_assignment()
	_test_price_margin()
	_test_save_load()
	world.queue_free()
	print("TESTS: %d checks, %d failures" % [checks, failures.size()])
	for failure: String in failures:
		print("FAIL: ", failure)
	var report := FileAccess.open("res://tests/test-results.txt", FileAccess.WRITE)
	if report:
		report.store_line("TESTS: %d checks, %d failures" % [checks, failures.size()])
		for failure: String in failures:
			report.store_line("FAIL: %s" % failure)
	get_tree().quit(1 if not failures.is_empty() else 0)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _test_registry() -> void:
	_expect(DataRegistry.ingredients.size() >= 18, "ingredient registry contains at least 18 entries")
	_expect(DataRegistry.recipes.size() == 12, "recipe registry contains 12 recipes")
	_expect(DataRegistry.stations.size() == 13, "station registry contains 13 stations")
	var unlocked := 0
	var ingredient_icon_indices: Dictionary = {}
	for ingredient: Dictionary in DataRegistry.ingredients:
		if ingredient.unlocked:
			unlocked += 1
		var icon_index := int(ingredient.get("icon_index", -1))
		ingredient_icon_indices[icon_index] = true
		_expect(icon_index >= 0 and icon_index < 20 and int(ingredient.get("rarity", 0)) in range(1, 6), "%s has a valid atlas icon and rarity" % ingredient.id)
	_expect(unlocked == 12, "exactly 12 ingredients start unlocked")
	_expect(ingredient_icon_indices.size() == 20 and GameIcons.ingredient_icon(DataRegistry.ingredients_by_id.tomato).region.size.x > 0.0, "all ingredient icons map uniquely to the supplied atlas")
	var ingredient_sheet_size := GameIcons.INGREDIENT_SHEET.get_size()
	_expect(int(ingredient_sheet_size.x) % 5 == 0 and int(ingredient_sheet_size.y) % 4 == 0 and ingredient_sheet_size.x >= 600.0, "transparent ingredient atlas has 20 uniform cells")
	_expect(_atlas_has_transparent_cell_corners(GameIcons.INGREDIENT_SHEET, 5, 4), "ingredient cells have transparent backgrounds and isolated borders")
	var recipe_icon_indices: Dictionary = {}
	for recipe: Dictionary in DataRegistry.recipes:
		recipe_icon_indices[int(recipe.get("icon_index", -1))] = true
	_expect(recipe_icon_indices.size() == 12 and GameIcons.recipe_icon(DataRegistry.recipes_by_id.margherita).region.size.x > 0.0, "all recipe icons map uniquely to the supplied atlas")
	var recipe_sheet_size := GameIcons.RECIPE_SHEET.get_size()
	_expect(int(recipe_sheet_size.x) % 3 == 0 and int(recipe_sheet_size.y) % 4 == 0 and recipe_sheet_size.y >= 640.0, "transparent recipe atlas has 12 uniform cells")
	_expect(_atlas_has_transparent_cell_corners(GameIcons.RECIPE_SHEET, 3, 4), "recipe cells have transparent backgrounds and isolated borders")
	_expect(GameIcons.NAVIGATION_INDICES.size() == 8 and GameIcons.navigation_icon("Impostazioni").region.size.x > 0.0, "all navigation and settings icons map to the supplied atlas")
	_expect(_atlas_has_transparent_cell_corners(GameIcons.NAVIGATION_SHEET, 4, 2), "navigation cells have transparent backgrounds")
	var lock_image := GameIcons.LOCK_TEXTURE.get_image()
	_expect(not lock_image.is_empty() and lock_image.get_pixel(0, 0).a < 0.01, "supplied lock icon has a transparent background")
	_expect(ResourceLoader.exists("res://assets/ui/fonts/FredokaOne-Regular.ttf") and GameFonts.medium().variation_embolden < GameFonts.semibold().variation_embolden and GameFonts.semibold().variation_embolden < GameFonts.bold().variation_embolden, "Fredoka One is embedded with cartoony Medium, SemiBold and Bold hierarchy")
	_expect(DataRegistry.recipes_by_id.margherita.steps.size() >= 5, "margherita is a multi-step process")


func _atlas_has_transparent_cell_corners(sheet: Texture2D, columns: int, rows: int) -> bool:
	var image := sheet.get_image()
	if image.is_empty():
		return false
	var cell_width := image.get_width() / columns
	var cell_height := image.get_height() / rows
	for row: int in rows:
		for column: int in columns:
			var left := column * cell_width
			var top := row * cell_height
			var corners := [
				Vector2i(left + 2, top + 2),
				Vector2i(left + cell_width - 3, top + 2),
				Vector2i(left + 2, top + cell_height - 3),
				Vector2i(left + cell_width - 3, top + cell_height - 3),
			]
			for corner: Vector2i in corners:
				if image.get_pixel(corner.x, corner.y).a > 0.01:
					return false
	return true


func _test_stock_consumption() -> void:
	GameState.reset_to_defaults(false)
	var before := int(GameState.stock.tomato.amount)
	_expect(GameState.consume_stock({"tomato": 2}), "stock requirements can be consumed")
	_expect(int(GameState.stock.tomato.amount) == before - 2, "stock amount decreases exactly")
	_expect(not GameState.consume_stock({"tomato": 9999}), "insufficient stock rejects consumption")
	_expect(int(GameState.stock.tomato.amount) == before - 2, "failed consumption is atomic")


func _test_reorder() -> void:
	GameState.reset_to_defaults(false)
	GameState.stock.tomato.amount = 1
	GameState.stock.tomato.auto_reorder = true
	var money_before := GameState.money
	EconomyManager._check_auto_reorders()
	_expect(GameState.deliveries.size() == 1, "auto reorder creates one delivery")
	_expect(GameState.money < money_before, "auto reorder charges money")
	if not GameState.deliveries.is_empty():
		GameState.deliveries[0].remaining = 0.0
		EconomyManager._process(0.0)
	_expect(int(GameState.stock.tomato.amount) >= int(GameState.stock.tomato.target), "delivery restores target stock")


func _test_pathfinding_and_placement(world: RestaurantWorld) -> void:
	var path := world.find_path(world.cell_to_world(world.entrance_cell), world.cell_to_world(Vector2i(9, 8)))
	_expect(not path.is_empty(), "pathfinding connects entrance to kitchen")
	var plant: Dictionary = DataRegistry.build_by_id.plant
	var valid: Dictionary = world.validate_placement(plant, Vector2i(16, 5), 0)
	_expect(bool(valid.valid), "free decoration placement is valid")
	var invalid: Dictionary = world.validate_placement(DataRegistry.build_by_id.table_small, world.entrance_cell, 0)
	_expect(not bool(invalid.valid), "the entrance cell remains reserved")
	_expect(bool(world.validate_placement(DataRegistry.build_by_id.worktable, Vector2i(0, 9), 0).valid), "equipment supports can use perimeter cells beside an exterior wall")
	var outward_fridge := world.validate_placement(DataRegistry.build_by_id.fridge, Vector2i(0, 10), 1)
	var inward_fridge := world.validate_placement(DataRegistry.build_by_id.fridge, Vector2i(0, 10), 3)
	_expect(not bool(outward_fridge.valid) and bool(inward_fridge.valid), "workstations are rejected when their operating face points outside instead of into a reachable aisle")
	var unsupported_door: Dictionary = world.validate_placement(DataRegistry.build_by_id.door, Vector2i(5, 5), 0)
	var supported_door: Dictionary = world.validate_placement(DataRegistry.build_by_id.door, Vector2i(2, 0), 0)
	_expect(not bool(unsupported_door.valid) and bool(supported_door.valid), "doors and windows can only replace an existing structural edge")
	for temporary_x: int in [9, 10, 11]:
		world._temporary_blocked_edge_keys[world.edge_key(Vector2i(temporary_x, 8), 0)] = true
	var blocker: Dictionary = world.validate_placement(DataRegistry.build_by_id.wall, Vector2i(8, 8), 0)
	for temporary_x: int in [9, 10, 11]:
		world._temporary_blocked_edge_keys.erase(world.edge_key(Vector2i(temporary_x, 8), 0))
	_expect(not bool(blocker.valid), "essential passage cannot be fully blocked")


func _test_builder_and_seating(world: RestaurantWorld) -> void:
	var build := world.build_system
	var table := world.placed_objects.get("table_1") as PlacedObject
	var environment := (world.get_node("WorldEnvironment") as WorldEnvironment).environment
	_expect(not environment.fog_enabled and environment.tonemap_mode == Environment.TONE_MAPPER_LINEAR and environment.ambient_light_energy <= 0.4, "map lighting preserves the original asset palette without a pale fog veil")
	var aligned_models := true
	var aligned_roots := true
	for object: PlacedObject in world.placed_objects.values():
		aligned_roots = aligned_roots and object.position.is_equal_approx(world.placement_world_position(object.definition, object.grid_cell, object.rotation_steps, object.support_uid, object.attachment_slot))
		if object.uid in ["door_1", "fridge_1", "storage_1", "stove_1", "oven_1", "plant_1"]:
			var bounds := ModelFactory.calculate_visual_bounds(object.visual_model, true)
			var center := bounds.get_center()
			aligned_models = aligned_models and absf(center.x) < 0.002 and absf(center.z) < 0.002 and absf(bounds.position.y) < 0.002
	_expect(aligned_roots and aligned_models, "placed visuals are centered, grounded and anchored to their logical grid footprint")
	var multi_footprint: Array = DataRegistry.build_by_id.multi_stove.footprint
	var pass_footprint: Array = DataRegistry.build_by_id.pass.footprint
	_expect(int(multi_footprint[0]) == 1 and int(multi_footprint[1]) == 1 and int(pass_footprint[0]) == 1 and int(pass_footprint[1]) == 1, "single-cell kitchen models no longer straddle a two-cell grid seam")
	var top_wall := world.placed_objects.get("wall_top_2") as PlacedObject
	var left_wall := world.placed_objects.get("wall_left_1") as PlacedObject
	_expect(top_wall.position.is_equal_approx(world.cell_to_world(top_wall.grid_cell) + world.edge_offset(top_wall.definition, top_wall.rotation_steps)) and left_wall.position.is_equal_approx(world.cell_to_world(left_wall.grid_cell) + world.edge_offset(left_wall.definition, left_wall.rotation_steps)), "wall thickness sits fully outside its anchored cell")
	_expect(not world.occupancy.has(Vector2i(6, 8)) and bool(world.validate_placement(DataRegistry.build_by_id.plant, Vector2i(6, 8), 0).valid), "a wall edge does not reserve the adjacent equipment cell")
	_expect(world.edge_key(Vector2i(6, 8), 0) != world.edge_key(Vector2i(6, 8), 1) and bool(world.validate_placement(DataRegistry.build_by_id.wall, Vector2i(6, 8), 1).valid), "perpendicular wall segments can meet at the same grid intersection")
	_expect(world._wall_blocks_step(Vector2i(6, 8), Vector2i(6, 7)) and not world._wall_blocks_step(Vector2i(8, 8), Vector2i(8, 7)), "pathfinding blocks solid wall edges while preserving structural openings")
	var layout_count := GameState.layout.size()
	var attached_chairs := world.attached_objects(table.uid)
	var chairs_face_table := attached_chairs.size() == 4
	for chair: PlacedObject in attached_chairs:
		chairs_face_table = chairs_face_table and chair.rotation_steps == world.seat_rotation_for_slot(chair.attachment_slot, table.rotation_steps) and chair.position.distance_to(table.position) <= 1.5
	_expect(chairs_face_table, "chairs occupy four explicit close-fit slots and face their table")
	var sample_chair := attached_chairs[0]
	var chair_screen := world.camera_rig.camera.unproject_position(sample_chair.global_position + Vector3.UP * 0.9)
	_expect(build._object_from_screen(chair_screen) == sample_chair, "ray selection prioritizes an attached chair over the overlapping table support")
	var wrong_rotation := posmod(sample_chair.rotation_steps + 1, 4)
	_expect(not bool(world.validate_placement(sample_chair.definition, table.grid_cell, wrong_rotation, sample_chair, table.uid, sample_chair.attachment_slot).valid), "a chair facing away from its table is never a valid seat")
	_expect(not bool(world.validate_placement(sample_chair.definition, table.grid_cell, sample_chair.rotation_steps, null, table.uid, sample_chair.attachment_slot).valid), "two chairs cannot share the same table slot")
	var cutting_board := world.placed_objects.get("cut_1") as PlacedObject
	var cutting_support := world.placed_objects.get(cutting_board.support_uid) as PlacedObject
	_expect(not bool(world.validate_placement(cutting_board.definition, cutting_board.grid_cell, cutting_board.rotation_steps).valid), "countertop equipment cannot be placed on the floor")
	_expect(world.attachment_slots_for(cutting_board.definition, cutting_support, cutting_board.attachment_slot, cutting_board.rotation_steps).size() == 2, "the cutting board reserves both slots of a two-place worktop")
	var preserved_support_uid := cutting_board.support_uid
	cutting_board.support_uid = "legacy_missing_support"
	_expect(bool(world.validate_placement(DataRegistry.build_by_id.worktable, Vector2i(16, 5), 0).valid), "a pre-existing unreachable legacy station no longer invalidates every unrelated placement")
	cutting_board.support_uid = preserved_support_uid
	_expect(String(DataRegistry.build_by_id.prep_counter.get("station", "")).is_empty() and String(DataRegistry.build_by_id.prep_bowl.station) == "prep_counter" and String(DataRegistry.build_by_id.pass.get("station", "")).is_empty() and String(DataRegistry.build_by_id.pass_tray.station) == "pass", "generic counters gain their operational role from visible countertop tools")
	_expect(String(DataRegistry.build_by_id.oven.placement) == "surface" and String(DataRegistry.build_by_id.pizza_oven.placement) == "surface" and String(DataRegistry.build_by_id.stove.get("placement", "cell")) == "cell" and String(DataRegistry.build_by_id.multi_stove.get("placement", "cell")) == "cell", "ovens require worktops while the two standalone cookers remain floor stations")
	var oven_support := world.placed_objects.get("support_oven_1") as PlacedObject
	_expect(not bool(world.validate_placement(oven_support.definition, Vector2i(0, 10), 1, oven_support).valid), "moving a counter also validates the operating face of its attached appliance")
	var storage := world.placed_objects.get("storage_1") as PlacedObject
	var storage_wall := world.placed_objects.get(storage.support_uid) as PlacedObject
	_expect(storage_wall != null and bool(world.validate_placement(storage.definition, storage_wall.grid_cell, storage_wall.rotation_steps, storage, storage_wall.uid, 0).valid) and not world.occupancy.has(storage.grid_cell), "wall storage mounts to a full wall without reserving the floor cell below")
	build.select_object(table)
	build.move_selected()
	var source_position := table.position
	var source_group_visible := table.visible and build.move_origin_marker != null
	for chair: PlacedObject in attached_chairs:
		source_group_visible = source_group_visible and chair.visible
	_expect(build.active and build.move_source == table and source_group_visible and table.position == source_position, "move mode keeps the real source group visible at its origin beside the coloured preview")
	build.cancel_preview()
	_expect(world.object_at_cell(Vector2i(3, 3)) == table and DataRegistry.build_by_id.table_medium.has("model"), "cancelling a move restores occupancy without corrupting the catalog")
	build.select_object(table)
	build.move_selected()
	build.preview_cell = Vector2i(6, 3)
	build._sync_preview_transform()
	_expect(build.placement_valid and build.confirm(), "moving furniture can be explicitly confirmed")
	var moved_chairs := world.attached_objects(table.uid)
	var chairs_followed := moved_chairs.size() == 4
	for chair: PlacedObject in moved_chairs:
		chairs_followed = chairs_followed and chair.support_uid == table.uid and chair.position.distance_to(table.position) <= 1.5
	_expect(GameState.layout.size() == layout_count and world.object_at_cell(Vector2i(6, 3)) == table and chairs_followed, "moving furniture preserves its UID, occupancy and attached chairs")
	var second_table := world.placed_objects.get("table_2") as PlacedObject
	_expect(world._seat_positions_for_table(second_table).size() == 4, "table capacity is derived from four real adjacent chairs")
	_expect(world.floor_tiles.size() == RestaurantWorld.GRID_SIZE.x * RestaurantWorld.GRID_SIZE.y and is_equal_approx((world.floor_tiles.values()[0] as Node3D).scale.x, 0.5), "floor tiles use non-overlapping normalized scale")
	var editable_walls := 0
	for object: PlacedObject in world.placed_objects.values():
		if object.item_id in ["wall", "wall_window"]:
			editable_walls += 1
	_expect(editable_walls > 20, "restaurant shell walls are real editable layout objects")
	var replacement_count := GameState.layout.size()
	var replaced_segment := world.placed_objects.get("wall_top_2") as PlacedObject
	build.start_place("door")
	build.preview_cell = Vector2i(2, 0)
	build.rotation_steps = 0
	build._sync_preview_transform()
	_expect(build.placement_valid and not replaced_segment.visible, "opening preview temporarily hides the wall segment it will replace")
	build.cancel_preview()
	_expect(replaced_segment.visible, "cancelling an opening preview restores its supporting wall")
	build.start_place("door")
	build.preview_cell = Vector2i(2, 0)
	build.rotation_steps = 0
	build._sync_preview_transform()
	_expect(build.confirm() and GameState.layout.size() == replacement_count and world.structural_edge_at(Vector2i(2, 0), 0).item_id == "door", "confirming a door atomically replaces one wall segment")
	build.start_place("wall")
	_expect(build.preview != null and build.preview.scale.is_equal_approx(Vector3.ONE) and is_equal_approx((build.preview_visual.get_node("BaseModel") as Node3D).scale.x, 0.5), "builder footprint and imported visual use independent transforms")
	build.cancel_preview()
	build.start_place("plant")
	var pinned_cell := build.preview_cell
	build.preview_pinned = true
	build.pointer_moved(Vector2(40, 40))
	_expect(build.preview_cell == pinned_cell, "click-pinned placement no longer follows the cursor while reaching the confirmation button")
	build.preview_pinned = false
	var before_smooth := build.preview.position
	build.preview_cell += Vector2i.RIGHT
	build._sync_preview_transform()
	_expect(build.preview.position.is_equal_approx(before_smooth) and not build._preview_target_position.is_equal_approx(before_smooth), "placement previews interpolate toward exact snapped targets instead of jumping cell by cell")
	build.cancel_preview()
	GameState.set_restaurant_state("open")
	build.start_place("fridge")
	_expect(not build.active, "operational equipment remains locked while the restaurant is open")
	build.start_place("plant")
	_expect(build.active, "non-blocking decoration remains editable during service")
	build.cancel_preview()
	GameState.set_restaurant_state("closed")


func _test_agent_navigation_and_appearance(world: RestaurantWorld) -> void:
	var blocked_table := world.placed_objects.get("table_1") as PlacedObject
	var safe_path := world.find_path(world.cell_to_world(world.entrance_cell), blocked_table.global_position)
	_expect(not safe_path.is_empty() and not world.astar.is_point_solid(world.world_to_cell(safe_path[safe_path.size() - 1])) and safe_path[safe_path.size() - 1].distance_to(blocked_table.global_position) > 0.5, "unreachable furniture targets resolve to a safe adjacent cell instead of a straight-line clip")
	_expect(not world.can_agent_move(world.cell_to_world(Vector2i(6, 8)), world.cell_to_world(Vector2i(6, 7)), 0.3), "continuous agent movement cannot cross a blocking wall edge between grid cells")
	var multi_runtime: Dictionary = SimulationManager.stations.get("multi_stove", [])[0]
	var interaction_positions: Array = multi_runtime.get("interaction_positions", [])
	var unique_positions: Dictionary = {}
	for position: Vector3 in interaction_positions:
		unique_positions[position] = true
	_expect(interaction_positions.size() == int(multi_runtime.worker_capacity) and unique_positions.size() == interaction_positions.size() and int(multi_runtime.capacity) >= int(multi_runtime.worker_capacity), "multi-capacity stations expose distinct physical worker slots without confusing batch capacity")
	_expect(CustomerAgent.CUSTOMER_APPEARANCES.size() >= 15 and CustomerAgent.CUSTOMER_APPEARANCES.all(func(appearance: String): return ResourceLoader.exists("res://assets/characters/%s.gltf" % appearance)), "customer population uses at least fifteen valid character variants")
	var sample_agent := AnimatedAgent.new()
	world.add_child(sample_agent)
	sample_agent.world = world
	var sample_tone := Color("df7e8b")
	var sample_model := sample_agent.add_character_model("res://assets/characters/Casual_Male.gltf", Vector3.ZERO, sample_tone)
	var skin_recoloured := false
	var face_recoloured := false
	for node: Node in sample_model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		for surface: int in mesh_instance.mesh.get_surface_count():
			var source := mesh_instance.mesh.surface_get_material(surface)
			var override := mesh_instance.get_surface_override_material(surface)
			if source != null and String(source.resource_name).to_lower() == "skin" and override is StandardMaterial3D:
				skin_recoloured = (override as StandardMaterial3D).albedo_color.is_equal_approx(sample_tone)
			elif source != null and String(source.resource_name).to_lower() == "face" and override is ShaderMaterial:
				face_recoloured = true
	_expect(skin_recoloured and face_recoloured, "runtime character palette applies pink skin and dark facial features without recolouring clothes")
	var employee_agent: EmployeeAgent = world.staff_agents.values()[0]
	var walk_loops := false
	for player: AnimationPlayer in employee_agent.animation_players:
		var walk_name := employee_agent.resolve_animation(player, "Walk")
		if not walk_name.is_empty() and player.get_animation(walk_name).loop_mode == Animation.LOOP_LINEAR:
			walk_loops = true
	_expect(walk_loops, "walk cycles are forced to loop so moving characters never freeze into a sliding pose")
	sample_agent.queue_free()


func _test_camera_input(world: RestaurantWorld) -> void:
	var camera := world.camera_rig
	var before := camera.target
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(300, 300)
	camera.handle_input(press)
	var drag := InputEventMouseMotion.new()
	drag.position = Vector2(340, 325)
	drag.relative = Vector2(40, 25)
	camera.handle_input(drag)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = drag.position
	camera.handle_input(release)
	_expect(camera.target.distance_to(before) > 0.1 and camera.consume_tap() == null, "left mouse drag pans the map instead of selecting")
	press.position = Vector2(420, 240)
	release.position = press.position
	camera.handle_input(press)
	camera.handle_input(release)
	_expect(camera.consume_tap() == Vector2(420, 240), "a short click remains available for object selection")
	var touch := InputEventScreenTouch.new()
	touch.index = 0
	touch.position = Vector2(360, 260)
	touch.pressed = true
	camera.handle_input(touch)
	camera._process(0.6)
	_expect(camera.consume_long_press() == Vector2(360, 260), "touch long press opens contextual build actions without becoming a tap")
	touch.pressed = false
	camera.handle_input(touch)
	world.toggle_debug_paths()
	world.find_path(world.cell_to_world(world.entrance_cell), world.cell_to_world(Vector2i(9, 8)))
	_expect(world.debug_paths_root.get_child_count() > 0, "debug path overlay renders logical routes")
	world.toggle_debug_paths()
	world.toggle_station_queue_labels()
	_expect(not world._queue_labels.is_empty(), "debug station overlay exposes live queues and capacity")
	world.toggle_station_queue_labels()


func _test_progression_and_menu_load(_world: RestaurantWorld) -> void:
	GameState.reset_to_defaults(false)
	var hottest_balanced := 0.0
	for station: Dictionary in DataRegistry.stations:
		hottest_balanced = maxf(hottest_balanced, SimulationManager.predicted_station_load(String(station.id)))
	_expect(hottest_balanced < 100.0, "initial four-dish menu is genuinely balanced with installed capacity")
	for recipe_id: String in GameState.menu:
		GameState.menu[recipe_id].active = false
	for recipe_id: String in ["margherita", "mushroom_pizza", "pepperoni_pizza"]:
		GameState.menu[recipe_id].unlocked = true
		GameState.menu[recipe_id].active = true
	_expect(SimulationManager.predicted_station_load("pizza_oven") > 100.0, "pizza-heavy menu visibly overloads the pizza oven")
	GameState.reset_to_defaults(false)
	GameState.progress.customers_served = 25
	GameState.check_progression(false)
	_expect(bool(GameState.stock.veg_patty.unlocked) and bool(GameState.menu.veggie_burger.unlocked), "customer objective permanently unlocks ingredient and compatible recipe")
	GameState.reputation = 2.0
	GameState.progress.services_started = 1
	GameState.check_progression(false)
	_expect(bool(GameState.stock.ham.unlocked) and bool(GameState.stock.egg.unlocked), "reputation and service objectives unlock their album entries")
	GameState.reset_to_defaults(false)


func _test_recipe_tasks_and_station_reservation() -> void:
	GameState.reset_to_defaults(false)
	SimulationManager.reset_service_stats()
	GameState.set_restaurant_state("open")
	var before_tomato := int(GameState.stock.tomato.amount)
	var order := SimulationManager.create_order("margherita", "table_test", null)
	_expect(not order.is_empty(), "order ticket is created")
	var cook: Dictionary = GameState.employees[0]
	SimulationManager.toggle_order_suspended(String(order.id))
	SimulationManager._update_waiting_tasks(0.0)
	_expect(bool(order.suspended) and SimulationManager.claim_kitchen_task(cook).is_empty(), "suspended pass ticket cannot be claimed")
	SimulationManager.toggle_order_suspended(String(order.id))
	var completed := 0
	for _iteration: int in 20:
		SimulationManager._update_waiting_tasks(0.0)
		var task := SimulationManager.claim_kitchen_task(cook)
		if task.is_empty():
			if bool(order.ready):
				break
			continue
		_expect(task.state == "reserved", "claimed task is atomically reserved")
		if SimulationManager.begin_kitchen_task(task.id):
			SimulationManager.advance_kitchen_task(task.id, 999.0, cook)
			completed += 1
	_expect(completed == DataRegistry.recipes_by_id.margherita.steps.size(), "all recipe dependencies complete in order")
	_expect(bool(order.ready), "final recipe step places dish at pass")
	_expect(int(GameState.stock.tomato.amount) == before_tomato - 2, "recipe consumes linked raw stock")
	var duplicate_count := 0
	for task_id: String in order.task_ids:
		if SimulationManager.tasks[task_id].state == "completed":
			duplicate_count += 1
	_expect(duplicate_count == order.task_ids.size(), "each work task completes once")


func _test_purchased_preparations() -> void:
	GameState.reset_to_defaults(false)
	SimulationManager.reset_service_stats()
	GameState.purchased_preparations = {"dough_base": 1, "tomato_sauce": 1, "cheese_grated": 1}
	var stock_before := {"dough": int(GameState.stock.dough.amount), "tomato": int(GameState.stock.tomato.amount), "cheese": int(GameState.stock.cheese.amount)}
	var order := SimulationManager.create_order("margherita", "prep_test", null)
	var prebuilt := 0
	for task_id: String in order.task_ids:
		if bool(SimulationManager.tasks[task_id].get("prebuilt", false)):
			prebuilt += 1
	_expect(prebuilt == 3 and int(GameState.purchased_preparations.dough_base) == 0, "purchased preparations replace matching preppable recipe tasks")
	_expect(int(GameState.stock.dough.amount) == stock_before.dough and int(GameState.stock.tomato.amount) == stock_before.tomato and int(GameState.stock.cheese.amount) == stock_before.cheese, "using purchased preparations preserves the corresponding raw stock")


func _test_service_assignment() -> void:
	var dummy := Node.new()
	add_child(dummy)
	var service := SimulationManager.request_service(dummy, "take_order", Vector3.ZERO)
	var waiter: Dictionary = GameState.employees[3]
	var claimed := SimulationManager.claim_service_task(waiter)
	_expect(claimed.id == service.id and claimed.state == "reserved", "waiter reserves service task")
	var second := SimulationManager.claim_service_task(waiter)
	_expect(second.is_empty(), "same service task cannot be claimed twice")
	SimulationManager.complete_service_task(claimed.id)
	dummy.queue_free()


func _test_price_margin() -> void:
	var recipe: Dictionary = DataRegistry.recipes_by_id.classic_burger
	var cost := DataRegistry.estimate_recipe_cost(recipe)
	_expect(cost > 0.0, "recipe cost is calculated from ingredients")
	_expect(float(GameState.menu.classic_burger.price) - cost > 0.0, "initial menu margin is positive")
	var predicted := SimulationManager.predicted_station_load("pizza_oven")
	_expect(predicted > 0.0, "menu analysis predicts station load")
	GameState.money = 10000
	var wage_due := 0
	for employee: Dictionary in GameState.employees:
		wage_due += int(employee.salary)
	_expect(EconomyManager.pay_shift_wages() == wage_due and GameState.money == 10000 - wage_due, "closing wage settlement charges the hired brigade")


func _test_save_load() -> void:
	var original_state := GameState.serialize().duplicate(true)
	GameState.money = 8765
	GameState.stock.tomato.amount = 23
	GameState.progress.customers_served = 7
	GameState.employees[0].preferred_station = "pizza_oven"
	var serialized_text := JSON.stringify(GameState.serialize())
	var serialized_state: Dictionary = JSON.parse_string(serialized_text)
	_expect(not serialized_text.is_empty() and not serialized_state.is_empty(), "save state serializes to valid JSON without touching the player's live save")
	GameState.money = 1
	GameState.stock.tomato.amount = 0
	GameState.progress.customers_served = 0
	GameState.employees[0].preferred_station = ""
	GameState.deserialize(serialized_state)
	_expect(GameState.money == 8765, "serialized save state loads successfully")
	_expect(GameState.money == 8765 and int(GameState.stock.tomato.amount) == 23, "save restores money and stock")
	_expect(int(GameState.progress.customers_served) == 7 and String(GameState.employees[0].preferred_station) == "pizza_oven", "save restores progression and preferred station")
	_expect(GameState.layout.size() > 10 and GameState.employees.size() >= 5, "save preserves layout and staff")
	var legacy_state := serialized_state.duplicate(true)
	legacy_state.save_version = 6
	legacy_state.layout = [{"uid":"legacy_oven", "item":"oven", "cell":[5, 10], "rotation":0}]
	GameState.deserialize(legacy_state)
	var legacy_oven_record: Dictionary = GameState.layout.filter(func(record: Dictionary): return String(record.get("uid", "")) == "legacy_oven")[0]
	var legacy_support_uid := String(legacy_oven_record.get("support_uid", ""))
	_expect(not legacy_support_uid.is_empty() and GameState.layout.any(func(record: Dictionary): return String(record.get("uid", "")) == legacy_support_uid and String(record.get("item", "")) == "worktable"), "version 7 repairs countertop appliances from intermediate saves by creating a valid support")
	GameState.deserialize(original_state)
