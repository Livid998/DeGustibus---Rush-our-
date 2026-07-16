extends Node


func _ready() -> void:
	SaveManager.writes_enabled = false
	seed(20260715)
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	SimulationManager.reset_service_stats()
	SimulationManager.set_speed(4.0)
	SimulationManager.open_restaurant()
	main.world.rush_mode = false
	main.world._spawn_clock = 99999.0
	main.ui.close_screen()
	var customer := CustomerAgent.new()
	main.world.customer_root.add_child(customer)
	customer.global_position = main.world.cell_to_world(main.world.entrance_cell)
	customer.setup(main.world, 1)
	# Avanza direttamente gli stessi _process usati in gioco: il test resta
	# deterministico e non dipende dalla velocità del renderer headless.
	for tick: int in 500:
		SimulationManager._process(0.25)
		main.world._process(0.25)
		for employee_agent: EmployeeAgent in main.world.staff_agents.values():
			employee_agent._process(0.25)
		if is_instance_valid(customer):
			customer._process(0.25)
		if int(SimulationManager.stats.customers_served) > 0:
			break
		if tick > 0 and tick % 50 == 0:
			var progress_line := "tick=%d customer=%s pos=%s path=%d/%d failed=%s stuck=%.1f orders=%d tasks=%d" % [tick, customer.state, customer.global_position, customer.path_index, customer.path.size(), customer.navigation_failed, customer.total_stuck_time, SimulationManager.orders.size(), SimulationManager.tasks.size()]
			print("SMOKE PROGRESS ", progress_line)
	var summary := SimulationManager.summary()
	var served := int(summary.customers_served)
	var customer_states := []
	for active_customer: Node in SimulationManager.customers:
		customer_states.append(active_customer.get("state"))
	var employee_states := []
	for active_employee: Node in main.world.staff_agents.values():
		employee_states.append("%s:%s" % [active_employee.name, active_employee.get("state")])
	var task_states := []
	for task: Dictionary in SimulationManager.tasks.values():
		if not task.is_empty():
			task_states.append("%s:%s@%s" % [task.get("recipe_step_id", "?"), task.get("state", "?"), task.get("station", "?")])
	var result := "SERVICE SMOKE: %s | served=%d revenue=%d active_customers=%d\n" % [
		"PASS" if served > 0 else "FAIL",
		served,
		int(summary.revenue),
		SimulationManager.customers.size()
	]
	result += "orders=%d kitchen_tasks=%d service_tasks=%d customers=%s employees=%s\n" % [SimulationManager.orders.size(), SimulationManager.tasks.size(), SimulationManager.service_tasks.size(), customer_states, employee_states]
	result += "task_states=%s stations=%s\n" % [task_states, SimulationManager.stations.keys()]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/service-smoke-result.txt", FileAccess.WRITE)
	file.store_string(result)
	SimulationManager.close_immediately()
	get_tree().quit(0 if served > 0 else 1)
