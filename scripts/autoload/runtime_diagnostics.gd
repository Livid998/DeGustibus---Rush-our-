extends Node

## Local-only runtime diagnostics. Nothing in this service performs a network
## request: snapshots can only be read in memory or explicitly downloaded by
## the player.

signal event_recorded(event: Dictionary)

const MAX_FRAME_SAMPLES := 18000
const FRAME_TRIM_BATCH := 3000
const MAX_TIMELINE_SAMPLES := 3600
const MAX_EVENTS := 128

var enabled := true
var _started_unix := 0
var _frame_times_ms: Array[float] = []
var _timeline: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _counters: Dictionary = {}
var _gauges: Dictionary = {}
var _sample_elapsed := 0.0
var _web_runtime_api: Variant = null
var _web_event_callback: Variant = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_unix = int(Time.get_unix_time_from_system())
	_setup_web_bridge()


func _process(delta: float) -> void:
	if not enabled:
		return
	if delta > 0.0 and delta < 1.0:
		_frame_times_ms.append(delta * 1000.0)
		if _frame_times_ms.size() > MAX_FRAME_SAMPLES:
			_frame_times_ms = _frame_times_ms.slice(FRAME_TRIM_BATCH)
	_sample_elapsed += delta
	if _sample_elapsed >= 1.0:
		_sample_elapsed = fmod(_sample_elapsed, 1.0)
		_capture_timeline_sample()


func record_counter(name: String, amount: int = 1) -> void:
	if not enabled or name.is_empty():
		return
	_counters[name] = int(_counters.get(name, 0)) + amount


func set_gauge(name: String, value: Variant) -> void:
	if not enabled or name.is_empty():
		return
	if value is int or value is float or value is bool or value is String:
		_gauges[name] = value


func record_event(kind: String, details: Dictionary = {}) -> void:
	if not enabled or kind.is_empty():
		return
	var event := {
		"kind": kind,
		"utc": Time.get_datetime_string_from_system(true, true),
		"details": details.duplicate(true)
	}
	_events.append(event)
	if _events.size() > MAX_EVENTS:
		_events.pop_front()
	event_recorded.emit(event.duplicate(true))


func record_repath(amount: int = 1) -> void:
	record_counter("repaths", amount)


func record_neighbor_query(amount: int = 1) -> void:
	record_counter("neighbor_queries", amount)


func record_lease_conflict(amount: int = 1) -> void:
	record_counter("lease_conflicts", amount)


func record_navigation_timeout(amount: int = 1) -> void:
	record_counter("navigation_timeouts", amount)


func snapshot() -> Dictionary:
	var percentiles := _frame_percentiles()
	var latest: Dictionary = _timeline.back().duplicate(true) if not _timeline.is_empty() else _current_performance_sample()
	return {
		"schema_version": 1,
		"local_only": true,
		"started_unix": _started_unix,
		"captured_at_utc": Time.get_datetime_string_from_system(true, true),
		"uptime_seconds": maxi(int(Time.get_unix_time_from_system()) - _started_unix, 0),
		"platform": OS.get_name(),
		"web": OS.has_feature("web"),
		"frame_window": {
			"sample_count": _frame_times_ms.size(),
			"p50_ms": percentiles.p50_ms,
			"p95_ms": percentiles.p95_ms,
			"p99_ms": percentiles.p99_ms,
			"worst_ms": percentiles.worst_ms
		},
		"latest": latest,
		"counters": _counters.duplicate(true),
		"gauges": _gauges.duplicate(true),
		"events": _events.duplicate(true),
		"timeline": _timeline.duplicate(true)
	}


func reset() -> void:
	_started_unix = int(Time.get_unix_time_from_system())
	_frame_times_ms.clear()
	_timeline.clear()
	_events.clear()
	_counters.clear()
	_gauges.clear()
	_sample_elapsed = 0.0


func export_json() -> String:
	return JSON.stringify(snapshot(), "  ")


func download_export(filename: String = "degustibus-diagnostics.json") -> Dictionary:
	var payload := export_json()
	if not _web_bridge_available() or _web_runtime_api == null:
		return {"success": false, "error": "Download disponibile solo nella versione Web", "payload": payload}
	var clean_filename := filename.get_file()
	if clean_filename.is_empty():
		clean_filename = "degustibus-diagnostics.json"
	_web_runtime_api.downloadText(clean_filename, payload)
	return {"success": true, "error": "", "payload": ""}


func _capture_timeline_sample() -> void:
	_timeline.append(_current_performance_sample())
	if _timeline.size() > MAX_TIMELINE_SAMPLES:
		_timeline.pop_front()


func _current_performance_sample() -> Dictionary:
	return {
		"elapsed_seconds": maxi(int(Time.get_unix_time_from_system()) - _started_unix, 0),
		"fps": float(Performance.get_monitor(Performance.TIME_FPS)),
		"process_ms": float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0,
		"physics_ms": float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0,
		"static_memory_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"static_memory_peak_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"rendered_objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	}


func _frame_percentiles() -> Dictionary:
	if _frame_times_ms.is_empty():
		return {"p50_ms": 0.0, "p95_ms": 0.0, "p99_ms": 0.0, "worst_ms": 0.0}
	var sorted := _frame_times_ms.duplicate()
	sorted.sort()
	return {
		"p50_ms": _percentile(sorted, 0.50),
		"p95_ms": _percentile(sorted, 0.95),
		"p99_ms": _percentile(sorted, 0.99),
		"worst_ms": sorted.back()
	}


func _percentile(sorted: Array[float], fraction: float) -> float:
	if sorted.is_empty():
		return 0.0
	var index := clampi(int(ceil(fraction * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return snappedf(sorted[index], 0.001)


func _setup_web_bridge() -> void:
	if not _web_bridge_available():
		return
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	_web_runtime_api = bridge.call("get_interface", "degustibusRuntime")
	if _web_runtime_api == null:
		return
	_web_event_callback = bridge.call("create_callback", Callable(self, "_on_web_event"))
	_web_runtime_api.registerEventCallback(_web_event_callback)


func _on_web_event(arguments: Array) -> void:
	if arguments.is_empty():
		return
	var kind := String(arguments[0])
	record_counter(kind, 1)
	record_event(kind)


func _web_bridge_available() -> bool:
	return OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge")
