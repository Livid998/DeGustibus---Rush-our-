extends Node


func _ready() -> void:
	seed(42)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	for _frame: int in 40:
		await get_tree().process_frame
	GameState.reset_to_defaults(false)
	main.world.load_layout()
	GameState.tutorial.skipped = true
	main.ui._update_tutorial()
	main.ui.close_screen()
	main.world.set_process_unhandled_input(false)
	main.world.camera_rig.zoom = 18.0
	main.world.camera_rig.target = main.world.cell_to_world(Vector2i(9, 10))
	main.world.camera_rig.global_position = main.world.camera_rig.target
	main.ui.open_builder()
	main.ui.build_hud.current_category = "Cucina"
	main.ui.build_hud.refresh_catalog()
	for _frame: int in 35:
		await get_tree().process_frame
	await _save_frame("res://artifacts/builder_countertop_system.png")

	var cutting_board := main.world.placed_objects.get("cut_1") as PlacedObject
	var cutting_support := main.world.placed_objects.get(cutting_board.support_uid) as PlacedObject
	main.world.build_system.select_object(cutting_board)
	main.world.build_system.move_selected()
	main.world.build_system.preview_cell = cutting_support.grid_cell
	main.world.build_system.rotation_steps = cutting_support.rotation_steps
	main.world.build_system.preview_support_uid = cutting_support.uid
	main.world.build_system.preview_attachment_slot = 0
	main.world.build_system.preview_pinned = true
	main.world.build_system._sync_preview_transform()
	for _frame: int in 35:
		await get_tree().process_frame
	await _save_frame("res://artifacts/builder_two_slot_tool.png")

	main.world.build_system.cancel_preview()
	main.world.camera_rig.target = main.world.cell_to_world(Vector2i(7, 4))
	main.world.camera_rig.global_position = main.world.camera_rig.target
	var table := main.world.placed_objects.get("table_1") as PlacedObject
	var chair := main.world.placed_objects.get("chair_2") as PlacedObject
	main.world.build_system.select_object(chair)
	main.world.build_system.move_selected()
	main.world.build_system.preview_cell = table.grid_cell
	main.world.build_system.rotation_steps = main.world.seat_rotation_for_slot(3, table.rotation_steps)
	main.world.build_system.preview_support_uid = table.uid
	main.world.build_system.preview_attachment_slot = 3
	main.world.build_system.preview_pinned = true
	main.world.build_system._sync_preview_transform()
	for _frame: int in 35:
		await get_tree().process_frame
	await _save_frame("res://artifacts/builder_chair_snap.png")

	main.world.build_system.cancel_preview()
	main.world.build_system.select_object(table)
	main.ui.build_hud.refresh_actions()
	for _frame: int in 20:
		await get_tree().process_frame
	await _save_frame("res://artifacts/builder_attachment_selection.png")

	main.world.build_system.move_selected()
	main.world.build_system.preview_cell = Vector2i(6, 3)
	main.world.build_system.preview_pinned = true
	main.world.build_system._sync_preview_transform()
	main.ui.build_hud.refresh_actions()
	for _frame: int in 35:
		await get_tree().process_frame
	await _save_frame("res://artifacts/builder_move_reference.png")

	main.world.build_system.cancel_preview()
	main.world.build_system.clear_selection()
	main.world.camera_rig.target = main.world.cell_to_world(Vector2i(1, 9))
	main.world.camera_rig.global_position = main.world.camera_rig.target
	main.world.build_system.start_place("fridge")
	main.world.build_system.preview_cell = Vector2i(0, 10)
	main.world.build_system.rotation_steps = 1
	main.world.build_system.preview_pinned = true
	main.world.build_system._sync_preview_transform()
	for _frame: int in 35:
		await get_tree().process_frame
	await _save_frame("res://artifacts/builder_front_access_invalid.png")
	get_tree().quit()


func _save_frame(path: String) -> void:
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("CAPTURED ", path, " ", image.get_size())
