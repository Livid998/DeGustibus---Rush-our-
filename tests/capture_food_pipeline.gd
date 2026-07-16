extends Node


func _ready() -> void:
	print("FOOD_CAPTURE start")
	seed(20260716)
	SaveManager.writes_enabled = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	get_window().size = Vector2i(1440, 900)
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	GameState.tutorial.skipped = true
	main.ui._update_tutorial()
	print("FOOD_CAPTURE main added")
	for _frame: int in 35:
		await get_tree().process_frame
	print("FOOD_CAPTURE initial frames")
	main.ui.close_screen()
	main.world.set_process_unhandled_input(false)
	main.world.camera_rig.zoom = 19.0
	main.world.camera_rig.target = Vector3(4.0, 0.0, 8.0)
	main.world.camera_rig.global_position = main.world.camera_rig.target
	_show_station_phase(main.world, "cutting_board", "beef_stew", "chop", 0.46)
	_show_station_phase(main.world, "dough", "margherita", "base", 0.48)
	_show_station_phase(main.world, "stove", "steak_plate", "sear", 0.54)
	_show_station_phase(main.world, "oven", "roast_potatoes", "cook", 0.52)
	_show_station_phase(main.world, "dessert", "mixed_sundae", "scoop", 0.50)
	_show_station_phase(main.world, "pass", "roast_potatoes", "finish", 0.88)
	print("FOOD_CAPTURE phases shown")
	for _frame: int in 24:
		await get_tree().process_frame
	await _save_frame("res://artifacts/food_pipeline_stations.png")
	print("FOOD_CAPTURE station saved")
	_clear_station_visuals(main.world)
	main.world.camera_rig.zoom = 10.8
	main.world.camera_rig.target = main.world.cell_to_world(Vector2i(11, 3))
	main.world.camera_rig.global_position = main.world.camera_rig.target
	var customer := _seat_party(main.world, 4)
	print("FOOD_CAPTURE party seated")
	var recipe_ids := ["margherita", "classic_burger", "mixed_salad", "beef_stew"]
	for index: int in customer.people.size():
		var order := {"id":"CAPTURE_%d" % index, "recipe_id":recipe_ids[index], "diner_index":index}
		customer._show_dish(order)
		var utensil := "spoon" if recipe_ids[index] == "beef_stew" else "fork"
		customer.people[index].set_seated_mode("eating", true, utensil)
		customer.people[index]._bite_active = index % 2 == 0
		customer.people[index]._bite_elapsed = customer.people[index]._bite_duration * (0.44 + 0.08 * index)
		customer.people[index]._maintain_seated_pose(0.0)
	for _frame: int in 8:
		await get_tree().process_frame
	await _save_frame("res://artifacts/customer_eating_gestures.png")
	print("FOOD_CAPTURE eating saved")
	main.world.camera_rig.zoom = 4.6
	main.world.camera_rig.target = customer.people[0].global_position
	main.world.camera_rig.global_position = main.world.camera_rig.target
	for _frame: int in 4:
		await get_tree().process_frame
		customer.people[0]._maintain_seated_pose(0.0)
	await _save_frame("res://artifacts/customer_utensil_grip.png")
	print("FOOD_CAPTURE utensil grip saved")
	main.world.camera_rig.zoom = 10.8
	main.world.camera_rig.target = main.world.cell_to_world(Vector2i(11, 3))
	main.world.camera_rig.global_position = main.world.camera_rig.target
	# One frame documents the complete table lifecycle without continuously
	# scaling a plated model: full serving, partial food, leftovers and dirt.
	customer._update_dish_consumption("CAPTURE_1", 0.50)
	customer._update_dish_consumption("CAPTURE_2", 0.20)
	customer._replace_dish_with_dirty("CAPTURE_3")
	for _frame: int in 5:
		await get_tree().process_frame
	await _save_frame("res://artifacts/customer_consumption_stages.png")
	print("FOOD_CAPTURE consumption saved")
	customer.visible = false
	var waiter := _first_waiter(main.world)
	if waiter != null:
		waiter.set_process(false)
		waiter.global_position = main.world.cell_to_world(Vector2i(11, 4))
		waiter.rotation.y = 0.0
		waiter.active_task = {"action":"serve", "payload":{"recipe_id":"classic_burger"}}
		waiter._show_task_prop(false)
		waiter.play_animation("Walk_Carry")
		waiter._update_carried_prop_anchor()
		main.world.camera_rig.zoom = 8.5
		main.world.camera_rig.target = waiter.global_position
		main.world.camera_rig.global_position = waiter.global_position
		for _frame: int in 8:
			await get_tree().process_frame
			waiter._update_carried_prop_anchor()
		await _save_frame("res://artifacts/waiter_carry_alignment.png")
		print("FOOD_CAPTURE carry saved")
	get_tree().quit()


func _show_station_phase(world: RestaurantWorld, station_id: String, recipe_id: String, step_id: String, progress: float) -> void:
	var station := _first_station(world, station_id)
	if station == null:
		return
	var recipe: Dictionary = DataRegistry.recipes_by_id.get(recipe_id, {})
	for step: Dictionary in recipe.get("steps", []):
		if String(step.id) != step_id:
			continue
		var task := {
			"id":"CAPTURE_%s_%s" % [recipe_id, step_id],
			"recipe_step_id":step_id,
			"station":station_id,
			"inputs":step.get("inputs", {}).duplicate(true),
			"dependencies":[],
			"output":String(step.get("output", "")),
			"model":String(step.get("model", "")),
			"visual":step.get("visual", {}).duplicate(true),
			"duration":10.0,
			"remaining":10.0 * (1.0 - progress)
		}
		station.show_task(task)
		station.update_task_progress(task)
		print("FOOD_CAPTURE anchor ", station_id, " local=", station._food_anchor.position, " global=", station._food_anchor.global_position, " station=", station.global_position, " interaction=", station.get_interaction_position(), " rot=", station.rotation_steps, " parts=", station._food_models.size())
		return


func _first_station(world: RestaurantWorld, station_id: String) -> PlacedObject:
	for value: Variant in world.placed_objects.values():
		var placed := value as PlacedObject
		if placed != null and placed.station_id == station_id:
			return placed
	return null


func _clear_station_visuals(world: RestaurantWorld) -> void:
	for value: Variant in world.placed_objects.values():
		var placed := value as PlacedObject
		if placed != null and not placed.station_id.is_empty():
			placed.clear_task()


func _seat_party(world: RestaurantWorld, size: int) -> CustomerAgent:
	var customer := CustomerAgent.new()
	world.customer_root.add_child(customer)
	customer.global_position = world.find_safe_agent_position(world.cell_to_world(world.entrance_cell), customer)
	customer.setup(world, size)
	customer.table = world.request_table(customer, size)
	customer._seat_group()
	customer._thought.visible = false
	customer._set_state("eating")
	return customer


func _first_waiter(world: RestaurantWorld) -> EmployeeAgent:
	for value: Variant in world.staff_agents.values():
		var employee := value as EmployeeAgent
		if employee != null and String(employee.employee.get("role", "")) == "waiter":
			return employee
	return null


func _save_frame(path: String) -> void:
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(path)
	print("CAPTURED ", path, " ", image.get_size())
