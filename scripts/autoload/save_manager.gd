extends Node

signal save_completed(success: bool)
signal import_completed(success: bool, message: String)
signal persistence_status_changed(status: Dictionary)

const SAVE_PATH := "user://restaurant_city_pro_save.json"
const BACKUP_PATH := "user://restaurant_city_pro_save.backup.json"
const TEMP_PATH := "user://restaurant_city_pro_save.tmp.json"
const PACKAGE_APP_ID := "degustibus-rush-hour"
const PACKAGE_VERSION := 1
const MAX_IMPORT_BYTES := 5 * 1024 * 1024

var writes_enabled := true
var dirty := false
var _autosave_remaining := 0.0
var _loading := false
var _web_persistence_api: Variant = null
var _web_lifecycle_callback: Variant = null
var _web_import_callback: Variant = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_state_signals()
	_setup_web_persistence()


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_CLOSE_REQUEST]:
		flush_autosave()


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


## Returns a portable, versioned JSON package. The contained payload is the
## exact same schema used by the regular save file, so old raw save files can
## continue to be imported without a separate conversion tool.
func export_package() -> String:
	var package := {
		"app_id": PACKAGE_APP_ID,
		"package_version": PACKAGE_VERSION,
		"created_at_utc": Time.get_datetime_string_from_system(true, true),
		"game_save_version": GameState.SAVE_VERSION,
		"commit": _build_commit(),
		"payload": GameState.serialize()
	}
	return JSON.stringify(package, "  ")


func download_export(filename: String = "degustibus-save.json") -> Dictionary:
	var payload := export_package()
	if not _web_bridge_available() or _web_persistence_api == null:
		return {"success": false, "error": "Download disponibile solo nella versione Web", "payload": payload}
	var clean_filename := filename.get_file()
	if clean_filename.is_empty():
		clean_filename = "degustibus-save.json"
	_web_persistence_api.call("downloadText", clean_filename, payload)
	return {"success": true, "error": "", "payload": ""}


func request_import_picker() -> Dictionary:
	if not _web_bridge_available() or _web_persistence_api == null:
		return _import_result(false, "Selettore file disponibile solo nella versione Web")
	if _web_import_callback == null:
		var bridge: Object = Engine.get_singleton("JavaScriptBridge")
		_web_import_callback = bridge.call("create_callback", Callable(self, "_on_web_import_selected"))
	_web_persistence_api.call("selectJsonFile", _web_import_callback, MAX_IMPORT_BYTES)
	return {"success": true, "pending": true, "error": ""}


## Imports either the versioned package produced above or a legacy raw save.
## Validation is performed on a deep copy before GameState is touched. The
## previous runtime state is kept as the rollback snapshot and, when writes are
## allowed, as the on-disk backup.
func import_package_json(payload_text: String) -> Dictionary:
	var byte_count := payload_text.to_utf8_buffer().size()
	if byte_count <= 0:
		return _import_result(false, "Il file e vuoto")
	if byte_count > MAX_IMPORT_BYTES:
		return _import_result(false, "Il file supera il limite di 5 MiB")
	var json := JSON.new()
	var parse_error := json.parse(payload_text)
	if parse_error != OK:
		return _import_result(false, "JSON non valido: %s" % json.get_error_message())
	if not json.data is Dictionary:
		return _import_result(false, "Il file non contiene un salvataggio")
	var extraction := _extract_import_payload((json.data as Dictionary).duplicate(true))
	if not bool(extraction.get("success", false)):
		return _import_result(false, String(extraction.get("error", "Pacchetto non valido")))
	var candidate: Dictionary = (extraction.payload as Dictionary).duplicate(true)
	var validation_error := _validate_save_payload(candidate)
	if not validation_error.is_empty():
		return _import_result(false, validation_error)

	var previous_state := GameState.serialize().duplicate(true)
	var previous_payload := JSON.stringify(previous_state, "  ")
	var imported_payload := JSON.stringify(candidate, "  ")
	if _persistence_allowed():
		# Do not let the normal atomic rotation overwrite this known-good snapshot.
		if not _write_text(BACKUP_PATH, previous_payload):
			return _import_result(false, "Impossibile creare il backup prima dell'importazione")
		if not _replace_primary_preserving_backup(imported_payload):
			_write_text(SAVE_PATH, previous_payload)
			return _import_result(false, "Impossibile salvare il file importato")

	_loading = true
	GameState.deserialize(candidate)
	_loading = false
	dirty = false
	_autosave_remaining = 0.0
	var result := _import_result(true, "Salvataggio importato", bool(extraction.get("legacy", false)))
	import_completed.emit(true, String(result.message))
	return result


func has_valid_backup() -> bool:
	if not FileAccess.file_exists(BACKUP_PATH):
		return false
	var parsed: Variant = _read_json(BACKUP_PATH)
	return parsed is Dictionary and _validate_save_payload((parsed as Dictionary).duplicate(true)).is_empty()


func restore_backup() -> Dictionary:
	if not has_valid_backup():
		return _import_result(false, "Nessun backup valido disponibile")
	var candidate: Dictionary = (_read_json(BACKUP_PATH) as Dictionary).duplicate(true)
	var previous_state := GameState.serialize().duplicate(true)
	var previous_payload := JSON.stringify(previous_state, "  ")
	var backup_payload := JSON.stringify(candidate, "  ")
	if _persistence_allowed() and not _replace_primary_preserving_backup(backup_payload):
		_write_text(SAVE_PATH, previous_payload)
		return _import_result(false, "Impossibile ripristinare il backup")
	_loading = true
	GameState.deserialize(candidate)
	_loading = false
	dirty = false
	_autosave_remaining = 0.0
	var result := _import_result(true, "Backup ripristinato")
	import_completed.emit(true, String(result.message))
	return result


func persistence_status() -> Dictionary:
	var result := {
		"platform": "web" if OS.has_feature("web") else "native",
		"supported": not OS.has_feature("web"),
		"persisted": not OS.has_feature("web"),
		"state": "filesystem" if not OS.has_feature("web") else "unavailable",
		"last_error": "",
		"backup_valid": has_valid_backup(),
		"unsaved_changes": dirty
	}
	if not _web_bridge_available():
		return result
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	var raw: Variant = bridge.call(
		"eval",
		"JSON.stringify(window.degustibusPersistence ? window.degustibusPersistence.status() : {supported:false,persisted:false,state:'unavailable',last_error:'bridge missing'})",
		true
	)
	var parsed: Variant = JSON.parse_string(String(raw))
	if parsed is Dictionary:
		result.merge(parsed, true)
	return result


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


func _replace_primary_preserving_backup(payload: String) -> bool:
	if not _write_text(TEMP_PATH, payload):
		return false
	if FileAccess.file_exists(SAVE_PATH) and not _remove_if_exists(SAVE_PATH):
		_remove_if_exists(TEMP_PATH)
		return false
	var temp_absolute := ProjectSettings.globalize_path(TEMP_PATH)
	var save_absolute := ProjectSettings.globalize_path(SAVE_PATH)
	if DirAccess.rename_absolute(temp_absolute, save_absolute) == OK:
		return true
	var success := _write_text(SAVE_PATH, payload)
	_remove_if_exists(TEMP_PATH)
	return success


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


func _extract_import_payload(root: Dictionary) -> Dictionary:
	if root.has("payload") or root.has("app_id") or root.has("package_version"):
		if String(root.get("app_id", "")) != PACKAGE_APP_ID:
			return {"success": false, "error": "Il file appartiene a un'altra applicazione"}
		if int(root.get("package_version", 0)) != PACKAGE_VERSION:
			return {"success": false, "error": "Versione del pacchetto non supportata"}
		if not root.get("payload") is Dictionary:
			return {"success": false, "error": "Payload del pacchetto mancante"}
		return {"success": true, "payload": (root.payload as Dictionary).duplicate(true), "legacy": false}
	return {"success": true, "payload": root.duplicate(true), "legacy": true}


func _validate_save_payload(candidate: Dictionary) -> String:
	if not candidate.has("save_version"):
		return "Versione del salvataggio mancante"
	var version_value: Variant = candidate.get("save_version")
	if not (version_value is int or version_value is float):
		return "Versione del salvataggio non valida"
	var version := int(version_value)
	if version < 0:
		return "Versione del salvataggio non valida"
	if version > GameState.SAVE_VERSION:
		return "Il salvataggio proviene da una versione piu recente del gioco"
	for numeric_key: String in ["money", "reputation", "review_reward_progress", "reputation_weight"]:
		if candidate.has(numeric_key) and not (candidate[numeric_key] is int or candidate[numeric_key] is float):
			return "Campo numerico non valido: %s" % numeric_key
	for dictionary_key: String in [
		"stock", "menu", "settings", "tutorial", "purchased_preparations",
		"progress", "album_inventory", "album_discovered", "world_clock",
		"restaurant_profile", "pending_delivery_batch", "cleanliness_state",
		"pest_state", "staff_preferences"
	]:
		if candidate.has(dictionary_key) and not candidate[dictionary_key] is Dictionary:
			return "Sezione non valida: %s" % dictionary_key
	for array_key: String in ["employees", "candidates", "layout", "reviews"]:
		if candidate.has(array_key) and not candidate[array_key] is Array:
			return "Sezione non valida: %s" % array_key
	for section_key: String in ["stock", "menu"]:
		var section: Variant = candidate.get(section_key, {})
		if section is Dictionary:
			for entry_key: Variant in section:
				if not section[entry_key] is Dictionary:
					return "Voce non valida in %s" % section_key
	for array_key: String in ["employees", "candidates", "layout", "reviews"]:
		var section: Variant = candidate.get(array_key, [])
		if section is Array:
			for entry: Variant in section:
				if not entry is Dictionary:
					return "Voce non valida in %s" % array_key
	return ""


func _import_result(success: bool, message: String, legacy: bool = false) -> Dictionary:
	if not success:
		import_completed.emit(false, message)
	return {"success": success, "message": message, "error": "" if success else message, "legacy": legacy}


func _build_commit() -> String:
	if not FileAccess.file_exists("res://build-info.json"):
		return "development"
	var info: Variant = _read_json("res://build-info.json")
	if not info is Dictionary:
		return "development"
	return String((info as Dictionary).get("commit", "development"))


func _setup_web_persistence() -> void:
	if not _web_bridge_available():
		return
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	_web_persistence_api = bridge.call("get_interface", "degustibusPersistence")
	if _web_persistence_api == null:
		return
	_web_lifecycle_callback = bridge.call("create_callback", Callable(self, "_on_web_lifecycle"))
	_web_persistence_api.call("registerLifecycleCallback", _web_lifecycle_callback)
	_web_persistence_api.call("requestPersistence")


func _on_web_lifecycle(arguments: Array) -> void:
	if arguments.is_empty():
		return
	var event_name := String(arguments[0])
	if event_name in ["pagehide", "visibility-hidden"]:
		flush_autosave()
	elif event_name == "persistence-status":
		persistence_status_changed.emit(persistence_status())


func _on_web_import_selected(arguments: Array) -> void:
	if arguments.is_empty() or not bool(arguments[0]):
		var error := String(arguments[1]) if arguments.size() > 1 else "Importazione annullata"
		if error != "cancelled":
			_import_result(false, error)
		return
	if arguments.size() < 2:
		_import_result(false, "Il browser non ha restituito il contenuto del file")
		return
	import_package_json(String(arguments[1]))


func _web_bridge_available() -> bool:
	return OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge")


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
