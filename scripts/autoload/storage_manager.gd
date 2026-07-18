extends Node

## Event-driven authority for physical storage, stock availability and order
## reservations. Reservations are deliberately runtime-only: GameState resets
## stock.reserved while loading and this ledger is rebuilt only by live orders.

signal capacity_changed(capacity: Dictionary)
signal usage_changed(usage: Dictionary)
signal overflow_changed(overflow: Dictionary)
signal delivery_forecast_changed(forecast: Dictionary)
signal reservation_changed(order_id: String, reservation: Dictionary)
signal ingredient_availability_changed(ingredient_id: String, available: int, reserved: int)
signal recipe_availability_changed(recipe_id: String, auto_sold_out: bool)
signal stock_policy_changed(ingredient_id: String, policy: Dictionary)

const STORAGE_TYPES: Array[String] = ["ambient", "refrigerated"]

var _capacity: Dictionary = {"ambient": 0, "refrigerated": 0}
var _usage: Dictionary = {"ambient": 0, "refrigerated": 0}
var _overflow: Dictionary = {"ambient": false, "refrigerated": false}
var _reservations: Dictionary = {}
var _refreshing_auto_sold_out := false


func _ready() -> void:
	GameState.layout_changed.connect(_on_layout_changed)
	GameState.stock_changed.connect(_on_stock_changed)
	GameState.pending_delivery_batch_changed.connect(_on_pending_delivery_batch_changed)
	GameState.restaurant_state_changed.connect(_on_restaurant_state_changed)
	reset_runtime_reservations()
	recalculate_layout_capacity()
	refresh_auto_sold_out()


func recalculate_layout_capacity() -> Dictionary:
	var next_capacity := _empty_storage_totals()
	for record: Dictionary in GameState.layout:
		var definition: Dictionary = DataRegistry.build_by_id.get(String(record.get("item", "")), {})
		var contribution: Variant = definition.get("storage_capacity", {})
		if not contribution is Dictionary:
			continue
		for storage_type: String in STORAGE_TYPES:
			next_capacity[storage_type] = int(next_capacity[storage_type]) + maxi(int((contribution as Dictionary).get(storage_type, 0)), 0)
	var capacity_did_change := next_capacity != _capacity
	_capacity = next_capacity
	recalculate_usage()
	if capacity_did_change:
		capacity_changed.emit(capacity_snapshot())
	delivery_forecast_changed.emit(forecast_usage())
	return capacity_snapshot()


func recalculate_usage() -> Dictionary:
	var next_usage := _empty_storage_totals()
	for ingredient_id: String in GameState.stock:
		var entry: Variant = GameState.stock[ingredient_id]
		if not entry is Dictionary:
			continue
		var metadata := DataRegistry.storage_metadata_for_ingredient(ingredient_id)
		var storage_type := String(metadata.storage_type)
		if not next_usage.has(storage_type):
			next_usage[storage_type] = 0
		next_usage[storage_type] = int(next_usage[storage_type]) + maxi(int((entry as Dictionary).get("amount", 0)), 0) * maxi(int(metadata.storage_units), 1)
	var usage_did_change := next_usage != _usage
	_usage = next_usage
	var next_overflow := _empty_overflow_flags()
	for storage_type: String in STORAGE_TYPES:
		next_overflow[storage_type] = int(_usage.get(storage_type, 0)) > int(_capacity.get(storage_type, 0))
	var overflow_did_change := next_overflow != _overflow
	_overflow = next_overflow
	if usage_did_change:
		usage_changed.emit(usage_snapshot())
	if overflow_did_change:
		overflow_changed.emit(overflow_snapshot())
	return usage_snapshot()


func capacity_snapshot() -> Dictionary:
	return _capacity.duplicate(true)


func usage_snapshot() -> Dictionary:
	return _usage.duplicate(true)


func overflow_snapshot() -> Dictionary:
	return _overflow.duplicate(true)


func capacity_for(storage_type: String) -> int:
	return int(_capacity.get(storage_type, 0))


func used_for(storage_type: String) -> int:
	return int(_usage.get(storage_type, 0))


func free_capacity(storage_type: String) -> int:
	return int(_capacity.get(storage_type, 0)) - int(_usage.get(storage_type, 0))


func is_overflowing(storage_type: String) -> bool:
	return bool(_overflow.get(storage_type, false))


func storage_metadata(ingredient_id: String) -> Dictionary:
	return DataRegistry.storage_metadata_for_ingredient(ingredient_id)


func available_amount(ingredient_id: String) -> int:
	var entry: Dictionary = GameState.stock.get(ingredient_id, {})
	return maxi(int(entry.get("amount", 0)) - int(entry.get("reserved", 0)), 0)


func reserved_amount(ingredient_id: String) -> int:
	return maxi(int(GameState.stock.get(ingredient_id, {}).get("reserved", 0)), 0)


func pending_items(batch_kind: String = "normal") -> Dictionary:
	var batch := _batch_for_kind(GameState.pending_delivery_batch, batch_kind)
	return _amounts_from_items(batch.get("items", {}))


func pending_amount(ingredient_id: String, batch_kind: String = "all") -> int:
	if batch_kind == "all":
		return int(pending_items("normal").get(ingredient_id, 0)) + int(pending_items("urgent").get(ingredient_id, 0))
	return int(pending_items(batch_kind).get(ingredient_id, 0))


func pending_delivery_summary(ingredient_id: String) -> Dictionary:
	var normal := _batch_for_kind(GameState.pending_delivery_batch, "normal")
	var urgent := _batch_for_kind(GameState.pending_delivery_batch, "urgent")
	var normal_amount := int(_amounts_from_items(normal.get("items", {})).get(ingredient_id, 0))
	var urgent_amount := int(_amounts_from_items(urgent.get("items", {})).get(ingredient_id, 0))
	var next_remaining := INF
	var next_kind := ""
	if normal_amount > 0:
		next_remaining = float(normal.get("remaining", INF))
		next_kind = "normal"
	if urgent_amount > 0 and float(urgent.get("remaining", INF)) < next_remaining:
		next_remaining = float(urgent.get("remaining", INF))
		next_kind = "urgent"
	return {
		"amount": normal_amount + urgent_amount,
		"normal_amount": normal_amount,
		"urgent_amount": urgent_amount,
		"remaining": next_remaining if next_remaining < INF else -1.0,
		"kind": next_kind
	}


func forecast_usage(additional_items: Dictionary = {}) -> Dictionary:
	var result := usage_snapshot()
	_add_item_units(result, pending_items("normal"))
	_add_item_units(result, pending_items("urgent"))
	_add_item_units(result, _amounts_from_items(additional_items))
	return result


func validate_delivery_capacity(additional_items: Dictionary) -> Dictionary:
	var additions := _amounts_from_items(additional_items)
	var added_units := _empty_storage_totals()
	_add_item_units(added_units, additions)
	var forecast := forecast_usage(additions)
	var blocked_types: Array[String] = []
	for storage_type: String in STORAGE_TYPES:
		# Existing overflow of one storage class must not prevent buying an item
		# belonging to the other class.
		if int(added_units.get(storage_type, 0)) <= 0:
			continue
		if int(forecast.get(storage_type, 0)) > int(_capacity.get(storage_type, 0)):
			blocked_types.append(storage_type)
	return {
		"valid": blocked_types.is_empty(),
		"forecast": forecast,
		"capacity": capacity_snapshot(),
		"added_units": added_units,
		"blocked_types": blocked_types
	}


func reserve_recipe_for_order(order_id: String, recipe_or_id: Variant) -> bool:
	return reserve_for_order(order_id, DataRegistry.recipe_raw_requirements(recipe_or_id))


func reserve_for_order(order_id: String, requirements: Dictionary) -> bool:
	if order_id.is_empty() or not _requirements_are_known(requirements):
		return false
	var normalized := _normalize_requirements(requirements)
	if normalized.is_empty():
		_reservations[order_id] = _new_reservation({}, {})
		reservation_changed.emit(order_id, reservation_for_order(order_id))
		return true
	if _reservations.has(order_id):
		var existing: Dictionary = _reservations[order_id]
		return existing.get("original", {}) == normalized
	for ingredient_id: String in normalized:
		if available_amount(ingredient_id) < int(normalized[ingredient_id]):
			return false
	for ingredient_id: String in normalized:
		var entry: Dictionary = GameState.stock[ingredient_id]
		entry.reserved = int(entry.get("reserved", 0)) + int(normalized[ingredient_id])
	_reservations[order_id] = _new_reservation(normalized, {})
	_emit_reservation_effects(order_id, normalized.keys())
	return true


func consume_reserved(order_id: String, requirements: Dictionary) -> bool:
	if not _requirements_are_known(requirements):
		return false
	if not _reservations.has(order_id):
		return requirements.is_empty()
	var normalized := _normalize_requirements(requirements)
	var ledger: Dictionary = _reservations[order_id]
	var remaining: Dictionary = ledger.get("remaining", {})
	for ingredient_id: String in normalized:
		var requested := int(normalized[ingredient_id])
		var entry: Dictionary = GameState.stock.get(ingredient_id, {})
		if int(remaining.get(ingredient_id, 0)) < requested:
			return false
		if int(entry.get("reserved", 0)) < requested or int(entry.get("amount", 0)) < requested:
			return false
	for ingredient_id: String in normalized:
		var requested := int(normalized[ingredient_id])
		var entry: Dictionary = GameState.stock[ingredient_id]
		entry.amount = int(entry.get("amount", 0)) - requested
		entry.reserved = int(entry.get("reserved", 0)) - requested
		remaining[ingredient_id] = int(remaining.get(ingredient_id, 0)) - requested
		ledger.consumed[ingredient_id] = int(ledger.get("consumed", {}).get(ingredient_id, 0)) + requested
		GameState.stock_changed.emit(ingredient_id, int(entry.amount))
	ledger.remaining = remaining
	_reservations[order_id] = ledger
	if not normalized.is_empty():
		GameState.mark_save_dirty()
	_emit_reservation_effects(order_id, normalized.keys())
	return true


func release_reserved_items(order_id: String, requirements: Dictionary) -> bool:
	if not _requirements_are_known(requirements):
		return false
	if not _reservations.has(order_id):
		return requirements.is_empty()
	var normalized := _normalize_requirements(requirements)
	var ledger: Dictionary = _reservations[order_id]
	var remaining: Dictionary = ledger.get("remaining", {})
	for ingredient_id: String in normalized:
		if int(remaining.get(ingredient_id, 0)) < int(normalized[ingredient_id]):
			return false
	for ingredient_id: String in normalized:
		var amount := int(normalized[ingredient_id])
		var entry: Dictionary = GameState.stock[ingredient_id]
		entry.reserved = maxi(int(entry.get("reserved", 0)) - amount, 0)
		remaining[ingredient_id] = int(remaining.get(ingredient_id, 0)) - amount
	ledger.remaining = remaining
	_reservations[order_id] = ledger
	_emit_reservation_effects(order_id, normalized.keys())
	return true


func release_order(order_id: String) -> Dictionary:
	if not _reservations.has(order_id):
		return {}
	var ledger: Dictionary = _reservations[order_id]
	var remaining: Dictionary = ledger.get("remaining", {}).duplicate(true)
	for ingredient_id: String in remaining:
		var amount := maxi(int(remaining[ingredient_id]), 0)
		if amount <= 0 or not GameState.stock.has(ingredient_id):
			continue
		GameState.stock[ingredient_id].reserved = maxi(int(GameState.stock[ingredient_id].get("reserved", 0)) - amount, 0)
	_reservations.erase(order_id)
	_emit_reservation_effects(order_id, remaining.keys())
	return ledger.duplicate(true)


func replace_order_reservation(order_id: String, recipe_or_requirements: Variant) -> bool:
	if not _reservations.has(order_id):
		var requirements: Dictionary
		if recipe_or_requirements is Dictionary and not (recipe_or_requirements as Dictionary).has("steps"):
			requirements = recipe_or_requirements
		else:
			requirements = DataRegistry.recipe_raw_requirements(recipe_or_requirements)
		if not _requirements_are_known(requirements):
			return false
		return reserve_for_order(order_id, requirements)
	var raw_next_requirements: Dictionary
	if recipe_or_requirements is Dictionary and not (recipe_or_requirements as Dictionary).has("steps"):
		raw_next_requirements = recipe_or_requirements
	else:
		raw_next_requirements = DataRegistry.recipe_raw_requirements(recipe_or_requirements)
	if not _requirements_are_known(raw_next_requirements):
		return false
	var next_requirements := _normalize_requirements(raw_next_requirements)
	var previous: Dictionary = _reservations[order_id]
	var previous_remaining: Dictionary = previous.get("remaining", {})
	for ingredient_id: String in next_requirements:
		var reclaimable := int(previous_remaining.get(ingredient_id, 0))
		if available_amount(ingredient_id) + reclaimable < int(next_requirements[ingredient_id]):
			return false
	var affected: Dictionary = {}
	for ingredient_id: String in previous_remaining:
		affected[ingredient_id] = true
	for ingredient_id: String in next_requirements:
		affected[ingredient_id] = true
	for ingredient_id: String in affected:
		if not GameState.stock.has(ingredient_id):
			continue
		var old_amount := int(previous_remaining.get(ingredient_id, 0))
		var new_amount := int(next_requirements.get(ingredient_id, 0))
		GameState.stock[ingredient_id].reserved = maxi(int(GameState.stock[ingredient_id].get("reserved", 0)) + new_amount - old_amount, 0)
	_reservations[order_id] = _new_reservation(next_requirements, previous.get("consumed", {}))
	_emit_reservation_effects(order_id, affected.keys())
	return true


func can_replace_order_with_recipe(order_id: String, recipe_or_id: Variant) -> bool:
	var next_requirements := _normalize_requirements(DataRegistry.recipe_raw_requirements(recipe_or_id))
	var reclaimable: Dictionary = {}
	if _reservations.has(order_id):
		reclaimable = _reservations[order_id].get("remaining", {})
	for ingredient_id: String in next_requirements:
		if available_amount(ingredient_id) + int(reclaimable.get(ingredient_id, 0)) < int(next_requirements[ingredient_id]):
			return false
	return true


func reservation_for_order(order_id: String) -> Dictionary:
	return (_reservations.get(order_id, {}) as Dictionary).duplicate(true)


func reservation_count() -> int:
	return _reservations.size()


func reset_runtime_reservations() -> void:
	_reservations.clear()
	for ingredient_id: String in GameState.stock:
		var entry: Variant = GameState.stock[ingredient_id]
		if entry is Dictionary:
			(entry as Dictionary).reserved = 0
	refresh_auto_sold_out()


func is_recipe_producible(recipe_or_id: Variant) -> bool:
	var requirements := DataRegistry.recipe_raw_requirements(recipe_or_id)
	for ingredient_id: String in requirements:
		if available_amount(ingredient_id) < int(requirements[ingredient_id]):
			return false
	return true


func refresh_auto_sold_out() -> void:
	if _refreshing_auto_sold_out or not is_instance_valid(GameState):
		return
	_refreshing_auto_sold_out = true
	for recipe: Dictionary in DataRegistry.recipes:
		var recipe_id := String(recipe.get("id", ""))
		var state: Dictionary = GameState.menu.get(recipe_id, {})
		if state.is_empty():
			continue
		var should_be_sold_out := bool(state.get("unlocked", false)) and not is_recipe_producible(recipe)
		var previous := bool(state.get("auto_sold_out", false))
		GameState.set_recipe_auto_sold_out(recipe_id, should_be_sold_out)
		if previous != should_be_sold_out:
			recipe_availability_changed.emit(recipe_id, should_be_sold_out)
	_refreshing_auto_sold_out = false


func set_auto_reorder(ingredient_id: String, enabled: bool) -> bool:
	return _set_stock_policy_value(ingredient_id, "auto_reorder", enabled)


func set_reorder_threshold(ingredient_id: String, value: int) -> bool:
	return _set_stock_policy_value(ingredient_id, "threshold", maxi(value, 0))


func set_stock_target(ingredient_id: String, value: int) -> bool:
	return _set_stock_policy_value(ingredient_id, "target", maxi(value, 1))


func set_lot_size(ingredient_id: String, value: int) -> bool:
	return _set_stock_policy_value(ingredient_id, "lot", maxi(value, 1))


func set_supplier(ingredient_id: String, supplier_id: String) -> bool:
	if not DataRegistry.suppliers_by_id.has(supplier_id):
		return false
	return _set_stock_policy_value(ingredient_id, "supplier", supplier_id)


func _set_stock_policy_value(ingredient_id: String, key: String, value: Variant) -> bool:
	if not GameState.stock.has(ingredient_id):
		return false
	var entry: Dictionary = GameState.stock[ingredient_id]
	if entry.get(key) == value:
		return true
	entry[key] = value
	stock_policy_changed.emit(ingredient_id, {
		"auto_reorder": bool(entry.get("auto_reorder", false)),
		"threshold": int(entry.get("threshold", 0)),
		"target": int(entry.get("target", 1)),
		"lot": int(entry.get("lot", 1)),
		"supplier": String(entry.get("supplier", ""))
	})
	GameState.mark_save_dirty()
	return true


func _emit_reservation_effects(order_id: String, ingredient_ids: Array) -> void:
	for ingredient_id_value: Variant in ingredient_ids:
		var ingredient_id := String(ingredient_id_value)
		ingredient_availability_changed.emit(ingredient_id, available_amount(ingredient_id), reserved_amount(ingredient_id))
	reservation_changed.emit(order_id, reservation_for_order(order_id))
	refresh_auto_sold_out()


func _on_layout_changed() -> void:
	recalculate_layout_capacity()


func _on_stock_changed(ingredient_id: String, _amount: int) -> void:
	recalculate_usage()
	ingredient_availability_changed.emit(ingredient_id, available_amount(ingredient_id), reserved_amount(ingredient_id))
	refresh_auto_sold_out()
	delivery_forecast_changed.emit(forecast_usage())


func _on_pending_delivery_batch_changed(_value: Dictionary) -> void:
	delivery_forecast_changed.emit(forecast_usage())


func _on_restaurant_state_changed(value: String) -> void:
	if value == "closed" and SimulationManager.orders.is_empty():
		reset_runtime_reservations()


func _batch_for_kind(root_batch: Dictionary, batch_kind: String) -> Dictionary:
	if batch_kind == "urgent":
		var urgent: Variant = root_batch.get("urgent", {})
		return (urgent as Dictionary).duplicate(true) if urgent is Dictionary else {}
	return root_batch.duplicate(true)


func _amounts_from_items(value: Variant) -> Dictionary:
	var result: Dictionary = {}
	if not value is Dictionary:
		return result
	for ingredient_id: String in value:
		var raw: Variant = (value as Dictionary)[ingredient_id]
		var amount := int((raw as Dictionary).get("amount", 0)) if raw is Dictionary else int(raw)
		if amount > 0 and DataRegistry.ingredients_by_id.has(ingredient_id):
			result[ingredient_id] = amount
	return result


func _normalize_requirements(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for ingredient_id: String in value:
		var amount := maxi(int(value[ingredient_id]), 0)
		if amount > 0 and GameState.stock.has(ingredient_id):
			result[ingredient_id] = amount
	return result


func _requirements_are_known(value: Dictionary) -> bool:
	for ingredient_id: String in value:
		if int(value[ingredient_id]) > 0 and not GameState.stock.has(ingredient_id):
			return false
	return true


func _new_reservation(requirements: Dictionary, consumed: Dictionary) -> Dictionary:
	return {
		"original": requirements.duplicate(true),
		"remaining": requirements.duplicate(true),
		"consumed": consumed.duplicate(true)
	}


func _add_item_units(target: Dictionary, items: Dictionary) -> void:
	for ingredient_id: String in items:
		var metadata := DataRegistry.storage_metadata_for_ingredient(ingredient_id)
		var storage_type := String(metadata.storage_type)
		target[storage_type] = int(target.get(storage_type, 0)) + maxi(int(items[ingredient_id]), 0) * maxi(int(metadata.storage_units), 1)


func _empty_storage_totals() -> Dictionary:
	return {"ambient": 0, "refrigerated": 0}


func _empty_overflow_flags() -> Dictionary:
	return {"ambient": false, "refrigerated": false}
