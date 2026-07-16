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
	var result := "MAINTENANCE SMOKE: %s | checks=%d failures=%d\n%s" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size(), "\n".join(failures)]
	print(result)
	var file := FileAccess.open("res://tests/maintenance-smoke-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
