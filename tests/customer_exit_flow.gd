extends Node

const STEP := 0.10
const MAX_DEPARTURE_SECONDS := 30.0
const SERVICE_STRESS_FIXTURE := preload("res://tests/fixtures/service_stress_fixture.gd")

var failures: Array[String] = []


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
	for employee: EmployeeAgent in main.world.staff_agents.values():
		employee.shutdown_navigation()
		employee.set_collision_enabled(false)
	SimulationManager.reset_service_stats()
	var customer := CustomerAgent.new()
	main.world.customer_root.add_child(customer)
	customer.global_position = main.world.cell_to_world(main.world.entrance_cell)
	customer.setup(main.world, 4)
	customer.table = main.world.request_table(customer, 4)
	_expect(not customer.table.is_empty() and customer._seat_group(), "four guests start from a valid occupied table")
	var gates: Array[Vector3] = []
	for index: int in customer.group_size:
		gates.append(customer._exit_gate_position(index))
	var lanes_are_unique := true
	for first: int in gates.size():
		for second: int in range(first + 1, gates.size()):
			lanes_are_unique = lanes_are_unique and gates[first].distance_to(gates[second]) >= CustomerAgent.EXIT_LANE_SPACING - 0.01
	_expect(lanes_are_unique, "all four diners own separate sidewalk lanes and gate coordinates")
	customer._begin_leaving(false)
	_expect(customer.lifecycle_state == CustomerAgent.LIFECYCLE_LEAVING, "departure enters the canonical terminal lifecycle exactly once")
	var departure_state := customer.state
	customer._set_state("waiting_order")
	_expect(customer.state == departure_state and customer.lifecycle_state == CustomerAgent.LIFECYCLE_LEAVING, "a leaving party cannot return to ordering or seated service")
	customer._process(0.0)
	var stand_started_at: Dictionary = {}
	var first_departed_at := -1.0
	var observed_individual_despawn := false
	var elapsed := 0.0
	for _tick: int in int(MAX_DEPARTURE_SECONDS / STEP) + 1:
		main.world._process(STEP)
		customer._process(STEP)
		elapsed += STEP
		for index: int in customer.people.size():
			if not stand_started_at.has(index) and customer.people[index].phase != "seated":
				stand_started_at[index] = elapsed
		var departed_count := customer._departed_members.size()
		if departed_count > 0 and departed_count < customer.group_size:
			if first_departed_at < 0.0:
				first_departed_at = elapsed
			var first_index := int(customer._departed_members.keys()[0])
			observed_individual_despawn = customer.people[first_index].is_queued_for_deletion() and not customer.is_queued_for_deletion()
		if customer.is_queued_for_deletion():
			break
	var latest_stand := 999.0
	if stand_started_at.size() == customer.group_size:
		latest_stand = 0.0
		for value: float in stand_started_at.values():
			latest_stand = maxf(latest_stand, value)
	_expect(latest_stand <= 0.75, "the entire party starts standing within one short overlapping launch window")
	_expect(observed_individual_despawn and first_departed_at > 0.0, "a diner is hidden and queued for removal while later party members are still walking")
	_expect(customer._departed_members.size() == customer.group_size and customer.is_queued_for_deletion(), "the controller ends exactly when the last member reaches their gate")
	_expect(customer.lifecycle_state == CustomerAgent.LIFECYCLE_DESPAWN, "the last independent guest advances the controller to canonical despawn")
	_expect(elapsed < MAX_DEPARTURE_SECONDS, "a four-person exit completes inside the bounded parallel-flow budget")
	var recovery_customer := CustomerAgent.new()
	main.world.customer_root.add_child(recovery_customer)
	recovery_customer.setup(main.world, 1)
	var recovery_person := recovery_customer.people[0]
	var recovery_origin := recovery_person.global_position
	var blocked_checkpoint: Vector3 = main.world.cell_to_world(Vector2i(main.world.entrance_cell.x, RestaurantWorld.ROAD_ROWS[0]))
	recovery_customer._force_person_checkpoint(recovery_person, blocked_checkpoint, "recovery_probe")
	_expect(recovery_person.global_position.is_equal_approx(recovery_origin) and recovery_person.phase != "arrived", "route recovery never teleports a guest or reports synthetic arrival")
	SimulationManager.unregister_customer(recovery_customer, false)
	recovery_customer._registered = false
	recovery_customer.queue_free()
	var closing_customer := CustomerAgent.new()
	main.world.customer_root.add_child(closing_customer)
	closing_customer.setup(main.world, 2)
	GameState.set_restaurant_state("closing")
	closing_customer._process(STEP)
	_expect(closing_customer.lifecycle_state == CustomerAgent.LIFECYCLE_LEAVING and closing_customer.people.all(func(person: CustomerPersonAgent): return person.target_tag.begins_with("exit_despawn_")), "closing immediately routes every unseated guest to an individual exterior gate")
	for person: CustomerPersonAgent in closing_customer.people:
		person.global_position = person.destination
		person.phase = "arrived"
	closing_customer._process(STEP)
	_expect(closing_customer.lifecycle_state == CustomerAgent.LIFECYCLE_DESPAWN and closing_customer.is_queued_for_deletion(), "controlled closing completes only after every physical guest reaches its own gate")
	var result := "CUSTOMER EXIT FLOW: %s checks=%d failures=%d elapsed=%.2f first_despawn=%.2f latest_stand=%.2f\n" % [
		"PASS" if failures.is_empty() else "FAIL",
		12,
		failures.size(),
		elapsed,
		first_departed_at,
		latest_stand,
	]
	print(result.strip_edges())
	for failure: String in failures:
		print("FAIL: ", failure)
	var file := FileAccess.open("res://tests/customer-exit-flow-result.txt", FileAccess.WRITE)
	file.store_string(result + ("" if failures.is_empty() else "FAIL: " + "\nFAIL: ".join(failures) + "\n"))
	get_tree().quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
