extends Node

const CAPTURE_DIR := "res://artifacts/m10-responsive-final"
const TARGETS := [
	{
		"size": Vector2i(390, 844),
		"screen": "Menu",
		"path": "phone-390x844-menu.png",
	},
	{
		"size": Vector2i(412, 915),
		"screen": "Ristorante",
		"path": "phone-412x915-altro.png",
		"more": true,
	},
	{
		"size": Vector2i(800, 1024),
		"screen": "Album",
		"path": "tablet-800x1024-album.png",
	},
	{
		"size": Vector2i(1280, 720),
		"screen": "Ristorante",
		"path": "desktop-1280x720-restaurant.png",
	},
	{
		"size": Vector2i(1366, 768),
		"screen": "Statistiche",
		"path": "desktop-1366x768-statistics.png",
	},
]

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	seed(42)
	var previous_writes_enabled := SaveManager.writes_enabled
	SaveManager.writes_enabled = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_DIR))

	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	for _frame: int in 30:
		await get_tree().process_frame

	# Native desktop builds retain an 800 px minimum for normal play. Captures
	# emulate the Web build, whose minimum is 320 px, so phone viewport images
	# are true 1:1 CSS-pixel fixtures instead of scaled desktop screenshots.
	get_window().min_size = Vector2i(320, 320)
	GameState.tutorial.skipped = true
	main.ui._update_tutorial()
	SimulationManager.close_immediately()

	for target: Dictionary in TARGETS:
		await _capture_target(main, target)

	SaveManager.writes_enabled = previous_writes_enabled
	if failures.is_empty():
		print("M10 CAPTURES: PASS | targets=%d" % TARGETS.size())
	else:
		print("M10 CAPTURES: FAIL | %s" % " | ".join(failures))
	get_tree().quit(0 if failures.is_empty() else 1)


func _capture_target(main: Node, target: Dictionary) -> void:
	var target_size: Vector2i = target.size
	get_window().size = target_size
	for _frame: int in 5:
		await get_tree().process_frame
	main.ui._apply_responsive_layout(Vector2(target_size))
	main.ui.show_screen(String(target.screen), false)
	for _frame: int in 12:
		await get_tree().process_frame
	if bool(target.get("more", false)):
		main.ui.more_button.pressed.emit()
		for _frame: int in 5:
			await get_tree().process_frame

	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var capture_path := "%s/%s" % [CAPTURE_DIR, String(target.path)]
	var error := image.save_png(capture_path)
	var actual_size := image.get_size()
	if error != OK:
		failures.append("%s save error %s" % [target.path, error_string(error)])
	if actual_size != target_size:
		failures.append("%s is %s, expected %s" % [target.path, actual_size, target_size])
	if Vector2i(main.ui.root.size) != target_size:
		failures.append(
			"%s UI root is %s, expected %s"
			% [target.path, Vector2i(main.ui.root.size), target_size]
		)
	if main.world.camera_rig.camera == null or not main.world.camera_rig.camera.current:
		failures.append("%s has no active world camera" % target.path)
	print(
		"CAPTURED %s | image=%s ui=%s camera=%s"
		% [
			capture_path,
			actual_size,
			Vector2i(main.ui.root.size),
			main.world.camera_rig.camera.current,
		]
	)
