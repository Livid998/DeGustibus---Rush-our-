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
const MAX_JSON_DEPTH := 64
const MAX_JSON_NODES := 250000
const MAX_JSON_CONTAINER_ENTRIES := 50000

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
	var transaction := _apply_payload_transactionally(candidate)
	if not bool(transaction.get("success", false)):
		return _import_result(false, String(transaction.get("error", "Salvataggio non valido")))

	if _persistence_allowed():
		var primary_snapshot := _capture_file_snapshot(SAVE_PATH)
		var previous_payload := JSON.stringify(transaction.previous_state, "  ")
		# The backup is always the known-good runtime snapshot. The imported file is
		# written only after it has survived deserialization, migration and a second
		# validation as the canonical current schema.
		if not _write_text(BACKUP_PATH, previous_payload):
			_rollback_runtime_transaction(transaction)
			return _import_result(false, "Impossibile creare il backup prima dell'importazione")
		var canonical_payload := JSON.stringify(transaction.canonical, "  ")
		if not _replace_primary_preserving_backup(canonical_payload):
			_restore_file_snapshot(SAVE_PATH, primary_snapshot)
			_rollback_runtime_transaction(transaction)
			return _import_result(false, "Impossibile salvare il file importato")

	_finish_runtime_transaction()
	var result := _import_result(true, "Salvataggio importato", bool(extraction.get("legacy", false)))
	import_completed.emit(true, String(result.message))
	return result


func has_valid_backup() -> bool:
	if not FileAccess.file_exists(BACKUP_PATH):
		return false
	var parsed: Variant = _read_json(BACKUP_PATH)
	return parsed is Dictionary and _validate_save_payload((parsed as Dictionary).duplicate(true)).is_empty()


func restore_backup() -> Dictionary:
	if not FileAccess.file_exists(BACKUP_PATH):
		return _import_result(false, "Nessun backup valido disponibile")
	var raw: Variant = _read_json(BACKUP_PATH)
	if not raw is Dictionary:
		return _import_result(false, "Il backup non contiene un salvataggio valido")
	var transaction := _apply_payload_transactionally((raw as Dictionary).duplicate(true))
	if not bool(transaction.get("success", false)):
		return _import_result(false, String(transaction.get("error", "Backup non valido")))
	if _persistence_allowed():
		var primary_snapshot := _capture_file_snapshot(SAVE_PATH)
		var canonical_payload := JSON.stringify(transaction.canonical, "  ")
		if not _replace_primary_preserving_backup(canonical_payload):
			_restore_file_snapshot(SAVE_PATH, primary_snapshot)
			_rollback_runtime_transaction(transaction)
			return _import_result(false, "Impossibile ripristinare il backup")
	_finish_runtime_transaction()
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
	var state := GameState.serialize()
	var validation_error := _validate_save_payload(state, true)
	if not validation_error.is_empty():
		push_error("Refusing to persist an invalid runtime save: %s" % validation_error)
		save_completed.emit(false)
		return false
	var payload := JSON.stringify(state, "  ")
	var success := _write_atomically(payload)
	if success:
		dirty = false
		_autosave_remaining = 0.0
	else:
		push_error("Could not write save file")
	save_completed.emit(success)
	return success


func load_game() -> bool:
	if not _persistence_allowed():
		return false
	var original_state := GameState.serialize().duplicate(true)
	var original_dirty := dirty
	var original_autosave := _autosave_remaining
	if FileAccess.file_exists(SAVE_PATH):
		var primary: Variant = _read_json(SAVE_PATH)
		if primary is Dictionary:
			var primary_result := _load_candidate((primary as Dictionary).duplicate(true), false)
			if bool(primary_result.get("success", false)):
				return true
			push_warning("Invalid primary save (%s); attempting backup" % String(primary_result.get("error", "unknown error")))
		else:
			push_warning("Corrupt save file; attempting backup")
	elif not FileAccess.file_exists(BACKUP_PATH):
		return false
	_restore_runtime_snapshot(original_state, original_dirty, original_autosave)
	if _load_backup():
		return true
	_restore_runtime_snapshot(original_state, original_dirty, original_autosave)
	return false


func _load_backup() -> bool:
	if not FileAccess.file_exists(BACKUP_PATH):
		return false
	var parsed: Variant = _read_json(BACKUP_PATH)
	if not parsed is Dictionary:
		return false
	return bool(_load_candidate((parsed as Dictionary).duplicate(true), true).get("success", false))


## Applies a parsed save to the runtime as a reversible transaction. A legacy
## payload is deliberately deserialized before any file write so migrations run
## in memory; only GameState.serialize() (the canonical current schema) may be
## persisted by the caller.
func _apply_payload_transactionally(candidate: Dictionary) -> Dictionary:
	var validation_error := _validate_save_payload(candidate)
	if not validation_error.is_empty():
		return {"success": false, "error": validation_error}
	var previous_state := GameState.serialize().duplicate(true)
	var transaction := {
		"success": false,
		"error": "",
		"previous_state": previous_state,
		"previous_dirty": dirty,
		"previous_autosave": _autosave_remaining,
		"canonical": {},
	}
	_loading = true
	GameState.deserialize(candidate.duplicate(true))
	_loading = false
	var canonical := GameState.serialize().duplicate(true)
	var canonical_error := _validate_save_payload(canonical, true)
	if canonical_error.is_empty() and int(canonical.get("save_version", -1)) != GameState.SAVE_VERSION:
		canonical_error = "La migrazione non ha prodotto la versione corrente"
	if not canonical_error.is_empty():
		transaction.error = "Applicazione non valida: %s" % canonical_error
		_rollback_runtime_transaction(transaction)
		return transaction
	transaction.success = true
	transaction.canonical = canonical
	return transaction


func _load_candidate(candidate: Dictionary, from_backup: bool) -> Dictionary:
	var transaction := _apply_payload_transactionally(candidate)
	if not bool(transaction.get("success", false)):
		return transaction
	var canonical: Dictionary = transaction.canonical
	# Promote a recovered backup and canonicalize every legacy/non-normalized
	# primary immediately. This prevents a later autosave from ever publishing a
	# partially migrated or merely structurally valid document.
	var needs_persist := from_backup or candidate != canonical
	if needs_persist:
		var primary_snapshot := _capture_file_snapshot(SAVE_PATH)
		var payload := JSON.stringify(canonical, "  ")
		var persisted := _replace_primary_preserving_backup(payload) if from_backup else _write_atomically(payload)
		if not persisted:
			_restore_file_snapshot(SAVE_PATH, primary_snapshot)
			_rollback_runtime_transaction(transaction)
			return {"success": false, "error": "Impossibile persistere il salvataggio canonico"}
	_finish_runtime_transaction()
	return {"success": true, "canonical": canonical}


func _finish_runtime_transaction() -> void:
	_loading = false
	dirty = false
	_autosave_remaining = 0.0


func _rollback_runtime_transaction(transaction: Dictionary) -> void:
	_restore_runtime_snapshot(
		(transaction.get("previous_state", {}) as Dictionary).duplicate(true),
		bool(transaction.get("previous_dirty", false)),
		float(transaction.get("previous_autosave", 0.0))
	)


func _restore_runtime_snapshot(snapshot: Dictionary, was_dirty: bool, autosave_remaining: float) -> void:
	_loading = true
	GameState.deserialize(snapshot.duplicate(true))
	_loading = false
	dirty = was_dirty
	_autosave_remaining = autosave_remaining


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


func _capture_file_snapshot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "payload": ""}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"exists": true, "payload": "", "readable": false}
	return {"exists": true, "payload": file.get_as_text(), "readable": true}


func _restore_file_snapshot(path: String, snapshot: Dictionary) -> bool:
	if not bool(snapshot.get("exists", false)):
		return _remove_if_exists(path)
	if not bool(snapshot.get("readable", true)):
		return false
	return _write_text(path, String(snapshot.get("payload", "")))


func _remove_if_exists(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


func _extract_import_payload(root: Dictionary) -> Dictionary:
	if root.has("payload") or root.has("app_id") or root.has("package_version"):
		if not root.get("app_id") is String or String(root.get("app_id", "")) != PACKAGE_APP_ID:
			return {"success": false, "error": "Il file appartiene a un'altra applicazione"}
		if not _is_integral_number(root.get("package_version")) or int(root.get("package_version", 0)) != PACKAGE_VERSION:
			return {"success": false, "error": "Versione del pacchetto non supportata"}
		if not root.get("payload") is Dictionary:
			return {"success": false, "error": "Payload del pacchetto mancante"}
		return {"success": true, "payload": (root.payload as Dictionary).duplicate(true), "legacy": false}
	return {"success": true, "payload": root.duplicate(true), "legacy": true}


func _validate_save_payload(candidate: Dictionary, require_current: bool = false) -> String:
	var tree_error := _validate_json_tree(candidate)
	if not tree_error.is_empty():
		return tree_error
	if not candidate.has("save_version"):
		return "Versione del salvataggio mancante"
	var version_value: Variant = candidate.get("save_version")
	if not _is_integral_number(version_value):
		return "Versione del salvataggio non valida"
	var version := int(version_value)
	if version < 0:
		return "Versione del salvataggio non valida"
	if version > GameState.SAVE_VERSION:
		return "Il salvataggio proviene da una versione piu recente del gioco"
	if require_current and version != GameState.SAVE_VERSION:
		return "Il salvataggio non e nello schema corrente"
	for numeric_key: String in ["money", "reputation", "review_reward_progress", "reputation_weight"]:
		if candidate.has(numeric_key) and not _is_number(candidate[numeric_key]):
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

	var error := _validate_entry_dictionary(
		candidate.get("stock", {}),
		["amount", "reserved", "storage_units", "average_cost", "threshold", "target", "lot", "quality"],
		["unlocked", "auto_reorder"],
		["storage_type", "supplier"],
		"stock"
	)
	if not error.is_empty():
		return error
	error = _validate_entry_dictionary(
		candidate.get("menu", {}),
		["price"],
		["active", "unlocked", "manual_paused", "auto_sold_out", "sold_out"],
		[],
		"menu"
	)
	if not error.is_empty():
		return error
	for numeric_map_key: String in ["purchased_preparations", "album_inventory"]:
		error = _validate_scalar_map(candidate.get(numeric_map_key, {}), TYPE_FLOAT, numeric_map_key, true)
		if not error.is_empty():
			return error
	if candidate.has("album_discovered"):
		error = _validate_scalar_map(candidate.album_discovered, TYPE_BOOL, "album_discovered")
		if not error.is_empty():
			return error
	for array_key: String in ["employees", "candidates"]:
		error = _validate_record_array(candidate.get(array_key, []), array_key, ["id", "name", "role", "appearance"], ["salary", "speed", "skill", "energy", "wage"])
		if not error.is_empty():
			return error
	error = _validate_layout(candidate.get("layout", []))
	if not error.is_empty():
		return error
	if candidate.get("world_clock", {}) is Dictionary:
		error = _validate_known_fields(candidate.get("world_clock", {}), ["day", "minute"], [], [])
		if not error.is_empty():
			return "Campo non valido in world_clock: %s" % error
	if candidate.get("settings", {}) is Dictionary:
		error = _validate_known_fields(
			candidate.get("settings", {}),
			["music_volume", "ambience_volume", "sfx_volume", "ui_volume", "camera_zoom", "camera_quadrant"],
			["music", "sound", "high_contrast", "reduced_motion"],
			["graphics_quality"]
		)
		if not error.is_empty():
			return "Campo non valido in settings: %s" % error
	if candidate.get("tutorial", {}) is Dictionary:
		var tutorial: Dictionary = candidate.get("tutorial", {})
		error = _validate_known_fields(tutorial, ["version", "step"], ["skipped", "complete"], ["current_step_id"])
		if not error.is_empty():
			return "Campo non valido in tutorial: %s" % error
		if tutorial.has("completed_ids"):
			if not tutorial.completed_ids is Array:
				return "Campo non valido in tutorial: completed_ids"
			for completed_id: Variant in tutorial.completed_ids:
				if not completed_id is String:
					return "Campo non valido in tutorial: completed_ids"
	if candidate.get("progress", {}) is Dictionary:
		var progress: Dictionary = candidate.get("progress", {})
		error = _validate_known_fields(
			progress,
			["customers_served", "desserts_served", "services_started", "album_reward_pity", "last_payroll_day", "wage_debt"],
			["emergency_recovery_used"],
			[]
		)
		if not error.is_empty():
			return "Campo non valido in progress: %s" % error
		if progress.has("onboarding_pacing"):
			if not progress.onboarding_pacing is Dictionary:
				return "Campo non valido in progress: onboarding_pacing"
			error = _validate_onboarding_pacing(progress.onboarding_pacing)
			if not error.is_empty():
				return error
	if candidate.get("restaurant_profile", {}) is Dictionary:
		error = _validate_known_fields(candidate.restaurant_profile, ["uniform_variant"], [], ["player_name", "restaurant_name", "avatar_appearance", "badge_id"])
		if not error.is_empty():
			return "Campo non valido in restaurant_profile: %s" % error
	if candidate.get("pending_delivery_batch", {}) is Dictionary:
		error = _validate_delivery_batch(candidate.pending_delivery_batch, "pending_delivery_batch", true)
		if not error.is_empty():
			return error
	if candidate.get("cleanliness_state", {}) is Dictionary:
		error = _validate_known_fields(candidate.cleanliness_state, ["score", "dirty_tables", "dirty_dishes", "spills", "kitchen_dirt", "below_pest_threshold_seconds"], [], [])
		if not error.is_empty():
			return "Campo non valido in cleanliness_state: %s" % error
	if candidate.get("pest_state", {}) is Dictionary:
		var pest: Dictionary = candidate.pest_state
		error = _validate_known_fields(pest, ["last_spawn_day", "spawn_serial", "below_threshold_seconds", "risk_progress"], ["warning"], ["pending_kind"])
		if not error.is_empty():
			return "Campo non valido in pest_state: %s" % error
		if pest.has("active") and not pest.active is Array:
			return "Campo non valido in pest_state: active"
	if candidate.get("staff_preferences", {}) is Dictionary:
		for employee_id: Variant in candidate.staff_preferences:
			var preference: Variant = candidate.staff_preferences[employee_id]
			if preference != null and not preference is String and not preference is Dictionary:
				return "Campo non valido in staff_preferences.%s" % String(employee_id)
	error = _validate_reviews(candidate.get("reviews", []))
	if not error.is_empty():
		return error
	if require_current:
		for required_key: String in [
			"money", "reputation", "stock", "menu", "employees", "candidates", "layout",
			"settings", "tutorial", "progress", "album_inventory", "album_discovered",
			"world_clock", "restaurant_profile", "pending_delivery_batch"
		]:
			if not candidate.has(required_key):
				return "Campo canonico mancante: %s" % required_key
	return ""


func _validate_json_tree(root: Variant) -> String:
	var stack: Array = [{"value": root, "depth": 0, "path": "$"}]
	var nodes := 0
	while not stack.is_empty():
		var current: Dictionary = stack.pop_back()
		var value: Variant = current.value
		var depth := int(current.depth)
		var path := String(current.path)
		nodes += 1
		if nodes > MAX_JSON_NODES:
			return "Il salvataggio contiene troppi elementi"
		if depth > MAX_JSON_DEPTH:
			return "Il salvataggio supera la profondita massima in %s" % path
		match typeof(value):
			TYPE_NIL, TYPE_BOOL, TYPE_INT:
				pass
			TYPE_FLOAT:
				if not is_finite(float(value)):
					return "Numero non finito in %s" % path
			TYPE_STRING:
				if String(value).to_utf8_buffer().size() > MAX_IMPORT_BYTES:
					return "Testo eccessivamente lungo in %s" % path
			TYPE_ARRAY:
				var array: Array = value
				if array.size() > MAX_JSON_CONTAINER_ENTRIES:
					return "Troppi elementi in %s" % path
				for index: int in array.size():
					stack.append({"value": array[index], "depth": depth + 1, "path": "%s[%d]" % [path, index]})
			TYPE_DICTIONARY:
				var dictionary: Dictionary = value
				if dictionary.size() > MAX_JSON_CONTAINER_ENTRIES:
					return "Troppe voci in %s" % path
				for key: Variant in dictionary:
					if not key is String:
						return "Chiave non testuale in %s" % path
					stack.append({"value": dictionary[key], "depth": depth + 1, "path": "%s.%s" % [path, String(key)]})
			_:
				return "Tipo non serializzabile in %s" % path
	return ""


func _validate_entry_dictionary(value: Variant, numeric_fields: Array, bool_fields: Array, string_fields: Array, section_name: String) -> String:
	if not value is Dictionary:
		return "Sezione non valida: %s" % section_name
	for entry_id: Variant in value:
		var entry: Variant = value[entry_id]
		if not entry is Dictionary:
			return "Voce non valida in %s" % section_name
		var error := _validate_known_fields(entry, numeric_fields, bool_fields, string_fields)
		if not error.is_empty():
			return "Campo non valido in %s.%s: %s" % [section_name, String(entry_id), error]
	return ""


func _validate_known_fields(value: Dictionary, numeric_fields: Array, bool_fields: Array, string_fields: Array) -> String:
	for key: Variant in numeric_fields:
		if value.has(key) and not _is_number(value[key]):
			return String(key)
	for key: Variant in bool_fields:
		if value.has(key) and not value[key] is bool:
			return String(key)
	for key: Variant in string_fields:
		if value.has(key) and not value[key] is String:
			return String(key)
	return ""


func _validate_scalar_map(value: Variant, expected_type: int, section_name: String, numeric: bool = false) -> String:
	if not value is Dictionary:
		return "Sezione non valida: %s" % section_name
	for key: Variant in value:
		var entry: Variant = value[key]
		if numeric:
			if not _is_number(entry):
				return "Valore non valido in %s.%s" % [section_name, String(key)]
		elif typeof(entry) != expected_type:
			return "Valore non valido in %s.%s" % [section_name, String(key)]
	return ""


func _validate_record_array(value: Variant, section_name: String, string_fields: Array, numeric_fields: Array) -> String:
	if not value is Array:
		return "Sezione non valida: %s" % section_name
	for index: int in value.size():
		var record: Variant = value[index]
		if not record is Dictionary:
			return "Voce non valida in %s" % section_name
		var error := _validate_known_fields(record, numeric_fields, [], string_fields)
		if not error.is_empty():
			return "Campo non valido in %s[%d]: %s" % [section_name, index, error]
	return ""


func _validate_layout(value: Variant) -> String:
	if not value is Array:
		return "Sezione non valida: layout"
	for index: int in value.size():
		var record: Variant = value[index]
		if not record is Dictionary:
			return "Voce non valida in layout"
		var error := _validate_known_fields(record, ["rotation", "attachment_slot"], [], ["uid", "item", "support_uid", "wall_uid", "table_uid"])
		if not error.is_empty():
			return "Campo non valido in layout[%d]: %s" % [index, error]
		if record.has("cell"):
			if not record.cell is Array or record.cell.size() != 2 or not _is_number(record.cell[0]) or not _is_number(record.cell[1]):
				return "Cella non valida in layout[%d]" % index
	return ""


func _validate_onboarding_pacing(value: Dictionary) -> String:
	var error := _validate_known_fields(
		value,
		["version", "elapsed_unpaused_seconds"],
		["legacy_bypassed", "first_album_reward_pending", "first_album_reward_complete", "complete"],
		[]
	)
	if not error.is_empty():
		return "Campo non valido in progress.onboarding_pacing: %s" % error
	for dictionary_key: String in ["milestones", "current_recommendation", "last_day_summary"]:
		if value.has(dictionary_key) and not value[dictionary_key] is Dictionary:
			return "Campo non valido in progress.onboarding_pacing: %s" % dictionary_key
	return ""


func _validate_delivery_batch(value: Dictionary, path: String, allow_urgent: bool) -> String:
	var error := _validate_known_fields(value, ["remaining", "paid_cost"], ["paid"], ["id"])
	if not error.is_empty():
		return "Campo non valido in %s: %s" % [path, error]
	if value.has("items"):
		if not value.items is Dictionary:
			return "Campo non valido in %s: items" % path
		for ingredient_id: Variant in value.items:
			var item: Variant = value.items[ingredient_id]
			if not item is Dictionary:
				return "Voce non valida in %s.items.%s" % [path, String(ingredient_id)]
			error = _validate_known_fields(item, ["amount", "unit_cost"], [], [])
			if not error.is_empty():
				return "Campo non valido in %s.items.%s: %s" % [path, String(ingredient_id), error]
	if allow_urgent and value.has("urgent"):
		if not value.urgent is Dictionary:
			return "Campo non valido in %s: urgent" % path
		return _validate_delivery_batch(value.urgent, "%s.urgent" % path, false)
	return ""


func _validate_reviews(value: Variant) -> String:
	if not value is Array:
		return "Sezione non valida: reviews"
	for index: int in value.size():
		var review: Variant = value[index]
		if not review is Dictionary:
			return "Voce non valida in reviews"
		var error := _validate_known_fields(
			review,
			["day", "minute", "stars", "satisfaction", "group_total", "tip", "tip_rate"],
			[],
			["id", "group_id", "customer_type", "text", "outcome"]
		)
		if not error.is_empty():
			return "Campo non valido in reviews[%d]: %s" % [index, error]
		for array_key: String in ["recipe_ids", "positive_tags", "negative_tags", "observation_keys", "incident_ids"]:
			if not review.has(array_key):
				continue
			if not review[array_key] is Array:
				return "Campo non valido in reviews[%d]: %s" % [index, array_key]
			for entry: Variant in review[array_key]:
				if not entry is String:
					return "Campo non valido in reviews[%d]: %s" % [index, array_key]
	return ""


func _is_number(value: Variant) -> bool:
	return (value is int) or (value is float and is_finite(float(value)))


func _is_integral_number(value: Variant) -> bool:
	if value is int:
		return true
	return value is float and is_finite(float(value)) and is_equal_approx(float(value), roundf(float(value)))


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
