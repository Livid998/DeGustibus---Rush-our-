class_name DayCycleClockManager
extends Node

## Emitted for every whole in-game minute crossed.
signal minute_changed(day: int, minute: int)
signal period_changed(period_id: String)
signal rush_warning(rush_id: String, seconds_remaining: float)
signal rush_started(rush_id: String)
signal rush_ended(rush_id: String)
## Stable integration hook for end-of-day payroll and rewards. The argument is
## the day that has just finished; persistence is already updated when emitted.
signal day_completed(completed_day: int)
signal pause_changed(paused: bool)

const MINUTES_PER_DAY := 1440.0
const MINIMUM_POSITIVE_INTERVAL := 0.05

var day := 1
var minute := 0.0
var paused := false
var current_period_id := "morning"
var rush_active := false
var active_rush_id := ""
var warning_rush_id := ""

var _forced_rush := false
var _forced_rush_remaining := -1.0
var _writing_world_clock := false
var _event_history: Dictionary = {}
var _last_emitted_absolute_minute := -1
var _pending_schedule_events: Array[Dictionary] = []
var _rush_windows_cache: Array[Dictionary] = []
var _balance_cache_ready := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_read_world_clock()
	_refresh_derived_state(false)
	if not GameState.world_clock_changed.is_connected(_on_world_clock_changed):
		GameState.world_clock_changed.connect(_on_world_clock_changed)
	if not GameState.restaurant_state_changed.is_connected(_on_restaurant_state_changed):
		GameState.restaurant_state_changed.connect(_on_restaurant_state_changed)


func _exit_tree() -> void:
	if paused and get_tree() != null:
		get_tree().paused = false


func _process(delta: float) -> void:
	if paused:
		return
	var restaurant_state := String(GameState.restaurant_state)
	if restaurant_state not in ["open", "closing"]:
		return
	advance_seconds(delta, _simulation_speed(), restaurant_state)


func advance_seconds(real_delta: float, speed_override: float = -1.0, restaurant_state_override: String = "") -> void:
	if paused or real_delta <= 0.0:
		return
	var restaurant_state := restaurant_state_override if not restaurant_state_override.is_empty() else String(GameState.restaurant_state)
	if restaurant_state not in ["open", "closing"]:
		return
	var speed := speed_override if speed_override >= 0.0 else _simulation_speed()
	if speed <= 0.0:
		return
	if _forced_rush and _forced_rush_remaining >= 0.0:
		_forced_rush_remaining = maxf(_forced_rush_remaining - real_delta * speed, 0.0)
		if _forced_rush_remaining <= 0.0:
			force_rush_debug(false)
	var configured_duration := maxf(float(DataRegistry.balance_value("day_cycle.real_seconds_at_1x", 1.0)), MINIMUM_POSITIVE_INTERVAL)
	var elapsed_minutes := real_delta * speed * MINUTES_PER_DAY / configured_duration
	_advance_game_minutes(elapsed_minutes)


func set_clock(day_value: int, minute_value: float, emit_transitions: bool = false) -> void:
	day = maxi(day_value, 1)
	minute = clampf(minute_value, 0.0, MINUTES_PER_DAY - 0.001)
	_last_emitted_absolute_minute = int(floor(_absolute_minute()))
	_commit_world_clock()
	_refresh_derived_state(emit_transitions)


func set_paused(value: bool, pause_tree: bool = true) -> void:
	if paused == value:
		if pause_tree and is_inside_tree() and get_tree().paused != value:
			get_tree().paused = value
		return
	paused = value
	if pause_tree and is_inside_tree():
		get_tree().paused = paused
	if paused:
		_commit_world_clock()
	pause_changed.emit(paused)


func force_rush_debug(enabled: bool = true, duration_seconds: float = -1.0) -> void:
	if _forced_rush == enabled:
		if enabled and duration_seconds >= 0.0:
			_forced_rush_remaining = duration_seconds
		return
	var previous_id := active_rush_id
	var was_active := rush_active
	_forced_rush = enabled
	_forced_rush_remaining = duration_seconds if enabled else -1.0
	_refresh_derived_state(false)
	if was_active and previous_id != active_rush_id:
		rush_ended.emit(previous_id)
	if rush_active and (not was_active or previous_id != active_rush_id):
		rush_started.emit(active_rush_id)


func is_rush_forced() -> bool:
	return _forced_rush


func reset_event_history() -> void:
	_event_history.clear()


func formatted_time() -> String:
	var whole_minute := clampi(int(floor(minute)), 0, 1439)
	return "%02d:%02d" % [whole_minute / 60, whole_minute % 60]


func period_display_name(period_id: String = "") -> String:
	var value := current_period_id if period_id.is_empty() else period_id
	return {
		"morning": "Mattina",
		"lunch": "Pranzo",
		"afternoon": "Pomeriggio",
		"dinner": "Cena",
		"night": "Notte",
		"debug": "Rush debug",
	}.get(value, value.capitalize())


func period_id_at(minute_value: float) -> String:
	var normalized := fposmod(minute_value, MINUTES_PER_DAY)
	var windows := configured_rush_windows()
	if windows.is_empty():
		return "morning"
	for window: Dictionary in windows:
		if normalized >= float(window.get("start", 0.0)) and normalized < float(window.get("end", 0.0)):
			return String(window.get("id", "rush"))
	if normalized < float((windows[0] as Dictionary).get("start", 0.0)):
		return "morning"
	if windows.size() == 1:
		return "night"
	if normalized < float((windows[1] as Dictionary).get("start", 0.0)):
		return "afternoon"
	return "night"


func configured_rush_windows() -> Array[Dictionary]:
	if not _balance_cache_ready:
		_rush_windows_cache.clear()
		var configured: Variant = DataRegistry.balance_value("day_cycle.rush_windows", [])
		if configured is Array:
			for value: Variant in configured:
				if value is Dictionary:
					_rush_windows_cache.append((value as Dictionary).duplicate(true))
		_rush_windows_cache.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("start", 0.0)) < float(b.get("start", 0.0))
		)
		_balance_cache_ready = true
	return _rush_windows_cache


func reload_balance_cache() -> void:
	_balance_cache_ready = false
	configured_rush_windows()
	_refresh_derived_state(false)


func natural_rush_window_at(minute_value: float = -1.0) -> Dictionary:
	var normalized := minute if minute_value < 0.0 else fposmod(minute_value, MINUTES_PER_DAY)
	for window: Dictionary in configured_rush_windows():
		if normalized >= float(window.get("start", 0.0)) and normalized < float(window.get("end", 0.0)):
			return window
	return {}


func next_rush_window(minute_value: float = -1.0) -> Dictionary:
	var normalized := minute if minute_value < 0.0 else fposmod(minute_value, MINUTES_PER_DAY)
	for window: Dictionary in configured_rush_windows():
		if normalized < float(window.get("start", 0.0)):
			return window
	return {}


func rush_status(speed_override: float = -1.0) -> Dictionary:
	var speed := maxf(speed_override if speed_override >= 0.0 else _simulation_speed(), MINIMUM_POSITIVE_INTERVAL)
	var minutes_per_real_second := MINUTES_PER_DAY / maxf(float(DataRegistry.balance_value("day_cycle.real_seconds_at_1x", 1.0)), MINIMUM_POSITIVE_INTERVAL)
	if rush_active:
		if _forced_rush:
			return {
				"phase": "active",
				"id": active_rush_id,
				"seconds_remaining": _forced_rush_remaining,
				"progress": 0.5,
			}
		var active := natural_rush_window_at()
		var start := float(active.get("start", minute))
		var end := float(active.get("end", minute + 1.0))
		return {
			"phase": "active",
			"id": String(active.get("id", active_rush_id)),
			"seconds_remaining": maxf((end - minute) / (minutes_per_real_second * speed), 0.0),
			"progress": clampf(inverse_lerp(start, end, minute), 0.0, 1.0),
		}
	var next := next_rush_window()
	if next.is_empty():
		return {"phase": "idle", "id": "", "seconds_remaining": -1.0, "progress": 0.0}
	var configured_warning := maxf(float(DataRegistry.balance_value("day_cycle.rush_warning_seconds", 0.0)), 0.0)
	var remaining := maxf((float(next.get("start", minute)) - minute) / (minutes_per_real_second * speed), 0.0)
	if remaining <= configured_warning / speed:
		return {
			"phase": "warning",
			"id": String(next.get("id", "")),
			"seconds_remaining": remaining,
			"progress": clampf(1.0 - remaining / maxf(configured_warning / speed, MINIMUM_POSITIVE_INTERVAL), 0.0, 1.0),
		}
	return {"phase": "idle", "id": "", "seconds_remaining": remaining, "progress": 0.0}


func reputation_traffic_multiplier(reputation: float) -> float:
	var configured_min := maxf(float(DataRegistry.balance_value("traffic.reputation_multiplier_min", 1.0)), MINIMUM_POSITIVE_INTERVAL)
	var configured_max := maxf(float(DataRegistry.balance_value("traffic.reputation_multiplier_max", configured_min)), configured_min)
	return lerpf(configured_min, configured_max, clampf(inverse_lerp(1.0, 5.0, reputation), 0.0, 1.0))


func period_traffic_multiplier(minute_value: float = -1.0) -> float:
	var evaluated := minute if minute_value < 0.0 else minute_value
	if period_id_at(evaluated) == "night":
		return maxf(float(DataRegistry.balance_value("traffic.night_multiplier", 1.0)), MINIMUM_POSITIVE_INTERVAL)
	return 1.0


func rush_traffic_multiplier(minute_value: float = -1.0) -> float:
	if _forced_rush and minute_value < 0.0:
		var strongest := 1.0
		for window: Dictionary in configured_rush_windows():
			strongest = maxf(strongest, float(window.get("traffic_multiplier", 1.0)))
		return strongest
	var active := natural_rush_window_at(minute_value)
	return maxf(float(active.get("traffic_multiplier", 1.0)), MINIMUM_POSITIVE_INTERVAL)


func effective_spawn_interval(reputation: float, has_producible_recipe: bool = true, minute_value: float = -1.0) -> float:
	var configured_base := maxf(float(DataRegistry.balance_value("traffic.base_spawn_interval", 1.0)), MINIMUM_POSITIVE_INTERVAL)
	var demand_multiplier := reputation_traffic_multiplier(reputation)
	demand_multiplier *= period_traffic_multiplier(minute_value)
	demand_multiplier *= rush_traffic_multiplier(minute_value)
	if not has_producible_recipe:
		# Stock-outs reuse the configured off-peak traffic multiplier so the
		# restaurant never becomes permanently empty, while demand visibly slows.
		demand_multiplier *= maxf(float(DataRegistry.balance_value("traffic.night_multiplier", 1.0)), MINIMUM_POSITIVE_INTERVAL)
	return maxf(configured_base / maxf(demand_multiplier, MINIMUM_POSITIVE_INTERVAL), MINIMUM_POSITIVE_INTERVAL)


func group_cap(seat_count: int) -> int:
	var queue_buffer := maxi(int(DataRegistry.balance_value("traffic.queue_buffer_groups", 0)), 0)
	var absolute_cap := maxi(int(DataRegistry.balance_value("traffic.absolute_group_cap", 1)), 1)
	return mini(maxi(seat_count, 0) + queue_buffer, absolute_cap)


func lighting_profile_for_minute(minute_value: float) -> Dictionary:
	var normalized := fposmod(minute_value, MINUTES_PER_DAY)
	var solar_curve := maxf(sin(PI * normalized / MINUTES_PER_DAY), 0.0)
	var daylight := pow(solar_curve, 1.35)
	var night_factor := 1.0 - daylight
	var horizon_factor := clampf(1.0 - absf(daylight - 0.48) * 4.0, 0.0, 1.0)
	var night_background := Color("1b3544")
	var day_background := Color("91bdc1")
	var night_ambient := Color("71849d")
	var day_ambient := Color("dce3e2")
	var neutral_sun := Color("fff7e8")
	var warm_sun := Color("ffc58f")
	return {
		"daylight": daylight,
		"night_factor": night_factor,
		"background_color": night_background.lerp(day_background, daylight),
		"ambient_color": night_ambient.lerp(day_ambient, daylight),
		# Keep ambient contribution under the established palette-preservation
		# ceiling; the day/night contrast comes from color, sun and background.
		"ambient_energy": lerpf(0.20, 0.40, daylight),
		"sun_color": neutral_sun.lerp(warm_sun, horizon_factor * 0.42),
		"sun_energy": lerpf(0.08, 0.84, daylight),
		"lamp_energy": smoothstep(0.42, 0.78, night_factor),
	}


func _advance_game_minutes(elapsed_minutes: float) -> void:
	if elapsed_minutes <= 0.0:
		return
	var old_absolute := _absolute_minute()
	var new_absolute := old_absolute + elapsed_minutes
	var crossed_whole_minute := int(floor(old_absolute)) != int(floor(new_absolute))
	_pending_schedule_events.clear()
	if crossed_whole_minute:
		_emit_scheduled_events(old_absolute, new_absolute)
	var previous_period := current_period_id
	var new_day_index := int(floor(new_absolute / MINUTES_PER_DAY))
	day = new_day_index + 1
	minute = fposmod(new_absolute, MINUTES_PER_DAY)
	if crossed_whole_minute:
		_emit_minute_boundaries(old_absolute, new_absolute)
		_commit_world_clock()
		_refresh_derived_state(false)
	_emit_pending_schedule_events()
	if current_period_id != previous_period:
		period_changed.emit(current_period_id)
	_prune_event_history()


func _emit_minute_boundaries(old_absolute: float, new_absolute: float) -> void:
	var first := int(floor(old_absolute)) + 1
	var last := int(floor(new_absolute))
	for absolute_whole: int in range(first, last + 1):
		if absolute_whole <= _last_emitted_absolute_minute:
			continue
		var emitted_day := absolute_whole / int(MINUTES_PER_DAY) + 1
		var emitted_minute := posmod(absolute_whole, int(MINUTES_PER_DAY))
		minute_changed.emit(emitted_day, emitted_minute)
		_last_emitted_absolute_minute = absolute_whole


func _emit_scheduled_events(old_absolute: float, new_absolute: float) -> void:
	var events: Array[Dictionary] = []
	var warning_game_minutes := maxf(float(DataRegistry.balance_value("day_cycle.rush_warning_seconds", 0.0)), 0.0)
	warning_game_minutes *= MINUTES_PER_DAY / maxf(float(DataRegistry.balance_value("day_cycle.real_seconds_at_1x", 1.0)), MINIMUM_POSITIVE_INTERVAL)
	var first_day_index := int(floor(old_absolute / MINUTES_PER_DAY))
	var last_day_index := int(floor(new_absolute / MINUTES_PER_DAY))
	for day_index: int in range(first_day_index, last_day_index + 1):
		var day_start := float(day_index) * MINUTES_PER_DAY
		for window: Dictionary in configured_rush_windows():
			var rush_id := String(window.get("id", "rush"))
			events.append({"at": day_start + float(window.get("start", 0.0)) - warning_game_minutes, "kind": "warning", "id": rush_id, "day_index": day_index})
			events.append({"at": day_start + float(window.get("start", 0.0)), "kind": "start", "id": rush_id, "day_index": day_index})
			events.append({"at": day_start + float(window.get("end", 0.0)), "kind": "end", "id": rush_id, "day_index": day_index})
		if day_index < last_day_index:
			events.append({"at": day_start + MINUTES_PER_DAY, "kind": "day", "id": "", "day_index": day_index})
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a.at), float(b.at)):
			return float(a.at) < float(b.at)
		return _event_priority(String(a.kind)) < _event_priority(String(b.kind))
	)
	for event: Dictionary in events:
		var boundary := float(event.at)
		if not (old_absolute < boundary and boundary <= new_absolute):
			continue
		var key := "%d:%s:%s" % [int(event.day_index), String(event.kind), String(event.id)]
		if _event_history.has(key):
			continue
		_event_history[key] = true
		_pending_schedule_events.append(event)


func _emit_pending_schedule_events() -> void:
	for event: Dictionary in _pending_schedule_events:
		match String(event.kind):
			"warning":
				if not _forced_rush:
					rush_warning.emit(String(event.id), float(DataRegistry.balance_value("day_cycle.rush_warning_seconds", 0.0)))
			"start":
				if not _forced_rush:
					rush_started.emit(String(event.id))
			"end":
				if not _forced_rush:
					rush_ended.emit(String(event.id))
			"day":
				var completed_day := int(event.day_index) + 1
				_process_day_completion(completed_day)
				day_completed.emit(completed_day)
	_pending_schedule_events.clear()


func _process_day_completion(completed_day: int) -> void:
	var economy := get_node_or_null("/root/EconomyManager")
	if economy != null and economy.has_method("process_daily_payroll"):
		economy.call("process_daily_payroll", completed_day)
	var last_reward_day := maxi(int(GameState.progress.get("last_album_reward_day", 0)), 0)
	if completed_day <= last_reward_day:
		return
	var collection := get_node_or_null("/root/CollectionManager")
	if collection != null and collection.has_method("handle_day_completed"):
		collection.call("handle_day_completed", completed_day)
	GameState.progress.last_album_reward_day = completed_day
	GameState.mark_save_dirty()


func _event_priority(kind: String) -> int:
	return {"warning": 0, "end": 1, "day": 2, "start": 3}.get(kind, 4)


func _refresh_derived_state(_emit_transitions: bool) -> void:
	current_period_id = period_id_at(minute)
	if _forced_rush:
		rush_active = true
		active_rush_id = "debug"
		warning_rush_id = ""
		return
	var active := natural_rush_window_at()
	rush_active = not active.is_empty()
	active_rush_id = String(active.get("id", "")) if rush_active else ""
	var status := rush_status()
	warning_rush_id = String(status.get("id", "")) if String(status.get("phase", "")) == "warning" else ""


func _read_world_clock() -> void:
	var value: Dictionary = GameState.world_clock
	day = maxi(int(value.get("day", 1)), 1)
	minute = clampf(float(value.get("minute", DataRegistry.balance_value("day_cycle.start_minute", 0.0))), 0.0, MINUTES_PER_DAY - 0.001)
	_last_emitted_absolute_minute = int(floor(_absolute_minute()))


func _commit_world_clock() -> void:
	_writing_world_clock = true
	GameState.set_world_clock({"day": day, "minute": minute})
	_writing_world_clock = false


func _on_world_clock_changed(_value: Dictionary) -> void:
	if _writing_world_clock:
		return
	var previous_period := current_period_id
	_read_world_clock()
	_refresh_derived_state(false)
	if current_period_id != previous_period:
		period_changed.emit(current_period_id)


func _on_restaurant_state_changed(_value: String) -> void:
	_commit_world_clock()


func _absolute_minute() -> float:
	return float(day - 1) * MINUTES_PER_DAY + minute


func _simulation_speed() -> float:
	var simulation := get_tree().root.get_node_or_null("SimulationManager") if is_inside_tree() else null
	if simulation != null:
		return maxf(float(simulation.get("simulation_speed")), 0.0)
	return 1.0


func _prune_event_history() -> void:
	var oldest_day_index := maxi(day - 3, 0)
	for key: String in _event_history.keys():
		var key_day := int(key.get_slice(":", 0))
		if key_day < oldest_day_index:
			_event_history.erase(key)
