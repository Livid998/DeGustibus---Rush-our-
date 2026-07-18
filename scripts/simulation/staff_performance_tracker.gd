class_name StaffPerformanceTracker
extends RefCounted

## Detailed per-employee operational statistics for the current service. This
## deliberately follows SimulationManager's existing service-stat lifecycle:
## it resets on open and never changes the save schema, preserving v9 saves.

const MAX_RECENT_EVENTS := 24

var _records: Dictionary = {}


func reset() -> void:
	_records.clear()


func record_task(
	employee_id: String,
	task_kind: String,
	action: String,
	task: Dictionary,
	completed_at: float
) -> void:
	if employee_id.is_empty():
		return
	var record := _record(employee_id)
	record.tasks_completed = int(record.get("tasks_completed", 0)) + 1
	var by_kind: Dictionary = record.get("tasks_by_kind", {})
	by_kind[task_kind] = int(by_kind.get(task_kind, 0)) + 1
	record.tasks_by_kind = by_kind
	if not action.is_empty():
		var by_action: Dictionary = record.get("tasks_by_action", {})
		by_action[action] = int(by_action.get(action, 0)) + 1
		record.tasks_by_action = by_action
	record.last_task = {
		"id": String(task.get("id", "")),
		"kind": task_kind,
		"action": action,
		"completed_at": completed_at,
	}
	_records[employee_id] = record


func record_quality_sample(
	employee_id: String,
	sample: Dictionary,
	task: Dictionary,
	order: Dictionary
) -> void:
	if employee_id.is_empty():
		return
	var record := _record(employee_id)
	var score := clampf(float(sample.get("quality_score", 70.0)), 0.0, 100.0)
	record.quality_sample_count = int(record.get("quality_sample_count", 0)) + 1
	record.quality_score_sum = float(record.get("quality_score_sum", 0.0)) + score
	record.last_quality_score = score
	record.last_quality_station = String(task.get("station", ""))
	record.last_quality_order_id = String(order.get("id", ""))
	_records[employee_id] = record


func record_quality_events(
	employee_id: String,
	result: Dictionary,
	task: Dictionary,
	order: Dictionary,
	recorded_at: float
) -> bool:
	if employee_id.is_empty():
		return false
	var events: Variant = result.get("quality_events", [])
	if not events is Array or (events as Array).is_empty():
		return false
	var record := _record(employee_id)
	var by_event: Dictionary = record.get("quality_events_by_id", {})
	var recent: Array = record.get("recent_quality_events", [])
	for event_value: Variant in events:
		if not event_value is Dictionary:
			continue
		var event := event_value as Dictionary
		var event_id := String(event.get("id", "quality_event"))
		by_event[event_id] = int(by_event.get(event_id, 0)) + 1
		record.quality_event_count = int(record.get("quality_event_count", 0)) + 1
		var entry := event.duplicate(true)
		entry.employee_id = employee_id
		entry.task_id = String(task.get("id", ""))
		entry.order_id = String(order.get("id", ""))
		entry.recorded_at = recorded_at
		recent.append(entry)
	var defect_id := String(result.get("defect", ""))
	if not defect_id.is_empty():
		record.defects_attributed = int(record.get("defects_attributed", 0)) + 1
		var by_defect: Dictionary = record.get("defects_by_id", {})
		by_defect[defect_id] = int(by_defect.get(defect_id, 0)) + 1
		record.defects_by_id = by_defect
		record.last_defect = {
			"id": defect_id,
			"severity": String(result.get("defect_severity", "")),
			"task_id": String(task.get("id", "")),
			"order_id": String(order.get("id", "")),
			"recorded_at": recorded_at,
		}
	while recent.size() > MAX_RECENT_EVENTS:
		recent.pop_front()
	record.quality_events_by_id = by_event
	record.recent_quality_events = recent
	_records[employee_id] = record
	return true


func snapshot(employees: Array, employee_id: String = "") -> Dictionary:
	var result: Dictionary = {}
	var employee_ids: Array[String] = []
	for employee_value: Variant in employees:
		if not employee_value is Dictionary:
			continue
		var known_id := String((employee_value as Dictionary).get("id", ""))
		if not known_id.is_empty() and (employee_id.is_empty() or known_id == employee_id):
			employee_ids.append(known_id)
	if not employee_id.is_empty() and not employee_ids.has(employee_id):
		employee_ids.append(employee_id)
	for known_id: String in employee_ids:
		var record := _record(known_id)
		var sample_count := int(record.get("quality_sample_count", 0))
		record.quality_average = (
			float(record.get("quality_score_sum", 0.0)) / float(sample_count)
			if sample_count > 0 else 0.0
		)
		record.scope = "current_service"
		result[known_id] = record
	if not employee_id.is_empty():
		return (result.get(employee_id, {}) as Dictionary).duplicate(true)
	return result


func _record(employee_id: String) -> Dictionary:
	var value: Variant = _records.get(employee_id, {})
	if value is Dictionary and not (value as Dictionary).is_empty():
		return (value as Dictionary).duplicate(true)
	return {
		"employee_id": employee_id,
		"tasks_completed": 0,
		"tasks_by_kind": {},
		"tasks_by_action": {},
		"quality_sample_count": 0,
		"quality_score_sum": 0.0,
		"last_quality_score": 0.0,
		"last_quality_station": "",
		"last_quality_order_id": "",
		"quality_event_count": 0,
		"quality_events_by_id": {},
		"defects_attributed": 0,
		"defects_by_id": {},
		"recent_quality_events": [],
		"last_defect": {},
		"last_task": {},
	}
