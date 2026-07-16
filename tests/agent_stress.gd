extends Node

var failures: Array[String] = []


func _ready() -> void:
	SaveManager.writes_enabled = false
	seed(20260716)
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	GameState.reset_to_defaults(false)
	main.world.load_layout()
	main.world.spawn_staff()
	SimulationManager.reset_service_stats()
	SimulationManager.set_speed(4.0)
	SimulationManager.open_restaurant()
	main.world.rush_mode = false
	main.world._spawn_clock = 99999.0
	var groups: Array[CustomerAgent] = []
	for size: int in [4, 2, 3, 1, 2]:
		var customer := CustomerAgent.new()
		main.world.customer_root.add_child(customer)
		customer.global_position = main.world.find_safe_agent_position(main.world.cell_to_world(main.world.entrance_cell), customer)
		customer.setup(main.world, size)
		customer.patience = 180.0
		groups.append(customer)
	var minimum_clearance := INF
	var minimum_pair := ""
	var solid_violations := 0
	var solid_details: Array[String] = []
	var duplicate_reservations := 0
	var duplicate_details: Array[String] = []
	var locomotion_animation_violations := 0
	var locomotion_details: Array[String] = []
	var previous_positions: Dictionary = {}
	var navigation_diagnostics: Dictionary = {}
	var employee_motion_records: Dictionary = {}
	var employee_active_task_ids: Dictionary = {}
	var employee_task_claims: Dictionary = {}
	var maintenance_records: Dictionary = {}
	var final_tick := 0
	var seated_checks := 0
	var seat_alignment_violations := 0
	for tick: int in 1600:
		final_tick = tick
		if tick > 0 and tick % 200 == 0:
			var task_states: Dictionary = {}
			for task: Dictionary in SimulationManager.tasks.values():
				task_states[String(task.get("state", "?"))] = int(task_states.get(String(task.get("state", "?")), 0)) + 1
			print("AGENT STRESS PROGRESS tick=", tick, " served=", int(SimulationManager.stats.customers_served), " active=", SimulationManager.customers.size(), " employees=", main.world.staff_agents.values().map(func(employee: EmployeeAgent): return "%s:%s/%s @%s ->%s path=%d/%d nav=%s fail=%s stuck=%.1f" % [employee.name, employee.state, employee.employee.get("current_task", ""), employee.global_position, employee.destination, employee.path_index, employee.path.size(), employee.navigation_active, employee.navigation_failed, employee.total_stuck_time]), " tasks=", task_states)
		SimulationManager._process(0.1)
		main.world._process(0.1)
		for employee: EmployeeAgent in main.world.staff_agents.values():
			employee._process(0.1)
			var employee_key := employee.get_instance_id()
			var active_task_id := String(employee.active_task.get("id", ""))
			var previous_active_id := String(employee_active_task_ids.get(employee_key, ""))
			var claim_key := ""
			if not active_task_id.is_empty() and active_task_id != previous_active_id:
				claim_key = "%s:%s" % [String(employee.employee.get("id", employee.name)), active_task_id]
				employee_task_claims[claim_key] = int(employee_task_claims.get(claim_key, 0)) + 1
			employee_active_task_ids[employee_key] = active_task_id
			if not active_task_id.is_empty():
				if claim_key.is_empty():
					claim_key = "%s:%s" % [String(employee.employee.get("id", employee.name)), active_task_id]
				var motion_record: Dictionary = employee_motion_records.get(claim_key, {
					"position": employee.global_position,
					"stationary_ticks": 0,
					"maximum_stationary_ticks": 0,
					"employee": employee.name,
					"task_id": active_task_id
				})
				if employee.state == "moving" and Vector3(motion_record.get("position", employee.global_position)).distance_to(employee.global_position) < 0.006:
					motion_record.stationary_ticks = int(motion_record.get("stationary_ticks", 0)) + 1
					motion_record.maximum_stationary_ticks = maxi(int(motion_record.get("maximum_stationary_ticks", 0)), int(motion_record.stationary_ticks))
				else:
					motion_record.stationary_ticks = 0
				motion_record.position = employee.global_position
				employee_motion_records[claim_key] = motion_record
			if employee.total_stuck_time >= 3.0 and not navigation_diagnostics.has(employee.get_instance_id()):
				navigation_diagnostics[employee.get_instance_id()] = _navigation_diagnostic(main.world, employee)
				print("NAV STALL ", navigation_diagnostics[employee.get_instance_id()])
		for customer: CustomerAgent in groups:
			if is_instance_valid(customer) and not customer.is_queued_for_deletion():
				customer._process(0.1)
		for maintenance_task: Dictionary in SimulationManager.maintenance_tasks.values():
			if String(maintenance_task.get("action", "")) != "clean_spill":
				continue
			var maintenance_id := String(maintenance_task.get("id", ""))
			var maintenance_record: Dictionary = maintenance_records.get(maintenance_id, {
				"first_tick": tick,
				"last_state": "",
				"completed": false
			})
			maintenance_record.last_state = String(maintenance_task.get("state", ""))
			if maintenance_record.last_state == "completed":
				maintenance_record.completed = true
			maintenance_records[maintenance_id] = maintenance_record
		var active_agents: Array[AnimatedAgent] = []
		var visible_people: Array[Dictionary] = []
		for agent: AnimatedAgent in main.world.navigation_agents:
			if is_instance_valid(agent) and not agent.is_queued_for_deletion() and agent.is_collision_enabled():
				active_agents.append(agent)
				for point_index: int in agent.get_avoidance_points().size():
					var point := agent.get_avoidance_points()[point_index]
					visible_people.append({"position": point, "radius": agent.agent_radius, "label": "%s#%d" % [agent.name, point_index]})
					# Sitting deliberately uses a chair/table attachment envelope and the
					# short radial sit/stand motion ignores furniture. Navigation through
					# solid furniture remains forbidden in every other phase.
					var seating_transition := agent is CustomerPersonAgent and ((agent as CustomerPersonAgent).seated or (agent as CustomerPersonAgent).is_transitioning() or (agent as CustomerPersonAgent).phase == "standing_ready")
					if not seating_transition and not main.world._agent_point_is_open(point, agent.agent_radius * 0.72):
						solid_violations += 1
						if solid_details.size() < 16:
							solid_details.append("tick %d %s state=%s point=%s cell=%s nav=%s" % [tick, agent.name, agent.get("phase") if agent is CustomerPersonAgent else agent.get("state"), point, main.world.world_to_cell(point), agent.navigation_active])
				var agent_key := agent.get_instance_id()
				if previous_positions.has(agent_key):
					var displacement := Vector3(previous_positions[agent_key]).distance_to(agent.global_position)
					if agent.navigation_active and displacement > 0.04:
						# A diner can finish one leg and receive the next waypoint in the
						# same simulation tick. During its deliberate reaction pause it is
						# stationary on screen even though the sampled positions span the
						# just-completed leg.
						if agent is CustomerPersonAgent and (agent as CustomerPersonAgent).reaction_delay > 0.0:
							previous_positions[agent_key] = agent.global_position
							continue
						if agent.current_animation not in ["Walk", "Walk_Carry"]:
							locomotion_animation_violations += 1
							if locomotion_details.size() < 12:
								locomotion_details.append("tick %d %s moved %.3f with %s" % [tick, agent.name, displacement, agent.current_animation])
						for player: AnimationPlayer in agent.animation_players:
							var expected := agent.resolve_animation(player, agent.current_animation)
							if expected.is_empty() or player.current_animation != expected or not player.is_playing() or player.speed_scale <= 0.05:
								locomotion_animation_violations += 1
								if locomotion_details.size() < 12:
									locomotion_details.append("tick %d %s player=%s expected=%s actual=%s playing=%s speed=%.2f" % [tick, agent.name, player.name, expected, player.current_animation, player.is_playing(), player.speed_scale])
				previous_positions[agent_key] = agent.global_position
		for first_index: int in visible_people.size():
			for second_index: int in range(first_index + 1, visible_people.size()):
				var first: Dictionary = visible_people[first_index]
				var second: Dictionary = visible_people[second_index]
				var first_position := Vector3(first.position)
				var second_position := Vector3(second.position)
				var clearance := Vector2(first_position.x, first_position.z).distance_to(Vector2(second_position.x, second_position.z)) - float(first.radius) - float(second.radius)
				if clearance < minimum_clearance:
					minimum_clearance = clearance
					minimum_pair = "%d:%s@%s <> %s@%s" % [tick, first.label, first_position, second.label, second_position]
		var reservations: Dictionary = {}
		for employee: EmployeeAgent in main.world.staff_agents.values():
			if employee.active_task.is_empty() or employee.state not in ["moving", "working"] or not employee._active_task_is_actionable():
				continue
			var key := ""
			if employee.active_task.has("order_id"):
				var runtime := employee._active_station_runtime()
				key = "station:%s:%d" % [runtime.get("node", null).get_instance_id() if is_instance_valid(runtime.get("node")) else 0, int(employee.active_task.get("interaction_slot", -1))]
			else:
				key = "service:%s" % String(employee.active_task.get("reservation_key", ""))
			if reservations.has(key) and reservations[key] != employee:
				duplicate_reservations += 1
				var detail := "%s: %s <> %s" % [key, (reservations[key] as EmployeeAgent).name, employee.name]
				if not duplicate_details.has(detail):
					duplicate_details.append(detail)
			reservations[key] = employee
		for customer: CustomerAgent in groups:
			if not is_instance_valid(customer) or customer.is_queued_for_deletion() or not customer._seated:
				continue
			var seats: Array = customer.table.get("seat_positions", [])
			for index: int in mini(customer.people.size(), seats.size()):
				var seated_person := customer.people[index]
				if seated_person.phase != "seated":
					continue
				seated_checks += 1
				if seated_person.visual_model.global_position.distance_to(Vector3(seats[index]) + Vector3.UP * AnimatedAgent.CHARACTER_FOOT_LIFT) > 0.06:
					seat_alignment_violations += 1
		if int(SimulationManager.stats.customers_served) >= 6 and SimulationManager.customers.is_empty():
			break
	var stalled_employee_tasks: Array[String] = []
	for task_key: String in employee_motion_records:
		var record: Dictionary = employee_motion_records[task_key]
		# Employee processing is sampled at 0.1 seconds while this stress test runs
		# at 4x speed: 25 consecutive samples represent ten simulated seconds.
		if int(record.get("maximum_stationary_ticks", 0)) >= 25:
			stalled_employee_tasks.append("%s(%d ticks)" % [task_key, int(record.maximum_stationary_ticks)])
	var reclaimed_employee_tasks: Array[String] = []
	for task_key: String in employee_task_claims:
		if int(employee_task_claims[task_key]) > 1:
			reclaimed_employee_tasks.append("%s(x%d)" % [task_key, int(employee_task_claims[task_key])])
	var completed_maintenance := 0
	var overdue_maintenance: Array[String] = []
	for maintenance_id: String in maintenance_records:
		var record: Dictionary = maintenance_records[maintenance_id]
		if bool(record.get("completed", false)):
			completed_maintenance += 1
		elif final_tick - int(record.get("first_tick", final_tick)) >= 125:
			overdue_maintenance.append("%s:%s" % [maintenance_id, String(record.get("last_state", "unknown"))])
	_expect(solid_violations == 0, "nessun personaggio attraversa celle occupate dall'arredamento")
	_expect(duplicate_reservations == 0, "postazioni e punti servizio hanno prenotazioni esclusive")
	_expect(locomotion_animation_violations == 0, "chi si muove usa sempre un'animazione di camminata attiva")
	_expect(navigation_diagnostics.is_empty(), "nessun dipendente accumula tre secondi di debito di navigazione: %s" % [navigation_diagnostics.values()])
	_expect(stalled_employee_tasks.is_empty(), "nessun task dipendente resta immobile per dieci secondi simulati: %s" % [stalled_employee_tasks])
	_expect(reclaimed_employee_tasks.is_empty(), "nessun task dipendente entra in un ciclo annulla/riprendi: %s" % [reclaimed_employee_tasks])
	_expect(completed_maintenance > 0 and overdue_maintenance.is_empty(), "la manutenzione viene completata senza richieste mature bloccate: completate=%d bloccate=%s" % [completed_maintenance, overdue_maintenance])
	_expect(seated_checks > 0, "i clienti raggiungono e usano sedie reali")
	_expect(seat_alignment_violations == 0, "i clienti seduti restano allineati alla propria sedia")
	_expect(minimum_clearance > -0.10, "la separazione fisica impedisce sovrapposizioni profonde tra persone visibili")
	_expect(int(SimulationManager.stats.customers_served) >= 2, "più gruppi completano il servizio sotto carico")
	var appearances: Dictionary = {}
	var tones: Dictionary = {}
	for customer: CustomerAgent in groups:
		if not is_instance_valid(customer):
			continue
		for model: Node3D in customer.group_models:
			appearances[String(model.get_meta("appearance", ""))] = true
			var tone: Color = model.get_meta("skin_tone", Color.WHITE)
			tones[tone.to_html()] = true
	_expect(appearances.size() >= 6 and tones.size() >= 4, "i gruppi usano modelli e tonalità di pelle differenti")
	var result := "AGENT STRESS: %s | served=%d lost=%d min_clearance=%.3f pair=%s seated_checks=%d appearances=%d tones=%d\n" % [
		"PASS" if failures.is_empty() else "FAIL",
		int(SimulationManager.stats.customers_served),
		int(SimulationManager.stats.customers_lost),
		minimum_clearance,
		minimum_pair,
		seated_checks,
		appearances.size(),
		tones.size()
	]
	for failure: String in failures:
		result += "FAIL: %s\n" % failure
	result += "customers=%s employees=%s tasks=%s service=%s\n" % [
		groups.map(func(customer: CustomerAgent): return "%s:%s@%s dest=%s nav=%s fail=%s path=%d/%d stuck=%.2f table=%s" % [customer.name, customer.state, customer.global_position, customer.destination, customer.navigation_active, customer.navigation_failed, customer.path_index, customer.path.size(), customer.total_stuck_time, String(customer.table.get("uid", "-"))] if is_instance_valid(customer) else "freed"),
		main.world.staff_agents.values().map(func(employee: EmployeeAgent): return "%s:%s:%s" % [employee.name, employee.state, employee.employee.get("current_task", "")]),
		SimulationManager.tasks.values().map(func(task: Dictionary): return "%s:%s@%s" % [task.get("id", "?"), task.get("state", "?"), task.get("station", "?")]),
		SimulationManager.service_tasks.values().map(func(task: Dictionary): return "%s:%s:%s" % [task.get("id", "?"), task.get("state", "?"), task.get("action", "?")])
	]
	result += "duplicate_details=%s\n" % [duplicate_details]
	result += "solid_details=%s\n" % [solid_details]
	result += "locomotion_details=%s\n" % [locomotion_details]
	result += "navigation_diagnostics=%s maintenance_completed=%d overdue_maintenance=%s\n" % [navigation_diagnostics.values(), completed_maintenance, overdue_maintenance]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/agent-stress-result.txt", FileAccess.WRITE)
	file.store_string(result)
	SimulationManager.close_immediately()
	get_tree().quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)


func _navigation_diagnostic(world: RestaurantWorld, agent: AnimatedAgent) -> String:
	var next_point := agent.path[agent.path_index] if agent.path_index < agent.path.size() else agent.destination
	var direction := agent.global_position.direction_to(next_point)
	var probe := direction * 0.12
	var nearby: Array[String] = []
	var collision := agent.move_and_collide(probe, true)
	var collider_description := "none"
	if collision != null:
		var collider := collision.get_collider() as Node
		collider_description = "%s:%s normal=%s" % [collider.name if collider != null else "unknown", collider.get_path() if collider != null else "", collision.get_normal()]
		var ancestor := collider
		while ancestor != null and ancestor != world:
			if ancestor is PlacedObject:
				var placed := ancestor as PlacedObject
				collider_description += " item=%s uid=%s cell=%s rot=%d" % [placed.item_id, placed.uid, placed.grid_cell, placed.rotation_steps]
				break
			ancestor = ancestor.get_parent()
	for other: AnimatedAgent in world.navigation_agents:
		if other == agent or not is_instance_valid(other):
			continue
		var distance := Vector2(agent.global_position.x, agent.global_position.z).distance_to(Vector2(other.global_position.x, other.global_position.z))
		if distance <= 4.0:
			nearby.append("%s@%s d=%.2f state=%s nav=%s" % [other.name, other.global_position, distance, other.get("state") if other is EmployeeAgent else other.get("phase"), other.navigation_active])
	return "%s pos=%s cell=%s next=%s next_cell=%s path=%s can_move=%s can_step=%s physics_block=%s collider=%s nearby=%s" % [agent.name, agent.global_position, world.world_to_cell(agent.global_position), next_point, world.world_to_cell(next_point), agent.path, world.can_agent_move(agent.global_position, agent.global_position + probe, agent.agent_radius), world.can_agent_step(agent, agent.global_position, agent.global_position + probe), agent.test_move(agent.global_transform, probe), collider_description, nearby]
