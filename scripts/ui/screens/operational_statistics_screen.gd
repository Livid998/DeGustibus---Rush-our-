class_name OperationalStatisticsScreen
extends VBoxContainer

var _ui: RestaurantUI
var _built := false
var _hierarchy_build_count := 0
var _refresh_count := 0
var _summary_label: Label
var _beauty_label: Label
var _cleanliness_label: Label
var _pest_label: Label
var _employee_list: VBoxContainer
var _station_grid: GridContainer
var _employee_rows: Dictionary = {}
var _station_cards: Dictionary = {}


static func create(ui: RestaurantUI) -> OperationalStatisticsScreen:
	var screen := OperationalStatisticsScreen.new()
	screen.name = "OperationalStatisticsScreen"
	screen._ui = ui
	return screen


func _ready() -> void:
	_ensure_hierarchy()
	_connect_signals()
	refresh()


func _exit_tree() -> void:
	_disconnect_signals()


func refresh() -> void:
	_ensure_hierarchy()
	_refresh_count += 1
	_update_summary()
	_update_ambience()
	_update_employee_rows()
	_update_station_cards()
	GameFonts.sanitize_control_tree(self)


func apply_responsive_layout(phone: bool, portrait: bool) -> void:
	if _station_grid == null:
		return
	_station_grid.columns = 1 if phone or portrait else 2


func hierarchy_build_count() -> int:
	return _hierarchy_build_count


func refresh_count() -> int:
	return _refresh_count


func station_card_instance_ids() -> Dictionary:
	var result: Dictionary = {}
	for station_id: String in _station_cards:
		var record: Dictionary = _station_cards[station_id]
		var card: PanelContainer = record.get("card")
		result[station_id] = card.get_instance_id() if is_instance_valid(card) else 0
	return result


func _ensure_hierarchy() -> void:
	if _built:
		return
	_built = true
	_hierarchy_build_count += 1
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 12)

	var heading := Label.new()
	heading.text = "ANDAMENTO OPERATIVO"
	heading.add_theme_font_override("font", GameFonts.bold())
	heading.add_theme_font_size_override("font_size", 22)
	add_child(heading)
	var description := Label.new()
	description.text = "Ricavi, produttività e carico si aggiornano quando cambia il servizio, senza ricostruire la schermata."
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_color_override("font_color", Color("52686b"))
	add_child(description)

	var overview := _ui.make_card()
	overview.name = "OperationalSummaryCard"
	add_child(overview)
	_summary_label = Label.new()
	_summary_label.name = "OperationalSummaryLabel"
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overview.add_child(_summary_label)

	var ambience := _ui.make_card()
	ambience.name = "AmbienceSummaryCard"
	add_child(ambience)
	var ambience_flow := HFlowContainer.new()
	ambience_flow.add_theme_constant_override("h_separation", 18)
	ambience_flow.add_theme_constant_override("v_separation", 8)
	ambience.add_child(ambience_flow)
	_beauty_label = _ambience_metric(
		ambience_flow,
		GameIcons.casual_system_icon("beauty"),
		"Bellezza"
	)
	_cleanliness_label = _ambience_metric(
		ambience_flow,
		GameIcons.casual_system_icon("dirt"),
		"Pulizia"
	)
	_pest_label = _ambience_metric(
		ambience_flow,
		GameIcons.casual_system_icon("mouse"),
		"Infestazioni"
	)

	var employees_heading := Label.new()
	employees_heading.text = "PRODUTTIVITÀ BRIGATA"
	employees_heading.add_theme_font_override("font", GameFonts.bold())
	employees_heading.add_theme_font_size_override("font_size", 19)
	add_child(employees_heading)
	_employee_list = VBoxContainer.new()
	_employee_list.name = "OperationalEmployeeList"
	_employee_list.add_theme_constant_override("separation", 6)
	add_child(_employee_list)

	var stations_heading := Label.new()
	stations_heading.text = "CARICO POSTAZIONI"
	stations_heading.add_theme_font_override("font", GameFonts.bold())
	stations_heading.add_theme_font_size_override("font_size", 19)
	add_child(stations_heading)
	var stations_description := Label.new()
	stations_description.text = "Previsto dal menu, utilizzo reale, code e capacità disponibili."
	stations_description.add_theme_color_override("font_color", Color("52686b"))
	stations_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(stations_description)
	_station_grid = GridContainer.new()
	_station_grid.name = "OperationalStationGrid"
	_station_grid.columns = 2
	_station_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_station_grid.add_theme_constant_override("h_separation", 10)
	_station_grid.add_theme_constant_override("v_separation", 10)
	add_child(_station_grid)


func _update_summary() -> void:
	var summary: Dictionary = SimulationManager.summary()
	var unavailable: Array = summary.get("ingredients_out", [])
	var unavailable_text := ", ".join(unavailable) if not unavailable.is_empty() else "nessuno"
	_summary_label.text = (
		"Ricavi %d monete · Ingredienti %d monete · Personale %d monete · Utile %d monete\n"
		+ "Serviti %d · Persi %d · Soddisfazione %.0f%% · Tempo medio %.1fs\n"
		+ "Più venduto: %s · Meno venduto: %s · Spreco %d · Terminati: %s"
	) % [
		int(summary.get("revenue", 0)),
		int(summary.get("ingredient_cost", 0)),
		int(summary.get("labor_cost", 0)),
		int(summary.get("profit", 0)),
		int(summary.get("customers_served", 0)),
		int(summary.get("customers_lost", 0)),
		float(summary.get("satisfaction", 0.0)) * 100.0,
		float(summary.get("average_time", 0.0)),
		String(summary.get("top_recipe", "N/D")),
		String(summary.get("low_recipe", "N/D")),
		int(summary.get("waste", 0)),
		unavailable_text,
	]


func _update_ambience(snapshot_override: Dictionary = {}) -> void:
	if _beauty_label == null:
		return
	var snapshot := snapshot_override
	if snapshot.is_empty() and _ui != null and _ui.world != null:
		snapshot = _ui.world.ambience_snapshot()
	var beauty := float(snapshot.get("beauty_score", 0.0))
	var cleanliness := float(snapshot.get("cleanliness_score", 100.0))
	var pest: Dictionary = snapshot.get("pest", {})
	var visible_kinds: Array = pest.get("visible_kinds", [])
	var risk := float(pest.get("risk_progress", 0.0))
	_beauty_label.text = "Bellezza %.0f" % beauty
	_cleanliness_label.text = "Pulizia %.0f%%" % cleanliness
	_pest_label.text = (
		"Infestazione visibile"
		if not visible_kinds.is_empty()
		else "Rischio %.0f%%" % (risk * 100.0)
	)
	_pest_label.add_theme_color_override(
		"font_color",
		Color("b94e48") if not visible_kinds.is_empty() or risk >= 0.5
		else Color("376c4a")
	)


func _ambience_metric(
	parent: HFlowContainer,
	texture: Texture2D,
	initial_text: String
) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	parent.add_child(row)
	var icon := TextureRect.new()
	icon.texture = texture
	icon.custom_minimum_size = Vector2(34, 34)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var label := Label.new()
	label.text = initial_text
	label.add_theme_font_override("font", GameFonts.semibold())
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	return label


func _update_employee_rows() -> void:
	var live_ids: Dictionary = {}
	var summary: Dictionary = SimulationManager.summary()
	var employee_tasks: Dictionary = summary.get("employee_tasks", {})
	for employee: Dictionary in GameState.employees:
		var employee_id := String(employee.get("id", ""))
		if employee_id.is_empty():
			continue
		live_ids[employee_id] = true
		var record: Dictionary = _employee_rows.get(employee_id, {})
		if record.is_empty():
			record = _create_employee_row()
			_employee_rows[employee_id] = record
		var name_label: Label = record.get("name_label")
		var value_label: Label = record.get("value_label")
		name_label.text = "%s · %s" % [
			String(employee.get("name", "Dipendente")),
			_role_name(String(employee.get("role", ""))),
		]
		value_label.text = "%d task · stress %.0f%%" % [
			int(employee_tasks.get(employee_id, 0)),
			float(employee.get("stress", 0.0)) * 100.0,
		]
	for employee_id: String in _employee_rows.keys():
		if live_ids.has(employee_id):
			continue
		var stale: Dictionary = _employee_rows[employee_id]
		var row: HBoxContainer = stale.get("row")
		if is_instance_valid(row):
			row.queue_free()
		_employee_rows.erase(employee_id)


func _create_employee_row() -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_employee_list.add_child(row)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(name_label)
	var value_label := Label.new()
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)
	return {
		"row": row,
		"name_label": name_label,
		"value_label": value_label,
	}


func _update_station_cards() -> void:
	var live_ids: Dictionary = {}
	for metric: Dictionary in SimulationManager.station_metrics():
		if int(metric.get("capacity", 0)) == 0 and float(metric.get("predicted", 0.0)) <= 0.0:
			continue
		var station_id := String(metric.get("id", ""))
		if station_id.is_empty():
			continue
		live_ids[station_id] = true
		var record: Dictionary = _station_cards.get(station_id, {})
		if record.is_empty():
			record = _create_station_card(station_id)
			_station_cards[station_id] = record
		_update_station_card(record, metric)
	for station_id: String in _station_cards.keys():
		if live_ids.has(station_id):
			continue
		var stale: Dictionary = _station_cards[station_id]
		var card: PanelContainer = stale.get("card")
		if is_instance_valid(card):
			card.queue_free()
		_station_cards.erase(station_id)


func _create_station_card(station_id: String) -> Dictionary:
	var card := _ui.make_card()
	card.name = "StationCard_%s" % station_id
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_station_grid.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(label)
	var bar := ProgressBar.new()
	bar.max_value = 150.0
	bar.show_percentage = true
	bar.custom_minimum_size.y = 24
	box.add_child(bar)
	return {
		"card": card,
		"label": label,
		"bar": bar,
	}


func _update_station_card(record: Dictionary, metric: Dictionary) -> void:
	var predicted := float(metric.get("predicted", 0.0))
	var status := (
		"SOVRACCARICO" if predicted > 100.0
		else "elevato" if predicted > 80.0
		else "regolare" if predicted > 45.0
		else "sottoutilizzato"
	)
	var label: Label = record.get("label")
	label.text = (
		"%s · previsto %.0f%% (%s) · attuale %.0f%%\n"
		+ "Coda %d · attivi %d/%d · attesa media %.1fs · completati %d · bloccati %d"
	) % [
		String(metric.get("name", "")),
		predicted,
		status,
		float(metric.get("utilization", 0.0)),
		int(metric.get("queue", 0)),
		int(metric.get("busy", 0)),
		int(metric.get("capacity", 0)),
		float(metric.get("average_wait", 0.0)),
		int(metric.get("completed", 0)),
		int(metric.get("blocked", 0)),
	]
	label.add_theme_color_override(
		"font_color",
		Color("b94e48") if predicted > 100.0
		else Color("9b761e") if predicted > 80.0
		else Color("376c4a")
	)
	var bar: ProgressBar = record.get("bar")
	bar.value = minf(predicted, 150.0)


func _connect_signals() -> void:
	_connect_signal(SimulationManager, "statistics_changed", "_on_data_changed")
	_connect_signal(SimulationManager, "task_board_changed", "_on_data_changed")
	_connect_signal(GameState, "employees_changed", "_on_data_changed")
	_connect_signal(GameState, "stock_changed", "_on_stock_changed")
	if _ui != null and _ui.world != null:
		_connect_signal(_ui.world, "ambience_changed", "_on_ambience_changed")
		_connect_signal(_ui.world, "pest_warning_changed", "_on_pest_warning_changed")


func _disconnect_signals() -> void:
	_disconnect_signal(SimulationManager, "statistics_changed", "_on_data_changed")
	_disconnect_signal(SimulationManager, "task_board_changed", "_on_data_changed")
	_disconnect_signal(GameState, "employees_changed", "_on_data_changed")
	_disconnect_signal(GameState, "stock_changed", "_on_stock_changed")
	if _ui != null and _ui.world != null:
		_disconnect_signal(_ui.world, "ambience_changed", "_on_ambience_changed")
		_disconnect_signal(_ui.world, "pest_warning_changed", "_on_pest_warning_changed")


func _connect_signal(source: Object, signal_name: String, method_name: String) -> void:
	var callback := Callable(self, method_name)
	if source.has_signal(signal_name) and not source.is_connected(signal_name, callback):
		source.connect(signal_name, callback)


func _disconnect_signal(source: Object, signal_name: String, method_name: String) -> void:
	var callback := Callable(self, method_name)
	if source.has_signal(signal_name) and source.is_connected(signal_name, callback):
		source.disconnect(signal_name, callback)


func _on_data_changed() -> void:
	refresh()


func _on_stock_changed(_ingredient_id: String, _amount: int) -> void:
	refresh()


func _on_ambience_changed(snapshot: Dictionary) -> void:
	_update_ambience(snapshot)


func _on_pest_warning_changed(_active: bool, _context: Dictionary) -> void:
	_update_ambience()


static func _role_name(role_id: String) -> String:
	return {
		"cook": "Cuoco",
		"waiter": "Cameriere",
		"handyman": "Tuttofare",
	}.get(role_id, role_id.capitalize())
