extends Node

signal delivery_created(delivery: Dictionary)
signal delivery_arrived(delivery: Dictionary)

var _clock := 0.0


func _process(delta: float) -> void:
	var scaled := delta * SimulationManager.simulation_speed
	_clock += scaled
	for delivery: Dictionary in GameState.deliveries.duplicate():
		delivery.remaining = float(delivery.remaining) - scaled
		if delivery.remaining <= 0.0:
			_complete_delivery(delivery)
	if _clock >= 1.0:
		_clock = 0.0
		_check_auto_reorders()


func _check_auto_reorders() -> void:
	for ingredient_id: String in GameState.stock:
		var entry: Dictionary = GameState.stock[ingredient_id]
		if not bool(entry.get("auto_reorder", false)) or int(entry.amount) >= int(entry.threshold):
			continue
		var already_pending := false
		for delivery: Dictionary in GameState.deliveries:
			if delivery.ingredient_id == ingredient_id:
				already_pending = true
				break
		if not already_pending:
			order_stock(ingredient_id, max(int(entry.target) - int(entry.amount), int(entry.lot)), false)


func order_stock(ingredient_id: String, requested_amount: int, urgent: bool = false) -> bool:
	var ingredient: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
	if ingredient.is_empty() or not bool(GameState.stock.get(ingredient_id, {}).get("unlocked", false)):
		return false
	var entry: Dictionary = GameState.stock[ingredient_id]
	var lot: int = maxi(int(entry.get("lot", 1)), 1)
	var amount: int = int(ceil(float(maxi(requested_amount, lot)) / lot)) * lot
	var supplier: Dictionary = DataRegistry.suppliers_by_id.get(String(entry.supplier), {})
	var cost := int(ceil(float(ingredient.get("cost", 1.0)) * amount))
	if urgent:
		cost += int(supplier.get("urgent_fee", 20))
	if not GameState.spend(cost, "Ordine %s" % ingredient.get("name", ingredient_id)):
		return false
	var delivery := {
		"id": "delivery_%d" % Time.get_ticks_msec(),
		"ingredient_id": ingredient_id,
		"amount": amount,
		"unit_cost": float(cost) / amount,
		"supplier": String(entry.supplier),
		"remaining": 0.8 if urgent else float(supplier.get("delivery", 5.0))
	}
	GameState.deliveries.append(delivery)
	delivery_created.emit(delivery)
	return true


func buy_preparation(preparation_id: String, amount: int) -> bool:
	var prep: Dictionary = DataRegistry.preparations_by_id.get(preparation_id, {})
	if prep.is_empty():
		return false
	var cost := int(ceil(float(prep.get("market_price", 5.0)) * amount))
	if not GameState.spend(cost, "Semilavorato %s" % prep.name):
		return false
	GameState.purchased_preparations[preparation_id] = int(GameState.purchased_preparations.get(preparation_id, 0)) + amount
	return true


func hire(candidate_id: String) -> bool:
	for candidate: Dictionary in GameState.candidates:
		if String(candidate.id) != candidate_id:
			continue
		if not GameState.spend(int(candidate.get("hire_cost", 0)), "Assunzione %s" % candidate.name):
			return false
		GameState.candidates.erase(candidate)
		var employee := candidate.duplicate(true)
		employee.erase("hire_cost")
		employee.id = "e_%d" % Time.get_ticks_msec()
		GameState.employees.append(employee)
		GameState.employees_changed.emit()
		return true
	return false


func fire(employee_id: String) -> bool:
	for employee: Dictionary in GameState.employees:
		if String(employee.id) == employee_id:
			GameState.employees.erase(employee)
			GameState.employees_changed.emit()
			return true
	return false


func pay_shift_wages() -> int:
	var due := 0
	for employee: Dictionary in GameState.employees:
		due += int(employee.get("salary", 0))
	var paid := mini(due, GameState.money)
	if paid > 0:
		GameState.spend(paid, "Stipendi del servizio")
	if paid < due:
		GameState.toast_requested.emit("Stipendi parziali: mancano %d ●" % (due - paid), "warning")
	return paid


func _complete_delivery(delivery: Dictionary) -> void:
	GameState.add_stock(delivery.ingredient_id, int(delivery.amount), float(delivery.unit_cost))
	GameState.deliveries.erase(delivery)
	GameState.toast_requested.emit("Consegna arrivata: %s ×%d" % [DataRegistry.ingredients_by_id[delivery.ingredient_id].name, delivery.amount], "income")
	delivery_arrived.emit(delivery)
