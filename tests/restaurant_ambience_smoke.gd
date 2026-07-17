extends Node

class FakeAmbienceWorld:
	extends Node

	var placed_objects: Dictionary = {}
	var table_dirty_records: Dictionary = {}
	var spill_records: Dictionary = {}
	var wash_batches: Dictionary = {}
	var floor_tiles: Dictionary = {}
	var kitchen_dirt := 0.0


var failures: Array[String] = []
var checks := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	GameState.reset_to_defaults(false)
	_test_data_driven_tuning()
	_test_catalogue_and_diminishing_returns()
	_test_scope_and_cleanliness_effect()
	_test_pest_warning_incident_and_recovery()
	_test_world_sources_and_persistence()
	var result := "RESTAURANT AMBIENCE SMOKE: %s | checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()]
	print(result)
	for failure: String in failures:
		print(failure)
	var file := FileAccess.open("res://tests/restaurant-ambience-smoke-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_data_driven_tuning() -> void:
	var system := RestaurantAmbienceSystem.new()
	add_child(system)
	system.configure()
	var settings := system.settings_snapshot()
	var configured_multipliers: Array = DataRegistry.balance_value("beauty.duplicate_multipliers", [])
	_expect(
		configured_multipliers == [1.0, 1.0, 0.65, 0.45, 0.25]
			and settings.duplicate_multipliers == configured_multipliers,
		"beauty duplicate returns are loaded from gameplay balance as 100/100/65/45/25"
	)
	_expect(
		is_equal_approx(float(settings.dirty_table_penalty), float(DataRegistry.balance_value("cleanliness.dirty_table_penalty")))
			and is_equal_approx(float(settings.mouse_penalty), float(DataRegistry.balance_value("cleanliness.visible_mouse_penalty")))
			and is_equal_approx(float(settings.beauty_target_per_seat), float(DataRegistry.balance_value("beauty.target_per_seat")))
			and is_equal_approx(float(settings.visible_mouse_delta), float(DataRegistry.balance_value("ambience_experience.visible_mouse_delta"))),
		"cleanliness, beauty and experience tuning come from gameplay_balance.json"
	)
	system.queue_free()


func _test_catalogue_and_diminishing_returns() -> void:
	var expected_decor_assets := {
		"decoration": "res://assets/decor/lamp_standing.gltf",
		"plant": "res://assets/decor/monstera_plant_medium_potted.gltf",
		"plant_sansevieria": "res://assets/decor/sansevieria_plant_medium_potted.gltf",
		"rug_rectangle": "res://assets/decor/rug_rectangle_stripes_A.gltf",
		"cabinet_decorated": "res://assets/decor/cabinet_medium_decorated.gltf",
		"shelf": "res://assets/decor/shelf_B_large_decorated.gltf"
	}
	for item_id: String in expected_decor_assets:
		var definition: Dictionary = DataRegistry.build_by_id.get(item_id, {})
		_expect(
			float(definition.get("beauty", 0.0)) > 0.0
				and not String(definition.get("beauty_group", "")).is_empty()
				and String(definition.get("room_scope", "")) == "dining",
			"%s exposes data-driven dining beauty metadata" % item_id
		)
		_expect(
			String(definition.get("model", "")) == String(expected_decor_assets[item_id])
				and FileAccess.file_exists(String(expected_decor_assets[item_id]))
				and int(definition.get("price", 0)) > 0,
			"%s uses its real decor asset and a purchasable price" % item_id
		)
	var rug: Dictionary = DataRegistry.build_by_id.rug_rectangle
	var rug_footprint: Array = rug.get("footprint", [])
	_expect(
		rug_footprint.size() == 2
			and int(rug_footprint[0]) == 2
			and int(rug_footprint[1]) == 1
			and not bool(rug.get("blocking", true)),
		"the rectangular rug uses a two-cell non-blocking floor footprint"
	)
	var table_cloth: Dictionary = DataRegistry.build_by_id.table_cloth
	_expect(
		float(table_cloth.get("beauty", 0.0)) > 0.0
			and String(table_cloth.get("room_scope", "")) == "dining",
		"the tablecloth remains part of dining-room beauty"
	)
	var system := RestaurantAmbienceSystem.new()
	add_child(system)
	system.configure(null, {
		"beauty_target_base": 50.0,
		"beauty_target_per_seat": 0.0,
		"beauty_target_per_cell": 0.0
	})
	var plant: Dictionary = DataRegistry.build_by_id.plant
	var one := system.calculate_beauty([plant])
	var two := system.calculate_beauty([plant, plant])
	var three := system.calculate_beauty([plant, plant, plant])
	var four := system.calculate_beauty([plant, plant, plant, plant])
	var five := system.calculate_beauty([plant, plant, plant, plant, plant])
	var six := system.calculate_beauty([plant, plant, plant, plant, plant, plant])
	_expect(is_equal_approx(float(one.diminished_total), 8.0), "the first copy contributes 100 percent beauty")
	_expect(is_equal_approx(float(two.diminished_total) - float(one.diminished_total), 8.0), "the second copy still contributes 100 percent")
	_expect(is_equal_approx(float(three.diminished_total) - float(two.diminished_total), 5.2), "the third copy contributes 65 percent")
	_expect(is_equal_approx(float(four.diminished_total) - float(three.diminished_total), 3.6), "the fourth copy contributes 45 percent")
	_expect(is_equal_approx(float(five.diminished_total) - float(four.diminished_total), 2.0), "the fifth copy contributes 25 percent")
	_expect(is_equal_approx(float(six.diminished_total) - float(five.diminished_total), 2.0), "copies after the fifth remain at 25 percent")
	var custom := RestaurantAmbienceSystem.new()
	add_child(custom)
	custom.configure(null, {"duplicate_multipliers": [1.0, 0.2]})
	var custom_two := custom.calculate_beauty([plant, plant])
	_expect(is_equal_approx(float(custom_two.diminished_total), 9.6), "duplicate multipliers remain configurable through the core API")
	custom.queue_free()
	system.queue_free()


func _test_scope_and_cleanliness_effect() -> void:
	var system := RestaurantAmbienceSystem.new()
	add_child(system)
	system.configure(null, {
		"beauty_target_base": 50.0,
		"beauty_target_per_seat": 0.0,
		"beauty_target_per_cell": 0.0
	})
	var plant: Dictionary = DataRegistry.build_by_id.plant
	var context := {
		"room_scope": "dining",
		"dining_cells": {Vector2i(1, 1): true},
		"area_cells": 1,
		"capacity": 0
	}
	var scoped := system.calculate_beauty([
		{"definition": plant, "cell": [1, 1]},
		{"definition": plant, "cell": [8, 8]},
		{"id": "outside_fake", "beauty": 100.0, "beauty_group": "fake", "room_scope": "exterior"}
	], context)
	_expect(int(scoped.entry_count) == 1 and is_equal_approx(float(scoped.diminished_total), 8.0), "only decor physically scoped to the dining room contributes")

	var layout: Array = [
		DataRegistry.build_by_id.plant,
		DataRegistry.build_by_id.decoration,
		DataRegistry.build_by_id.shelf,
		DataRegistry.build_by_id.table_cloth
	]
	var clean := system.recalculate(layout, {}, {"capacity": 0, "area_cells": 0})
	var used := system.recalculate(layout, {"dirty_dishes": 1}, {"capacity": 0, "area_cells": 0})
	var dirty := system.recalculate(layout, {"spills": 6}, {"capacity": 0, "area_cells": 0})
	_expect(is_equal_approx(float(clean.beauty_score), float(used.beauty_score)), "ordinary used-room signs do not reduce effective beauty")
	_expect(float(dirty.cleanliness_score) < 30.0 and float(dirty.beauty_score) < float(clean.beauty_score), "serious dirt lowers both cleanliness and effective beauty")
	_expect(String(dirty.cleanliness_level) in ["very_dirty", "neglected"], "cleanliness exposes a readable severity level")
	system.queue_free()


func _test_pest_warning_incident_and_recovery() -> void:
	var system := RestaurantAmbienceSystem.new()
	add_child(system)
	system.configure(null, {
		"pest_delay_seconds": 4.0,
		"pest_warning_ratio": 0.5,
		"mouse_every": 99
	})
	var event_order: Array[String] = []
	var requested: Array[Dictionary] = []
	var resolved: Array[Dictionary] = []
	system.pest_warning_changed.connect(func(active: bool, _context: Dictionary):
		if active:
			event_order.append("warning")
	)
	system.pest_spawn_requested.connect(func(kind: String, context: Dictionary):
		event_order.append("spawn")
		requested.append({"kind": kind, "context": context.duplicate(true)})
	)
	system.pest_resolved.connect(func(kind: String, context: Dictionary):
		resolved.append({"kind": kind, "context": context.duplicate(true)})
	)
	system.recalculate([], {"kitchen_dirt": 90.0})
	var before_warning := system.advance_pest_risk(1.9)
	var warning := system.advance_pest_risk(0.2)
	var before_spawn := system.advance_pest_risk(1.7)
	var spawned := system.advance_pest_risk(0.3)
	_expect(not bool(before_warning.warning) and bool(warning.warning), "pest warning starts at the configured pre-spawn threshold")
	_expect(String(before_spawn.spawn_requested).is_empty() and String(spawned.spawn_requested) == "insect", "pest spawn requires both low cleanliness and the full configured duration")
	_expect(event_order == ["warning", "spawn"], "the visible warning is emitted before the spawn request")
	_expect(not requested.is_empty() and not bool(requested[0].context.visible), "a spawn request is not treated as a visible incident before the world confirms it")
	var pre_confirmation := system.experience_contribution()
	_expect(pre_confirmation.visible_pests.is_empty() and _all_causes_are_visible(pre_confirmation.causes), "pending risk creates no invisible pest penalty")
	var warning_context := system.warning_context()
	_expect(bool(warning_context.visible) and not String(warning_context.message).is_empty() and String(warning_context.icon_id) == "insect", "warning API supplies a message and an existing generated icon id")

	system.confirm_pest_spawn("insect", String(requested[0].context.incident_id))
	var active := system.experience_contribution()
	var pest_cause_found := false
	for cause: Dictionary in active.causes:
		pest_cause_found = pest_cause_found or String(cause.id) == "visible_insect"
	_expect(active.visible_pests == ["insect"] and pest_cause_found, "confirmed visible pests enter the structured experience API")
	var review := system.review_context()
	_expect(
		review.has("beauty_score")
			and review.has("cleanliness_score")
			and review.incident_ids.size() == 1
			and review.tags.has("pest"),
		"review context exposes scores, visible incident ids and review tags"
	)
	var clean := system.recalculate([], {})
	_expect(
		float(clean.cleanliness_score) < 100.0
			and system.visible_pest_kinds() == ["insect"]
			and system.warning_context().active_incident
			and resolved.is_empty(),
		"cleaning the room does not auto-resolve a confirmed visible incident without runtime completion"
	)
	var incident_id := String(requested[0].context.incident_id)
	_expect(system.resolve_pest(incident_id, "maintenance_completed"), "runtime can explicitly resolve the confirmed pest incident")
	var after_resolution := system.current_snapshot()
	_expect(
		float(after_resolution.cleanliness_score) == 100.0
			and system.visible_pest_kinds().is_empty()
			and not system.warning_context().visible
			and resolved.size() == 1
			and String(resolved[0].context.reason) == "maintenance_completed",
		"explicit maintenance completion clears the incident, warning and pest deduction"
	)
	system.queue_free()


func _test_world_sources_and_persistence() -> void:
	GameState.reset_to_defaults(false)
	var world := FakeAmbienceWorld.new()
	add_child(world)
	world.floor_tiles = {
		Vector2i(1, 1): "floor_dining",
		Vector2i(2, 1): "floor_dining",
		Vector2i(1, 2): "floor_kitchen"
	}
	world.placed_objects = {
		"plant": {"definition": DataRegistry.build_by_id.plant, "cell": [1, 1]},
		"outside_plant": {"definition": DataRegistry.build_by_id.plant, "cell": [1, 2]},
		"chair": {"definition": DataRegistry.build_by_id.chair, "cell": [2, 1]}
	}
	world.table_dirty_records = {
		"table": {
			"state": "dirty",
			"container_kinds": ["plate", "bowl"],
			"nodes": []
		}
	}
	world.wash_batches = {
		"legacy": true,
		"active_batch": {"state": "waiting", "dish_count": 3},
		"completed_batch": {"state": "cleaned", "dish_count": 8}
	}
	world.spill_records = {
		"dirty": {"state": "dirty"},
		"done": {"state": "clean"}
	}
	world.kitchen_dirt = 4.0
	var system := RestaurantAmbienceSystem.new()
	add_child(system)
	system.configure(world, {}, true)
	var snapshot := system.refresh_from_world()
	_expect(
		int(snapshot.cleanliness.dirty_tables) == 1
			and int(snapshot.cleanliness.dirty_dishes) == 6
			and int(snapshot.cleanliness.spills) == 1
			and is_equal_approx(float(snapshot.cleanliness.kitchen_dirt), 4.0),
		"world adapter derives global cleanliness from tables, queued washing, spills and kitchen dirt"
	)
	_expect(
		int(snapshot.dining_area_cells) == 2
			and int(snapshot.dining_capacity) == 1
			and int(snapshot.beauty_groups.potted_plant.count) == 1,
		"world adapter derives dining area/capacity and excludes decor on kitchen flooring"
	)
	_expect(
		int(GameState.cleanliness_state.get("dirty_tables", 0)) == 1
			and int(GameState.cleanliness_state.get("dirty_dishes", 0)) == 6
			and int(GameState.cleanliness_state.get("spills", 0)) == 1,
		"optional persistence writes the derived state through the existing GameState API"
	)
	var priority := system.handyman_priority_context()
	_expect(
		priority.recommended_actions.has("clean_spills")
			and priority.recommended_actions.has("bus_tables")
			and priority.recommended_actions.has("wash_dishes")
			and priority.recommended_actions.has("clean_kitchen"),
		"handyman API explains every concrete cleanup source instead of applying a hidden penalty"
	)
	system.queue_free()
	world.queue_free()


func _all_causes_are_visible(causes: Array) -> bool:
	for raw_cause: Variant in causes:
		if not raw_cause is Dictionary:
			return false
		var cause := raw_cause as Dictionary
		if not bool(cause.get("visible", false)) or String(cause.get("label", "")).is_empty() or String(cause.get("icon_id", "")).is_empty():
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
