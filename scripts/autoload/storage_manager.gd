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


## Returns the capacity-safe subset of a requested delivery. Existing stock and
## (by default) both pending batches are treated as already occupying space.
## Allocation is deterministic so the same save and cart always yield the same
## accepted/rejected split.
func plan_delivery(requested_items: Dictionary, include_pending: bool = true) -> Dictionary:
	var requested := _amounts_from_items(requested_items)
	var occupied := usage_snapshot()
	if include_pending:
		_add_item_units(occupied, pending_items("normal"))
		_add_item_units(occupied, pending_items("urgent"))
	var accepted: Dictionary = {}
	var rejected: Dictionary = {}
	var remaining_units := _empty_storage_totals()
	for storage_type: String in STORAGE_TYPES:
		remaining_units[storage_type] = maxi(
			int(_capacity.get(storage_type, 0)) - int(occupied.get(storage_type, 0)),
			0
		)
	var ingredient_ids: Array = requested.keys()
	ingredient_ids.sort()
	for ingredient_value: Variant in ingredient_ids:
		var ingredient_id := String(ingredient_value)
		var amount := maxi(int(requested.get(ingredient_id, 0)), 0)
		var metadata := DataRegistry.storage_metadata_for_ingredient(ingredient_id)
		var storage_type := String(metadata.storage_type)
		var units_per_item := maxi(int(metadata.storage_units), 1)
		var accepted_amount := mini(amount, int(remaining_units.get(storage_type, 0)) / units_per_item)
		if accepted_amount > 0:
			accepted[ingredient_id] = accepted_amount
			remaining_units[storage_type] = int(remaining_units.get(storage_type, 0)) - accepted_amount * units_per_item
		if accepted_amount < amount:
			rejected[ingredient_id] = amount - accepted_amount
	var accepted_forecast := occupied.duplicate(true)
	_add_item_units(accepted_forecast, accepted)
	var requested_forecast := occupied.duplicate(true)
	_add_item_units(requested_forecast, requested)
	var blocked_types: Array[String] = []
	for ingredient_id: String in rejected:
		var storage_type := String(DataRegistry.storage_metadata_for_ingredient(ingredient_id).storage_type)
		if not blocked_types.has(storage_type):
			blocked_types.append(storage_type)
	return {
		"valid": not accepted.is_empty(),
		"fully_accepted": not requested.is_empty() and rejected.is_empty(),
		"requested_items": requested,
		"accepted_items": accepted,
		"rejected_items": rejected,
		"forecast": accepted_forecast,
		"requested_forecast": requested_forecast,
		"capacity": capacity_snapshot(),
		"remaining_units": remaining_units,
		"blocked_types": blocked_types,
	}


func max_orderable_amount(ingredient_id: String, additional_items: Dictionary = {}, include_pending: bool = true) -> int:
	if not DataRegistry.ingredients_by_id.has(ingredient_id):
		return 0
	var occupied := usage_snapshot()
	if include_pending:
		_add_item_units(occupied, pending_items("normal"))
		_add_item_units(occupied, pending_items("urgent"))
	_add_item_units(occupied, _amounts_from_items(additional_items))
	var metadata := DataRegistry.storage_metadata_for_ingredient(ingredient_id)
	var storage_type := String(metadata.storage_type)
	var units_per_item := maxi(int(metadata.storage_units), 1)
	var free_units := maxi(int(_capacity.get(storage_type, 0)) - int(occupied.get(storage_type, 0)), 0)
	return free_units / units_per_item


func validate_delivery_capacity(additional_items: Dictionary) -> Dictionary:
	var plan := plan_delivery(additional_items)
	var additions: Dictionary = plan.requested_items
	var added_units := _empty_storage_totals()
	_add_item_units(added_units, additions)
	return {
		"valid": bool(plan.fully_accepted),
		"forecast": plan.requested_forecast,
		"capacity": capacity_snapshot(),
		"added_units": added_units,
		"blocked_types": plan.blocked_types,
		"accepted_items": plan.accepted_items,
		"rejected_items": plan.rejected_items,
	}


func capacity_snapshot_for_layout(layout_records: Array) -> Dictionary:
	var result := _empty_storage_totals()
	for record_value: Variant in layout_records:
		if not record_value is Dictionary:
			continue
		var definition: Dictionary = DataRegistry.build_by_id.get(String((record_value as Dictionary).get("item", "")), {})
		var contribution: Variant = definition.get("storage_capacity", {})
		if not contribution is Dictionary:
			continue
		for storage_type: String in STORAGE_TYPES:
			result[storage_type] = int(result[storage_type]) + maxi(int((contribution as Dictionary).get(storage_type, 0)), 0)
	return result


## Builder guard: call this with the proposed layout before committing a
## removal. Pending paid deliveries are included by default.
func validate_storage_capacity_for_layout(layout_records: Array, include_pending: bool = true) -> Dictionary:
	var proposed_capacity := capacity_snapshot_for_layout(layout_records)
	var required := usage_snapshot()
	if include_pending:
		_add_item_units(required, pending_items("normal"))
		_add_item_units(required, pending_items("urgent"))
	var blocked_types: Array[String] = []
	for storage_type: String in STORAGE_TYPES:
		if int(required.get(storage_type, 0)) > int(proposed_capacity.get(storage_type, 0)):
			blocked_types.append(storage_type)
	return {
		"valid": blocked_types.is_empty(),
		"capacity": proposed_capacity,
		"required": required,
		"blocked_types": blocked_types,
	}


func can_remove_storage_item(layout_uid: String, include_pending: bool = true) -> Dictionary:
	var removed_uids: Dictionary = {layout_uid: true}
	var changed := true
	while changed:
		changed = false
		for record: Dictionary in GameState.layout:
			var uid := String(record.get("uid", ""))
			var support_uid := String(record.get("support_uid", ""))
			if not uid.is_empty() and removed_uids.has(support_uid) and not removed_uids.has(uid):
				removed_uids[uid] = true
				changed = true
	var proposed: Array = []
	var found := false
	for record: Dictionary in GameState.layout:
		var uid := String(record.get("uid", ""))
		if uid == layout_uid:
			found = true
		if removed_uids.has(uid):
			continue
		proposed.append(record.duplicate(true))
	if not found:
		return {
			"valid": false,
			"capacity": capacity_snapshot(),
			"required": forecast_usage() if include_pending else usage_snapshot(),
			"blocked_types": [],
			"reason": "not_found",
			"removed_uids": [],
		}
	var result := validate_storage_capacity_for_layout(proposed, include_pending)
	result.reason = "" if bool(result.valid) else "capacity"
	result.removed_uids = removed_uids.keys()
	return result


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


## Single source of truth for the "can this save continue?" warning. A future
## paid delivery counts as recoverable; a recipe that requires a locked
## ingredient does not.
func soft_lock_snapshot() -> Dictionary:
	recalculate_layout_capacity()
	var active_recipe_ids: Array[String] = []
	var producible_recipe_ids: Array[String] = []
	var pending_recipe_ids: Array[String] = []
	var orderable_recipe_ids: Array[String] = []
	for recipe: Dictionary in DataRegistry.recipes:
		var recipe_id := String(recipe.get("id", ""))
		var state: Dictionary = GameState.menu.get(recipe_id, {})
		if not bool(state.get("unlocked", false)) or not bool(state.get("active", false)) or bool(state.get("manual_paused", false)):
			continue
		active_recipe_ids.append(recipe_id)
		if is_recipe_producible(recipe):
			producible_recipe_ids.append(recipe_id)
			continue
		var requirements := DataRegistry.recipe_raw_requirements(recipe)
		var missing_after_pending: Dictionary = {}
		var pending_can_complete := true
		for ingredient_id: String in requirements:
			var required := int(requirements[ingredient_id])
			var eventual := available_amount(ingredient_id) + pending_amount(ingredient_id, "all")
			if eventual < required:
				pending_can_complete = false
				missing_after_pending[ingredient_id] = required - eventual
		if pending_can_complete:
			pending_recipe_ids.append(recipe_id)
			continue
		var ingredients_unlocked := true
		var purchase_cost := 0.0
		for ingredient_id: String in missing_after_pending:
			if not bool(GameState.stock.get(ingredient_id, {}).get("unlocked", false)):
				ingredients_unlocked = false
				break
			purchase_cost += float(DataRegistry.ingredients_by_id.get(ingredient_id, {}).get("cost", 0.0)) * int(missing_after_pending[ingredient_id])
		var purchase_plan := plan_delivery(missing_after_pending)
		if ingredients_unlocked and bool(purchase_plan.fully_accepted) and GameState.can_afford(int(ceil(purchase_cost))):
			orderable_recipe_ids.append(recipe_id)
	var recovery_plan := build_recovery_plan()
	var soft_locked := producible_recipe_ids.is_empty() and pending_recipe_ids.is_empty() and orderable_recipe_ids.is_empty()
	return {
		"soft_locked": soft_locked,
		"active_recipe_ids": active_recipe_ids,
		"producible_recipe_ids": producible_recipe_ids,
		"pending_recipe_ids": pending_recipe_ids,
		"orderable_recipe_ids": orderable_recipe_ids,
		"capacity": capacity_snapshot(),
		"usage": usage_snapshot(),
		"forecast": forecast_usage(),
		"overflow": overflow_snapshot(),
		"discardable_items": _discardable_stock_snapshot(),
		"recovery_available": soft_locked and bool(recovery_plan.get("eligible", false)),
		"recovery_plan": recovery_plan,
	}


## Builds a deterministic, non-mutating emergency repair. The executor lives in
## EconomyManager so preview and confirmation use the exact same payload.
func build_recovery_plan() -> Dictionary:
	recalculate_layout_capacity()
	var selected_recipe: Dictionary = {}
	var selected_score := INF
	for recipe: Dictionary in DataRegistry.recipes:
		var recipe_id := String(recipe.get("id", ""))
		var state: Dictionary = GameState.menu.get(recipe_id, {})
		if not bool(state.get("unlocked", false)):
			continue
		var active_penalty := 0.0 if bool(state.get("active", false)) else 1000000.0
		var score := active_penalty + DataRegistry.estimate_recipe_cost(recipe)
		if selected_recipe.is_empty() or score < selected_score or (is_equal_approx(score, selected_score) and recipe_id < String(selected_recipe.get("id", ""))):
			selected_recipe = recipe
			selected_score = score
	if selected_recipe.is_empty():
		return {
			"eligible": false,
			"viable": false,
			"reason": "no_unlocked_recipe",
			"recipe_id": "",
			"cancel_batches": [],
			"discard_items": {},
			"grant_items": {},
		}
	var recipe_id := String(selected_recipe.get("id", ""))
	var requirements := DataRegistry.recipe_raw_requirements(selected_recipe)
	var grant_items: Dictionary = {}
	var required_units := _empty_storage_totals()
	for ingredient_id: String in requirements:
		var missing := maxi(int(requirements[ingredient_id]) - available_amount(ingredient_id), 0)
		if missing <= 0:
			continue
		grant_items[ingredient_id] = missing
		var metadata := DataRegistry.storage_metadata_for_ingredient(ingredient_id)
		required_units[String(metadata.storage_type)] = int(required_units.get(String(metadata.storage_type), 0)) + missing * maxi(int(metadata.storage_units), 1)
	var cancel_batches: Array[String] = []
	var pending_refund := 0
	for batch_kind: String in ["normal", "urgent"]:
		var batch := _batch_for_kind(GameState.pending_delivery_batch, batch_kind)
		var items := _amounts_from_items(batch.get("items", {}))
		if items.is_empty():
			continue
		cancel_batches.append(batch_kind)
		for ingredient_id: String in items:
			var item: Dictionary = batch.get("items", {}).get(ingredient_id, {})
			pending_refund += int(round(float(item.get("unit_cost", DataRegistry.ingredients_by_id.get(ingredient_id, {}).get("cost", 0.0))) * int(items[ingredient_id])))
	var simulated_usage := usage_snapshot()
	var deficit := _empty_storage_totals()
	for storage_type: String in STORAGE_TYPES:
		deficit[storage_type] = maxi(
			int(simulated_usage.get(storage_type, 0)) + int(required_units.get(storage_type, 0)) - int(_capacity.get(storage_type, 0)),
			0
		)
	var discard_items: Dictionary = {}
	var candidates: Array[Dictionary] = []
	for ingredient_id: String in GameState.stock:
		var metadata := DataRegistry.storage_metadata_for_ingredient(ingredient_id)
		var storage_type := String(metadata.storage_type)
		if int(deficit.get(storage_type, 0)) <= 0:
			continue
		var keep_amount := int(requirements.get(ingredient_id, 0))
		var discardable := maxi(available_amount(ingredient_id) - keep_amount, 0)
		if discardable <= 0:
			continue
		candidates.append({
			"ingredient_id": ingredient_id,
			"storage_type": storage_type,
			"storage_units": maxi(int(metadata.storage_units), 1),
			"amount": discardable,
			"is_recipe_input": requirements.has(ingredient_id),
			"average_cost": float(GameState.stock[ingredient_id].get("average_cost", 0.0)),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.is_recipe_input) != bool(b.is_recipe_input):
			return not bool(a.is_recipe_input)
		if not is_equal_approx(float(a.average_cost), float(b.average_cost)):
			return float(a.average_cost) < float(b.average_cost)
		return String(a.ingredient_id) < String(b.ingredient_id)
	)
	for candidate: Dictionary in candidates:
		var storage_type := String(candidate.storage_type)
		var units_needed := int(deficit.get(storage_type, 0))
		if units_needed <= 0:
			continue
		var units_per_item := int(candidate.storage_units)
		var amount := mini(int(candidate.amount), ceili(float(units_needed) / float(units_per_item)))
		if amount <= 0:
			continue
		discard_items[String(candidate.ingredient_id)] = amount
		deficit[storage_type] = maxi(units_needed - amount * units_per_item, 0)
	var viable := true
	for storage_type: String in STORAGE_TYPES:
		if int(deficit.get(storage_type, 0)) > 0:
			viable = false
			break
	var already_used := bool(GameState.progress.get("emergency_recovery_used", false))
	return {
		"eligible": viable and not already_used,
		"viable": viable,
		"reason": "already_used" if already_used else ("insufficient_capacity" if not viable else ""),
		"recipe_id": recipe_id,
		"activate_recipe": not bool(GameState.menu.get(recipe_id, {}).get("active", false)),
		"cancel_batches": cancel_batches,
		"pending_refund": pending_refund,
		"discard_items": discard_items,
		"grant_items": grant_items,
		"capacity": capacity_snapshot(),
		"usage": usage_snapshot(),
	}


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


func _discardable_stock_snapshot() -> Dictionary:
	var result: Dictionary = {}
	for ingredient_id: String in GameState.stock:
		var amount := available_amount(ingredient_id)
		if amount > 0:
			result[ingredient_id] = amount
	return result


func _add_item_units(target: Dictionary, items: Dictionary) -> void:
	for ingredient_id: String in items:
		var metadata := DataRegistry.storage_metadata_for_ingredient(ingredient_id)
		var storage_type := String(metadata.storage_type)
		target[storage_type] = int(target.get(storage_type, 0)) + maxi(int(items[ingredient_id]), 0) * maxi(int(metadata.storage_units), 1)


func _empty_storage_totals() -> Dictionary:
	return {"ambient": 0, "refrigerated": 0}


func _empty_overflow_flags() -> Dictionary:
	return {"ambient": false, "refrigerated": false}
