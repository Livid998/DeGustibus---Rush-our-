extends Node

var failures: Array[String] = []


func _ready() -> void:
	SaveManager.writes_enabled = false
	seed(20260722)
	GameState.reset_to_defaults(false)
	SimulationManager.reset_service_stats()
	var customer := Node.new()
	customer.name = "IdempotentPartyFixture"
	add_child(customer)
	var first := SimulationManager.create_order("margherita", "idempotency_table", customer, "party-a:diner-0")
	var duplicate := SimulationManager.create_order("margherita", "idempotency_table", customer, "party-a:diner-0")
	_expect(not first.is_empty(), "the first diner ticket is accepted")
	_expect(
		String(first.get("id", "")) == String(duplicate.get("id", "")) and SimulationManager.orders.size() == 1,
		"replaying the same diner commit returns the original ticket without reserving ingredients twice"
	)
	var second_diner := SimulationManager.create_order("margherita", "idempotency_table", customer, "party-a:diner-1")
	_expect(
		not second_diner.is_empty() and String(second_diner.get("id", "")) != String(first.get("id", "")) and SimulationManager.orders.size() == 2,
		"a different diner slot still receives exactly one independent ticket"
	)
	for order: Dictionary in SimulationManager.orders.values():
		SimulationManager.cancel_order(String(order.get("id", "")), "idempotency_test_cleanup")
	var result := "CUSTOMER ORDER IDEMPOTENCY: %s checks=3 failures=%d\n" % [
		"PASS" if failures.is_empty() else "FAIL",
		failures.size(),
	]
	print(result.strip_edges())
	for failure: String in failures:
		print("FAIL: ", failure)
	var file := FileAccess.open("res://tests/customer-order-idempotency-result.txt", FileAccess.WRITE)
	file.store_string(result + ("" if failures.is_empty() else "FAIL: " + "\nFAIL: ".join(failures) + "\n"))
	get_tree().quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
