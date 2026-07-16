extends Node


func _ready() -> void:
	SaveManager.writes_enabled = false
	seed(20260716)
	GameState.reset_to_defaults(false)
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	main.world.load_layout()
	main.world.spawn_staff()
	SimulationManager.reset_service_stats()
	SimulationManager.set_speed(4.0)
	SimulationManager.open_restaurant()
	main.world._spawn_clock = 99999.0
	var groups: Array[CustomerAgent] = []
	for size: int in [4, 2, 3, 1, 2]:
		var customer := CustomerAgent.new()
		main.world.customer_root.add_child(customer)
		customer.setup(main.world, size)
		customer.patience = 240.0
		groups.append(customer)
	for tick: int in 1400:
		SimulationManager._process(0.1)
		main.world._process(0.1)
		for employee: EmployeeAgent in main.world.staff_agents.values():
			employee._process(0.1)
		for customer: CustomerAgent in groups:
			if is_instance_valid(customer) and not customer.is_queued_for_deletion():
				customer._process(0.1)
		if tick in [20, 100, 300, 700, 1200]:
			for customer: CustomerAgent in groups:
				if not is_instance_valid(customer):
					continue
				print("FLOW tick=", tick, " party=", customer.name, " state=", customer.state, " table=", customer.table.get("uid", "-"), " people=", customer.people.map(func(person: CustomerPersonAgent): return "%s:%s pos=%s dest=%s nav=%s fail=%s" % [person.member_index, person.phase, person.global_position, person.destination, person.navigation_active, person.navigation_failed]))
	var all_served: bool = int(SimulationManager.stats.customers_served) == 12
	var queue_drained: bool = main.world.customer_queue.is_empty()
	var no_registered_parties: bool = SimulationManager.customers.is_empty()
	var passed: bool = all_served and queue_drained and no_registered_parties
	var result := "CUSTOMER FLOW SMOKE: %s served=%d queue=%d active=%d\n" % ["PASS" if passed else "FAIL", int(SimulationManager.stats.customers_served), main.world.customer_queue.size(), SimulationManager.customers.size()]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/customer-flow-smoke-result.txt", FileAccess.WRITE)
	file.store_string(result)
	SimulationManager.close_immediately()
	get_tree().quit(0 if passed else 1)
