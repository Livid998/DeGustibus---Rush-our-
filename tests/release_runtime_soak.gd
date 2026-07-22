extends Node

## Short, deterministic headless regression soak. The numbers produced here
## are CI evidence only: they never claim to satisfy the physical iPad gate.

const SERVICE_STRESS_FIXTURE := preload("res://tests/fixtures/service_stress_fixture.gd")
const WARMUP_FRAMES := 900
const SOAK_FRAMES := 720
const MAX_HEADLESS_P95_MS := 100.0
const MAX_MEMORY_GROWTH_RATIO := 0.10
const PERMANENT_STALL_SECONDS := 8.25

var checks := 0
var failures: Array[String] = []
var ghost_observations := 0
var max_stall_seconds := 0.0
var _positions: Dictionary = {}
var _stalled_seconds: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	var original_state := GameState.serialize().duplicate(true)
	var original_speed := SimulationManager.simulation_speed
	var original_max_fps := Engine.max_fps
	Engine.max_fps = 60
	GameState.reset_to_defaults(false)
	SERVICE_STRESS_FIXTURE.apply()
	SimulationManager.close_immediately()
	SimulationManager.reset_service_stats()
	RuntimeDiagnostics.reset()

	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	main.world.load_layout()
	main.world.spawn_staff()
	await get_tree().process_frame
	SimulationManager.set_speed(4.0)
	_expect(SimulationManager.open_restaurant(), "stress fixture supera la checklist di apertura")
	main.world.set_rush_mode(false)
	main.world._spawn_clock = 99999.0
	for group_size: int in [4, 3, 2, 4]:
		var customer := CustomerAgent.new()
		main.world.customer_root.add_child(customer)
		customer.global_position = main.world.find_safe_agent_position(
			main.world.cell_to_world(main.world.entrance_cell), customer
		)
		customer.setup(main.world, group_size)
		customer.patience = 180.0

	for _frame: int in WARMUP_FRAMES:
		await get_tree().process_frame
	RuntimeDiagnostics.reset()
	var baseline_memory := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	_expect(baseline_memory > 0, "baseline memoria headless disponibile dopo warm-up")

	for frame_index: int in SOAK_FRAMES:
		await get_tree().process_frame
		_track_navigation_progress(main.world, get_process_delta_time())
		if frame_index % 60 == 0:
			ghost_observations += _ghost_lease_count(main.world)

	SimulationManager._audit_staff_leases()
	ghost_observations += _ghost_lease_count(main.world)
	var ending_memory := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var memory_growth_ratio := 0.0
	if baseline_memory > 0:
		memory_growth_ratio = maxf(float(ending_memory - baseline_memory) / float(baseline_memory), 0.0)
	var diagnostics := RuntimeDiagnostics.snapshot()
	var p95_ms := float((diagnostics.get("frame_window", {}) as Dictionary).get("p95_ms", 0.0))
	var frame_samples := int((diagnostics.get("frame_window", {}) as Dictionary).get("sample_count", 0))

	_expect(frame_samples >= SOAK_FRAMES - 5, "diagnostica registra l'intera finestra frame del soak")
	_expect(p95_ms > 0.0 and p95_ms <= MAX_HEADLESS_P95_MS, "p95 headless resta sotto il limite regressivo di %.0f ms (misurato %.3f)" % [MAX_HEADLESS_P95_MS, p95_ms])
	_expect(memory_growth_ratio < MAX_MEMORY_GROWTH_RATIO, "memoria dopo warm-up cresce meno del 10%% (%.2f%%)" % (memory_growth_ratio * 100.0))
	_expect(ghost_observations == 0, "nessun task o lease fantasma durante il soak")
	_expect(max_stall_seconds < PERMANENT_STALL_SECONDS, "nessun agente navigante resta fermo permanentemente (max %.2fs)" % max_stall_seconds)

	SimulationManager.close_immediately()
	SimulationManager.reset_service_stats()
	main.world.load_layout()
	await get_tree().process_frame
	_expect(int(SimulationManager.staff_lease_snapshot().get("active", -1)) == 0, "teardown rilascia tutte le lease staff")
	_expect(main.world.runtime_leases.active_count() == 0, "teardown rilascia tutte le lease di traffico")
	_expect(SimulationManager.tasks.is_empty() and SimulationManager.service_tasks.is_empty() and SimulationManager.maintenance_tasks.is_empty(), "teardown non lascia task fantasma")

	var evidence := {
		"status": "pass" if failures.is_empty() else "fail",
		"headless_regression_only": true,
		"hardware_ipad_gate_passed": false,
		"warmup_frames": WARMUP_FRAMES,
		"soak_frames": SOAK_FRAMES,
		"frame_p95_ms": p95_ms,
		"frame_samples": frame_samples,
		"baseline_memory_bytes": baseline_memory,
		"ending_memory_bytes": ending_memory,
		"memory_growth_ratio": memory_growth_ratio,
		"ghost_observations": ghost_observations,
		"maximum_navigation_stall_seconds": max_stall_seconds,
		"diagnostics": diagnostics,
	}
	var result := "RELEASE RUNTIME SOAK: %s | p95=%.3fms memory_growth=%.2f%% ghosts=%d max_stall=%.2fs checks=%d failures=%d" % [
		"PASS" if failures.is_empty() else "FAIL",
		p95_ms,
		memory_growth_ratio * 100.0,
		ghost_observations,
		max_stall_seconds,
		checks,
		failures.size(),
	]
	print(result)
	print("RELEASE_RUNTIME_EVIDENCE=%s" % JSON.stringify(evidence))
	for failure: String in failures:
		print(failure)
	var file := FileAccess.open("user://release-runtime-soak.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(evidence, "  "))
		file.close()
	var evidence_directory := OS.get_environment("DEGUSTIBUS_RELEASE_EVIDENCE_DIR")
	if not evidence_directory.is_empty():
		DirAccess.make_dir_recursive_absolute(evidence_directory)
		var evidence_file := FileAccess.open(evidence_directory.path_join("release-runtime-soak.json"), FileAccess.WRITE)
		if evidence_file != null:
			evidence_file.store_string(JSON.stringify(evidence, "  "))
			evidence_file.close()

	main.queue_free()
	GameState.deserialize(original_state)
	SimulationManager.set_speed(original_speed)
	Engine.max_fps = original_max_fps
	get_tree().quit(0 if failures.is_empty() else 1)


func _track_navigation_progress(world: RestaurantWorld, delta: float) -> void:
	for agent: AnimatedAgent in world.navigation_agents:
		if not is_instance_valid(agent) or agent.is_queued_for_deletion():
			continue
		var key := agent.get_instance_id()
		var previous: Vector3 = _positions.get(key, agent.global_position)
		if agent.navigation_active and previous.distance_to(agent.global_position) < 0.005:
			_stalled_seconds[key] = float(_stalled_seconds.get(key, 0.0)) + delta
			max_stall_seconds = maxf(max_stall_seconds, float(_stalled_seconds[key]))
		else:
			_stalled_seconds[key] = 0.0
		_positions[key] = agent.global_position


func _ghost_lease_count(world: RestaurantWorld) -> int:
	SimulationManager._audit_staff_leases()
	var ghosts := 0
	var boards := {
		"kitchen": SimulationManager.tasks,
		"service": SimulationManager.service_tasks,
		"maintenance": SimulationManager.maintenance_tasks,
	}
	for kind: String in boards:
		var board: Dictionary = boards[kind]
		for task_value: Variant in board.values():
			var task: Dictionary = task_value
			var active := String(task.get("state", "")) in ["reserved", "in_progress"]
			if not active and not (task.get("runtime_lease_ids", []) as Array).is_empty():
				ghosts += 1
	for record_value: Variant in SimulationManager.staff_leases.records_snapshot().values():
		var metadata: Dictionary = (record_value as Dictionary).get("metadata", {})
		var kind := String(metadata.get("task_kind", ""))
		var task_id := String(metadata.get("task_id", ""))
		if kind.is_empty() or task_id.is_empty():
			continue
		var board: Dictionary = boards.get(kind, {})
		var task: Dictionary = board.get(task_id, {})
		if task.is_empty() or String(task.get("state", "")) not in ["reserved", "in_progress"]:
			ghosts += 1
	for record_value: Variant in world.runtime_leases.records_snapshot().values():
		var owner: Variant = (record_value as Dictionary).get("owner")
		if owner is Object and not is_instance_valid(owner):
			ghosts += 1
	return ghosts


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
