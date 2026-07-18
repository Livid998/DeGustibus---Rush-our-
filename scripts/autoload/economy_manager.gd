extends Node

signal delivery_created(delivery: Dictionary)
signal delivery_arrived(delivery: Dictionary)
signal delivery_rejected(reason: String, details: Dictionary)
signal delivery_cart_changed(cart: Dictionary)
signal delivery_batch_changed(batch: Dictionary)
signal payroll_processed(summary: Dictionary)

var delivery_cart: Dictionary = {}
var _auto_reorder_clock := 0.0
var _batch_serial := 0
var _publishing_batch := false
var _auto_reorder_dirty := true


func _ready() -> void:
	GameState.pending_delivery_batch_changed.connect(_on_pending_delivery_batch_changed)
	GameState.stock_changed.connect(_on_stock_changed)
	GameState.layout_changed.connect(func(): _auto_reorder_dirty = true)
	_publish_batch(_ensure_batch_schema(GameState.pending_delivery_batch), false)


func _process(delta: float) -> void:
	var legacy_override := _ingest_legacy_countdown_overrides()
	if delta > 0.0 or legacy_override:
		advance_delivery_time(delta, SimulationManager.simulation_speed)
	var scaled := maxf(delta, 0.0) * SimulationManager.simulation_speed
	_auto_reorder_clock += scaled
	if _auto_reorder_dirty or _auto_reorder_clock >= 1.0:
		_auto_reorder_clock = 0.0
		_auto_reorder_dirty = false
		_check_auto_reorders()


func add_to_delivery_cart(ingredient_id: String, amount: int) -> bool:
	if not _ingredient_is_purchasable(ingredient_id) or amount <= 0:
		return false
	delivery_cart[ingredient_id] = int(delivery_cart.get(ingredient_id, 0)) + amount
	delivery_cart_changed.emit(delivery_cart.duplicate(true))
	return true


func remove_from_delivery_cart(ingredient_id: String, amount: int) -> bool:
	if not delivery_cart.has(ingredient_id) or amount <= 0:
		return false
	var remaining := maxi(int(delivery_cart[ingredient_id]) - amount, 0)
	if remaining == 0:
		delivery_cart.erase(ingredient_id)
	else:
		delivery_cart[ingredient_id] = remaining
	delivery_cart_changed.emit(delivery_cart.duplicate(true))
	return true


func clear_delivery_cart() -> void:
	if delivery_cart.is_empty():
		return
	delivery_cart.clear()
	delivery_cart_changed.emit({})


func delivery_cart_snapshot() -> Dictionary:
	return delivery_cart.duplicate(true)


func delivery_preview(items: Dictionary = {}, urgent: bool = false) -> Dictionary:
	var normalized := _normalize_purchase_items(delivery_cart if items.is_empty() else items)
	var capacity := StorageManager.validate_delivery_capacity(normalized)
	var cost := _delivery_cost(normalized, urgent)
	return {
		"valid": not normalized.is_empty() and bool(capacity.valid) and GameState.can_afford(cost),
		"items": normalized,
		"cost": cost,
		"capacity_valid": bool(capacity.valid),
		"forecast": capacity.forecast,
		"capacity": capacity.capacity,
		"blocked_types": capacity.blocked_types,
		"affordable": GameState.can_afford(cost),
		"urgent": urgent
	}


func confirm_delivery_cart(urgent: bool = false) -> bool:
	var cart := delivery_cart.duplicate(true)
	if not _confirm_items(cart, urgent, "Carrello consegna urgente" if urgent else "Carrello prossima consegna"):
		return false
	clear_delivery_cart()
	return true


func add_to_delivery_batch(ingredient_id: String, requested_amount: int, urgent: bool = false) -> bool:
	if not _ingredient_is_purchasable(ingredient_id):
		return false
	var entry: Dictionary = GameState.stock[ingredient_id]
	var lot := maxi(int(entry.get("lot", 1)), 1)
	var amount := int(ceil(float(maxi(requested_amount, lot)) / float(lot))) * lot
	return _confirm_items({ingredient_id: amount}, urgent, "Riordino urgente" if urgent else "Riordino automatico")


func order_stock(ingredient_id: String, requested_amount: int, urgent: bool = false) -> bool:
	# Compatibility API for older UI/tests. It now confirms one item into the
	# aggregate normal or urgent batch instead of creating one delivery per row.
	return add_to_delivery_batch(ingredient_id, requested_amount, urgent)


func _confirm_items(items: Dictionary, urgent: bool, reason: String) -> bool:
	var normalized := _normalize_purchase_items(items)
	if normalized.is_empty():
		delivery_rejected.emit("empty", {})
		return false
	var preview := delivery_preview(normalized, urgent)
	if not bool(preview.capacity_valid):
		delivery_rejected.emit("capacity", preview)
		GameState.toast_requested.emit("Capacita insufficiente all'arrivo della consegna", "warning")
		return false
	var cost := int(preview.cost)
	if not GameState.spend(cost, reason):
		delivery_rejected.emit("money", preview)
		return false
	var root := _ensure_batch_schema(GameState.pending_delivery_batch)
	var batch := _batch_for_kind(root, "urgent" if urgent else "normal")
	var was_empty := (batch.get("items", {}) as Dictionary).is_empty()
	if String(batch.get("id", "")).is_empty():
		_batch_serial += 1
		batch.id = "%s_%d_%d" % ["urgent" if urgent else "batch", Time.get_ticks_msec(), _batch_serial]
	if urgent and was_empty:
		batch.remaining = float(DataRegistry.balance_value("delivery.urgent_delivery_seconds", 30.0))
	for ingredient_id: String in normalized:
		var amount := int(normalized[ingredient_id])
		var unit_cost := _unit_cost(ingredient_id, urgent)
		var current: Dictionary = batch.get("items", {}).get(ingredient_id, {})
		var previous_amount := int(current.get("amount", 0))
		var merged_amount := previous_amount + amount
		var previous_cost := float(current.get("unit_cost", unit_cost))
		batch.items[ingredient_id] = {
			"amount": merged_amount,
			"unit_cost": ((previous_cost * previous_amount) + unit_cost * amount) / float(maxi(merged_amount, 1))
		}
	batch.paid = true
	if urgent:
		root.urgent = batch
	else:
		root.id = batch.id
		root.items = batch.items
		root.remaining = batch.remaining
		root.paid = true
	_publish_batch(root)
	delivery_created.emit(batch.duplicate(true))
	return true


func advance_delivery_time(real_seconds: float, speed_multiplier: float = 1.0) -> void:
	var scaled := maxf(real_seconds, 0.0) * maxf(speed_multiplier, 0.0)
	var root := _ensure_batch_schema(GameState.pending_delivery_batch)
	var normal_interval := float(DataRegistry.balance_value("delivery.batch_interval_seconds", 300.0))
	var normal_remaining := float(root.get("remaining", normal_interval)) - scaled
	while normal_remaining <= 0.0:
		if not (root.get("items", {}) as Dictionary).is_empty():
			_deliver_batch(_batch_for_kind(root, "normal"), "normal")
			root.id = ""
			root.items = {}
			root.paid = false
		normal_remaining += normal_interval
		if normal_interval <= 0.0:
			normal_remaining = 0.0
			break
	root.remaining = normal_remaining

	var urgent := _batch_for_kind(root, "urgent")
	if not (urgent.get("items", {}) as Dictionary).is_empty():
		urgent.remaining = float(urgent.get("remaining", DataRegistry.balance_value("delivery.urgent_delivery_seconds", 30.0))) - scaled
		if float(urgent.remaining) <= 0.0:
			_deliver_batch(urgent, "urgent")
			urgent = _empty_urgent_batch()
	else:
		urgent.remaining = float(DataRegistry.balance_value("delivery.urgent_delivery_seconds", 30.0))
	root.urgent = urgent
	_publish_batch(root)


func normal_batch_snapshot() -> Dictionary:
	return _batch_for_kind(_ensure_batch_schema(GameState.pending_delivery_batch), "normal")


func urgent_batch_snapshot() -> Dictionary:
	return _batch_for_kind(_ensure_batch_schema(GameState.pending_delivery_batch), "urgent")


func next_delivery_for_ingredient(ingredient_id: String) -> Dictionary:
	return StorageManager.pending_delivery_summary(ingredient_id)


func _check_auto_reorders() -> void:
	# Tests, migrations and builder confirmations may replace GameState directly
	# without emitting layout/stock signals. Recalculate only at this explicit
	# event boundary; StorageManager never polls per frame.
	StorageManager.recalculate_layout_capacity()
	for ingredient_id: String in GameState.stock:
		var entry: Dictionary = GameState.stock[ingredient_id]
		if not bool(entry.get("auto_reorder", false)):
			continue
		var amount := int(entry.get("amount", 0))
		if amount > int(entry.get("threshold", 0)):
			continue
		var pending := StorageManager.pending_amount(ingredient_id, "all")
		var required := int(entry.get("target", 0)) - amount - pending
		if required <= 0:
			continue
		# Automatic reorder fills the configured target exactly. Manual orders
		# still respect the selected lot multiple.
		_confirm_items({ingredient_id: required}, false, "Riordino automatico")


func buy_preparation(preparation_id: String, amount: int) -> bool:
	var prep: Dictionary = DataRegistry.preparations_by_id.get(preparation_id, {})
	if prep.is_empty():
		return false
	var cost := int(ceil(float(prep.get("market_price", 5.0)) * amount))
	if not GameState.spend(cost, "Semilavorato %s" % prep.name):
		return false
	GameState.purchased_preparations[preparation_id] = int(GameState.purchased_preparations.get(preparation_id, 0)) + amount
	GameState.mark_save_dirty()
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
		GameState.mark_save_dirty()
		return true
	return false


func fire(employee_id: String) -> bool:
	for employee: Dictionary in GameState.employees:
		if String(employee.id) == employee_id:
			GameState.employees.erase(employee)
			GameState.employees_changed.emit()
			GameState.mark_save_dirty()
			return true
	return false


func pay_shift_wages() -> int:
	# Legacy API retained for old tools. Continuous service pays at midnight via
	# process_daily_payroll(); closing the restaurant must never charge twice.
	var due := 0
	for employee: Dictionary in GameState.employees:
		due += int(employee.get("salary", 0))
	var paid := mini(due, GameState.money)
	if paid > 0:
		GameState.spend(paid, "Stipendi del servizio")
	if paid < due:
		GameState.toast_requested.emit("Stipendi parziali: mancano %d monete" % (due - paid), "warning")
	return paid


func process_daily_payroll(completed_day: int) -> Dictionary:
	var normalized_day := maxi(completed_day, 1)
	var last_processed := maxi(int(GameState.progress.get("last_payroll_day", 0)), 0)
	if normalized_day <= last_processed:
		return {
			"processed": false,
			"day": normalized_day,
			"wages": 0,
			"previous_debt": maxi(int(GameState.progress.get("wage_debt", 0)), 0),
			"paid": 0,
			"debt": maxi(int(GameState.progress.get("wage_debt", 0)), 0),
		}
	var wages := 0
	for employee: Dictionary in GameState.employees:
		wages += maxi(int(employee.get("salary", 0)), 0)
	var previous_debt := maxi(int(GameState.progress.get("wage_debt", 0)), 0)
	var total_due := wages + previous_debt
	var paid := mini(total_due, maxi(GameState.money, 0))
	if paid > 0:
		GameState.spend(paid, "Stipendi giorno %d" % normalized_day)
	var debt := maxi(total_due - paid, 0)
	GameState.progress.last_payroll_day = normalized_day
	GameState.progress.wage_debt = debt
	GameState.mark_save_dirty()
	var summary := {
		"processed": true,
		"day": normalized_day,
		"wages": wages,
		"previous_debt": previous_debt,
		"paid": paid,
		"debt": debt,
	}
	if debt > 0:
		GameState.toast_requested.emit(
			"Stipendi: pagati %d, debito recuperabile %d" % [paid, debt],
			"warning"
		)
	elif previous_debt > 0:
		GameState.toast_requested.emit("Debito stipendi saldato", "income")
	payroll_processed.emit(summary.duplicate(true))
	return summary


func _deliver_batch(batch: Dictionary, batch_kind: String) -> void:
	var delivered_total := 0
	for ingredient_id: String in batch.get("items", {}):
		var item: Dictionary = batch.items[ingredient_id]
		var amount := maxi(int(item.get("amount", 0)), 0)
		if amount <= 0:
			continue
		GameState.add_stock(ingredient_id, amount, float(item.get("unit_cost", -1.0)))
		delivered_total += amount
	if delivered_total > 0:
		GameState.toast_requested.emit("%s arrivata: %d unita" % ["Consegna urgente" if batch_kind == "urgent" else "Consegna", delivered_total], "income")
		delivery_arrived.emit(batch.duplicate(true))
	StorageManager.recalculate_usage()
	StorageManager.refresh_auto_sold_out()
	_auto_reorder_dirty = true


func _delivery_cost(items: Dictionary, urgent: bool) -> int:
	var result := 0.0
	for ingredient_id: String in items:
		result += _unit_cost(ingredient_id, urgent) * int(items[ingredient_id])
	return int(ceil(result))


func _unit_cost(ingredient_id: String, urgent: bool) -> float:
	var base := float(DataRegistry.ingredients_by_id.get(ingredient_id, {}).get("cost", 0.0))
	if urgent:
		base *= float(DataRegistry.balance_value("delivery.urgent_surcharge_multiplier", 1.35))
	return base


func _normalize_purchase_items(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for ingredient_id: String in value:
		if not _ingredient_is_purchasable(ingredient_id):
			continue
		var raw: Variant = value[ingredient_id]
		var amount := int((raw as Dictionary).get("amount", 0)) if raw is Dictionary else int(raw)
		if amount > 0:
			result[ingredient_id] = amount
	return result


func _ingredient_is_purchasable(ingredient_id: String) -> bool:
	return DataRegistry.ingredients_by_id.has(ingredient_id) and bool(GameState.stock.get(ingredient_id, {}).get("unlocked", false))


func _ensure_batch_schema(value: Dictionary) -> Dictionary:
	var interval := float(DataRegistry.balance_value("delivery.batch_interval_seconds", 300.0))
	var result := {
		"id": String(value.get("id", "")),
		"items": (value.get("items", {}) as Dictionary).duplicate(true) if value.get("items") is Dictionary else {},
		"remaining": clampf(float(value.get("remaining", interval)), 0.0, interval),
		"paid": bool(value.get("paid", false)),
		"urgent": _empty_urgent_batch()
	}
	var urgent_value: Variant = value.get("urgent", {})
	if urgent_value is Dictionary:
		var urgent_interval := float(DataRegistry.balance_value("delivery.urgent_delivery_seconds", 30.0))
		result.urgent = {
			"id": String((urgent_value as Dictionary).get("id", "")),
			"items": ((urgent_value as Dictionary).get("items", {}) as Dictionary).duplicate(true) if (urgent_value as Dictionary).get("items") is Dictionary else {},
			"remaining": clampf(float((urgent_value as Dictionary).get("remaining", urgent_interval)), 0.0, urgent_interval),
			"paid": bool((urgent_value as Dictionary).get("paid", false))
		}
	return result


func _empty_urgent_batch() -> Dictionary:
	return {
		"id": "",
		"items": {},
		"remaining": float(DataRegistry.balance_value("delivery.urgent_delivery_seconds", 30.0)),
		"paid": false
	}


func _batch_for_kind(root: Dictionary, batch_kind: String) -> Dictionary:
	if batch_kind == "urgent":
		return (root.get("urgent", _empty_urgent_batch()) as Dictionary).duplicate(true)
	return {
		"id": String(root.get("id", "")),
		"items": (root.get("items", {}) as Dictionary).duplicate(true),
		"remaining": float(root.get("remaining", DataRegistry.balance_value("delivery.batch_interval_seconds", 300.0))),
		"paid": bool(root.get("paid", false))
	}


func _publish_batch(root: Dictionary, emit_signal: bool = true) -> void:
	_publishing_batch = true
	GameState.set_pending_delivery_batch(root)
	_publishing_batch = false
	_sync_legacy_deliveries(root)
	if emit_signal:
		delivery_batch_changed.emit(root.duplicate(true))


func _sync_legacy_deliveries(root: Dictionary) -> void:
	# Runtime compatibility for old diagnostics. Persistent state lives solely
	# in GameState.pending_delivery_batch.
	GameState.deliveries.clear()
	for batch_kind: String in ["normal", "urgent"]:
		var batch := _batch_for_kind(root, batch_kind)
		var items: Dictionary = batch.get("items", {})
		if items.is_empty():
			continue
		var ingredient_ids: Array = items.keys()
		var first_id := String(ingredient_ids[0])
		GameState.deliveries.append({
			"id": String(batch.get("id", "")),
			"batch_kind": batch_kind,
			"ingredient_id": first_id,
			"amount": int(items[first_id].get("amount", 0)),
			"unit_cost": float(items[first_id].get("unit_cost", 0.0)),
			"remaining": float(batch.get("remaining", 0.0))
		})


func _ingest_legacy_countdown_overrides() -> bool:
	if GameState.deliveries.is_empty():
		return false
	var root := _ensure_batch_schema(GameState.pending_delivery_batch)
	var changed := false
	for legacy: Dictionary in GameState.deliveries:
		var kind := String(legacy.get("batch_kind", "normal"))
		var batch := _batch_for_kind(root, kind)
		var override := float(legacy.get("remaining", batch.get("remaining", 0.0)))
		if override < float(batch.get("remaining", 0.0)):
			batch.remaining = override
			changed = true
			if kind == "urgent":
				root.urgent = batch
			else:
				root.remaining = override
	if changed:
		_publish_batch(root, false)
	return changed


func _on_pending_delivery_batch_changed(value: Dictionary) -> void:
	if _publishing_batch:
		return
	_sync_legacy_deliveries(_ensure_batch_schema(value))
	delivery_batch_changed.emit(value.duplicate(true))


func _on_stock_changed(_ingredient_id: String, _amount: int) -> void:
	_auto_reorder_dirty = true
