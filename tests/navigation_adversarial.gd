extends Node

var failures: Array[String] = []
var checks := 0
var metrics: Dictionary = {}


func _ready() -> void:
	SaveManager.writes_enabled = false
	seed(20260716)
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	GameState.reset_to_defaults(false)
	main.world.load_layout()
	_stop_existing_agents(main.world)
	_test_opposing_corridor_traffic(main.world)
	main.world.load_layout()
	_test_crossing_traffic(main.world)
	_test_station_contention(main.world)
	var result := "NAVIGATION ADVERSARIAL: %s | %d checks | %s\n" % ["PASS" if failures.is_empty() else "FAIL", checks, metrics]
	for failure: String in failures:
		result += "FAIL: %s\n" % failure
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/navigation-adversarial-result.txt", FileAccess.WRITE)
	file.store_string(result)
	SimulationManager.reset_service_stats()
	get_tree().quit(0 if failures.is_empty() else 1)


func _stop_existing_agents(world: RestaurantWorld) -> void:
	for agent: AnimatedAgent in world.navigation_agents.duplicate():
		if is_instance_valid(agent):
			agent.shutdown_navigation()
	world.navigation_agents.clear()
	world.agent_motion_intents.clear()
	world.corridor_reservations.clear()
	world.agent_corridor_reservations.clear()


func _configure_arena(world: RestaurantWorld, open_cells: Array[Vector2i]) -> void:
	world.astar.fill_solid_region(world.astar.region, true)
	for cell: Vector2i in open_cells:
		world.astar.set_point_solid(cell, false)
	world._blocked_edge_uids.clear()
	world._temporary_blocked_edge_keys.clear()
	world._grid_path_cache.clear()
	world._corridor_key_cache.clear()
	world.corridor_reservations.clear()
	world.agent_corridor_reservations.clear()
	world.agent_motion_intents.clear()
	world.navigation_revision += 1


func _make_agent(world: RestaurantWorld, cell: Vector2i, priority: int = 3) -> AnimatedAgent:
	var agent := AnimatedAgent.new()
	world.add_child(agent)
	agent.world = world
	agent.global_position = world.cell_to_world(cell)
	agent.movement_speed = 2.45
	agent.movement_acceleration = 14.0
	agent.arrival_tolerance = 0.12
	agent.configure_navigation(0.36, priority)
	# The synthetic arena is represented by the navigation grid only. Dynamic
	# person clearance remains fully enforced by RestaurantWorld.can_agent_step.
	agent.collision_mask = 0
	return agent


func _test_opposing_corridor_traffic(world: RestaurantWorld) -> void:
	var open_cells: Array[Vector2i] = []
	for y: int in range(4, 7):
		for x: int in range(0, 3):
			open_cells.append(Vector2i(x, y))
		for x: int in range(8, 11):
			open_cells.append(Vector2i(x, y))
	for x: int in range(3, 8):
		open_cells.append(Vector2i(x, 5))
	_configure_arena(world, open_cells)
	var first := _make_agent(world, Vector2i(1, 5))
	var second := _make_agent(world, Vector2i(9, 5))
	var first_started := first.move_to(world.cell_to_world(Vector2i(9, 5)))
	var second_started := second.move_to(world.cell_to_world(Vector2i(1, 5)))
	_expect(first_started and second_started, "entrambi gli agenti trovano il passaggio a cella singola")
	var first_arrived := false
	var second_arrived := false
	var minimum_clearance := INF
	var elapsed := 0.0
	for tick: int in 600:
		world._traffic_epoch += 1
		# Alternate update order: right of way must not depend on scene order.
		if tick % 2 == 0:
			if not first_arrived:
				first_arrived = first.advance_path(0.04)
			if not second_arrived:
				second_arrived = second.advance_path(0.04)
		else:
			if not second_arrived:
				second_arrived = second.advance_path(0.04)
			if not first_arrived:
				first_arrived = first.advance_path(0.04)
		var distance := Vector2(first.global_position.x, first.global_position.z).distance_to(Vector2(second.global_position.x, second.global_position.z))
		minimum_clearance = minf(minimum_clearance, distance - first.agent_radius - second.agent_radius)
		elapsed += 0.04
		if first_arrived and second_arrived:
			break
	_expect(first_arrived and second_arrived and elapsed <= 24.0, "due agenti opposti liberano il corridoio entro il tempo massimo")
	_expect(not first.navigation_failed and not second.navigation_failed, "l'attesa per diritto di precedenza non diventa un fallimento di percorso")
	_expect(minimum_clearance >= -0.04, "nel passaggio stretto non avvengono sovrapposizioni profonde")
	_expect(second.recovery_count >= 1, "chi cede la precedenza usa una piazzola laterale invece di bloccare l'uscita")
	world.finish_agent_navigation(first)
	world.finish_agent_navigation(second)
	_expect(world.corridor_reservations.is_empty() and world.agent_corridor_reservations.is_empty(), "le prenotazioni del corridoio vengono rilasciate a percorso concluso")
	metrics.corridor_seconds = elapsed
	metrics.corridor_min_clearance = minimum_clearance
	metrics.corridor_recoveries = first.recovery_count + second.recovery_count
	first.shutdown_navigation()
	second.shutdown_navigation()
	first.queue_free()
	second.queue_free()


func _test_crossing_traffic(world: RestaurantWorld) -> void:
	_stop_existing_agents(world)
	var open_cells: Array[Vector2i] = []
	for y: int in range(3, 10):
		for x: int in range(3, 10):
			open_cells.append(Vector2i(x, y))
	_configure_arena(world, open_cells)
	var eastbound := _make_agent(world, Vector2i(4, 6), 3)
	var westbound := _make_agent(world, Vector2i(8, 6), 3)
	var southbound := _make_agent(world, Vector2i(6, 4), 3)
	var agents: Array[AnimatedAgent] = [eastbound, westbound, southbound]
	eastbound.move_to(world.cell_to_world(Vector2i(8, 6)))
	westbound.move_to(world.cell_to_world(Vector2i(4, 6)))
	southbound.move_to(world.cell_to_world(Vector2i(6, 8)))
	var arrived: Dictionary = {}
	var minimum_clearance := INF
	for tick: int in 500:
		world._traffic_epoch += 1
		var order: Array[AnimatedAgent] = agents.duplicate()
		if tick % 2 == 1:
			order.reverse()
		for agent: AnimatedAgent in order:
			if not arrived.has(agent.get_instance_id()):
				if agent.advance_path(0.04):
					arrived[agent.get_instance_id()] = true
		for first_index: int in agents.size():
			for second_index: int in range(first_index + 1, agents.size()):
				var first := agents[first_index]
				var second := agents[second_index]
				var distance := Vector2(first.global_position.x, first.global_position.z).distance_to(Vector2(second.global_position.x, second.global_position.z))
				minimum_clearance = minf(minimum_clearance, distance - first.agent_radius - second.agent_radius)
		if arrived.size() == agents.size():
			break
	_expect(arrived.size() == agents.size(), "tre traiettorie incrociate terminano senza stallo")
	_expect(minimum_clearance >= -0.04, "l'incrocio predittivo conserva lo spazio personale")
	_expect(agents.all(func(agent: AnimatedAgent): return not agent.navigation_failed), "nessun agente fallisce durante una precedenza all'incrocio")
	metrics.crossing_min_clearance = minimum_clearance
	for agent: AnimatedAgent in agents:
		agent.shutdown_navigation()
		agent.queue_free()


func _test_station_contention(world: RestaurantWorld) -> void:
	SimulationManager.reset_service_stats()
	var selected_station := ""
	for station_id: String in SimulationManager.stations:
		if not (SimulationManager.stations.get(station_id, []) as Array).is_empty():
			selected_station = station_id
			break
	_expect(not selected_station.is_empty(), "il layout espone almeno una postazione di lavoro")
	if selected_station.is_empty():
		return
	var runtime_count := (SimulationManager.stations.get(selected_station, []) as Array).size()
	for index: int in runtime_count + 2:
		var task_id := "ADV_%02d" % index
		SimulationManager.tasks[task_id] = {
			"id": task_id, "order_id": "", "station": selected_station,
			"state": "queued", "priority": 1, "wait_age": float(index),
			"employee_id": "", "dependencies": [], "inputs": {}
		}
	var claimed: Array[Dictionary] = []
	for index: int in runtime_count + 2:
		var employee := {"id": "adv_worker_%02d" % index, "role": "cook", "skills": {selected_station: 0.75}}
		var task := SimulationManager.claim_kitchen_task(employee)
		if not task.is_empty():
			claimed.append(task)
	var reservation_keys: Dictionary = {}
	var duplicate := false
	for task: Dictionary in claimed:
		var runtime: Dictionary = task.get("station_runtime", {})
		var node := runtime.get("node") as Node
		var key := "%d:%d" % [node.get_instance_id() if is_instance_valid(node) else 0, int(task.get("interaction_slot", -1))]
		if reservation_keys.has(key):
			duplicate = true
		reservation_keys[key] = true
	_expect(not duplicate, "una postazione contesa assegna ogni slot a un solo dipendente")
	_expect(claimed.size() <= runtime_count, "i dipendenti in eccesso restano in coda invece di insistere su postazioni occupate")
	metrics.station_claims = claimed.size()
	metrics.station_slots = runtime_count
	for task: Dictionary in claimed:
		SimulationManager.cancel_employee_task(String(task.get("employee_id", "")))
	SimulationManager.reset_service_stats()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition and not failures.has(message):
		failures.append(message)
