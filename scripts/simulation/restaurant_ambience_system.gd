class_name RestaurantAmbienceSystem
extends Node

## Event-driven, presentation-agnostic core for dining-room beauty, global
## cleanliness and visible pest incidents. It deliberately does not mutate
## customer satisfaction, tips or reputation: consumers import the structured
## causes returned by experience_contribution() / review_context().

signal ambience_changed(snapshot: Dictionary)
signal pest_warning_changed(active: bool, context: Dictionary)
signal pest_spawn_requested(kind: String, context: Dictionary)
signal pest_resolved(kind: String, context: Dictionary)

const ROOM_DINING := "dining"
const PEST_INSECT := "insect"
const PEST_MOUSE := "mouse"

var source_world: Node
var persist_to_game_state := false

var _settings: Dictionary = {}
var _snapshot: Dictionary = {}
var _last_layout_objects: Array = []
var _last_cleanliness_sources: Dictionary = {}
var _last_dining_context: Dictionary = {}

var _active_pests: Array[Dictionary] = []
var _warning := false
var _pest_elapsed := 0.0
var _pending_pest_kind := ""
var _spawn_serial := 0
var _last_persisted_second := -1


func _init() -> void:
	_settings = _default_settings()
	_snapshot = _empty_snapshot()


func configure(world: Node = null, overrides: Dictionary = {}, persist: bool = false) -> void:
	source_world = world
	persist_to_game_state = persist
	_settings = _default_settings()
	for key: Variant in overrides:
		_settings[key] = overrides[key]
	_normalize_settings()
	_active_pests.clear()
	_warning = false
	_pest_elapsed = 0.0
	_pending_pest_kind = ""
	_spawn_serial = 0
	_last_persisted_second = -1
	if persist_to_game_state:
		_restore_persistent_state()
	_snapshot = _empty_snapshot()


func settings_snapshot() -> Dictionary:
	return _settings.duplicate(true)


func current_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func refresh_from_world() -> Dictionary:
	if source_world == null or not is_instance_valid(source_world):
		return recalculate([], {}, {})
	var layout_objects: Array = []
	var raw_objects: Variant = _property_value(source_world, &"placed_objects", {})
	if raw_objects is Dictionary:
		layout_objects.assign((raw_objects as Dictionary).values())
	var cleanliness_sources := cleanliness_sources_from_world(source_world)
	var dining_context := dining_context_from_world(source_world)
	return recalculate(layout_objects, cleanliness_sources, dining_context)


func recalculate(layout_objects: Array, cleanliness_sources: Dictionary, dining_context: Dictionary = {}) -> Dictionary:
	# Keep shallow copies: production layout entries can contain live Nodes.
	_last_layout_objects = layout_objects.duplicate(false)
	_last_cleanliness_sources = cleanliness_sources.duplicate(true)
	_last_dining_context = dining_context.duplicate(true)

	var old_warning := _warning
	var cleanliness := calculate_cleanliness(cleanliness_sources, _active_pests)
	if float(cleanliness.score) >= float(_settings.pest_threshold):
		_pest_elapsed = 0.0
		_pending_pest_kind = ""
		_warning = false
	var beauty := calculate_beauty(layout_objects, dining_context)
	var beauty_multiplier := _cleanliness_beauty_multiplier(float(cleanliness.score))
	var effective_beauty := clampf(float(beauty.base_score) * beauty_multiplier, 0.0, 100.0)

	_snapshot = {
		"revision": int(_snapshot.get("revision", 0)) + 1,
		"beauty_score": effective_beauty,
		"beauty_base_score": float(beauty.base_score),
		"beauty_raw": float(beauty.diminished_total),
		"beauty_undiminished": float(beauty.undiminished_total),
		"beauty_target": float(beauty.target),
		"beauty_cleanliness_multiplier": beauty_multiplier,
		"beauty_groups": beauty.groups.duplicate(true),
		"cleanliness_score": float(cleanliness.score),
		"cleanliness_level": String(cleanliness.level),
		"cleanliness": cleanliness.duplicate(true),
		"pest": _pest_snapshot(),
		"dining_capacity": int(beauty.capacity),
		"dining_area_cells": int(beauty.area_cells)
	}
	_sync_elapsed_into_snapshot()
	_persist_state(true)
	ambience_changed.emit(current_snapshot())
	if old_warning != _warning:
		pest_warning_changed.emit(_warning, warning_context())
	return current_snapshot()


func calculate_beauty(layout_objects: Array, dining_context: Dictionary = {}) -> Dictionary:
	var room_scope := String(dining_context.get("room_scope", ROOM_DINING))
	var grouped_values: Dictionary = {}
	var counted_entries := 0
	for entry: Variant in layout_objects:
		var definition := _definition_from_entry(entry)
		if definition.is_empty() or float(definition.get("beauty", 0.0)) <= 0.0:
			continue
		if String(definition.get("room_scope", "")) != room_scope:
			continue
		if not _entry_is_in_room(entry, dining_context):
			continue
		var group := String(definition.get("beauty_group", definition.get("id", "ungrouped")))
		if group.is_empty():
			group = String(definition.get("id", "ungrouped"))
		if not grouped_values.has(group):
			grouped_values[group] = []
		(grouped_values[group] as Array).append(float(definition.beauty))
		counted_entries += 1

	var groups: Dictionary = {}
	var undiminished_total := 0.0
	var diminished_total := 0.0
	var duplicate_multipliers: Array = _settings.duplicate_multipliers
	for group: String in grouped_values:
		var values: Array = grouped_values[group]
		values.sort()
		values.reverse()
		var group_undiminished := 0.0
		var group_diminished := 0.0
		var contributions: Array[float] = []
		for index: int in values.size():
			var value := float(values[index])
			var multiplier := float(duplicate_multipliers[mini(index, duplicate_multipliers.size() - 1)])
			group_undiminished += value
			group_diminished += value * multiplier
			contributions.append(value * multiplier)
		undiminished_total += group_undiminished
		diminished_total += group_diminished
		groups[group] = {
			"count": values.size(),
			"undiminished": group_undiminished,
			"diminished": group_diminished,
			"contributions": contributions
		}

	var capacity := maxi(int(dining_context.get("capacity", dining_context.get("dining_capacity", 0))), 0)
	var area_cells := maxi(int(dining_context.get("area_cells", 0)), 0)
	var target := maxf(
		float(_settings.beauty_target_base)
			+ float(capacity) * float(_settings.beauty_target_per_seat)
			+ float(area_cells) * float(_settings.beauty_target_per_cell),
		1.0
	)
	return {
		"base_score": clampf(diminished_total / target * 100.0, 0.0, 100.0),
		"undiminished_total": undiminished_total,
		"diminished_total": diminished_total,
		"target": target,
		"groups": groups,
		"entry_count": counted_entries,
		"capacity": capacity,
		"area_cells": area_cells,
		"room_scope": room_scope
	}


func calculate_cleanliness(sources: Dictionary, visible_pests: Array = []) -> Dictionary:
	var dirty_tables := maxi(int(sources.get("dirty_tables", 0)), 0)
	var dirty_dishes := maxi(int(sources.get("dirty_dishes", 0)), 0)
	var spills := maxi(int(sources.get("spills", 0)), 0)
	var kitchen_dirt := maxf(float(sources.get("kitchen_dirt", 0.0)), 0.0)
	var insect_count := 0
	var mouse_count := 0
	for raw_pest: Variant in visible_pests:
		var kind := _pest_kind(raw_pest)
		if kind == PEST_MOUSE:
			mouse_count += 1
		elif kind == PEST_INSECT:
			insect_count += 1

	var deductions := {
		"dirty_tables": float(dirty_tables) * float(_settings.dirty_table_penalty),
		"dirty_dishes": float(dirty_dishes) * float(_settings.dirty_dish_penalty),
		"spills": float(spills) * float(_settings.spill_penalty),
		"kitchen_dirt": kitchen_dirt * float(_settings.kitchen_dirt_penalty),
		"visible_insects": float(insect_count) * float(_settings.insect_penalty),
		"visible_mice": float(mouse_count) * float(_settings.mouse_penalty)
	}
	var total_deduction := 0.0
	for value: Variant in deductions.values():
		total_deduction += float(value)
	var score := clampf(float(_settings.clean_score) - total_deduction, 0.0, float(_settings.clean_score))
	return {
		"score": score,
		"level": _cleanliness_level(score),
		"dirty_tables": dirty_tables,
		"dirty_dishes": dirty_dishes,
		"spills": spills,
		"kitchen_dirt": kitchen_dirt,
		"visible_insects": insect_count,
		"visible_mice": mouse_count,
		"deductions": deductions,
		"total_deduction": total_deduction,
		"below_pest_threshold_seconds": _pest_elapsed
	}


func cleanliness_sources_from_world(world: Node) -> Dictionary:
	var dirty_tables := 0
	var dirty_dishes := 0
	var table_records: Variant = _property_value(world, &"table_dirty_records", {})
	if table_records is Dictionary:
		for raw_record: Variant in (table_records as Dictionary).values():
			if not raw_record is Dictionary:
				continue
			var record := raw_record as Dictionary
			if String(record.get("state", "dirty")) not in ["clean", "resolved"]:
				dirty_tables += 1
				var containers: Variant = record.get("container_kinds", [])
				var nodes: Variant = record.get("nodes", [])
				var container_count := (containers as Array).size() if containers is Array else 0
				var node_count := (nodes as Array).size() if nodes is Array else 0
				dirty_dishes += maxi(container_count, node_count)
	var wash_batches: Variant = _property_value(world, &"wash_batches", {})
	if wash_batches is Dictionary:
		for raw_batch: Variant in (wash_batches as Dictionary).values():
			if not raw_batch is Dictionary:
				# Legacy saves represented each batch as a boolean marker.
				dirty_dishes += 1
				continue
			var batch := raw_batch as Dictionary
			if String(batch.get("state", "waiting")) in ["clean", "cleaned", "resolved"]:
				continue
			dirty_dishes += maxi(int(batch.get("dish_count", 1)), 0)
	var spills := 0
	var spill_records: Variant = _property_value(world, &"spill_records", {})
	if spill_records is Dictionary:
		for raw_spill: Variant in (spill_records as Dictionary).values():
			if raw_spill is Dictionary and String((raw_spill as Dictionary).get("state", "dirty")) not in ["clean", "resolved"]:
				spills += 1
	var saved_cleanliness: Dictionary = GameState.cleanliness_state if GameState.cleanliness_state is Dictionary else {}
	var kitchen_dirt := maxf(
		float(_property_value(world, &"kitchen_dirt", saved_cleanliness.get("kitchen_dirt", 0.0))),
		0.0
	)
	return {
		"dirty_tables": dirty_tables,
		"dirty_dishes": dirty_dishes,
		"spills": spills,
		"kitchen_dirt": kitchen_dirt
	}


func dining_context_from_world(world: Node) -> Dictionary:
	var dining_cells: Dictionary = {}
	var floor_tiles: Variant = _property_value(world, &"floor_tiles", {})
	if floor_tiles is Dictionary:
		for raw_cell: Variant in (floor_tiles as Dictionary):
			if String((floor_tiles as Dictionary)[raw_cell]) == "floor_dining":
				dining_cells[raw_cell] = true
	var capacity := 0
	var placed_objects: Variant = _property_value(world, &"placed_objects", {})
	if placed_objects is Dictionary:
		for entry: Variant in (placed_objects as Dictionary).values():
			var definition := _definition_from_entry(entry)
			if String(definition.get("placement", "")) != "seat":
				continue
			var cell := _cell_from_entry(entry)
			if dining_cells.is_empty() or cell == Vector2i(-99999, -99999) or dining_cells.has(cell):
				capacity += 1
	return {
		"room_scope": ROOM_DINING,
		"capacity": capacity,
		"area_cells": dining_cells.size() if not dining_cells.is_empty() else int(_settings.default_dining_area_cells),
		"dining_cells": dining_cells
	}


func advance_pest_risk(delta_seconds: float) -> Dictionary:
	if _snapshot.is_empty():
		recalculate(_last_layout_objects, _last_cleanliness_sources, _last_dining_context)
	var score := float(_snapshot.get("cleanliness_score", _settings.clean_score))
	var old_warning := _warning
	var spawn_kind := ""
	var elapsed_before := _pest_elapsed
	if score < float(_settings.pest_threshold):
		_pest_elapsed += maxf(delta_seconds, 0.0)
		var warning_at := float(_settings.pest_delay_seconds) * float(_settings.pest_warning_ratio)
		if _pest_elapsed >= warning_at and _active_pests.is_empty():
			_warning = true
		if (
			_pest_elapsed >= float(_settings.pest_delay_seconds)
			and _active_pests.is_empty()
			and _pending_pest_kind.is_empty()
		):
			_spawn_serial += 1
			spawn_kind = _choose_pest_kind(score)
			_pending_pest_kind = spawn_kind
			_warning = true
	else:
		_pest_elapsed = 0.0
		_pending_pest_kind = ""
		_warning = false

	_sync_elapsed_into_snapshot()
	var whole_second_changed := floori(elapsed_before) != floori(_pest_elapsed)
	if whole_second_changed or old_warning != _warning or not spawn_kind.is_empty():
		_persist_state(true)
	if old_warning != _warning:
		pest_warning_changed.emit(_warning, warning_context())
		ambience_changed.emit(current_snapshot())
	if not spawn_kind.is_empty():
		var request_context := warning_context()
		request_context.kind = spawn_kind
		request_context.visible = false
		request_context.incident_id = "%s_%04d" % [spawn_kind, _spawn_serial]
		pest_spawn_requested.emit(spawn_kind, request_context)
		ambience_changed.emit(current_snapshot())
	return {
		"warning": _warning,
		"elapsed": _pest_elapsed,
		"risk_progress": _pest_risk_progress(),
		"spawn_requested": spawn_kind,
		"pending_kind": _pending_pest_kind
	}


func register_visible_pest(kind: String, incident_id: String = "") -> String:
	var normalized_kind := _pest_kind(kind)
	if normalized_kind.is_empty():
		return ""
	if incident_id.is_empty():
		_spawn_serial += 1
		incident_id = "%s_%04d" % [normalized_kind, _spawn_serial]
	for record: Dictionary in _active_pests:
		if String(record.id) == incident_id:
			return incident_id
	_active_pests.append({
		"id": incident_id,
		"kind": normalized_kind,
		"visible": true
	})
	_pending_pest_kind = ""
	_warning = false
	recalculate(_last_layout_objects, _last_cleanliness_sources, _last_dining_context)
	return incident_id


func confirm_pest_spawn(kind: String, incident_id: String = "") -> String:
	return register_visible_pest(kind, incident_id)


func resolve_pest(incident_id_or_kind: String, reason: String = "cleaned") -> bool:
	var normalized_kind := _pest_kind(incident_id_or_kind)
	for index: int in range(_active_pests.size() - 1, -1, -1):
		var record: Dictionary = _active_pests[index]
		if String(record.id) != incident_id_or_kind and String(record.kind) != normalized_kind:
			continue
		_active_pests.remove_at(index)
		recalculate(_last_layout_objects, _last_cleanliness_sources, _last_dining_context)
		pest_resolved.emit(String(record.kind), {
			"id": String(record.id),
			"reason": reason,
			"cleanliness_score": float(_snapshot.cleanliness_score)
		})
		return true
	return false


func resolve_all_pests(reason: String = "cleaned") -> int:
	var records := _active_pests.duplicate(true)
	if records.is_empty():
		return 0
	_active_pests.clear()
	recalculate(_last_layout_objects, _last_cleanliness_sources, _last_dining_context)
	for record: Dictionary in records:
		pest_resolved.emit(String(record.kind), {
			"id": String(record.id),
			"reason": reason,
			"cleanliness_score": float(_snapshot.cleanliness_score)
		})
	return records.size()


func visible_pest_kinds() -> Array[String]:
	var result: Array[String] = []
	for record: Dictionary in _active_pests:
		var kind := String(record.kind)
		if not result.has(kind):
			result.append(kind)
	return result


func experience_contribution() -> Dictionary:
	var beauty_score := float(_snapshot.get("beauty_score", 0.0))
	var cleanliness_score := float(_snapshot.get("cleanliness_score", _settings.clean_score))
	var causes: Array[Dictionary] = []
	var beauty_cause := _beauty_cause(beauty_score)
	if not beauty_cause.is_empty():
		causes.append(beauty_cause)
	var cleanliness_cause := _cleanliness_cause(cleanliness_score)
	if not cleanliness_cause.is_empty():
		causes.append(cleanliness_cause)
	for kind: String in visible_pest_kinds():
		causes.append(_pest_cause(kind))
	var score_delta := 0.0
	for cause: Dictionary in causes:
		score_delta += float(cause.delta)
	return {
		"beauty_score": beauty_score,
		"cleanliness_score": cleanliness_score,
		"visible_pests": visible_pest_kinds(),
		"causes": causes,
		"score_delta": score_delta
	}


func review_context() -> Dictionary:
	var contribution := experience_contribution()
	var tags: Array[String] = []
	for cause: Dictionary in contribution.causes:
		for tag: Variant in cause.get("tags", []):
			var normalized := String(tag)
			if not tags.has(normalized):
				tags.append(normalized)
	var incident_ids: Array[String] = []
	for record: Dictionary in _active_pests:
		incident_ids.append(String(record.id))
	return {
		"beauty_score": float(contribution.beauty_score),
		"cleanliness_score": float(contribution.cleanliness_score),
		"visible_pests": contribution.visible_pests.duplicate(),
		"incident_ids": incident_ids,
		"tags": tags,
		"causes": contribution.causes.duplicate(true),
		"score_delta": float(contribution.score_delta)
	}


func warning_context() -> Dictionary:
	var active_kinds := visible_pest_kinds()
	var icon_id := "insect"
	if active_kinds.has(PEST_MOUSE):
		icon_id = "mouse"
	var active := not active_kinds.is_empty()
	var message := ""
	if active:
		message = "Infestazione visibile: assegna subito un tuttofare."
	elif _warning:
		message = "Rischio infestazione: dai priorità a piatti, macchie e tavoli sporchi."
	return {
		"visible": active or _warning,
		"active_incident": active,
		"warning": _warning,
		"message": message,
		"icon_id": icon_id,
		"risk_progress": _pest_risk_progress(),
		"elapsed": _pest_elapsed,
		"threshold": float(_settings.pest_threshold),
		"pending_kind": _pending_pest_kind,
		"cleanliness_score": float(_snapshot.get("cleanliness_score", _settings.clean_score))
	}


func handyman_priority_context() -> Dictionary:
	var cleanliness: Dictionary = _snapshot.get("cleanliness", {})
	var actions: Array[String] = []
	if not visible_pest_kinds().is_empty():
		actions.append("remove_pests")
	if int(cleanliness.get("spills", 0)) > 0:
		actions.append("clean_spills")
	if int(cleanliness.get("dirty_tables", 0)) > 0:
		actions.append("bus_tables")
	if int(cleanliness.get("dirty_dishes", 0)) > 0:
		actions.append("wash_dishes")
	if float(cleanliness.get("kitchen_dirt", 0.0)) > 0.0:
		actions.append("clean_kitchen")
	var priority := "normal"
	if not visible_pest_kinds().is_empty():
		priority = "critical"
	elif _warning:
		priority = "high"
	elif float(_snapshot.get("cleanliness_score", _settings.clean_score)) < float(_settings.dirty_threshold):
		priority = "elevated"
	return {
		"priority": priority,
		"recommended_actions": actions,
		"warning": warning_context()
	}


func _default_settings() -> Dictionary:
	return {
		"clean_score": float(DataRegistry.balance_value("cleanliness.clean_score", 100.0)),
		"dirty_threshold": float(DataRegistry.balance_value("cleanliness.dirty_threshold", 60.0)),
		"very_dirty_threshold": float(DataRegistry.balance_value("cleanliness.very_dirty_threshold", 30.0)),
		"pest_threshold": float(DataRegistry.balance_value("cleanliness.pest_threshold", 18.0)),
		"pest_delay_seconds": float(DataRegistry.balance_value("cleanliness.pest_delay_seconds", 60.0)),
		"pest_warning_ratio": float(DataRegistry.balance_value("cleanliness.pest_warning_ratio", 0.50)),
		"mouse_score_threshold": float(DataRegistry.balance_value("cleanliness.mouse_score_threshold", 6.0)),
		"mouse_every": int(DataRegistry.balance_value("cleanliness.mouse_every_incidents", 4)),
		"dirty_table_penalty": float(DataRegistry.balance_value("cleanliness.dirty_table_penalty", 11.0)),
		"dirty_dish_penalty": float(DataRegistry.balance_value("cleanliness.dirty_dish_penalty", 3.0)),
		"spill_penalty": float(DataRegistry.balance_value("cleanliness.spill_penalty", 13.0)),
		"kitchen_dirt_penalty": float(DataRegistry.balance_value("cleanliness.kitchen_dirt_penalty", 1.0)),
		"insect_penalty": float(DataRegistry.balance_value("cleanliness.visible_insect_penalty", 8.0)),
		"mouse_penalty": float(DataRegistry.balance_value("cleanliness.visible_mouse_penalty", 16.0)),
		"duplicate_multipliers": DataRegistry.balance_value("beauty.duplicate_multipliers", [1.0, 1.0, 0.65, 0.45, 0.25]),
		"beauty_target_base": float(DataRegistry.balance_value("beauty.target_base", 12.0)),
		"beauty_target_per_seat": float(DataRegistry.balance_value("beauty.target_per_seat", 2.0)),
		"beauty_target_per_cell": float(DataRegistry.balance_value("beauty.target_per_cell", 0.05)),
		"beauty_cleanliness_floor": float(DataRegistry.balance_value("beauty.cleanliness_floor_multiplier", 0.35)),
		"default_dining_area_cells": int(DataRegistry.balance_value("beauty.default_dining_area_cells", 144)),
		"beautiful_room_threshold": float(DataRegistry.balance_value("ambience_experience.beautiful_room_threshold", 80.0)),
		"beautiful_room_delta": float(DataRegistry.balance_value("ambience_experience.beautiful_room_delta", 5.0)),
		"pleasant_room_threshold": float(DataRegistry.balance_value("ambience_experience.pleasant_room_threshold", 65.0)),
		"pleasant_room_delta": float(DataRegistry.balance_value("ambience_experience.pleasant_room_delta", 3.0)),
		"bare_room_threshold": float(DataRegistry.balance_value("ambience_experience.bare_room_threshold", 20.0)),
		"bare_room_delta": float(DataRegistry.balance_value("ambience_experience.bare_room_delta", -6.0)),
		"plain_room_threshold": float(DataRegistry.balance_value("ambience_experience.plain_room_threshold", 40.0)),
		"plain_room_delta": float(DataRegistry.balance_value("ambience_experience.plain_room_delta", -3.0)),
		"spotless_threshold": float(DataRegistry.balance_value("ambience_experience.spotless_threshold", 95.0)),
		"spotless_delta": float(DataRegistry.balance_value("ambience_experience.spotless_delta", 2.0)),
		"neglected_delta": float(DataRegistry.balance_value("ambience_experience.neglected_delta", -16.0)),
		"very_dirty_delta": float(DataRegistry.balance_value("ambience_experience.very_dirty_delta", -12.0)),
		"dirty_delta": float(DataRegistry.balance_value("ambience_experience.dirty_delta", -7.0)),
		"visible_insect_delta": float(DataRegistry.balance_value("ambience_experience.visible_insect_delta", -14.0)),
		"visible_mouse_delta": float(DataRegistry.balance_value("ambience_experience.visible_mouse_delta", -22.0))
	}


func _normalize_settings() -> void:
	var raw_duplicate_multipliers: Variant = _settings.get("duplicate_multipliers", [])
	var duplicate_multipliers: Array[float] = []
	if raw_duplicate_multipliers is Array:
		for raw_multiplier: Variant in raw_duplicate_multipliers:
			if raw_multiplier is int or raw_multiplier is float:
				duplicate_multipliers.append(clampf(float(raw_multiplier), 0.0, 1.0))
	if duplicate_multipliers.is_empty():
		duplicate_multipliers.assign([1.0, 1.0, 0.65, 0.45, 0.25])
	_settings.duplicate_multipliers = duplicate_multipliers
	_settings.clean_score = maxf(float(_settings.clean_score), 1.0)
	_settings.dirty_threshold = clampf(float(_settings.dirty_threshold), 0.0, float(_settings.clean_score))
	_settings.very_dirty_threshold = clampf(float(_settings.very_dirty_threshold), 0.0, float(_settings.dirty_threshold))
	_settings.pest_threshold = clampf(float(_settings.pest_threshold), 0.0, float(_settings.very_dirty_threshold))
	_settings.pest_delay_seconds = maxf(float(_settings.pest_delay_seconds), 0.01)
	_settings.pest_warning_ratio = clampf(float(_settings.pest_warning_ratio), 0.0, 0.99)
	_settings.mouse_every = maxi(int(_settings.mouse_every), 1)
	_settings.beauty_cleanliness_floor = clampf(float(_settings.beauty_cleanliness_floor), 0.0, 1.0)


func _empty_snapshot() -> Dictionary:
	var clean_score := float(_settings.get("clean_score", 100.0))
	return {
		"revision": 0,
		"beauty_score": 0.0,
		"beauty_base_score": 0.0,
		"beauty_raw": 0.0,
		"beauty_undiminished": 0.0,
		"beauty_target": 1.0,
		"beauty_cleanliness_multiplier": 1.0,
		"beauty_groups": {},
		"cleanliness_score": clean_score,
		"cleanliness_level": "clean",
		"cleanliness": {
			"score": clean_score,
			"level": "clean",
			"dirty_tables": 0,
			"dirty_dishes": 0,
			"spills": 0,
			"kitchen_dirt": 0.0,
			"below_pest_threshold_seconds": _pest_elapsed
		},
		"pest": _pest_snapshot(),
		"dining_capacity": 0,
		"dining_area_cells": 0
	}


func _pest_snapshot() -> Dictionary:
	return {
		"warning": _warning,
		"active": _active_pests.duplicate(true),
		"visible_kinds": visible_pest_kinds(),
		"pending_kind": _pending_pest_kind,
		"below_threshold_seconds": _pest_elapsed,
		"risk_progress": _pest_risk_progress(),
		"last_spawn_day": int(GameState.world_clock.get("day", 1)) if not _pending_pest_kind.is_empty() or not _active_pests.is_empty() else int(GameState.pest_state.get("last_spawn_day", 0))
	}


func _sync_elapsed_into_snapshot() -> void:
	if _snapshot.is_empty():
		return
	_snapshot.cleanliness.below_pest_threshold_seconds = _pest_elapsed
	_snapshot.pest = _pest_snapshot()


func _pest_risk_progress() -> float:
	return clampf(_pest_elapsed / maxf(float(_settings.pest_delay_seconds), 0.01), 0.0, 1.0)


func _choose_pest_kind(score: float) -> String:
	if (
		score <= float(_settings.mouse_score_threshold)
		and posmod(_spawn_serial, int(_settings.mouse_every)) == 0
	):
		return PEST_MOUSE
	return PEST_INSECT


func _cleanliness_beauty_multiplier(score: float) -> float:
	var dirty_threshold := maxf(float(_settings.dirty_threshold), 0.01)
	if score >= dirty_threshold:
		return 1.0
	return lerpf(float(_settings.beauty_cleanliness_floor), 1.0, clampf(score / dirty_threshold, 0.0, 1.0))


func _cleanliness_level(score: float) -> String:
	if score >= float(_settings.clean_score) - 0.01:
		return "clean"
	if score >= float(_settings.dirty_threshold):
		return "used"
	if score >= float(_settings.very_dirty_threshold):
		return "dirty"
	if score >= float(_settings.pest_threshold):
		return "very_dirty"
	return "neglected"


func _beauty_cause(score: float) -> Dictionary:
	if score >= float(_settings.beautiful_room_threshold):
		return _cause("beautiful_room", "ambience", float(_settings.beautiful_room_delta), ["beautiful", "welcoming"], "Sala bellissima", "beauty", "record_ambience", {"score": score})
	if score >= float(_settings.pleasant_room_threshold):
		return _cause("pleasant_room", "ambience", float(_settings.pleasant_room_delta), ["welcoming"], "Sala piacevole", "beauty", "record_ambience", {"score": score})
	if score < float(_settings.bare_room_threshold):
		return _cause("bare_room", "ambience", float(_settings.bare_room_delta), ["bare", "unwelcoming"], "Sala spoglia", "beauty", "record_ambience", {"score": score})
	if score < float(_settings.plain_room_threshold):
		return _cause("plain_room", "ambience", float(_settings.plain_room_delta), ["plain"], "Sala poco curata", "beauty", "record_ambience", {"score": score})
	return {}


func _cleanliness_cause(score: float) -> Dictionary:
	if score >= float(_settings.spotless_threshold):
		return _cause("spotless", "cleanliness", float(_settings.spotless_delta), ["spotless"], "Pulizia impeccabile", "dirt", "record_ambience", {"score": score})
	if score < float(_settings.pest_threshold):
		return _cause("neglected", "cleanliness", float(_settings.neglected_delta), ["filthy", "neglected"], "Locale trascurato", "dirt", "record_ambience", {"score": score})
	if score < float(_settings.very_dirty_threshold):
		return _cause("very_dirty", "cleanliness", float(_settings.very_dirty_delta), ["very_dirty"], "Locale molto sporco", "dirt", "record_ambience", {"score": score})
	if score < float(_settings.dirty_threshold):
		return _cause("dirty", "cleanliness", float(_settings.dirty_delta), ["dirty"], "Pulizia insufficiente", "dirt", "record_ambience", {"score": score})
	return {}


func _pest_cause(kind: String) -> Dictionary:
	if kind == PEST_MOUSE:
		return _cause("visible_mouse", "cleanliness", float(_settings.visible_mouse_delta), ["mouse", "pest"], "Topo visibile", "mouse", "record_visible_pest", {"pest_type": kind})
	return _cause("visible_insect", "cleanliness", float(_settings.visible_insect_delta), ["insect", "pest"], "Insetti visibili", "insect", "record_visible_pest", {"pest_type": PEST_INSECT})


func _cause(
	id: String,
	category: String,
	delta: float,
	tags: Array,
	label: String,
	icon_id: String,
	handled_by: String,
	metadata: Dictionary
) -> Dictionary:
	return {
		"id": id,
		"category": category,
		"delta": delta,
		"tags": tags.duplicate(),
		"template_key": "review.%s" % id,
		"label": label,
		"icon_id": icon_id,
		"visible": true,
		"handled_by": handled_by,
		"metadata": metadata.duplicate(true)
	}


func _restore_persistent_state() -> void:
	var cleanliness: Dictionary = GameState.cleanliness_state if GameState.cleanliness_state is Dictionary else {}
	var pest_state: Dictionary = GameState.pest_state if GameState.pest_state is Dictionary else {}
	_pest_elapsed = maxf(float(cleanliness.get("below_pest_threshold_seconds", 0.0)), 0.0)
	_warning = bool(pest_state.get("warning", false))
	_pending_pest_kind = _pest_kind(pest_state.get("pending_kind", ""))
	_spawn_serial = maxi(int(pest_state.get("spawn_serial", 0)), 0)
	var active: Variant = pest_state.get("active", [])
	if active is Array:
		for index: int in (active as Array).size():
			var raw_record: Variant = (active as Array)[index]
			var kind := _pest_kind(raw_record)
			if kind.is_empty():
				continue
			var incident_id := "%s_saved_%02d" % [kind, index]
			if raw_record is Dictionary:
				incident_id = String((raw_record as Dictionary).get("id", incident_id))
			_active_pests.append({"id": incident_id, "kind": kind, "visible": true})


func _persist_state(force: bool = false) -> void:
	if not persist_to_game_state:
		return
	var elapsed_second := floori(_pest_elapsed)
	if not force and elapsed_second == _last_persisted_second:
		return
	_last_persisted_second = elapsed_second
	var cleanliness: Dictionary = _snapshot.get("cleanliness", {}).duplicate(true)
	cleanliness.score = float(_snapshot.get("cleanliness_score", _settings.clean_score))
	cleanliness.below_pest_threshold_seconds = _pest_elapsed
	GameState.set_cleanliness_state(cleanliness)
	var pest_state := _pest_snapshot()
	pest_state.spawn_serial = _spawn_serial
	GameState.set_pest_state(pest_state)


func _entry_is_in_room(entry: Variant, dining_context: Dictionary) -> bool:
	var cell := _cell_from_entry(entry)
	if cell == Vector2i(-99999, -99999):
		return true
	var dining_cells: Variant = dining_context.get("dining_cells", {})
	if dining_cells is Dictionary and not (dining_cells as Dictionary).is_empty():
		return (dining_cells as Dictionary).has(cell)
	var bounds: Variant = dining_context.get("bounds", null)
	if bounds is Rect2i:
		return (bounds as Rect2i).has_point(cell)
	return true


func _definition_from_entry(entry: Variant) -> Dictionary:
	if entry is Dictionary:
		var dictionary := entry as Dictionary
		var nested: Variant = dictionary.get("definition", null)
		return nested as Dictionary if nested is Dictionary else dictionary
	if entry is PlacedObject:
		return (entry as PlacedObject).definition
	return {}


func _cell_from_entry(entry: Variant) -> Vector2i:
	var raw_cell: Variant = null
	if entry is Dictionary:
		var dictionary := entry as Dictionary
		raw_cell = dictionary.get("grid_cell", dictionary.get("cell", null))
	elif entry is PlacedObject:
		return (entry as PlacedObject).grid_cell
	if raw_cell is Vector2i:
		return raw_cell
	if raw_cell is Array and (raw_cell as Array).size() >= 2:
		return Vector2i(int((raw_cell as Array)[0]), int((raw_cell as Array)[1]))
	return Vector2i(-99999, -99999)


func _pest_kind(raw_pest: Variant) -> String:
	var value := ""
	if raw_pest is Dictionary:
		value = String((raw_pest as Dictionary).get("kind", (raw_pest as Dictionary).get("type", "")))
	else:
		value = String(raw_pest)
	value = value.to_lower().strip_edges()
	if value in ["insect", "insects", "bug", "bugs"]:
		return PEST_INSECT
	if value in ["mouse", "mice", "rat", "rats"]:
		return PEST_MOUSE
	return ""


func _property_value(owner: Object, property_name: StringName, fallback: Variant) -> Variant:
	if owner == null:
		return fallback
	for info: Dictionary in owner.get_property_list():
		if StringName(info.get("name", "")) == property_name:
			return owner.get(property_name)
	return fallback
