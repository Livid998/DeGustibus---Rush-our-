extends Node


func _ready() -> void:
	seed(20260716)
	SaveManager.writes_enabled = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	get_window().size = Vector2i(1440, 900)
	GameState.reset_to_defaults(false)
	GameState.tutorial.skipped = true
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	for _frame: int in 2:
		await get_tree().process_frame
	main.ui._update_tutorial()
	main.ui.close_screen()
	main.world.set_process_unhandled_input(false)
	main.world.camera_rig.zoom = 16.0
	main.world.camera_rig.camera.size = 16.0
	main.world.camera_rig.target = main.world.cell_to_world(Vector2i(8, 3))
	main.world.camera_rig.global_position = main.world.camera_rig.target

	var customer := CustomerAgent.new()
	main.world.customer_root.add_child(customer)
	customer.setup(main.world, 2)
	customer.table = main.world.request_table(customer, 2)
	customer._seat_group()
	customer._set_state("waiting_order")
	customer._thought.text = "MENU"
	customer._thought.visible = true

	var staff_states := ["COMANDA", "PRONTO!", "LAVAGGIO", "PULIZIA"]
	var staff_index := 0
	for employee: EmployeeAgent in main.world.staff_agents.values():
		if staff_index >= staff_states.size():
			employee.visible = false
			continue
		employee.set_process(false)
		employee.global_position = main.world.cell_to_world(Vector2i(5 + staff_index * 2, 6))
		employee._thought.text = staff_states[staff_index]
		employee._thought.visible = true
		staff_index += 1

	for _frame: int in 2:
		await get_tree().process_frame
	await _save_frame("res://artifacts/status_bubbles_close_zoom.png")
	get_tree().quit()


func _save_frame(path: String) -> void:
	RenderingServer.force_draw()
	# Some display backends do not emit `frame_post_draw` reliably after an
	# explicit force. The scene already rendered two frames; one more process
	# frame flushes the close-zoom bubble sprites deterministically.
	await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("CAPTURED ", path, " ", image.get_size())
