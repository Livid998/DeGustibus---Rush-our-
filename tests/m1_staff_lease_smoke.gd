extends Node

class ServiceOwner:
	extends Node3D
	var completions := 0

	func accepts_service_action(_action: String, _payload: Dictionary) -> bool:
		return true

	func service_completed(_action: String, _payload: Dictionary) -> void:
		completions += 1


class MaintenanceOwner:
	extends Node3D

	func accepts_maintenance_action(_action: String, _payload: Dictionary) -> bool:
		return true


var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	SaveManager.writes_enabled = false
	SimulationManager.bind_world(null)
	_test_kitchen_bundle()
	_test_service_bundle()
	_test_work_cell_bundle()
	SimulationManager.reset_service_stats()
	var result := "M1 STAFF LEASES: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/m1-staff-lease-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_kitchen_bundle() -> void:
	_reset_runtime()
	var first_station := Node3D.new()
	var second_station := Node3D.new()
	add_child(first_station)
	add_child(second_station)
	first_station.position = Vector3(-2.0, 0.0, 0.0)
	second_station.position = Vector3(2.0, 0.0, 0.0)
	SimulationManager.register_station("lease_prep", first_station, 1)
	SimulationManager.register_station("lease_prep", second_station, 1)
	SimulationManager.orders = {
		"order_a": {"id": "order_a", "state": "cooking"},
		"order_b": {"id": "order_b", "state": "cooking"},
	}
	SimulationManager.tasks = {
		"kitchen_a": _kitchen_task("kitchen_a", "order_a"),
		"kitchen_b": _kitchen_task("kitchen_b", "order_b"),
	}
	var cook_a := {"id": "lease_cook_a", "role": "cook", "skills": {"lease_prep": 0.8}}
	var cook_b := {"id": "lease_cook_b", "role": "cook", "skills": {"lease_prep": 0.8}}
	var first := SimulationManager.claim_kitchen_task(cook_a)
	var same_worker_second := SimulationManager.claim_kitchen_task(cook_a)
	var second := SimulationManager.claim_kitchen_task(cook_b)
	_expect(not first.is_empty() and same_worker_second.is_empty(), "one employee cannot own two task bundles")
	_expect(not second.is_empty() and first.station_runtime.node != second.station_runtime.node, "different cooks atomically own different free stations")
	_expect(SimulationManager.kitchen_task_reservation_is_valid(String(first.id), String(cook_a.id)), "kitchen ownership validates task and station leases together")
	var diagnostic := SimulationManager.staff_lease_snapshot()
	_expect(int(diagnostic.get("active", 0)) == 6 and int(diagnostic.get("by_kind", {}).get("station_slot", 0)) == 2, "two kitchen bundles expose six authoritative leases")
	var released_node: Node = first.station_runtime.node
	SimulationManager.cancel_employee_task(String(cook_a.id))
	SimulationManager.cancel_employee_task(String(cook_a.id))
	var replacement := SimulationManager.claim_kitchen_task({"id": "lease_cook_c", "role": "cook", "skills": {"lease_prep": 0.8}})
	_expect(not replacement.is_empty() and replacement.station_runtime.node == released_node, "idempotent cancellation releases the exact workstation for reuse")


func _test_service_bundle() -> void:
	_reset_runtime()
	var first_owner := ServiceOwner.new()
	var second_owner := ServiceOwner.new()
	add_child(first_owner)
	add_child(second_owner)
	var first_task := SimulationManager.request_service(first_owner, "take_order", Vector3.ZERO, {"reservation_key": "party:a"})
	var second_task := SimulationManager.request_service(second_owner, "take_order", Vector3(4.0, 0.0, 0.0), {"reservation_key": "party:b"})
	var waiter_a := {"id": "lease_waiter_a", "role": "waiter"}
	var first := SimulationManager.claim_service_task(waiter_a)
	var duplicate := SimulationManager.claim_service_task(waiter_a)
	var second := SimulationManager.claim_service_task({"id": "lease_waiter_b", "role": "waiter"})
	_expect(String(first.get("id", "")) == String(first_task.id) and duplicate.is_empty(), "service claim reserves employee and party slot in one transaction")
	_expect(String(second.get("id", "")) == String(second_task.id), "another waiter can independently claim another party")
	_expect(SimulationManager.service_task_reservation_is_valid(String(first.id), String(waiter_a.id)), "service lease validation rejects phantom ownership")
	SimulationManager.cancel_employee_task(String(waiter_a.id))
	var replacement := SimulationManager.claim_service_task({"id": "lease_waiter_c", "role": "waiter"})
	_expect(String(replacement.get("id", "")) == String(first_task.id), "cancelled service work is safely reclaimable")
	# Simulate a bad external terminal transition: the periodic audit must remove
	# every lease rather than keeping a ghost employee/party reservation.
	replacement.state = "cancelled"
	SimulationManager._audit_staff_leases()
	_expect(not SimulationManager.service_task_reservation_is_valid(String(replacement.id), "lease_waiter_c"), "audit repairs terminal service tasks with stale leases")


func _test_work_cell_bundle() -> void:
	_reset_runtime()
	var first_owner := MaintenanceOwner.new()
	var second_owner := MaintenanceOwner.new()
	add_child(first_owner)
	add_child(second_owner)
	SimulationManager.request_maintenance_task(first_owner, "clean_spill", Vector3(3.01, 0.0, 2.99), {"reservation_key": "spill:a"})
	SimulationManager.request_maintenance_task(second_owner, "clean_spill", Vector3(3.08, 0.0, 3.02), {"reservation_key": "spill:b"})
	var first := SimulationManager.claim_maintenance_task({"id": "lease_handyman_a", "role": "handyman"})
	var blocked := SimulationManager.claim_maintenance_task({"id": "lease_handyman_b", "role": "handyman"})
	_expect(not first.is_empty() and blocked.is_empty(), "near-identical free-standing work positions share one exclusive work-cell lease")
	SimulationManager.cancel_employee_task("lease_handyman_a")
	var replacement := SimulationManager.claim_maintenance_task({"id": "lease_handyman_b", "role": "handyman"})
	_expect(not replacement.is_empty() and SimulationManager.maintenance_task_reservation_is_valid(String(replacement.id), "lease_handyman_b"), "work-cell lease is released on route cancellation")


func _kitchen_task(task_id: String, order_id: String) -> Dictionary:
	return {
		"id": task_id,
		"order_id": order_id,
		"state": "queued",
		"station": "lease_prep",
		"priority": 1,
		"wait_age": 0.0,
		"inputs": {},
		"dependencies": [],
	}


func _reset_runtime() -> void:
	SimulationManager.reset_service_stats()
	SimulationManager.stations = {}
	SimulationManager.bind_world(null)
	RuntimeDiagnostics.reset()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
