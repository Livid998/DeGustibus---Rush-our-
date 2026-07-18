extends Node

class DummyGroup:
	extends Node
	var group_size := 1

var failures: Array[String] = []
var checks := 0
var storage_visual_events := 0
var statistics_events := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	SimulationManager.close_immediately()
	GameState.reset_to_defaults(false)
	GameState.employees = [{
		"id": "runtime_cook",
		"name": "Cook test",
		"role": "cook",
		"speed": 1.0,
		"precision": 0.8,
		"skills": {"stove": 0.75},
	}]
	GameState.layout = [
		{"uid":"capacity_table", "item":"table_medium", "cell":[4,3], "rotation":0},
		{"uid":"capacity_chair_a", "item":"chair", "cell":[4,3], "rotation":3, "support_uid":"capacity_table", "attachment_slot":1},
		{"uid":"capacity_chair_b", "item":"chair", "cell":[4,3], "rotation":1, "support_uid":"capacity_table", "attachment_slot":3},
		{"uid":"runtime_crate", "item":"storage_crate", "cell":[3,9], "rotation":0},
		{"uid":"runtime_fridge", "item":"fridge", "cell":[6,9], "rotation":0},
		{"uid":"runtime_wall", "item":"wall", "cell":[8,9], "rotation":0},
		{"uid":"runtime_shelf", "item":"storage", "cell":[8,9], "rotation":0, "support_uid":"runtime_wall", "attachment_slot":0},
	]
	GameState.set_restaurant_state("closed")
	SimulationManager.reset_service_stats()

	var world := RestaurantWorld.new()
	add_child(world)
	world.storage_fill_visuals_changed.connect(_on_storage_visuals_changed)
	SimulationManager.statistics_changed.connect(_on_statistics_changed)
	await get_tree().process_frame
	await get_tree().process_frame

	await _test_storage_visuals(world)
	await _test_group_capacity(world)
	_test_staff_performance()

	var result := "RUNTIME SYSTEM GAPS: %s | checks=%d failures=%d" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
	]
	print(result)
	for failure: String in failures:
		print(failure)
	var file := FileAccess.open("res://tests/runtime-system-gaps-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()

	for customer: Node in SimulationManager.customers.duplicate():
		SimulationManager.customers.erase(customer)
		if customer != null and is_instance_valid(customer):
			customer.queue_free()
	world.queue_free()
	SimulationManager.reset_service_stats()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_storage_visuals(world: RestaurantWorld) -> void:
	_expect(world.storage_fill_visualizer != null, "storage fill is delegated to its dedicated runtime visualizer")
	for ingredient_id: String in GameState.stock:
		GameState.stock[ingredient_id].amount = 0
	GameState.stock_changed.emit("tomato", 0)
	var empty := world.storage_fill_snapshot()
	_expect(
		int((empty.get("ambient", {}) as Dictionary).get("crate_count", -1)) == 0,
		"zero ambient usage produces no aggregate stock crate"
	)
	_expect(
		int((empty.get("refrigerated", {}) as Dictionary).get("indicator_count", 0)) == 1,
		"refrigerated capacity has one visually distinct indicator"
	)
	var cold_label := world.storage_fill_visualizer.find_child("ColdFillLabel", true, false) as Label3D
	_expect(
		cold_label != null and cold_label.text.begins_with("FREDDO "),
		"the cold provider uses a textual/cyan FREDDO badge rather than ambient crates"
	)

	GameState.stock.tomato.amount = 1
	GameState.stock_changed.emit("tomato", 1)
	var low := world.storage_fill_snapshot()
	_expect(
		int((low.get("ambient", {}) as Dictionary).get("crate_count", 0)) == 1
			and world.storage_fill_visualizer.find_child("AmbientStockCrate_00", false, false) != null,
		"low ambient fill creates exactly one physical aggregate crate"
	)
	_expect(
		String((low.get("ambient", {}) as Dictionary).get("display_provider_uid", "")) == "runtime_crate"
			and String((low.get("ambient", {}) as Dictionary).get("display_mode", "")) == "floor_stack",
		"a floor storage_crate is the visible ambient anchor even when a wall shelf also exists"
	)

	var ambient_capacity := StorageManager.capacity_for("ambient")
	GameState.stock.tomato.amount = ambient_capacity
	GameState.stock_changed.emit("tomato", ambient_capacity)
	var full := world.storage_fill_snapshot()
	_expect(
		int((full.get("ambient", {}) as Dictionary).get("crate_count", 0)) == 4,
		"full ambient storage is represented by the bounded four-crate maximum"
	)
	_expect(
		world.storage_fill_visualizer.get_children().filter(
			func(child: Node): return child.name.begins_with("AmbientStockCrate_")
		).size() == 4,
		"the physical node count matches the aggregate storage snapshot"
	)
	var floor_provider := world.placed_objects.get("runtime_crate") as PlacedObject
	var floor_provider_bounds := ModelFactory.calculate_visual_bounds(
		floor_provider.visual_model,
		true
	)
	var floor_provider_top := floor_provider.global_position.y + floor_provider_bounds.end.y
	var floor_nodes: Array[Node] = world.storage_fill_visualizer.find_children(
		"AmbientStockCrate_*",
		"Node3D",
		false,
		false
	)
	var floor_geometry_valid := floor_nodes.size() == 4
	var highest_floor_crate_y := -INF
	for node: Node in floor_nodes:
		var crate_node := node as Node3D
		highest_floor_crate_y = maxf(highest_floor_crate_y, crate_node.global_position.y)
		var horizontal_distance := Vector2(
			crate_node.global_position.x,
			crate_node.global_position.z
		).distance_to(Vector2(
			floor_provider.global_position.x,
			floor_provider.global_position.z
		))
		floor_geometry_valid = (
			floor_geometry_valid
			and crate_node.is_visible_in_tree()
			and String(crate_node.get_meta("storage_provider_uid", "")) == "runtime_crate"
			and String(crate_node.get_meta("storage_display_mode", "")) == "floor_stack"
			and crate_node.global_position.y > floor_provider_top + 0.02
			and horizontal_distance < 0.75
		)
	for first_index: int in floor_nodes.size():
		for second_index: int in range(first_index + 1, floor_nodes.size()):
			floor_geometry_valid = (
				floor_geometry_valid
				and (floor_nodes[first_index] as Node3D).global_position.distance_to(
					(floor_nodes[second_index] as Node3D).global_position
				) > 0.3
			)
	var ambient_label := world.storage_fill_visualizer.find_child(
		"AmbientFillLabel",
		false,
		false
	) as Label3D
	_expect(
		floor_geometry_valid
			and highest_floor_crate_y > floor_provider_top + 0.35
			and ambient_label != null
			and ambient_label.is_visible_in_tree()
			and ambient_label.global_position.y > floor_provider_top + 0.5,
		"all four aggregate crates are separated, visible and clear of the floor provider surface"
	)
	var refresh_before_idle := int(full.get("refresh_count", 0))
	var events_before_idle := storage_visual_events
	for _frame: int in 4:
		await get_tree().process_frame
	var after_idle := world.storage_fill_snapshot()
	_expect(
		int(after_idle.get("refresh_count", -1)) == refresh_before_idle
			and storage_visual_events == events_before_idle,
		"storage visuals do not poll or rebuild on idle frames"
	)
	GameState.stock.tomato.amount = ambient_capacity - 1
	GameState.stock_changed.emit("tomato", ambient_capacity - 1)
	_expect(
		int(world.storage_fill_snapshot().get("refresh_count", 0)) > refresh_before_idle
			and storage_visual_events > events_before_idle,
		"a stock signal updates the world representation event-by-event"
	)
	var aggregate_before_reload := (
		world.storage_fill_visualizer.find_child("AmbientStockCrate_00", false, false) as Node3D
	)
	var aggregate_position_before := aggregate_before_reload.global_position
	var refresh_before_reload := int(world.storage_fill_snapshot().get("refresh_count", 0))
	for record: Dictionary in GameState.layout:
		if String(record.get("uid", "")) == "runtime_crate":
			record["cell"] = [4, 9]
			break
	world.load_layout()
	var aggregate_after_reload := (
		world.storage_fill_visualizer.find_child("AmbientStockCrate_00", false, false) as Node3D
	)
	_expect(
		int(world.storage_fill_snapshot().get("refresh_count", 0)) > refresh_before_reload
			and aggregate_after_reload != null
			and not aggregate_after_reload.global_position.is_equal_approx(aggregate_position_before),
		"a direct layout reload immediately reattaches aggregate stock visuals to rebuilt providers"
	)
	GameState.layout = GameState.layout.filter(
		func(record: Dictionary): return String(record.get("uid", "")) != "runtime_crate"
	)
	world.load_layout()
	StorageManager.recalculate_layout_capacity()
	var wall_snapshot := world.storage_fill_snapshot()
	var wall_nodes: Array[Node] = world.storage_fill_visualizer.find_children(
		"AmbientStockCrate_*",
		"Node3D",
		false,
		false
	)
	var wall_provider := world.placed_objects.get("runtime_shelf") as PlacedObject
	var wall_provider_bounds := ModelFactory.calculate_visual_bounds(
		wall_provider.visual_model,
		true
	)
	var wall_provider_top := wall_provider.global_position.y + wall_provider_bounds.end.y
	var wall_geometry_valid := not wall_nodes.is_empty()
	for node: Node in wall_nodes:
		var segment := node as Node3D
		wall_geometry_valid = (
			wall_geometry_valid
			and segment.is_visible_in_tree()
			and String(segment.get_meta("storage_provider_uid", "")) == "runtime_shelf"
			and String(segment.get_meta("storage_display_mode", "")) == "wall_compact"
			and segment.global_position.y > wall_provider_top + 0.02
			and segment.global_position.distance_to(wall_provider.global_position) < 2.0
		)
	for first_index: int in wall_nodes.size():
		for second_index: int in range(first_index + 1, wall_nodes.size()):
			wall_geometry_valid = (
				wall_geometry_valid
				and (wall_nodes[first_index] as Node3D).global_position.distance_to(
					(wall_nodes[second_index] as Node3D).global_position
				) > 0.3
			)
	_expect(
		String((wall_snapshot.get("ambient", {}) as Dictionary).get("display_provider_uid", "")) == "runtime_shelf"
			and String((wall_snapshot.get("ambient", {}) as Dictionary).get("display_mode", "")) == "wall_compact"
			and wall_geometry_valid,
		"wall-only ambient storage uses separated compact indicators above and in front of its shelf"
	)


func _test_group_capacity(world: RestaurantWorld) -> void:
	var empty_snapshot := world.customer_capacity_snapshot(2)
	var queue_buffer := int(DataRegistry.balance_value("traffic.queue_buffer_groups", 0))
	var absolute_cap := int(DataRegistry.balance_value("traffic.absolute_group_cap", 1))
	_expect(
		int(empty_snapshot.get("table_count", 0)) == 1
			and int(empty_snapshot.get("seat_count", 0)) == 2
			and world.customer_group_cap() == mini(1 + queue_buffer, absolute_cap),
		"group cap counts one physical table as one group slot, never two seats as two groups"
	)
	_expect(
		world.can_accept_customer_group(1)
			and world.can_accept_customer_group(2)
			and not world.can_accept_customer_group(3),
		"party size must fit at least one physically chaired table"
	)
	_expect(
		CustomerCapacityPlanner.spawnable_group_size(world, 0.999) <= 2,
		"weighted spawning filters out party sizes the room cannot ever seat"
	)

	var owner := DummyGroup.new()
	owner.group_size = 2
	add_child(owner)
	SimulationManager.customers.append(owner)
	world.table_occupants["capacity_table"] = owner
	var queued := DummyGroup.new()
	queued.group_size = 2
	add_child(queued)
	SimulationManager.customers.append(queued)
	world.customer_queue.append(queued)
	var buffered := world.customer_capacity_snapshot(2)
	_expect(
		int(buffered.get("occupied_groups", 0)) == 1
			and int(buffered.get("queued_groups", 0)) == 1
			and bool(buffered.get("accepts_proposed", false)),
		"fixed occupation and the existing queue are both matched before admitting a buffered party"
	)

	var queued_second := DummyGroup.new()
	queued_second.group_size = 1
	add_child(queued_second)
	SimulationManager.customers.append(queued_second)
	world.customer_queue.append(queued_second)
	var saturated := world.customer_capacity_snapshot(1)
	_expect(
		not bool(saturated.get("accepts_proposed", true))
			and int(saturated.get("active_groups", 0)) == 3,
		"physical table slots plus queue buffer cap further spawns even below the absolute cap"
	)
	for group: DummyGroup in [owner, queued, queued_second]:
		SimulationManager.customers.erase(group)
		world.customer_queue.erase(group)
		group.queue_free()
	world.table_occupants["capacity_table"] = null
	await get_tree().process_frame


func _test_staff_performance() -> void:
	SimulationManager.reset_service_stats()
	var employee_id := "runtime_cook"
	SimulationManager._record_employee_task_completed(
		employee_id,
		"kitchen",
		"stove",
		{"id": "task_runtime", "station": "stove"}
	)
	SimulationManager._record_employee_quality_sample(
		employee_id,
		{"quality_score": 82, "quality_events": []},
		{"id": "quality_a", "station": "stove"},
		{"id": "order_a"}
	)
	SimulationManager._record_employee_quality_sample(
		employee_id,
		{"quality_score": 68, "quality_events": []},
		{"id": "quality_b", "station": "stove"},
		{"id": "order_b"}
	)
	var event_result := {
		"defect": "burned",
		"defect_severity": "severe",
		"quality_events": [{
			"id": "burned",
			"severity": "severe",
			"quality_penalty": 30.0,
			"employee_id": employee_id,
		}],
	}
	SimulationManager._record_employee_quality_events(
		employee_id,
		event_result,
		{"id": "quality_b", "station": "stove"},
		{"id": "order_b"}
	)
	var performance := SimulationManager.employee_performance_snapshot(employee_id)
	_expect(
		int(performance.get("tasks_completed", 0)) == 1
			and int((performance.get("tasks_by_kind", {}) as Dictionary).get("kitchen", 0)) == 1
			and int(SimulationManager.stats.employee_tasks.get(employee_id, 0)) == 1,
		"detailed task stats extend the existing per-employee task counter"
	)
	_expect(
		int(performance.get("quality_sample_count", 0)) == 2
			and is_equal_approx(float(performance.get("quality_average", 0.0)), 75.0),
		"individual average quality is derived deterministically from attributed task samples"
	)
	_expect(
		int(performance.get("defects_attributed", 0)) == 1
			and int((performance.get("defects_by_id", {}) as Dictionary).get("burned", 0)) == 1
			and int(performance.get("quality_event_count", 0)) == 1
			and (performance.get("recent_quality_events", []) as Array).size() == 1,
		"defects and their concrete quality events remain attributed to the responsible employee"
	)
	_expect(
		String(performance.get("scope", "")) == "current_service"
			and (SimulationManager.summary().get("employee_performance", {}) as Dictionary).has(employee_id),
		"the public operational summary exposes an explicit current-service scope"
	)
	var employee_value := OperationalStatisticsScreen.employee_performance_text(
		1,
		performance,
		0.0
	)
	_expect(
		"qualità 75%" in employee_value
			and "1 difetti" in employee_value
			and "1 eventi" in employee_value,
		"the event-driven operational screen renders individual quality, defects and events"
	)
	var serialized := GameState.serialize()
	_expect(
		not serialized.has("employee_performance")
			and not (serialized.get("employees", []) as Array)[0].has("employee_performance"),
		"service statistics do not mutate the save schema or legacy employee records"
	)
	var event_count_before_reset := statistics_events
	SimulationManager.reset_service_stats()
	var reset := SimulationManager.employee_performance_snapshot(employee_id)
	_expect(
		int(reset.get("tasks_completed", -1)) == 0
			and int(reset.get("quality_sample_count", -1)) == 0
			and int(reset.get("defects_attributed", -1)) == 0
			and statistics_events > event_count_before_reset,
		"opening/resetting a service clears detailed staff statistics and emits one data update"
	)


func _on_storage_visuals_changed(_snapshot: Dictionary) -> void:
	storage_visual_events += 1


func _on_statistics_changed() -> void:
	statistics_events += 1


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
