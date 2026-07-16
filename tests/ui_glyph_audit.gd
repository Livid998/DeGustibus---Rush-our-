extends Node

const RUNTIME_ROOTS := [
	"res://scripts",
	"res://data",
	"res://scenes",
	"res://web",
]
const RUNTIME_EXTENSIONS := ["gd", "json", "tscn", "html"]
const RESULT_PATH := "res://tests/ui-glyph-audit-result.txt"

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	for root_path: String in RUNTIME_ROOTS:
		_audit_directory(root_path)
	var legacy_text := "10" + String.chr(0x25CF) + " " + String.chr(0x00D7) + "5 " + String.chr(0x2191) + " " + String.chr(0x1F512)
	_check(
		GameFonts.unsupported_runtime_characters(GameFonts.web_safe_text(legacy_text)).is_empty(),
		"legacy text symbols are sanitized before reaching a Godot control"
	)
	for texture: Texture2D in [
		GameIcons.currency_icon(), GameIcons.lock_icon(),
		GameIcons.rotate_left_icon(), GameIcons.rotate_right_icon(),
		GameIcons.previous_icon(), GameIcons.next_icon(),
		GameIcons.play_icon(), GameIcons.pause_icon(), GameIcons.priority_icon(),
	]:
		_check(texture != null and texture.get_width() > 0 and texture.get_height() > 0, "required Web-safe UI icon is importable")
	var report := "UI GLYPH AUDIT: %d checks, %d failures\n" % [checks, failures.size()]
	for failure: String in failures:
		report += "FAIL: %s\n" % failure
	var result_file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if result_file:
		result_file.store_string(report)
	print(report)
	get_tree().quit(0 if failures.is_empty() else 1)


func _audit_directory(path: String) -> void:
	var directory := DirAccess.open(path)
	_check(directory != null, "runtime directory exists: %s" % path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry.begins_with("."):
			entry = directory.get_next()
			continue
		var entry_path := path.path_join(entry)
		if directory.current_is_dir():
			_audit_directory(entry_path)
		elif entry.get_extension().to_lower() in RUNTIME_EXTENSIONS:
			_audit_file(entry_path)
		entry = directory.get_next()
	directory.list_dir_end()


func _audit_file(path: String) -> void:
	var source := FileAccess.get_file_as_string(path)
	var unsupported := GameFonts.unsupported_runtime_characters(source)
	_check(
		unsupported.is_empty(),
		"%s uses only Fredoka/Web-safe runtime glyphs%s" % [path, " (unsupported: %s)" % _format_codepoints(unsupported) if not unsupported.is_empty() else ""]
	)


func _format_codepoints(codepoints: PackedInt32Array) -> String:
	var values: Array[String] = []
	for codepoint: int in codepoints:
		values.append("U+%04X" % codepoint)
	return ", ".join(values)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
