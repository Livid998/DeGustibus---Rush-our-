class_name OrderManager
extends Node

signal orders_changed
signal order_failed(order: Dictionary)
signal order_created(order: Dictionary)

var orders: Array[Dictionary] = []
var next_id := 1
var spawn_timer := 0.0
var rng := RandomNumberGenerator.new()
var session: SessionState

func setup(value: SessionState) -> void:
	session = value
	rng.seed = 74291
	reset()

func reset() -> void:
	orders.clear()
	next_id = 1
	spawn_timer = 3.0
	orders_changed.emit()

func tick(delta: float) -> void:
	if session.phase != SessionState.Phase.SERVICE and session.phase != SessionState.Phase.BREAKDOWN:
		return
	spawn_timer -= delta
	var active := active_orders()
	if spawn_timer <= 0.0 and active.size() < 5 and session.service_time_left > 25.0:
		create_order()
		spawn_timer = rng.randf_range(24.0, 34.0)
	var changed_any := false
	for order in orders:
		if order.status != "waiting":
			continue
		order.elapsed += delta
		var patience_loss := delta * (0.18 + float(order.sensitivity) * 0.006)
		if session.phase == SessionState.Phase.BREAKDOWN:
			patience_loss *= 2.0
		if "update_tables" in session.directives:
			patience_loss *= 0.82
		order.patience = maxf(0.0, float(order.patience) - patience_loss)
		changed_any = true
		if order.patience <= 0.0:
			fail_order(order, "Il tavolo %d se n'è andato per l'attesa" % order.table)
	if changed_any:
		orders_changed.emit()

func create_order(forced_recipe := "") -> Dictionary:
	var available := ["burger", "pasta", "special"]
	if "soldout_burger" in session.directives:
		available.erase("burger")
	if session.special_promised >= session.special_real:
		available.erase("special")
	if available.is_empty():
		available = ["pasta"]
	var recipe: String = forced_recipe if not forced_recipe.is_empty() else available[rng.randi_range(0, available.size() - 1)]
	if "promote_pasta" in session.directives and rng.randf() < 0.42:
		recipe = "pasta"
	var recipe_data: Dictionary = GameData.RECIPES[recipe]
	var invalid_chance := 0.13 + float(session.staff_state.cassiera.stress) * 0.002
	var is_invalid := rng.randf() < invalid_chance
	var mods: Array = recipe_data.invalid_mods if is_invalid else recipe_data.valid_mods
	var mod: String = ""
	if rng.randf() < 0.62:
		mod = str(mods[rng.randi_range(0, mods.size() - 1)])
	var forbidden := (mod == "salsa a parte" and "forbid_sauce" in session.directives) or (mod == "senza formaggio" and "forbid_cheese" in session.directives)
	if forbidden:
		var memory_roll := rng.randi_range(0, 100)
		if memory_roll < int(GameData.STAFF.cassiera.memory) - int(session.staff_state.cassiera.stress * 0.2):
			mod = "alternativa proposta"
			is_invalid = false
		else:
			is_invalid = true
			session.add_anger(7.0, "La cassa ha accettato una modifica vietata dal briefing")
			session.incidents.append({"actor": "cassiera", "text": "Ha accettato una modifica vietata", "severity": 7.0, "fault": true})
	var table := _first_free_table()
	var archetype: Dictionary = GameData.CUSTOMER_ARCHETYPES[rng.randi_range(0, GameData.CUSTOMER_ARCHETYPES.size() - 1)]
	var order := {
		"id": next_id,
		"table": table,
		"recipe": recipe,
		"mod": mod,
		"invalid": is_invalid,
		"priority": 1,
		"elapsed": 0.0,
		"patience": float(archetype.patience),
		"max_patience": float(archetype.patience),
		"sensitivity": float(archetype.aggression),
		"status": "waiting",
		"waiter": "Nico",
		"archetype": archetype.name,
	}
	if recipe == "special":
		session.special_promised += 1
	orders.append(order)
	next_id += 1
	order_created.emit(order)
	orders_changed.emit()
	return order

func complete_recipe(recipe: String, quality: float) -> Dictionary:
	var target := {}
	for order in orders:
		if order.status == "waiting" and order.recipe == recipe:
			target = order
			break
	if target.is_empty():
		return {}
	target.status = "delivered"
	target.quality = quality
	orders_changed.emit()
	return target

func fail_order(order: Dictionary, reason: String) -> void:
	if order.status != "waiting":
		return
	order.status = "failed"
	order.failure_reason = reason
	order_failed.emit(order)
	orders_changed.emit()

func active_orders() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for order in orders:
		if order.status == "waiting":
			result.append(order)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.elapsed) > float(b.elapsed))
	return result

func _first_free_table() -> int:
	for table in range(1, 7):
		var occupied := false
		for order in orders:
			if order.status == "waiting" and order.table == table:
				occupied = true
				break
		if not occupied:
			return table
	return rng.randi_range(1, 6)

