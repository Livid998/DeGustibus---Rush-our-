class_name PersistenceDiagnosticsPanel
extends VBoxContainer

var _ui: Node
var _status_label: Label
var _diagnostics_label: Label
var _restore_button: Button


static func create(ui: Node) -> PersistenceDiagnosticsPanel:
	var panel := PersistenceDiagnosticsPanel.new()
	panel.name = "PersistenceDiagnosticsPanel"
	panel._ui = ui
	return panel


func _ready() -> void:
	add_theme_constant_override("separation", 12)
	_build_persistence_card()
	_build_diagnostics_card()
	SaveManager.import_completed.connect(_on_import_completed)
	SaveManager.persistence_status_changed.connect(_on_persistence_status_changed)
	_refresh_status()


func _build_persistence_card() -> void:
	var card: Control = _ui.call("make_card")
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	card.add_child(box)
	var title := Label.new()
	title.text = "SALVATAGGI E RECUPERO"
	title.add_theme_font_override("font", GameFonts.bold())
	title.add_theme_font_size_override("font_size", 19)
	box.add_child(title)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_color_override("font_color", Color("52686b"))
	box.add_child(_status_label)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 8)
	box.add_child(actions)
	actions.add_child(_ui.call("make_button", "Esporta salvataggio", _export_save, "green"))
	var import_button: Button = _ui.call("make_button", "Importa salvataggio", _import_save, "blue")
	import_button.disabled = not OS.has_feature("web")
	actions.add_child(import_button)
	_restore_button = _ui.call("make_button", "Ripristina backup", _restore_backup, "yellow")
	actions.add_child(_restore_button)
	add_child(card)


func _build_diagnostics_card() -> void:
	var card: Control = _ui.call("make_card")
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	card.add_child(box)
	var title := Label.new()
	title.text = "DIAGNOSTICA LOCALE"
	title.add_theme_font_override("font", GameFonts.bold())
	title.add_theme_font_size_override("font_size", 19)
	box.add_child(title)
	var description := Label.new()
	description.text = "Frame time, memoria e problemi di navigazione restano sul dispositivo. Nessun dato viene inviato automaticamente."
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_color_override("font_color", Color("52686b"))
	box.add_child(description)
	_diagnostics_label = Label.new()
	_diagnostics_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_diagnostics_label)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_child(_ui.call("make_button", "Esporta diagnostica", _export_diagnostics, "blue"))
	actions.add_child(_ui.call("make_button", "Azzera diagnostica", _reset_diagnostics, "ghost"))
	box.add_child(actions)
	add_child(card)


func _refresh_status() -> void:
	var status: Dictionary = SaveManager.persistence_status()
	var state_name: String = String({
		"persistent": "spazio Web persistente concesso",
		"best-effort": "spazio Web non garantito: esporta periodicamente un backup",
		"unsupported": "persistenza Web non supportata dal browser",
		"error": "errore nel controllo della persistenza",
		"filesystem": "salvataggio locale su filesystem",
		"checking": "controllo della persistenza in corso",
		"unavailable": "persistenza Web non disponibile"
	}.get(String(status.get("state", "unavailable")), "stato sconosciuto"))
	_status_label.text = "Stato: %s. Backup: %s. Modifiche non salvate: %s." % [
		state_name,
		"valido" if bool(status.get("backup_valid", false)) else "non disponibile",
		"si" if bool(status.get("unsaved_changes", false)) else "no"
	]
	_restore_button.disabled = not bool(status.get("backup_valid", false))
	var diagnostics: Dictionary = RuntimeDiagnostics.snapshot()
	_diagnostics_label.text = "Frame p95: %.1f ms  |  Memoria: %.1f MiB  |  Context loss: %d" % [
		float(diagnostics.frame_window.p95_ms),
		float(diagnostics.latest.get("static_memory_bytes", 0)) / 1048576.0,
		int(diagnostics.counters.get("webglcontextlost", 0))
	]


func _export_save() -> void:
	var result: Dictionary = SaveManager.download_export()
	if bool(result.get("success", false)):
		_ui.call("show_toast", "Salvataggio esportato", "income")
	else:
		_ui.call("show_toast", String(result.get("error", "Esportazione non riuscita")), "warning")


func _import_save() -> void:
	var result: Dictionary = SaveManager.request_import_picker()
	if not bool(result.get("success", false)):
		_ui.call("show_toast", String(result.get("error", "Importazione non riuscita")), "warning")


func _restore_backup() -> void:
	SaveManager.restore_backup()


func _export_diagnostics() -> void:
	var result: Dictionary = RuntimeDiagnostics.download_export()
	if bool(result.get("success", false)):
		_ui.call("show_toast", "Diagnostica esportata", "income")
	else:
		_ui.call("show_toast", String(result.get("error", "Esportazione non riuscita")), "warning")


func _reset_diagnostics() -> void:
	RuntimeDiagnostics.reset()
	_refresh_status()
	_ui.call("show_toast", "Diagnostica locale azzerata", "info")


func _on_import_completed(success: bool, message: String) -> void:
	_ui.call("show_toast", message, "income" if success else "warning")
	_refresh_status()
	if success and _ui.has_method("refresh_screen"):
		_ui.call_deferred("refresh_screen")


func _on_persistence_status_changed(_status: Dictionary) -> void:
	_refresh_status()
