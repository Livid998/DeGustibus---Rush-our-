extends Node


func _ready() -> void:
	seed(42)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	for _frame: int in 60:
		await get_tree().process_frame
	GameState.tutorial.skipped = true
	main.ui._update_tutorial()
	main.ui.close_screen()
	main.world.set_process_unhandled_input(false)
	main.world.camera_rig.zoom = 23.0
	for _frame: int in 30:
		await get_tree().process_frame
	await _save_frame("res://artifacts/map_palette_fixed.png")

	main.ui.open_builder()
	main.ui.build_hud.current_category = "Cucina"
	main.ui.build_hud.refresh_catalog()
	main.world.build_system.start_place("prep_counter")
	main.world.build_system.preview_cell = Vector2i(14, 5)
	main.world.build_system.rotation_steps = 0
	main.world.build_system._sync_preview_transform()
	for _frame: int in 45:
		await get_tree().process_frame
	await _save_frame("res://artifacts/map_grid_alignment.png")

	main.world.build_system.cancel_preview()
	main.ui.build_hud.current_category = "Strutture"
	main.ui.build_hud.refresh_catalog()
	main.world.build_system.start_place("wall_window")
	main.world.build_system.preview_cell = Vector2i(6, 8)
	main.world.build_system.rotation_steps = 0
	main.world.build_system._sync_preview_transform()
	for _frame: int in 45:
		await get_tree().process_frame
	await _save_frame("res://artifacts/map_wall_edge_snap.png")

	main.world.build_system.cancel_preview()
	main.ui.build_hud.current_category = "Cucina"
	main.ui.build_hud.refresh_catalog()
	main.world.build_system.start_place("prep_counter")
	main.world.build_system.preview_cell = Vector2i(13, 4)
	main.world.build_system.rotation_steps = 0
	main.world.build_system._sync_preview_transform()
	for _frame: int in 90:
		await get_tree().process_frame
	await _save_frame("res://artifacts/map_grid_alignment.png")

	main.world.build_system.cancel_preview()
	main.ui.build_hud.current_category = "Strutture"
	main.ui.build_hud.refresh_catalog()
	main.world.build_system.start_place("wall_window")
	main.world.build_system.preview_cell = Vector2i(6, 8)
	main.world.build_system.rotation_steps = 0
	main.world.build_system._sync_preview_transform()
	for _frame: int in 90:
		await get_tree().process_frame
	await _save_frame("res://artifacts/map_wall_edge_snap.png")

	main.world.build_system.cancel_preview()
	main.ui.build_hud.close_builder(false)
	var door_support: PlacedObject = main.world.structural_edge_at(Vector2i(6, 8), 0)
	if door_support != null:
		main.world.remove_placed_object(door_support, true)
	main.world.add_layout_object("door", Vector2i(6, 8), 0)
	main.world.set_grid_visible(true)
	for _frame: int in 90:
		await get_tree().process_frame
	await _save_frame("res://artifacts/map_door_composite.png")

	main.ui.open_builder()
	main.ui.build_hud.current_category = "Cucina"
	main.ui.build_hud.refresh_catalog()
	main.world.build_system.start_place("fridge")
	var perimeter_cell := Vector2i(0, 1)
	for candidate_y: int in range(1, RestaurantWorld.GRID_SIZE.y):
		var candidate := Vector2i(0, candidate_y)
		if bool(main.world.validate_placement(DataRegistry.build_by_id.fridge, candidate, 0).valid):
			perimeter_cell = candidate
			break
	main.world.build_system.preview_cell = perimeter_cell
	main.world.build_system.rotation_steps = 0
	main.world.build_system._sync_preview_transform()
	for _frame: int in 90:
		await get_tree().process_frame
	await _save_frame("res://artifacts/map_perimeter_equipment.png")

	main.world.build_system.cancel_preview()
	main.ui.build_hud.current_category = "Strutture"
	main.ui.build_hud.refresh_catalog()
	main.world.build_system.start_place("wall")
	main.world.build_system.preview_cell = Vector2i(1, 8)
	main.world.build_system.rotation_steps = 1
	main.world.build_system._sync_preview_transform()
	for _frame: int in 90:
		await get_tree().process_frame
	await _save_frame("res://artifacts/map_wall_intersection.png")
	get_tree().quit()


func _save_frame(path: String) -> void:
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("CAPTURED ", path, " ", image.get_size())
