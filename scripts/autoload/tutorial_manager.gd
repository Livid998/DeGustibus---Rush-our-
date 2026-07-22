extends Node

signal state_changed(snapshot: Dictionary)
signal step_completed(step_id: String)
signal event_ignored(event_id: String, expected_step_id: String)

const SCHEMA_VERSION := 2
const STEPS: Array[Dictionary] = [
	{"id": "table_moved", "text": "Sposta un tavolo in modalita costruzione."},
	{"id": "chair_placed", "text": "Aggiungi una sedia e agganciala a un tavolo."},
	{"id": "menu_validated", "text": "Controlla il menu e conferma una selezione valida."},
	{"id": "tomato_auto_reorder_enabled", "text": "Attiva il riordino automatico del pomodoro."},
	{"id": "restaurant_opened", "text": "Apri il ristorante quando la checklist e pronta."},
	{"id": "first_dish_ready", "text": "Porta a termine il primo piatto del servizio."},
	{"id": "station_load_viewed", "text": "Controlla il carico delle postazioni."},
]

const LEGACY_EVENT_BY_STEP := {
	# Step zero used to complete when the builder was merely opened. It is now
	# deliberately ignored: the table must actually be moved.
	2: "menu_validated",
	3: "tomato_auto_reorder_enabled",
	4: "restaurant_opened",
	6: "station_load_viewed",
}


func _ready() -> void:
	ensure_schema()


func ensure_schema() -> Dictionary:
	var source: Dictionary = GameState.tutorial if GameState.tutorial is Dictionary else {}
	var normalized := _normalize(source)
	if source != normalized:
		GameState.tutorial = normalized
	return GameState.tutorial


func restart() -> void:
	GameState.tutorial = _default_state()
	GameState.mark_save_dirty()
	state_changed.emit(snapshot())


func skip() -> void:
	var state := ensure_schema()
	if bool(state.get("complete", false)) or bool(state.get("skipped", false)):
		return
	state.skipped = true
	GameState.tutorial = state
	GameState.mark_save_dirty()
	state_changed.emit(snapshot())


func record_event(event_id: String, _metadata: Dictionary = {}) -> bool:
	var state := ensure_schema()
	if bool(state.get("skipped", false)) or bool(state.get("complete", false)):
		return false
	var expected := String(state.get("current_step_id", ""))
	if event_id != expected:
		event_ignored.emit(event_id, expected)
		return false
	var completed: Array = state.get("completed_ids", []).duplicate()
	if not completed.has(event_id):
		completed.append(event_id)
	var next_index := completed.size()
	state.completed_ids = completed
	state.step = next_index # compatibility for legacy UI/tests and old saves
	state.complete = next_index >= STEPS.size()
	state.current_step_id = "" if bool(state.complete) else String(STEPS[next_index].id)
	GameState.tutorial = state
	GameState.mark_save_dirty()
	step_completed.emit(event_id)
	state_changed.emit(snapshot())
	return true


func record_legacy_step(step: int) -> bool:
	var event_id := String(LEGACY_EVENT_BY_STEP.get(step, ""))
	return not event_id.is_empty() and record_event(event_id)


func current_step() -> Dictionary:
	var state := ensure_schema()
	if bool(state.get("complete", false)):
		return {}
	var index := int(state.get("step", 0))
	return STEPS[index].duplicate(true) if index >= 0 and index < STEPS.size() else {}


func snapshot() -> Dictionary:
	var state := ensure_schema()
	var result := state.duplicate(true)
	result.total_steps = STEPS.size()
	result.current_index = int(state.get("step", 0))
	result.current = current_step()
	return result


func _default_state() -> Dictionary:
	return {
		"version": SCHEMA_VERSION,
		"current_step_id": String(STEPS[0].id),
		"completed_ids": [],
		"step": 0,
		"skipped": false,
		"complete": false,
	}


func _normalize(source: Dictionary) -> Dictionary:
	var state := _default_state()
	state.skipped = bool(source.get("skipped", false))
	var completed: Array = []
	if int(source.get("version", 0)) >= SCHEMA_VERSION and source.get("completed_ids") is Array:
		for value: Variant in source.completed_ids:
			var step_id := String(value)
			if _step_index(step_id) == completed.size() and not completed.has(step_id):
				completed.append(step_id)
	else:
		# The old schema stored the index of the next objective in `step`.
		var legacy_count := clampi(int(source.get("step", 0)), 0, STEPS.size())
		for index: int in legacy_count:
			completed.append(String(STEPS[index].id))
	state.completed_ids = completed
	state.step = completed.size()
	state.complete = bool(source.get("complete", false)) or completed.size() >= STEPS.size()
	state.current_step_id = "" if bool(state.complete) else String(STEPS[completed.size()].id)
	return state


func _step_index(step_id: String) -> int:
	for index: int in STEPS.size():
		if String(STEPS[index].id) == step_id:
			return index
	return -1
