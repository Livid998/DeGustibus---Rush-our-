class_name CustomerCapacityPlanner
extends RefCounted

## Stateless table/party matcher used by traffic spawning. One table equals one
## concurrent group slot; chairs only determine which party sizes are compatible.


static func snapshot(world: RestaurantWorld, proposed_group_size: int = 0) -> Dictionary:
	var tables := _physical_tables(world)
	var maximum_table_capacity := 0
	var physical_seats := 0
	for table: Dictionary in tables:
		maximum_table_capacity = maxi(maximum_table_capacity, int(table.capacity))
		physical_seats += int(table.capacity)

	var groups := _active_group_records(world)
	const PROPOSED_ID := -1
	if proposed_group_size > 0:
		groups.append({
			"id": PROPOSED_ID,
			"node": null,
			"size": proposed_group_size,
			"source": "proposed",
		})

	var used_tables: Dictionary = {}
	var assigned_groups: Dictionary = {}
	var invalid_fixed_assignments := 0
	var occupied_groups := 0
	for table: Dictionary in tables:
		var owner := table.get("owner") as Node
		if owner == null:
			continue
		var owner_id := owner.get_instance_id()
		var owner_size := maxi(int(owner.get("group_size")), 1)
		used_tables[String(table.uid)] = true
		assigned_groups[owner_id] = true
		occupied_groups += 1
		if owner_size > int(table.capacity):
			invalid_fixed_assignments += 1

	var waiting: Array[Dictionary] = []
	for group: Dictionary in groups:
		if not assigned_groups.has(int(group.id)):
			waiting.append(group)
	waiting.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.size) == int(b.size):
			return int(a.id) < int(b.id)
		return int(a.size) > int(b.size)
	)

	var unmatched_groups := invalid_fixed_assignments
	var proposed_matched_to_table := false
	for group: Dictionary in waiting:
		var best_table_uid := ""
		var best_capacity := 999999
		for table: Dictionary in tables:
			var table_uid := String(table.uid)
			var capacity := int(table.capacity)
			if used_tables.has(table_uid) or capacity < int(group.size):
				continue
			if capacity < best_capacity:
				best_capacity = capacity
				best_table_uid = table_uid
		if best_table_uid.is_empty():
			unmatched_groups += 1
			continue
		used_tables[best_table_uid] = true
		assigned_groups[int(group.id)] = true
		if int(group.id) == PROPOSED_ID:
			proposed_matched_to_table = true

	var queue_buffer := maxi(int(DataRegistry.balance_value("traffic.queue_buffer_groups", 0)), 0)
	var absolute_cap := maxi(int(DataRegistry.balance_value("traffic.absolute_group_cap", 1)), 1)
	var physical_group_slots := tables.size()
	var theoretical_cap := (
		mini(physical_group_slots + queue_buffer, absolute_cap)
		if physical_group_slots > 0 else 0
	)
	var proposed_compatible := (
		proposed_group_size <= 0
		or proposed_group_size <= maximum_table_capacity
	)
	var accepts_proposed := (
		proposed_group_size > 0
		and proposed_compatible
		and groups.size() <= absolute_cap
		and groups.size() <= theoretical_cap
		and unmatched_groups <= queue_buffer
	)
	var queued_groups := 0
	for customer: Node in world.customer_queue:
		if customer != null and is_instance_valid(customer) and not customer.is_queued_for_deletion():
			queued_groups += 1
	return {
		"table_count": physical_group_slots,
		"seat_count": physical_seats,
		"table_capacities": tables.map(func(table: Dictionary): return int(table.capacity)),
		"maximum_table_capacity": maximum_table_capacity,
		"occupied_groups": occupied_groups,
		"queued_groups": queued_groups,
		"active_groups": groups.size() - (1 if proposed_group_size > 0 else 0),
		"unmatched_groups": unmatched_groups,
		"queue_buffer": queue_buffer,
		"absolute_cap": absolute_cap,
		"group_cap": theoretical_cap,
		"proposed_group_size": proposed_group_size,
		"proposed_compatible": proposed_compatible,
		"proposed_matched_to_table": proposed_matched_to_table,
		"accepts_proposed": accepts_proposed,
	}


static func spawnable_group_size(world: RestaurantWorld, unit_roll: float = -1.0) -> int:
	var weighted_sizes: Array[Dictionary] = [
		{"size": 1, "weight": 0.34},
		{"size": 2, "weight": 0.42},
		{"size": 3, "weight": 0.17},
		{"size": 4, "weight": 0.07},
	]
	var candidates: Array[Dictionary] = []
	var total_weight := 0.0
	for candidate: Dictionary in weighted_sizes:
		if not bool(snapshot(world, int(candidate.size)).get("accepts_proposed", false)):
			continue
		candidates.append(candidate)
		total_weight += float(candidate.weight)
	if candidates.is_empty() or total_weight <= 0.0:
		return 0
	var normalized_roll := clampf(unit_roll, 0.0, 0.999999) if unit_roll >= 0.0 else randf()
	var roll := normalized_roll * total_weight
	var accumulated := 0.0
	for candidate: Dictionary in candidates:
		accumulated += float(candidate.weight)
		if roll <= accumulated:
			return int(candidate.size)
	return int(candidates[-1].size)


static func table_count(world: RestaurantWorld) -> int:
	return _physical_tables(world).size()


static func seat_count(world: RestaurantWorld) -> int:
	var result := 0
	for table: Dictionary in _physical_tables(world):
		result += int(table.capacity)
	return result


static func _physical_tables(world: RestaurantWorld) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for object: PlacedObject in world.placed_objects.values():
		if object == null or not is_instance_valid(object) or not object.item_id.begins_with("table"):
			continue
		var capacity := world._seat_assignments_for_table(object).size()
		if capacity <= 0:
			continue
		var owner := world.table_occupants.get(object.uid) as Node
		result.append({
			"uid": object.uid,
			"capacity": capacity,
			"owner": owner if owner != null and is_instance_valid(owner) else null,
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.capacity) == int(b.capacity):
			return String(a.uid) < String(b.uid)
		return int(a.capacity) < int(b.capacity)
	)
	return result


static func _active_group_records(world: RestaurantWorld) -> Array[Dictionary]:
	var by_id: Dictionary = {}
	for customer: Node in SimulationManager.customers:
		_add_group(by_id, customer, "active")
	for customer: Node in world.customer_queue:
		_add_group(by_id, customer, "queue")
	for owner_value: Variant in world.table_occupants.values():
		if owner_value is Node:
			_add_group(by_id, owner_value as Node, "table")
	var result: Array[Dictionary] = []
	for value: Variant in by_id.values():
		if value is Dictionary:
			result.append(value as Dictionary)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.id) < int(b.id)
	)
	return result


static func _add_group(records: Dictionary, customer: Node, source: String) -> void:
	if customer == null or not is_instance_valid(customer) or customer.is_queued_for_deletion():
		return
	var instance_id := customer.get_instance_id()
	if records.has(instance_id):
		var existing: Dictionary = records[instance_id]
		if not String(existing.get("source", "")).contains(source):
			existing.source = "%s+%s" % [String(existing.get("source", "")), source]
		return
	records[instance_id] = {
		"id": instance_id,
		"node": customer,
		"size": maxi(int(customer.get("group_size")), 1),
		"source": source,
	}
