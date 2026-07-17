extends Node

signal save_completed(success: bool)

const SAVE_PATH := "user://restaurant_city_pro_save.json"
const BACKUP_PATH := "user://restaurant_city_pro_save.backup.json"
const TEMP_PATH := "user://restaurant_city_pro_save.tmp.json"

var writes_enabled := true
var dirty := false
var _autosave_remaining := 0.0
var _loading := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_state_signals()


func _process(delta: float) -> void:
	if not dirty or _loading or not _persistence_allowed():
		return
	_autosave_remaining -= delta
	if _autosave_remaining <= 0.0:
		save_game()


func request_autosave() -> void:
	if _loading or not _persistence_allowed():
		return
	# Do not postpone forever while a continuous system (for example the world
	# clock) keeps changing. The first dirty mutation starts the debounce window.
	if dirty:
		return
	dirty = true
	_autosave_remaining = maxf(float(DataRegistry.balance_value("save.autosave_debounce_seconds", 1.5)), 0.05)


func flush_autosave() -> bool:
	if not dirty:
		return true
	return save_game()


func has_unsaved_changes() -> bool:
	return dirty


func save_game() -> bool:
	if not _persistence_allowed():
		dirty = false
		return true
	var payload := JSON.stringify(GameState.serialize(), "  ")
	var success := _write_atomically(payload)
	if success:
		dirty = false
		_autosave_remaining = 0.0
	else:
		push_error("Could not write save file")
	save_completed.emit(success)
	return success


func load_game() -> bool:
	if not _persistence_allowed() or not FileAccess.file_exists(SAVE_PATH):
		return false
	var parsed: Variant = _read_json(SAVE_PATH)
	if not parsed is Dictionary:
		push_warning("Corrupt save file; attempting backup")
		# Keep the valid backup from being replaced by the corrupt primary on the
		# recovery autosave.
		_remove_if_exists(SAVE_PATH)
		return _load_backup()
	var loaded_version := int((parsed as Dictionary).get("save_version", 0))
	_loading = true
	GameState.deserialize(parsed)
	_loading = false
	dirty = false
	if loaded_version < GameState.SAVE_VERSION:
		request_autosave()
	return true


func _load_backup() -> bool:
	if not FileAccess.file_exists(BACKUP_PATH):
		GameState.reset_to_defaults()
		return false
	var parsed: Variant = _read_json(BACKUP_PATH)
	if parsed is Dictionary:
		_loading = true
		GameState.deserialize(parsed)
		_loading = false
		dirty = false
		request_autosave()
		return true
	GameState.reset_to_defaults()
	return false


func reset_save() -> void:
	if not _persistence_allowed():
		GameState.reset_to_defaults()
		dirty = false
		return
	_remove_if_exists(SAVE_PATH)
	_remove_if_exists(BACKUP_PATH)
	_remove_if_exists(TEMP_PATH)
	GameState.reset_to_defaults()
	save_game()


func _connect_state_signals() -> void:
	GameState.money_changed.connect(func(_value: int): request_autosave())
	GameState.reputation_changed.connect(func(_value: float): request_autosave())
	GameState.stock_changed.connect(func(_ingredient_id: String, _amount: int): request_autosave())
	GameState.menu_changed.connect(request_autosave)
	GameState.employees_changed.connect(request_autosave)
	GameState.layout_changed.connect(request_autosave)
	GameState.album_inventory_changed.connect(func(_ingredient_id: String, _amount: int): request_autosave())
	GameState.album_discovered_changed.connect(func(_ingredient_id: String, _discovered: bool): request_autosave())
	GameState.reviews_changed.connect(request_autosave)
	GameState.review_reward_progress_changed.connect(func(_value: int): request_autosave())
	GameState.world_clock_changed.connect(func(_value: Dictionary): request_autosave())
	GameState.restaurant_profile_changed.connect(func(_value: Dictionary): request_autosave())
	GameState.pending_delivery_batch_changed.connect(func(_value: Dictionary): request_autosave())
	GameState.cleanliness_state_changed.connect(func(_value: Dictionary): request_autosave())
	GameState.pest_state_changed.connect(func(_value: Dictionary): request_autosave())
	GameState.staff_preferences_changed.connect(func(_employee_id: String, _preference: Variant): request_autosave())


func _write_atomically(payload: String) -> bool:
	if not _write_text(TEMP_PATH, payload):
		return false
	var had_primary := FileAccess.file_exists(SAVE_PATH)
	if had_primary and not _copy_file(SAVE_PATH, BACKUP_PATH):
		_remove_if_exists(TEMP_PATH)
		return false
	if had_primary and not _remove_if_exists(SAVE_PATH):
		_remove_if_exists(TEMP_PATH)
		return false
	var temp_absolute := ProjectSettings.globalize_path(TEMP_PATH)
	var save_absolute := ProjectSettings.globalize_path(SAVE_PATH)
	if DirAccess.rename_absolute(temp_absolute, save_absolute) == OK:
		return true
	# Some Web virtual filesystems cannot rename. A direct write is the safest
	# available fallback; the previous primary is already preserved as backup.
	var fallback_success := _write_text(SAVE_PATH, payload)
	_remove_if_exists(TEMP_PATH)
	if fallback_success:
		return true
	if had_primary:
		_copy_file(BACKUP_PATH, SAVE_PATH)
	return false


func _write_text(path: String, payload: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(payload)
	file.flush()
	return true


func _copy_file(source_path: String, destination_path: String) -> bool:
	var source := FileAccess.open(source_path, FileAccess.READ)
	if source == null:
		return false
	var destination := FileAccess.open(destination_path, FileAccess.WRITE)
	if destination == null:
		return false
	destination.store_buffer(source.get_buffer(source.get_length()))
	destination.flush()
	return true


func _read_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return null
	return json.data


func _remove_if_exists(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


func _persistence_allowed() -> bool:
	# Automated scenes must be completely isolated from the player's user://
	# data. The explicit switch covers fixtures, while the scene/argument guard
	# also protects captures and any future smoke test that forgets to set it.
	if not writes_enabled:
		return false
	var current_scene := get_tree().current_scene
	if current_scene != null and String(current_scene.scene_file_path).begins_with("res://tests/"):
		return false
	for argument: String in OS.get_cmdline_args():
		if argument.begins_with("res://tests/"):
			return false
	return true
