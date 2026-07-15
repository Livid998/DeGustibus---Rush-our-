extends Node


func _ready() -> void:
	seed(42)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	for _frame: int in 45:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_closed.png")
	main.ui.show_screen("Album")
	for _frame: int in 45:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_album.png")
	main.ui.show_screen("Menu", false)
	for _frame: int in 20:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_menu.png")
	main.ui.show_screen("Mercato", false)
	for _frame: int in 20:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_market.png")
	main.ui.show_screen("Personale", false)
	for _frame: int in 15:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_staff.png")
	main.ui.show_screen("Statistiche", false)
	for _frame: int in 15:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_statistics.png")
	main.ui.show_screen("Impostazioni", false)
	for _frame: int in 15:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_settings.png")
	main.ui.show_screen("Ristorante", false)
	main.ui.open_builder()
	main.ui.build_hud.current_category = "Cucina"
	main.ui.build_hud.refresh_catalog()
	main.world.build_system.start_place("pizza_oven")
	main.world.build_system.preview_cell = Vector2i(14, 8)
	main.world.build_system._sync_preview_transform()
	for _frame: int in 20:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_builder.png")
	main.world.build_system.cancel_preview()
	main.ui.build_hud.close_builder(false)
	SimulationManager.open_restaurant()
	SimulationManager.set_speed(4.0)
	main.ui.close_screen()
	main.world._spawn_clock = 99999.0
	main.world.table_occupants["table_1"] = main
	var customer := CustomerAgent.new()
	main.world.customer_root.add_child(customer)
	customer.global_position = main.world.cell_to_world(main.world.entrance_cell)
	customer.setup(main.world, 4)
	for _frame: int in 800:
		await get_tree().process_frame
		if customer.state in ["waiting_food", "eating"]:
			break
	print("SEATING state=", customer.state, " group=", customer.group_size, " seats=", customer.table.get("seat_positions", []).size())
	for index: int in customer.group_models.size():
		var model: Node3D = customer.group_models[index]
		var geometries := model.find_children("*", "GeometryInstance3D", true, false)
		print("SEAT_MODEL ", index, " name=", model.name, " visible=", model.visible, " pos=", model.global_position, " screen=", main.world.camera_rig.camera.unproject_position(model.global_position), " geometry=", geometries[0].global_position if not geometries.is_empty() else Vector3.ZERO)
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_service.png")
	SimulationManager.close_immediately()
	main.ui.show_screen("Magazzino")
	get_window().size = Vector2i(768, 1024)
	for _frame: int in 30:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_save_frame("res://artifacts/demo_portrait.png")
	get_tree().quit()


func _save_frame(path: String) -> void:
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("CAPTURED ", path, " ", image.get_size())
