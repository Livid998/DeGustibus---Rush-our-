extends Node

class MaintenanceOwner:
	extends Node3D
	var actionable := true
	var started := 0
	var completed := 0

	func accepts_maintenance_action(_action: String, _payload: Dictionary) -> bool:
		return actionable

	func maintenance_started(_action: String, _payload: Dictionary, _employee_id: String) -> void:
		started += 1

	func maintenance_completed(_action: String, _payload: Dictionary) -> void:
		completed += 1


var failures: Array[String] = []
var checks := 0


func _ready() -> void:
	SaveManager.writes_enabled = false
	var previous_world: Node = SimulationManager.world
	var previous_stations: Dictionary = SimulationManager.stations
	SimulationManager.bind_world(null)
	SimulationManager.stations = {}
	SimulationManager.reset_service_stats()

	var owner := MaintenanceOwner.new()
	add_child(owner)
	var task := SimulationManager.request_maintenance_task(owner, "clean_spill", Vector3(2, 0, 2), {"reservation_key":"spill:test"}, 3, 0.25)
	var duplicate := SimulationManager.request_maintenance_task(owner, "clean_spill", Vector3(2, 0, 2), {"reservation_key":"spill:test"}, 3, 0.25)
	_expect(not task.is_empty() and String(task.id) == String(duplicate.id), "maintenance requests are idempotent per reservation key")
	_expect(SimulationManager.claim_maintenance_task({"id":"cook", "role":"cook"}).is_empty() and SimulationManager.claim_maintenance_task({"id":"waiter", "role":"waiter"}).is_empty(), "only handymen can claim maintenance")
	var claimed := SimulationManager.claim_maintenance_task({"id":"handyman", "role":"handyman"})
	_expect(String(claimed.get("id", "")) == String(task.id) and SimulationManager.begin_maintenance_task(String(task.id)), "a handyman atomically reserves and begins generic owner work")
	_expect(SimulationManager.complete_maintenance_task(String(task.id)) and owner.started == 1 and owner.completed == 1, "generic owner receives exactly one start and completion callback")

	var sink := Node3D.new()
	add_child(sink)
	sink.global_position = Vector3.ZERO
	SimulationManager.register_station("sink", sink, 1)
	SimulationManager.tasks["kitchen_guard"] = {"id":"kitchen_guard", "order_id":"", "state":"queued", "station":"sink", "priority":1, "wait_age":0.0}
	_expect(SimulationManager.claim_kitchen_task({"id":"handyman_guard", "role":"handyman", "skills":{"sink":1.0}}).is_empty(), "a handyman never steals queued kitchen work")
	SimulationManager.tasks.erase("kitchen_guard")
	var owner_a := MaintenanceOwner.new()
	var owner_b := MaintenanceOwner.new()
	add_child(owner_a)
	add_child(owner_b)
	var wash_a := SimulationManager.request_maintenance_task(owner_a, "wash_dishes", Vector3.ZERO, {"station_id":"sink", "reservation_key":"wash:a"})
	var wash_b := SimulationManager.request_maintenance_task(owner_b, "wash_dishes", Vector3.ZERO, {"station_id":"sink", "reservation_key":"wash:b"})
	var first_wash := SimulationManager.claim_maintenance_task({"id":"handyman_a", "role":"handyman"})
	var blocked_wash := SimulationManager.claim_maintenance_task({"id":"handyman_b", "role":"handyman"})
	_expect(String(first_wash.get("id", "")) in [String(wash_a.id), String(wash_b.id)] and blocked_wash.is_empty(), "a physical sink admits one handyman at a time")
	SimulationManager.cancel_employee_task("handyman_a")
	var replacement := SimulationManager.claim_maintenance_task({"id":"handyman_b", "role":"handyman"})
	_expect(not replacement.is_empty() and SimulationManager.maintenance_task_reservation_is_valid(String(replacement.id), "handyman_b"), "an interrupted maintenance route releases its station reservation")

	SimulationManager.reset_service_stats()
	_expect(SimulationManager.maintenance_tasks.is_empty(), "service reset clears transient maintenance work")
	SimulationManager.stations = previous_stations
	SimulationManager.bind_world(previous_world)
	_test_handyman_navigation_completion()
	var result := "MAINTENANCE SMOKE: %s | checks=%d failures=%d\n%s" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size(), "\n".join(failures)]
	print(result)
	var file := FileAccess.open("res://tests/maintenance-smoke-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_handyman_navigation_completion() -> void:
	_expect(bool(DataRegistry.build_by_id.get("plant", {}).get("blocking", false)) and bool(DataRegistry.build_by_id.get("decoration", {}).get("blocking", false)), "solid decorative props are marked blocking in the navigation catalogue")
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	GameState.reset_to_defaults(false)
	main.world.load_layout()
	var default_plant := main.world.placed_objects.get("plant_1") as PlacedObject
	var plant_has_collider := false
	if default_plant != null:
		for child: Node in default_plant.find_children("*", "CollisionShape3D", true, false):
			if (child as CollisionShape3D).shape != null:
				plant_has_collider = true
				break
	_expect(default_plant != null and plant_has_collider, "the default plant owns a real physical collider")
	_expect(default_plant != null and main.world.astar.is_point_solid(default_plant.grid_cell), "the default plant's physical collider is mirrored by a solid AStar cell")
	main.world.spawn_staff()
	SimulationManager.reset_service_stats()
	GameState.set_restaurant_state("closed")
	var handyman: EmployeeAgent
	for staff: EmployeeAgent in main.world.staff_agents.values():
		staff.cancel_active_task()
		if String(staff.employee.get("role", "")) == "handyman":
			handyman = staff
		else:
			staff.shutdown_navigation()
			staff.set_collision_enabled(false)
	_expect(handyman != null, "the integration layout has a handyman agent")
	if handyman == null:
		main.queue_free()
		return
	handyman.global_position = Vector3(13.0, 0.0, -5.576835)
	handyman.velocity = Vector3.ZERO
	handyman.state = "idle"
	handyman.navigation_failed = false
	handyman.navigation_active = false
	handyman.path.clear()
	var route_owner := MaintenanceOwner.new()
	add_child(route_owner)
	var task := SimulationManager.request_maintenance_task(route_owner, "clean_spill", Vector3(9.0, 0.0, -9.0), {"reservation_key":"spill:navigation_regression"}, 3, 0.35)
	GameState.set_restaurant_state("open")
	main.world._spawn_clock = 99999.0
	main.world._spill_clock = 99999.0
	var claim_count := 0
	var previous_active_id := ""
	var maximum_stationary_ticks := 0
	var stationary_ticks := 0
	var last_position := handyman.global_position
	for _tick: int in 500:
		main.world._process(0.04)
		handyman._process(0.04)
		var active_id := String(handyman.active_task.get("id", ""))
		if not active_id.is_empty() and active_id != previous_active_id:
			claim_count += 1
		previous_active_id = active_id
		if handyman.state == "moving" and handyman.global_position.distance_to(last_position) < 0.006:
			stationary_ticks += 1
			maximum_stationary_ticks = maxi(maximum_stationary_ticks, stationary_ticks)
		else:
			stationary_ticks = 0
		last_position = handyman.global_position
		if route_owner.completed > 0:
			break
	_expect(route_owner.completed == 1 and String(task.get("state", "")) == "completed", "a handyman reaches and completes the formerly deadlocking spill route")
	_expect(maximum_stationary_ticks < 75, "maintenance navigation never remains motionless for three simulated seconds")
	_expect(claim_count == 1, "maintenance does not cancel and reclaim the same route in a loop")
	SimulationManager.close_immediately()
	main.queue_free()
	route_owner.queue_free()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
