extends Node

const SAVE_PATH := "user://restaurant_city_pro_save.json"
const BACKUP_PATH := "user://restaurant_city_pro_save.backup.json"

var writes_enabled := true


func save_game() -> bool:
	if not _persistence_allowed():
		return true
	if FileAccess.file_exists(SAVE_PATH):
		var old_file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		var backup := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
		if old_file and backup:
			backup.store_string(old_file.get_as_text())
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("Could not write save file")
		return false
	file.store_string(JSON.stringify(GameState.serialize(), "  "))
	return true


func load_game() -> bool:
	if not _persistence_allowed():
		return false
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
		push_warning("Corrupt save file; attempting backup")
		return _load_backup()
	GameState.deserialize(json.data)
	return true


func _load_backup() -> bool:
	if not FileAccess.file_exists(BACKUP_PATH):
		GameState.reset_to_defaults()
		return false
	var file := FileAccess.open(BACKUP_PATH, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		GameState.deserialize(parsed)
		return true
	GameState.reset_to_defaults()
	return false


func reset_save() -> void:
	if not _persistence_allowed():
		GameState.reset_to_defaults()
		return
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	if FileAccess.file_exists(BACKUP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BACKUP_PATH))
	GameState.reset_to_defaults()
	save_game()


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
