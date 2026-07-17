extends Node

var failures: Array[String] = []
var checks := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	SimulationManager.close_immediately()
	SimulationManager.reset_service_stats()
	GameState.reset_to_defaults(false)
	GameState.employees = []
	GameState.set_restaurant_state("closed")

	var world := RestaurantWorld.new()
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame

	_expect(world.ambience_system != null, "the restaurant creates one runtime ambience system")
	var initial := world.ambience_snapshot()
	_expect(
		initial.has("beauty_score")
			and initial.has("cleanliness_score")
			and initial.has("pest"),
		"the world exposes the structured ambience snapshot"
	)

	var plant: Dictionary = DataRegistry.build_by_id.get("plant", {})
	var preview := world.beauty_preview(plant, Vector2i(6, 4))
	_expect(
		float(preview.get("item_beauty", 0.0)) > 0.0
			and float(preview.get("after", 0.0)) >= float(preview.get("before", 0.0)),
		"the builder can preview a decor item's beauty without mutating layout"
	)

	var dirt_before := world.kitchen_dirt
	world.register_kitchen_work_dirt({"station": "cutting_board"})
	_expect(world.kitchen_dirt > dirt_before, "a real completed kitchen step produces persistent kitchen dirt")
	_expect(
		is_equal_approx(
			float(GameState.cleanliness_state.get("kitchen_dirt", -1.0)),
			world.kitchen_dirt
		),
		"runtime kitchen dirt is persisted through the ambience snapshot"
	)

	world.kitchen_dirt = float(DataRegistry.balance_value("cleanliness.kitchen_clean_task_threshold", 8.0)) + 1.0
	world._refresh_kitchen_dirt_visuals()
	world._refresh_ambience()
	world._ensure_kitchen_cleaning_task()
	var kitchen_task := _maintenance_task_for_action("clean_kitchen")
	_expect(
		not kitchen_task.is_empty()
			and String(kitchen_task.get("reservation_key", "")) == "clean:kitchen",
		"dirty kitchen work creates one actionable handyman task"
	)
	_expect(not world.kitchen_dirt_visuals.is_empty(), "persistent kitchen dirt has lightweight visible grime marks")
	var kitchen_dirt_before_clean := world.kitchen_dirt
	world.maintenance_completed("clean_kitchen", {})
	_expect(world.kitchen_dirt < kitchen_dirt_before_clean, "finishing the kitchen task removes a data-driven amount of dirt")
	_expect(world.kitchen_dirt_visuals.is_empty(), "cleaning removes the corresponding grime marks")

	var incident_id := "runtime_insect_01"
	world._on_pest_spawn_requested("insect", {"incident_id": incident_id})
	await get_tree().process_frame
	var pest_task := _maintenance_task_for_incident(incident_id)
	_expect(world.pest_visuals.has(incident_id), "a requested infestation creates a visible lightweight world model")
	_expect(
		not pest_task.is_empty()
			and int(pest_task.get("priority", 0)) >= 5
			and String((pest_task.get("payload", {}) as Dictionary).get("maintenance_category", "")) == "emergency",
		"a visible pest creates a high-priority emergency task"
	)
	var active_ids := _active_pest_ids(world.visible_pest_incidents())
	_expect(active_ids.has(incident_id), "only the confirmed world visual becomes a visible ambience incident")
	_expect(
		(GameState.pest_state.get("active", []) as Array).any(
			func(record: Variant) -> bool:
				return record is Dictionary and String((record as Dictionary).get("id", "")) == incident_id
		),
		"confirmed infestations are persisted for reload"
	)

	world.maintenance_completed("remove_pest", {"incident_id": incident_id})
	await get_tree().process_frame
	active_ids = _active_pest_ids(world.visible_pest_incidents())
	_expect(not world.pest_visuals.has(incident_id), "handyman completion removes the pest visual")
	_expect(not active_ids.has(incident_id), "handyman completion explicitly resolves the ambience incident")

	var result := "AMBIENCE RUNTIME SMOKE: %s | checks=%d failures=%d" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
	]
	print(result)
	for failure: String in failures:
		print(failure)
	var file := FileAccess.open("res://tests/ambience-runtime-smoke-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	world.queue_free()
	SimulationManager.close_immediately()
	get_tree().quit(0 if failures.is_empty() else 1)


func _maintenance_task_for_action(action: String) -> Dictionary:
	for task: Dictionary in SimulationManager.maintenance_tasks.values():
		if String(task.get("action", "")) == action and String(task.get("state", "")) not in ["completed", "cancelled"]:
			return task
	return {}


func _maintenance_task_for_incident(incident_id: String) -> Dictionary:
	for task: Dictionary in SimulationManager.maintenance_tasks.values():
		var payload: Dictionary = task.get("payload", {})
		if String(payload.get("incident_id", "")) == incident_id and String(task.get("state", "")) not in ["completed", "cancelled"]:
			return task
	return {}


func _active_pest_ids(records: Array) -> Dictionary:
	var result: Dictionary = {}
	for record: Variant in records:
		if record is Dictionary:
			result[String((record as Dictionary).get("id", ""))] = true
	return result


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
