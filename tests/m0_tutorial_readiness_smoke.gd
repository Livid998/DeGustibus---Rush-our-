extends Node

var failures: Array[String] = []
var checks := 0


class ReadinessWorldStub extends Node:
	var seating := {"reachable_tables": 1, "reachable_seats": 2, "unreachable_table_uids": []}
	var access := {"entrance_present": true, "entrance_reachable": true, "exit_reachable": true}

	func opening_seating_snapshot() -> Dictionary:
		return seating.duplicate(true)

	func opening_access_snapshot() -> Dictionary:
		return access.duplicate(true)

	func opening_station_snapshot(required: Array[String]) -> Dictionary:
		return {
			"required": required.duplicate(),
			"operational": required.duplicate(),
			"missing": [],
			"inoperative": [],
			"unreachable": [],
		}

	func unventilated_heat_stations() -> Array:
		return []


func _ready() -> void:
	SaveManager.writes_enabled = false
	_test_tutorial_sequence()
	_test_readiness_contract()
	print("M0 TUTORIAL/READINESS: %s | checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	for failure: String in failures:
		print("FAIL: ", failure)
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_tutorial_sequence() -> void:
	GameState.tutorial = {"step": 0, "skipped": false, "complete": false}
	var migrated := TutorialManager.ensure_schema()
	_expect(int(migrated.get("version", 0)) == 2 and String(migrated.get("current_step_id", "")) == "table_moved", "legacy tutorial state migrates to schema v2")
	_expect(not TutorialManager.record_event("chair_placed") and int(GameState.tutorial.step) == 0, "out-of-order events never advance onboarding")
	var ordered := [
		"table_moved",
		"chair_placed",
		"menu_validated",
		"tomato_auto_reorder_enabled",
		"restaurant_opened",
		"first_dish_ready",
		"station_load_viewed",
	]
	for event_id: String in ordered:
		_expect(TutorialManager.record_event(event_id), "tutorial accepts expected event %s" % event_id)
	_expect(bool(GameState.tutorial.complete) and String(GameState.tutorial.current_step_id).is_empty(), "final event completes the tutorial")
	TutorialManager.restart()
	TutorialManager.skip()
	_expect(bool(GameState.tutorial.skipped) and not TutorialManager.record_event("table_moved"), "skipped onboarding remains immutable")


func _test_readiness_contract() -> void:
	GameState.reset_to_defaults(false)
	var world := ReadinessWorldStub.new()
	add_child(world)
	var ready := OpeningReadinessService.evaluate(world)
	_expect(bool(ready.get("ready", false)) and (ready.get("blockers", []) as Array).is_empty(), "valid menu, staff, seating, access and stations pass readiness")
	GameState.employees = []
	for recipe_id: String in GameState.menu:
		GameState.menu[recipe_id].active = false
	world.seating = {"reachable_tables": 0, "reachable_seats": 0, "unreachable_table_uids": ["blocked_table"]}
	world.access = {"entrance_present": false, "entrance_reachable": false, "exit_reachable": false}
	var blocked := OpeningReadinessService.evaluate(world)
	var blocker_ids: Array = (blocked.get("blockers", []) as Array).map(func(issue: Dictionary): return String(issue.id))
	_expect(not bool(blocked.get("ready", true)), "invalid restaurant is blocked")
	_expect("menu_empty" in blocker_ids and "seating_unreachable" in blocker_ids and "entrance_missing" in blocker_ids, "readiness reports menu, seating and entrance blockers")
	_expect("cook_missing" in blocker_ids and "waiter_missing" in blocker_ids, "readiness reports mandatory staff roles")
	var warning_ids: Array = (blocked.get("warnings", []) as Array).map(func(issue: Dictionary): return String(issue.id))
	_expect("handyman_missing" in warning_ids, "missing handyman is a warning, not a blocker")
	world.queue_free()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
