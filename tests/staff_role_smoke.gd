extends Node

class PreferenceWorld:
	extends Node

	func world_to_cell(value: Vector3) -> Vector2i:
		return Vector2i(roundi(value.x), roundi(value.z))


class TaskOwner:
	extends Node3D

	func accepts_service_action(_action: String, _payload: Dictionary) -> bool:
		return true

	func accepts_maintenance_action(_action: String, _payload: Dictionary) -> bool:
		return true


var failures: Array[String] = []
var checks := 0
var preference_events: Array[Dictionary] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	GameState.reset_to_defaults(false)

	var original_roles: Dictionary = {}
	for employee: Dictionary in GameState.employees:
		original_roles[String(employee.id)] = String(employee.role)
	for candidate: Dictionary in GameState.candidates:
		original_roles[String(candidate.id)] = String(candidate.role)

	var screen := StaffScreen.create()
	add_child(screen)
	screen.operational_preference_changed.connect(
		func(employee_id: String, value: Dictionary) -> void:
			preference_events.append({"employee_id": employee_id, "value": value.duplicate(true)})
	)
	await get_tree().process_frame
	await get_tree().process_frame

	var tabs := screen.find_child("RoleTabs", true, false) as TabBar
	_expect(
		screen.hierarchy_build_count() == 1 and tabs != null and tabs.tab_count == 3,
		"StaffScreen builds one persistent hierarchy with three explicit role tabs"
	)
	var role_icons_are_real := true
	for index: int in tabs.tab_count:
		role_icons_are_real = role_icons_are_real and tabs.get_tab_icon(index) != null
	_expect(
		role_icons_are_real
		and tabs.get_tab_icon(0) == GameIcons.casual_system_icon("role_chef")
		and tabs.get_tab_icon(1) == GameIcons.casual_system_icon("role_waiter")
		and tabs.get_tab_icon(2) == GameIcons.casual_system_icon("role_handyman"),
		"role tabs use generated GameIcons textures rather than emoji or unsupported glyphs"
	)
	_expect(
		screen.find_child("RoleSelector", true, false) == null,
		"employee cards expose no control capable of converting a worker to another role"
	)
	_expect(
		_ids_match_role(screen.visible_employee_ids(), "cook", GameState.employees)
		and _ids_match_role(screen.visible_candidate_ids(), "cook", GameState.candidates),
		"the initial Cuochi tab filters both employees and candidates"
	)

	screen.set_role_filter("waiter")
	_expect(
		screen.selected_role == "waiter"
		and _ids_match_role(screen.visible_employee_ids(), "waiter", GameState.employees)
		and _ids_match_role(screen.visible_candidate_ids(), "waiter", GameState.candidates),
		"the Camerieri tab filters hired workers and candidates together"
	)
	screen.set_role_filter("handyman")
	_expect(
		screen.selected_role == "handyman"
		and _ids_match_role(screen.visible_employee_ids(), "handyman", GameState.employees)
		and _ids_match_role(screen.visible_candidate_ids(), "handyman", GameState.candidates),
		"the Manutentori tab filters hired workers and candidates together"
	)
	var roles_unchanged := true
	for employee: Dictionary in GameState.employees:
		roles_unchanged = (
			roles_unchanged
			and String(employee.role) == String(original_roles.get(String(employee.id), ""))
		)
	for candidate: Dictionary in GameState.candidates:
		roles_unchanged = (
			roles_unchanged
			and String(candidate.role) == String(original_roles.get(String(candidate.id), ""))
		)
	_expect(roles_unchanged, "changing filters never mutates the immutable employee roles")

	var cook: Dictionary = _first_role(GameState.employees, "cook")
	var waiter: Dictionary = _first_role(GameState.employees, "waiter")
	var handyman: Dictionary = _first_role(GameState.employees, "handyman")
	var cook_stats := screen.stats_text_for(cook)
	var waiter_stats := screen.stats_text_for(waiter)
	var handyman_stats := screen.stats_text_for(handyman)
	_expect(
		"Velocità" in cook_stats
		and "Precisione" in cook_stats
		and "Specialità" in cook_stats
		and _best_skill_percent(cook) in cook_stats,
		"cook cards map speed, precision and the real strongest station skill"
	)
	_expect(
		"Velocità" in waiter_stats
		and "Servizio" in waiter_stats
		and "Precisione" in waiter_stats
		and _percent(float(waiter.get("skills", {}).get("service", 0.0))) in waiter_stats,
		"waiter cards map speed, real service skill and precision"
	)
	_expect(
		"Velocità pulizia" in handyman_stats
		and "Ordine" in handyman_stats
		and "Resistenza" in handyman_stats
		and _percent(float(handyman.get("stamina", 0.0))) in handyman_stats,
		"maintenance cards map cleaning speed, order and stamina from existing fields"
	)

	screen.apply_preference(String(cook.id), "cook", {"station": "pizza_oven"})
	_expect(
		String(GameState.staff_preferences.get(String(cook.id), {}).get("station", "")) == "pizza_oven"
		and StaffPreferences.cook_station(cook) == "pizza_oven"
		and StaffPreferences.cook_station_bonus(cook, "pizza_oven") > 0.0
		and StaffPreferences.cook_station_bonus(cook, "stove") == 0.0,
		"cook preference persists through GameState and only adds a score to the matching station"
	)

	screen.apply_preference(String(waiter.id), "waiter", {"standby_zone": "pass"})
	_expect(
		String(GameState.staff_preferences.get(String(waiter.id), {}).get("standby_zone", "")) == "pass"
		and StaffPreferences.waiter_standby_zone(waiter) == "pass"
		and StaffPreferences.waiter_task_bonus(waiter, "serve", Vector3.ZERO, null) > 0.0
		and StaffPreferences.waiter_task_bonus(waiter, "payment", Vector3.ZERO, null) == 0.0,
		"waiter standby/zone preference is real, persisted and biases matching service work"
	)

	var preference_world := PreferenceWorld.new()
	add_child(preference_world)
	screen.apply_preference(String(handyman.id), "handyman", {"priority": "dishes"})
	_expect(
		String(GameState.staff_preferences.get(String(handyman.id), {}).get("priority", "")) == "dishes"
		and StaffPreferences.handyman_task_bonus(
			handyman,
			"wash_dishes",
			Vector3(4, 0, 10),
			preference_world
		) > 0.0
		and StaffPreferences.handyman_task_bonus(
			handyman,
			"clean_spill",
			Vector3(4, 0, 3),
			preference_world
		) == 0.0,
		"handyman dish priority changes scoring without forbidding unrelated cleanup"
	)
	screen.apply_preference(String(handyman.id), "handyman", {"priority": "emergency"})
	_expect(
		StaffPreferences.handyman_task_bonus(
			handyman,
			"remove_pest",
			Vector3.ZERO,
			preference_world,
			{"pest_type": "mouse"}
		) > 0.0
		and StaffPreferences.handyman_task_bonus(
			handyman,
			"wash_dishes",
			Vector3.ZERO,
			preference_world
		) == 0.0,
		"emergency preference recognizes pest work while retaining zero-bonus fallback tasks"
	)

	var preference_events_are_structured := preference_events.size() == 4
	for event: Dictionary in preference_events:
		preference_events_are_structured = (
			preference_events_are_structured
			and event.get("value") is Dictionary
			and not String(event.get("employee_id", "")).is_empty()
		)
	_expect(
		preference_events_are_structured,
		"each selector commit emits one structured operational preference event"
	)
	_test_scheduler_preferences(cook, waiter, handyman)
	var refresh_before := screen.content_refresh_count()
	var hierarchy_before := screen.hierarchy_build_count()
	var selected_before := screen.selected_role
	GameState.employees_changed.emit()
	await get_tree().process_frame
	_expect(
		screen.hierarchy_build_count() == hierarchy_before
		and screen.content_refresh_count() == refresh_before + 1
		and screen.selected_role == selected_before,
		"employee changes refresh role rows event-by-event without rebuilding hierarchy or losing the tab"
	)

	var serialized := GameState.serialize()
	GameState.staff_preferences.clear()
	GameState.deserialize(serialized)
	_expect(
		String(GameState.staff_preferences.get(String(cook.id), {}).get("station", "")) == "pizza_oven"
		and String(
			GameState.staff_preferences.get(String(waiter.id), {}).get("standby_zone", "")
		) == "pass"
		and String(
			GameState.staff_preferences.get(String(handyman.id), {}).get("priority", "")
		) == "emergency",
		"all role-specific preferences survive a save round-trip"
	)

	GameState.staff_preferences[String(handyman.id)] = "stoviglie"
	_expect(
		StaffPreferences.handyman_priority(handyman) == "dishes",
		"legacy scalar preferences remain readable after the schema becomes structured"
	)
	_expect(
		_collect_unsupported_text(screen).is_empty(),
		"staff UI contains no web-unsafe placeholder glyphs"
	)

	var result := "STAFF ROLE SMOKE: %s | checks=%d failures=%d" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
	]
	print(result)
	for failure: String in failures:
		print(failure)
	screen.queue_free()
	preference_world.queue_free()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_scheduler_preferences(
	cook_template: Dictionary,
	waiter_template: Dictionary,
	handyman_template: Dictionary
) -> void:
	SimulationManager.reset_service_stats()
	SimulationManager.stations.clear()
	SimulationManager.bind_world(null)

	var station_node := TaskOwner.new()
	add_child(station_node)
	var stove_runtime := _station_runtime(station_node, Vector3(2, 0, 2))
	var pizza_runtime := _station_runtime(station_node, Vector3(4, 0, 2))
	SimulationManager.stations = {
		"stove": [stove_runtime],
		"pizza_oven": [pizza_runtime],
	}
	SimulationManager.orders = {
		"scheduler_order_stove": {"suspended": false},
		"scheduler_order_pizza": {"suspended": false},
	}
	SimulationManager.tasks = {
		"scheduler_stove": _kitchen_task(
			"scheduler_stove",
			"scheduler_order_stove",
			"stove"
		),
		"scheduler_pizza": _kitchen_task(
			"scheduler_pizza",
			"scheduler_order_pizza",
			"pizza_oven"
		),
	}
	var cook := cook_template.duplicate(true)
	cook.id = "scheduler_cook"
	cook.skills = {"stove": 0.8, "pizza_oven": 0.8}
	GameState.set_staff_preference(
		String(cook.id),
		{"role": "cook", "station": "pizza_oven"}
	)
	var claimed_kitchen := SimulationManager.claim_kitchen_task(cook)
	_expect(
		String(claimed_kitchen.get("id", "")) == "scheduler_pizza",
		"the real kitchen scheduler chooses a free preferred station when scores are otherwise equal"
	)
	SimulationManager.cancel_employee_task(String(cook.id))
	SimulationManager.tasks.scheduler_pizza.state = "completed"
	var fallback_kitchen := SimulationManager.claim_kitchen_task(cook)
	_expect(
		String(fallback_kitchen.get("id", "")) == "scheduler_stove",
		"a cook immediately falls back to another free station when the preference has no task"
	)
	SimulationManager.cancel_employee_task(String(cook.id))

	var service_owner := TaskOwner.new()
	add_child(service_owner)
	SimulationManager.service_tasks = {
		"scheduler_payment": _service_task(
			"scheduler_payment",
			service_owner,
			"payment",
			"service:payment"
		),
		"scheduler_serve": _service_task(
			"scheduler_serve",
			service_owner,
			"serve",
			"service:serve"
		),
	}
	var waiter := waiter_template.duplicate(true)
	waiter.id = "scheduler_waiter"
	GameState.set_staff_preference(
		String(waiter.id),
		{"role": "waiter", "standby_zone": "pass"}
	)
	var claimed_service := SimulationManager.claim_service_task(waiter)
	_expect(
		String(claimed_service.get("id", "")) == "scheduler_serve",
		"the real waiter scheduler applies the configured pass/service bonus"
	)
	SimulationManager.cancel_employee_task(String(waiter.id))
	SimulationManager.service_tasks.scheduler_serve.state = "completed"
	var fallback_service := SimulationManager.claim_service_task(waiter)
	_expect(
		String(fallback_service.get("id", "")) == "scheduler_payment",
		"a waiter still claims non-preferred service work when it is the useful fallback"
	)
	SimulationManager.cancel_employee_task(String(waiter.id))

	var maintenance_owner := TaskOwner.new()
	add_child(maintenance_owner)
	SimulationManager.maintenance_tasks = {
		"scheduler_spill": _maintenance_task(
			"scheduler_spill",
			maintenance_owner,
			"clean_spill",
			"maintenance:spill",
			{"maintenance_category": "dining"}
		),
		"scheduler_dishes": _maintenance_task(
			"scheduler_dishes",
			maintenance_owner,
			"wash_dishes",
			"maintenance:dishes",
			{"maintenance_category": "dishes"}
		),
	}
	var handyman := handyman_template.duplicate(true)
	handyman.id = "scheduler_handyman"
	GameState.set_staff_preference(
		String(handyman.id),
		{"role": "handyman", "priority": "dishes"}
	)
	var claimed_maintenance := SimulationManager.claim_maintenance_task(handyman)
	_expect(
		String(claimed_maintenance.get("id", "")) == "scheduler_dishes",
		"the real maintenance scheduler applies the preferred task-category bonus"
	)
	SimulationManager.cancel_employee_task(String(handyman.id))
	SimulationManager.maintenance_tasks.scheduler_dishes.state = "completed"
	var fallback_maintenance := SimulationManager.claim_maintenance_task(handyman)
	_expect(
		String(fallback_maintenance.get("id", "")) == "scheduler_spill",
		"a handyman still claims a non-preferred cleanup when preferred work is absent"
	)
	SimulationManager.cancel_employee_task(String(handyman.id))

	SimulationManager.reset_service_stats()
	SimulationManager.stations.clear()
	station_node.queue_free()
	service_owner.queue_free()
	maintenance_owner.queue_free()


func _station_runtime(owner: Node, position: Vector3) -> Dictionary:
	return {
		"node": owner,
		"capacity": 1,
		"worker_capacity": 1,
		"interaction_positions": [position],
		"reservations": {},
		"busy": 0,
	}


func _kitchen_task(task_id: String, order_id: String, station_id: String) -> Dictionary:
	return {
		"id": task_id,
		"order_id": order_id,
		"station": station_id,
		"state": "queued",
		"employee_id": "",
		"priority": 1,
		"wait_age": 0.0,
	}


func _service_task(
	task_id: String,
	owner: Node,
	action: String,
	reservation_key: String
) -> Dictionary:
	return {
		"id": task_id,
		"customer": owner,
		"action": action,
		"target": Vector3.ZERO,
		"payload": {},
		"state": "queued",
		"employee_id": "",
		"reservation_key": reservation_key,
		"created_at": 0.0,
		"priority": 1,
	}


func _maintenance_task(
	task_id: String,
	owner: Node,
	action: String,
	reservation_key: String,
	payload: Dictionary
) -> Dictionary:
	return {
		"id": task_id,
		"task_kind": "maintenance",
		"owner": owner,
		"action": action,
		"target": Vector3.ZERO,
		"payload": payload,
		"station": "",
		"station_runtime": null,
		"state": "queued",
		"employee_id": "",
		"reservation_key": reservation_key,
		"created_at": 0.0,
		"priority": 1,
		"duration": 1.0,
	}


func _first_role(collection: Array, role: String) -> Dictionary:
	for entry: Dictionary in collection:
		if String(entry.get("role", "")) == role:
			return entry
	return {}


func _ids_match_role(ids: Array[String], role: String, collection: Array) -> bool:
	var expected: Array[String] = []
	for entry: Dictionary in collection:
		if String(entry.get("role", "")) == role:
			expected.append(String(entry.get("id", "")))
	expected.sort()
	var actual := ids.duplicate()
	actual.sort()
	return actual == expected


func _best_skill_percent(employee: Dictionary) -> String:
	var best := 0.0
	for value: Variant in employee.get("skills", {}).values():
		best = maxf(best, float(value))
	return _percent(best)


func _percent(value: float) -> String:
	return "%.0f%%" % (value * 100.0)


func _collect_unsupported_text(root: Node) -> PackedInt32Array:
	var result := PackedInt32Array()
	var values: Array[String] = []
	if root is Label:
		values.append((root as Label).text)
	elif root is OptionButton:
		var option := root as OptionButton
		for index: int in option.item_count:
			values.append(option.get_item_text(index))
	elif root is Button:
		values.append((root as Button).text)
	elif root is TabBar:
		var tabs := root as TabBar
		for index: int in tabs.tab_count:
			values.append(tabs.get_tab_title(index))
	for value: String in values:
		for codepoint: int in GameFonts.unsupported_runtime_characters(value):
			if codepoint not in result:
				result.append(codepoint)
	for child: Node in root.get_children():
		for codepoint: int in _collect_unsupported_text(child):
			if codepoint not in result:
				result.append(codepoint)
	return result


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
