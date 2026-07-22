extends Node

## Release gate: ten independent new games reach the end of day three through
## public stock/order/clock APIs. This catches starter-state regressions without
## relying on a developer cheat or a pre-baked save.

const RUNS := 10
const DAYS := 3
const ORDERS_PER_DAY := 2

var checks := 0
var failures: Array[String] = []
var _original_state: Dictionary
var _original_world: Node
var _simulation_was_processing := true
var _economy_was_processing := true


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	_original_state = GameState.serialize().duplicate(true)
	_original_world = SimulationManager.world
	_simulation_was_processing = SimulationManager.is_processing()
	_economy_was_processing = EconomyManager.is_processing()
	SimulationManager.set_process(false)
	EconomyManager.set_process(false)
	DayCycleManager.set_paused(false, false)

	for run_index: int in RUNS:
		_run_fresh_game(run_index)

	SimulationManager.close_immediately()
	SimulationManager.bind_world(_original_world)
	SimulationManager.reset_service_stats()
	StorageManager.reset_runtime_reservations()
	GameState.deserialize(_original_state)
	SimulationManager.set_process(_simulation_was_processing)
	EconomyManager.set_process(_economy_was_processing)

	var result := "RELEASE FRESH RUN MATRIX: %s | runs=%d days=%d checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		RUNS,
		DAYS,
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("user://release-fresh-run-matrix.txt", FileAccess.WRITE)
	if file != null:
		file.store_string(result)
		file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _run_fresh_game(run_index: int) -> void:
	seed(2026072200 + run_index)
	SimulationManager.close_immediately()
	SimulationManager.reset_service_stats()
	GameState.reset_to_defaults(false)
	GameState.set_restaurant_state("closed")
	StorageManager.reset_runtime_reservations()
	StorageManager.recalculate_layout_capacity()
	StorageManager.refresh_auto_sold_out()
	EconomyManager.clear_delivery_cart()
	DayCycleManager.reset_event_history()
	DayCycleManager.set_clock(1, float(DataRegistry.balance_value("day_cycle.start_minute", 540.0)))

	var customer := Node.new()
	customer.name = "ReleaseFreshRunCustomer%d" % run_index
	add_child(customer)
	var paid_before := int(GameState.progress.get("customers_served", 0))
	for day: int in range(1, DAYS + 1):
		for order_index: int in ORDERS_PER_DAY:
			var recipe_id := "margherita" if (run_index + day + order_index) % 2 == 0 else "mixed_salad"
			_expect(
				_serve_paid_order(recipe_id, customer, "run_%02d_day_%d_order_%d" % [run_index, day, order_index]),
				"fresh run %d day %d completes %s" % [run_index + 1, day, recipe_id]
			)
		_assert_recoverable("fresh run %d day %d" % [run_index + 1, day])
		DayCycleManager.set_clock(day, 1438.0)
		DayCycleManager.advance_seconds(5.0, 1.0, "closed")
		_expect(int(GameState.world_clock.day) == day + 1, "fresh run %d completes management day %d" % [run_index + 1, day])
		_assert_recoverable("fresh run %d after payroll day %d" % [run_index + 1, day])

	var completed_delta := int(GameState.progress.get("customers_served", 0)) - paid_before
	_expect(completed_delta >= DAYS * ORDERS_PER_DAY, "fresh run %d records every paid cover" % [run_index + 1])
	_expect(GameState.money >= 0, "fresh run %d reaches day three without bankruptcy" % [run_index + 1])
	_expect(StorageManager.reservation_count() == 0, "fresh run %d leaves no stock lease" % [run_index + 1])
	customer.queue_free()


func _serve_paid_order(recipe_id: String, customer: Node, label: String) -> bool:
	if not StorageManager.is_recipe_producible(recipe_id):
		if not _restock_recipe(recipe_id):
			failures.append("FAIL: %s cannot restock %s" % [label, recipe_id])
			return false
	GameState.set_recipe_unlocked(recipe_id, true)
	GameState.set_recipe_active(recipe_id, true)
	GameState.set_recipe_manual_paused(recipe_id, false)
	var order := SimulationManager.create_order(recipe_id, "release_gate_table", customer, label)
	if order.is_empty():
		return false
	var order_id := String(order.get("id", ""))
	if not StorageManager.consume_reserved(order_id, DataRegistry.recipe_raw_requirements(recipe_id)):
		SimulationManager.cancel_order(order_id, "release_gate_consume_failed")
		return false
	SimulationManager.complete_order_payment(order_id, 1.0)
	return String(SimulationManager.orders.get(order_id, {}).get("state", "")) == "paid"


func _restock_recipe(recipe_id: String) -> bool:
	var requirements := DataRegistry.recipe_raw_requirements(recipe_id)
	EconomyManager.clear_delivery_cart()
	for ingredient_id: String in requirements:
		var missing := int(requirements[ingredient_id]) - StorageManager.available_amount(ingredient_id)
		if missing <= 0:
			continue
		if not bool(GameState.stock.get(ingredient_id, {}).get("unlocked", false)):
			return false
		if not EconomyManager.add_to_delivery_cart(ingredient_id, missing):
			return false
	var preview := EconomyManager.delivery_preview({}, true)
	if not bool(preview.get("fully_accepted", false)) or not bool(preview.get("affordable", false)):
		EconomyManager.clear_delivery_cart()
		return false
	if not EconomyManager.confirm_delivery_cart(true):
		return false
	EconomyManager.advance_delivery_time(float(DataRegistry.balance_value("delivery.urgent_delivery_seconds", 30.0)))
	return StorageManager.is_recipe_producible(recipe_id)


func _assert_recoverable(label: String) -> void:
	var audit := StorageManager.soft_lock_snapshot()
	_expect(
		not (audit.get("producible_recipe_ids", []) as Array).is_empty()
			or not (audit.get("pending_recipe_ids", []) as Array).is_empty()
			or not (audit.get("orderable_recipe_ids", []) as Array).is_empty()
			or bool(audit.get("recovery_available", false)),
		"%s remains recoverable" % label
	)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
