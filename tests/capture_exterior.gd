extends Node


func _ready() -> void:
	seed(42)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	for _frame: int in 90:
		await get_tree().process_frame
	GameState.tutorial.skipped = true
	main.ui._update_tutorial()
	main.ui.close_screen()
	main.world.set_process_unhandled_input(false)
	main.world.camera_rig.target = Vector3(6.0, 0.0, 0.0)
	main.world.camera_rig.zoom = 34.0
	for _frame: int in 60:
		await get_tree().process_frame
	await _save_frame("res://artifacts/exterior_lot.png")

	main.ui.open_builder()
	main.ui.build_hud.current_category = "Esterni"
	main.ui.build_hud.refresh_catalog()
	main.world.build_system.start_place("exterior_tree")
	main.world.build_system.preview_cell = Vector2i(20, 15)
	main.world.build_system.rotation_steps = 0
	main.world.build_system._sync_preview_transform()
	for _frame: int in 45:
		await get_tree().process_frame
	await _save_frame("res://artifacts/exterior_builder.png")
	get_tree().quit()


func _save_frame(path: String) -> void:
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("CAPTURED ", path, " ", image.get_size())
