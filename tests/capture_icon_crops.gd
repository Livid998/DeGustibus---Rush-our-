extends Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	await _wait_frames(35)

	main.ui.show_screen("Album")
	await _wait_frames(25)
	await _save_frame("res://artifacts/demo_album_icons_fixed.png")
	main.ui.screen_scroll.scroll_vertical = int(main.ui.screen_scroll.get_v_scroll_bar().max_value)
	await _wait_frames(10)
	await _save_frame("res://artifacts/demo_album_icons_lower.png")

	main.ui.show_screen("Menu", false)
	await _wait_frames(25)
	await _save_frame("res://artifacts/demo_menu_icons_fixed.png")
	main.ui.screen_scroll.scroll_vertical = int(main.ui.screen_scroll.get_v_scroll_bar().max_value)
	await _wait_frames(10)
	await _save_frame("res://artifacts/demo_menu_icons_lower.png")

	main.ui.show_screen("Impostazioni", false)
	main.ui.screen_scroll.scroll_vertical = 0
	await _wait_frames(20)
	await _save_frame("res://artifacts/demo_settings_icons.png")
	get_tree().quit()


func _wait_frames(count: int) -> void:
	for _frame: int in count:
		await get_tree().process_frame


func _save_frame(path: String) -> void:
	RenderingServer.force_draw()
	await get_tree().process_frame
	await get_tree().process_frame
	RenderingServer.force_draw()
	await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("CAPTURED ", path, " ", image.get_size())
