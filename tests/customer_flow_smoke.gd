extends Node

const SERVICE_STRESS_FIXTURE := preload("res://tests/fixtures/service_stress_fixture.gd")


func _ready() -> void:
	SaveManager.writes_enabled = false
	seed(20260716)
	GameState.reset_to_defaults(false)
	SERVICE_STRESS_FIXTURE.apply()
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
	var lifecycle_rank_by_party: Dictionary = {}
	var lifecycle_monotone := true
	var order_id_by_commit_key: Dictionary = {}
	var order_commits_unique := true
	var decision_offsets: Dictionary = {}
	var meal_animation_valid := true
	for size: int in [4, 2, 3, 1, 2]:
		var customer := CustomerAgent.new()
		main.world.customer_root.add_child(customer)
		customer.setup(main.world, size)
		customer.patience = 240.0
		groups.append(customer)
		decision_offsets[customer._decision_phase_offset] = true
	for tick: int in 1400:
		SimulationManager._process(0.1)
		main.world._process(0.1)
		for employee: EmployeeAgent in main.world.staff_agents.values():
			employee._process(0.1)
		for customer: CustomerAgent in groups:
			if is_instance_valid(customer) and not customer.is_queued_for_deletion():
				customer._process(0.1)
			if not is_instance_valid(customer):
				continue
			var party_id := customer.get_instance_id()
			var rank := int(CustomerAgent.LIFECYCLE_RANKS.get(customer.lifecycle_state, -1))
			var previous_rank := int(lifecycle_rank_by_party.get(party_id, -1))
			lifecycle_monotone = lifecycle_monotone and rank >= previous_rank
			lifecycle_rank_by_party[party_id] = rank
			for person: CustomerPersonAgent in customer.people:
				if person._seated_mode == "eating":
					meal_animation_valid = meal_animation_valid and person.meal_present and customer.served_order_ids.values().size() > 0
		for order: Dictionary in SimulationManager.orders.values():
			var commit_key := String(order.get("idempotency_key", ""))
			if commit_key.is_empty():
				continue
			var order_id := String(order.get("id", ""))
			if order_id_by_commit_key.has(commit_key) and String(order_id_by_commit_key[commit_key]) != order_id:
				order_commits_unique = false
			order_id_by_commit_key[commit_key] = order_id
		if tick in [20, 100, 300, 700, 1200]:
			for customer: CustomerAgent in groups:
				if not is_instance_valid(customer):
					continue
				print("FLOW tick=", tick, " party=", customer.name, " state=", customer.state, " table=", customer.table.get("uid", "-"), " people=", customer.people.map(func(person: CustomerPersonAgent): return "%s:%s pos=%s dest=%s nav=%s fail=%s" % [person.member_index, person.phase, person.global_position, person.destination, person.navigation_active, person.navigation_failed]))
	var all_served: bool = int(SimulationManager.stats.customers_served) == 12
	var queue_drained: bool = main.world.customer_queue.is_empty()
	var no_registered_parties: bool = SimulationManager.customers.is_empty()
	var all_despawned := groups.all(func(customer: CustomerAgent): return customer.lifecycle_state == CustomerAgent.LIFECYCLE_DESPAWN)
	var scheduler_staggered := decision_offsets.size() > 1
	var service_requests_event_driven := groups.all(func(customer: CustomerAgent): return customer._service_request_attempts <= 3)
	var canonical_stages: Array[String] = [CustomerAgent.LIFECYCLE_QUEUE, CustomerAgent.LIFECYCLE_ENTER, CustomerAgent.LIFECYCLE_TABLE, CustomerAgent.LIFECYCLE_SEATING, CustomerAgent.LIFECYCLE_ORDER, CustomerAgent.LIFECYCLE_WAIT_FOOD, CustomerAgent.LIFECYCLE_EATING, CustomerAgent.LIFECYCLE_PAYMENT, CustomerAgent.LIFECYCLE_LEAVING, CustomerAgent.LIFECYCLE_DESPAWN]
	var canonical_lifecycle_complete := groups.all(func(customer: CustomerAgent): return canonical_stages.all(func(stage: String): return customer.lifecycle_history.has(stage)))
	var passed: bool = all_served and queue_drained and no_registered_parties and lifecycle_monotone and order_commits_unique and all_despawned and scheduler_staggered and service_requests_event_driven and canonical_lifecycle_complete and meal_animation_valid
	var result := "CUSTOMER FLOW SMOKE: %s served=%d queue=%d active=%d monotone=%s canonical=%s unique_orders=%s despawned=%s staggered=%s event_service=%s meal_animation=%s\n" % ["PASS" if passed else "FAIL", int(SimulationManager.stats.customers_served), main.world.customer_queue.size(), SimulationManager.customers.size(), lifecycle_monotone, canonical_lifecycle_complete, order_commits_unique, all_despawned, scheduler_staggered, service_requests_event_driven, meal_animation_valid]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/customer-flow-smoke-result.txt", FileAccess.WRITE)
	file.store_string(result)
	SimulationManager.close_immediately()
	get_tree().quit(0 if passed else 1)
