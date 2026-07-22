extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	SaveManager.writes_enabled = false
	await get_tree().process_frame
	_check_every_character_rig()
	_check_service_phase_contract()
	_check_object_markers_and_feedback()
	var result := "M3 VISUAL CONTRACTS: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL", checks, failures.size(), "\n".join(failures)
	]
	print(result)
	var file := FileAccess.open("res://tests/m3-visual-contract-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _check_every_character_rig() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/avatar_presets.json"))
	var presets: Array = parsed if parsed is Array else []
	_expect(presets.size() >= 19, "the complete supplied character roster is audited")
	for preset: Dictionary in presets:
		var agent := AnimatedAgent.new()
		agent.name = "Rig_%s" % String(preset.get("appearance", "unknown"))
		add_child(agent)
		var model := agent.add_character_model(String(preset.get("model", "")), Vector3.ZERO, AnimatedAgent.skin_tone_for_key(String(preset.get("id", ""))))
		var snapshot := agent.rig_contract_snapshot()
		var markers: Dictionary = snapshot.get("markers", {})
		var all_markers := true
		var finite_markers := true
		for marker_name: StringName in ModelFactory.RIG_MARKER_NAMES:
			var marker := agent.rig_marker(String(marker_name))
			all_markers = all_markers and marker != null and bool(markers.get(String(marker_name), {}).get("present", false))
			if marker != null:
				var p := marker.global_position
				finite_markers = finite_markers and is_finite(p.x) and is_finite(p.y) and is_finite(p.z)
		var left_source := String(markers.get("Hand_L", {}).get("source", ""))
		var right_source := String(markers.get("Hand_R", {}).get("source", ""))
		_expect(all_markers and finite_markers, "%s exposes six valid canonical markers" % String(preset.get("appearance", "rig")))
		_expect(left_source.begins_with("bone:") and right_source.begins_with("bone:"), "%s binds both hand markers to the animated skeleton" % String(preset.get("appearance", "rig")))
		var carry := agent.rig_marker("Carry")
		if carry != null:
			carry.call("sync_now")
		var midpoint := (agent.rig_marker("Hand_L").global_position + agent.rig_marker("Hand_R").global_position) * 0.5
		_expect(carry != null and carry.global_position.distance_to(midpoint) <= 0.18, "%s Carry marker follows the animated hand midpoint" % String(preset.get("appearance", "rig")))
		var animations: Dictionary = snapshot.get("animations", {})
		var complete_contract := true
		for logical_name: String in AnimatedAgent.ANIMATION_CONTRACT:
			complete_contract = complete_contract and not String(animations.get(logical_name, "")).is_empty()
		_expect(complete_contract, "%s resolves the complete logical animation contract with credible fallbacks" % String(preset.get("appearance", "rig")))
		var bounds := ModelFactory.calculate_visual_bounds(model, true)
		_expect(bounds.position.y >= -0.002 and bounds.position.y <= 0.11, "%s feet remain on the navigation plane (min_y %.3f)" % [String(preset.get("appearance", "rig")), bounds.position.y])
		agent.free()


func _check_service_phase_contract() -> void:
	_expect(FoodVisualFactory.is_service_ready_food("margherita") and not FoodVisualFactory.is_service_ready_food("pizza_raw"), "only authored recipes are service-ready")
	var premature := FoodVisualFactory.instantiate_canonical_serving("pizza_raw")
	_expect(not bool(premature.get_meta("service_ready", true)) and String(premature.get_meta("food_stage", "")) == "preparation", "a semilavorato cannot masquerade as a completed serving")
	premature.free()

	var pass_object := PlacedObject.new()
	add_child(pass_object)
	pass_object.setup("m3_pass", DataRegistry.build_by_id.get("pass_tray", {}), Vector2i.ZERO, 0)
	var task := {
		"id":"m3_final", "station":"pass", "recipe_step_id":"finish",
		"output":"margherita", "remaining":0.2, "duration":0.2,
		"inputs":{}, "dependencies":[], "visual":{"style":"plate"}
	}
	pass_object.show_task(task)
	_expect(not bool(pass_object.task_visual_snapshot().service_ready), "the pass input/process phase is not service-ready")
	task.remaining = 0.0
	pass_object.update_task_progress(task)
	_expect(not bool(pass_object.task_visual_snapshot().service_ready), "even 100% progress waits for the authoritative completion callback")
	pass_object.complete_task_visual(task)
	var final_snapshot := pass_object.task_visual_snapshot()
	var container := pass_object._food_visual_root.get_node_or_null("StableContainer") as Node3D
	var expected := FoodVisualFactory.canonical_container_size("plate")
	var actual := ModelFactory.calculate_visual_bounds(container, true).size if container != null else Vector3.ZERO
	_expect(bool(final_snapshot.service_ready) and container != null and _same_footprint(actual, expected), "completed pass output uses the same canonical plate as hands, table and dirty state (ready=%s container=%s actual=%s expected=%s)" % [final_snapshot.service_ready, container != null, actual, expected])
	var food := pass_object._food_visual_root.get_node_or_null("FoodContent") as Node3D
	var food_bounds := ModelFactory.calculate_visual_bounds(food, true).size if food != null else Vector3.ZERO
	var coverage := maxf(food_bounds.x, food_bounds.z) / maxf(maxf(actual.x, actual.z), 0.0001)
	_expect(coverage >= 1.10 and coverage <= 1.20, "pizza fills about 90%% of the visible plate interior after source-mesh padding (coverage=%.3f)" % coverage)
	pass_object.free()

	var prep_task := {
		"id":"m3_prep", "station":"pizza_oven", "recipe_step_id":"bake",
		"output":"margherita_baked", "remaining":0.0, "duration":1.0,
		"inputs":{}, "dependencies":[], "visual":{"style":"bake", "process_id":"pizza_raw"}
	}
	_expect(not FoodVisualFactory.task_output_is_service_ready(prep_task), "a completed oven preparation remains non-serviceable until pass assembly")


func _check_object_markers_and_feedback() -> void:
	var table := _placed("m3_table", "table_small")
	var chair := _placed("m3_chair", "chair")
	var stove := _placed("m3_stove", "stove")
	var oven := _placed("m3_oven", "oven")
	_expect(table.interaction_marker("Table") != null, "dining tables publish the canonical Table marker")
	_expect(chair.interaction_marker("Seat") != null, "chairs publish the canonical Seat marker")
	_expect(stove.interaction_marker("Work") != null and oven.interaction_marker("Work") != null, "workstations publish the canonical Work marker")

	var heat_task := {
		"id":"m3_heat", "station":"stove", "recipe_step_id":"sear",
		"output":"steak_cooked", "remaining":2.0, "duration":2.0,
		"inputs":{"steak":1}, "dependencies":[], "visual":{"style":"sear"}
	}
	_expect(not bool(stove.task_visual_snapshot().burner_active) and not bool(stove.task_visual_snapshot().steam_active), "idle cooker effects are off")
	stove.show_task(heat_task)
	_expect(bool(stove.task_visual_snapshot().burner_active) and bool(stove.task_visual_snapshot().steam_active), "burner and steam follow a real heat task")
	stove.clear_task()
	_expect(not bool(stove.task_visual_snapshot().burner_active) and not bool(stove.task_visual_snapshot().steam_active), "clearing the heat task immediately clears its effects")

	var bake_task := {
		"id":"m3_bake", "station":"oven", "recipe_step_id":"cook",
		"output":"roast_potatoes_batch", "remaining":2.0, "duration":2.0,
		"inputs":{}, "dependencies":[], "visual":{"style":"bake", "process_id":"roast_potatoes_batch"}
	}
	_expect(not bool(oven.task_visual_snapshot().access_active), "idle oven door is not animated")
	oven.show_task(bake_task)
	_expect(bool(oven.task_visual_snapshot().access_active) and bool(oven.task_visual_snapshot().steam_active), "oven door and heat feedback start with the real bake task")
	oven.clear_task()
	_expect(not bool(oven.task_visual_snapshot().steam_active), "oven heat feedback stops when its task is cancelled")

	for object: PlacedObject in [table, chair, stove, oven]:
		object.free()


func _placed(uid: String, item_id: String) -> PlacedObject:
	var object := PlacedObject.new()
	add_child(object)
	object.setup(uid, DataRegistry.build_by_id.get(item_id, {}), Vector2i.ZERO, 0)
	return object


func _same_footprint(actual: Vector3, expected: Vector3) -> bool:
	return absf(actual.x - expected.x) <= 0.001 and absf(actual.z - expected.z) <= 0.001


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
