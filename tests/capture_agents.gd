extends Node


func _ready() -> void:
	seed(20260716)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	for _frame: int in 25:
		await get_tree().process_frame
	GameState.reset_to_defaults(false)
	GameState.tutorial.skipped = true
	main.world.load_layout()
	main.world.spawn_staff()
	main.ui._update_tutorial()
	main.world.set_process_unhandled_input(false)
	main.ui.close_screen()
	main.world.camera_rig.zoom = 15.0
	main.world.camera_rig.target = main.world.cell_to_world(Vector2i(7, 4))
	main.world.camera_rig.global_position = main.world.camera_rig.target
	var first := _seat_group(main.world, 4)
	var second := _seat_group(main.world, 4)
	first._thought.visible = false
	second._thought.visible = false
	for _frame: int in 70:
		await get_tree().process_frame
	for person: CustomerPersonAgent in first.people:
		person._maintain_seated_pose()
	for person: CustomerPersonAgent in second.people:
		person._maintain_seated_pose()
	await _save_frame("res://artifacts/agents_seated_variety.png")
	get_tree().quit()


func _seat_group(world: RestaurantWorld, size: int) -> CustomerAgent:
	var customer := CustomerAgent.new()
	world.customer_root.add_child(customer)
	customer.global_position = world.find_safe_agent_position(world.cell_to_world(world.entrance_cell), customer)
	customer.setup(world, size)
	customer.table = world.request_table(customer, size)
	customer._seat_group()
	for person: CustomerPersonAgent in customer.people:
		person._lock_animation_pose("SitDown", 1.0)
	customer._set_state("waiting_food")
	customer.state_elapsed = 2.0
	return customer


func _save_frame(path: String) -> void:
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("CAPTURED ", path, " ", image.get_size())
