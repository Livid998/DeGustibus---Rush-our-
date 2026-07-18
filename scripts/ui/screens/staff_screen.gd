class_name StaffScreen
extends VBoxContainer

signal role_filter_changed(role: String)
signal operational_preference_changed(employee_id: String, preference: Dictionary)

const ROLES: Array[String] = ["cook", "waiter", "handyman"]
const ROLE_LABELS := {
	"cook": "Cuochi",
	"waiter": "Camerieri",
	"handyman": "Manutentori",
}
const ROLE_ICONS := {
	"cook": "role_chef",
	"waiter": "role_waiter",
	"handyman": "role_handyman",
}

var selected_role := "cook"
var _ui: Node
var _built := false
var _hierarchy_build_count := 0
var _content_refresh_count := 0
var _role_tabs: TabBar
var _employees_heading: Label
var _employees_list: VBoxContainer
var _candidates_heading: Label
var _candidates_list: VBoxContainer
var _visible_employee_ids: Array[String] = []
var _visible_candidate_ids: Array[String] = []


static func create(ui: Node = null) -> StaffScreen:
	var screen := StaffScreen.new()
	screen.setup(ui)
	return screen


func setup(ui: Node = null) -> void:
	_ui = ui
	_ensure_hierarchy()
	_connect_state()
	refresh_from_state()


func _ready() -> void:
	_ensure_hierarchy()
	_connect_state()
	refresh_from_state()


func set_role_filter(role: String) -> void:
	if role not in ROLES:
		return
	selected_role = role
	if _role_tabs != null:
		var index := ROLES.find(role)
		if _role_tabs.current_tab != index:
			_role_tabs.set_block_signals(true)
			_role_tabs.current_tab = index
			_role_tabs.set_block_signals(false)
	refresh_from_state()
	role_filter_changed.emit(role)


func refresh_from_state() -> void:
	_ensure_hierarchy()
	if _employees_list == null or _candidates_list == null:
		return
	_content_refresh_count += 1
	_clear_rows(_employees_list)
	_clear_rows(_candidates_list)
	_visible_employee_ids.clear()
	_visible_candidate_ids.clear()

	var employees := employees_for_role(selected_role)
	var candidates := candidates_for_role(selected_role)
	_employees_heading.text = "DIPENDENTI · %d" % employees.size()
	_candidates_heading.text = "CANDIDATI · %d" % candidates.size()

	for employee: Dictionary in employees:
		_visible_employee_ids.append(String(employee.get("id", "")))
		_employees_list.add_child(_employee_card(employee))
	if employees.is_empty():
		_employees_list.add_child(_empty_label("Nessun dipendente in questo ruolo."))

	for candidate: Dictionary in candidates:
		_visible_candidate_ids.append(String(candidate.get("id", "")))
		_candidates_list.add_child(_candidate_card(candidate))
	if candidates.is_empty():
		_candidates_list.add_child(_empty_label("Nessun candidato disponibile in questo ruolo."))

	GameFonts.sanitize_control_tree(self)


func employees_for_role(role: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for employee: Dictionary in GameState.employees:
		if String(employee.get("role", "")) == role:
			result.append(employee)
	return result


func candidates_for_role(role: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for candidate: Dictionary in GameState.candidates:
		if String(candidate.get("role", "")) == role:
			result.append(candidate)
	return result


func stats_text_for(employee: Dictionary) -> String:
	var role := String(employee.get("role", "cook"))
	var speed := float(employee.get("speed", 1.0)) * 100.0
	var precision := float(employee.get("precision", 0.0)) * 100.0
	match role:
		"waiter":
			var service := float(employee.get("skills", {}).get("service", 0.0)) * 100.0
			return "Velocità %.0f%% · Servizio %.0f%% · Precisione %.0f%%" % [
				speed,
				service,
				precision,
			]
		"handyman":
			return "Velocità pulizia %.0f%% · Ordine %.0f%% · Resistenza %.0f%%" % [
				speed,
				float(employee.get("order", 0.0)) * 100.0,
				float(employee.get("stamina", 0.0)) * 100.0,
			]
		_:
			var specialty := _specialty_text(employee)
			return "Velocità %.0f%% · Precisione %.0f%% · Specialità %s" % [
				speed,
				precision,
				specialty,
			]


func visible_employee_ids() -> Array[String]:
	return _visible_employee_ids.duplicate()


func visible_candidate_ids() -> Array[String]:
	return _visible_candidate_ids.duplicate()


func hierarchy_build_count() -> int:
	return _hierarchy_build_count


func content_refresh_count() -> int:
	return _content_refresh_count


func apply_preference(employee_id: String, role: String, value: Dictionary) -> bool:
	var normalized := StaffPreferences.normalize(role, value)
	var changed := GameState.set_staff_preference(employee_id, normalized)
	if changed:
		operational_preference_changed.emit(employee_id, normalized.duplicate(true))
	return changed


func _ensure_hierarchy() -> void:
	if _built:
		return
	_built = true
	_hierarchy_build_count += 1
	name = "StaffScreen"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 12)

	var intro := PanelContainer.new()
	intro.name = "StaffIntro"
	intro.add_theme_stylebox_override("panel", _panel_style(Color("f4eee2"), 12))
	add_child(intro)
	var intro_box := VBoxContainer.new()
	intro_box.add_theme_constant_override("separation", 6)
	intro.add_child(intro_box)
	var title := Label.new()
	title.name = "StaffTitle"
	title.text = "BRIGATA"
	title.add_theme_font_override("font", GameFonts.bold())
	title.add_theme_font_size_override("font_size", 25)
	intro_box.add_child(title)
	var subtitle := Label.new()
	subtitle.text = (
		"I ruoli sono permanenti. Le preferenze orientano il lavoro e lo standby, "
		+ "ma il personale continua a coprire ogni attività libera del proprio ruolo."
	)
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.add_theme_color_override("font_color", Color("52686b"))
	intro_box.add_child(subtitle)

	_role_tabs = TabBar.new()
	_role_tabs.name = "RoleTabs"
	_role_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_role_tabs.clip_tabs = false
	for role: String in ROLES:
		_role_tabs.add_tab(String(ROLE_LABELS[role]), GameIcons.casual_system_icon(ROLE_ICONS[role]))
		_role_tabs.set_tab_tooltip(
			_role_tabs.tab_count - 1,
			"Mostra dipendenti e candidati: %s" % String(ROLE_LABELS[role])
		)
	_role_tabs.tab_changed.connect(_on_tab_changed)
	intro_box.add_child(_role_tabs)

	_employees_heading = _list_heading("DIPENDENTI")
	_employees_heading.name = "EmployeesHeading"
	add_child(_employees_heading)
	_employees_list = VBoxContainer.new()
	_employees_list.name = "EmployeesList"
	_employees_list.add_theme_constant_override("separation", 9)
	add_child(_employees_list)

	_candidates_heading = _list_heading("CANDIDATI")
	_candidates_heading.name = "CandidatesHeading"
	add_child(_candidates_heading)
	_candidates_list = VBoxContainer.new()
	_candidates_list.name = "CandidatesList"
	_candidates_list.add_theme_constant_override("separation", 9)
	add_child(_candidates_list)


func _connect_state() -> void:
	var employees_callable := Callable(self, "_on_employees_changed")
	if not GameState.employees_changed.is_connected(employees_callable):
		GameState.employees_changed.connect(employees_callable)
	var preferences_callable := Callable(self, "_on_staff_preference_changed")
	if not GameState.staff_preferences_changed.is_connected(preferences_callable):
		GameState.staff_preferences_changed.connect(preferences_callable)


func _on_tab_changed(index: int) -> void:
	if index < 0 or index >= ROLES.size():
		return
	selected_role = ROLES[index]
	refresh_from_state()
	role_filter_changed.emit(selected_role)


func _on_employees_changed() -> void:
	refresh_from_state()


func _on_staff_preference_changed(employee_id: String, _preference: Variant) -> void:
	if not _visible_employee_ids.has(employee_id):
		return
	var employee: Dictionary = {}
	for candidate: Dictionary in GameState.employees:
		if String(candidate.get("id", "")) == employee_id:
			employee = candidate
			break
	if employee.is_empty():
		return
	var role := String(employee.get("role", ""))
	var current := StaffPreferences.for_employee(employee)
	var current_value := _preference_value(current, role)
	for raw_selector: Node in _employees_list.find_children(
		"PreferenceSelector",
		"OptionButton",
		true,
		false
	):
		var selector := raw_selector as OptionButton
		if selector == null or String(selector.get_meta("employee_id", "")) != employee_id:
			continue
		for index: int in selector.item_count:
			if String(selector.get_item_metadata(index)) != current_value:
				continue
			selector.set_block_signals(true)
			selector.select(index)
			selector.set_block_signals(false)
			break


func _employee_card(employee: Dictionary) -> PanelContainer:
	var card := _card()
	card.name = "Employee_%s" % String(employee.get("id", ""))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	card.add_child(box)

	var top := HFlowContainer.new()
	top.add_theme_constant_override("h_separation", 10)
	top.add_theme_constant_override("v_separation", 7)
	box.add_child(top)
	top.add_child(_role_icon(String(employee.get("role", "cook")), Vector2(50, 50)))
	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(identity)
	var name_label := Label.new()
	name_label.text = String(employee.get("name", "Dipendente"))
	name_label.add_theme_font_override("font", GameFonts.bold())
	name_label.add_theme_font_size_override("font_size", 20)
	identity.add_child(name_label)
	var contract := Label.new()
	contract.text = "%s · %d monete al giorno" % [
		_role_singular(String(employee.get("role", ""))),
		int(employee.get("salary", 0)),
	]
	contract.add_theme_color_override("font_color", Color("52686b"))
	identity.add_child(contract)
	var fire_button := _button("Licenzia", "red")
	var employee_id := String(employee.get("id", ""))
	fire_button.pressed.connect(_request_fire.bind(employee_id, String(employee.get("name", ""))))
	top.add_child(fire_button)

	var stats := Label.new()
	stats.name = "RoleStats"
	stats.text = stats_text_for(employee)
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.add_theme_font_override("font", GameFonts.semibold())
	stats.add_theme_color_override("font_color", Color("315d62"))
	box.add_child(stats)
	box.add_child(_preference_selector(employee))
	return card


func _candidate_card(candidate: Dictionary) -> PanelContainer:
	var card := _card()
	card.name = "Candidate_%s" % String(candidate.get("id", ""))
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 10)
	row.add_theme_constant_override("v_separation", 7)
	card.add_child(row)
	row.add_child(_role_icon(String(candidate.get("role", "cook")), Vector2(46, 46)))
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(details)
	var name_label := Label.new()
	name_label.text = "%s · %s" % [
		String(candidate.get("name", "Candidato")),
		_role_singular(String(candidate.get("role", ""))),
	]
	name_label.add_theme_font_override("font", GameFonts.bold())
	details.add_child(name_label)
	var stats := Label.new()
	stats.text = stats_text_for(candidate)
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.add_theme_color_override("font_color", Color("52686b"))
	details.add_child(stats)
	var cost := Label.new()
	cost.text = "Ingaggio %d monete · salario %d al giorno" % [
		int(candidate.get("hire_cost", 0)),
		int(candidate.get("salary", 0)),
	]
	cost.add_theme_color_override("font_color", Color("8f6423"))
	details.add_child(cost)
	var hire_button := _button("Assumi", "green")
	hire_button.disabled = not GameState.can_afford(int(candidate.get("hire_cost", 0)))
	hire_button.pressed.connect(_hire_candidate.bind(String(candidate.get("id", ""))))
	row.add_child(hire_button)
	return card


func _preference_selector(employee: Dictionary) -> Control:
	var row := HFlowContainer.new()
	row.name = "OperationalPreference"
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 6)
	var label := Label.new()
	label.text = _preference_label(String(employee.get("role", "")))
	label.custom_minimum_size.x = 156
	label.add_theme_font_override("font", GameFonts.semibold())
	row.add_child(label)
	var selector := OptionButton.new()
	selector.name = "PreferenceSelector"
	selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var options := _preference_options(employee)
	var current := StaffPreferences.for_employee(employee)
	var current_value := _preference_value(current, String(employee.get("role", "")))
	for option: Dictionary in options:
		selector.add_item(String(option.label))
		selector.set_item_metadata(selector.item_count - 1, String(option.value))
		if String(option.value) == current_value:
			selector.select(selector.item_count - 1)
	var employee_id := String(employee.get("id", ""))
	var employee_role := String(employee.get("role", ""))
	selector.set_meta("employee_id", employee_id)
	selector.item_selected.connect(
		func(index: int) -> void:
			var selected := String(selector.get_item_metadata(index))
			apply_preference(
				employee_id,
				employee_role,
				_preference_dictionary(employee_role, selected)
			)
	)
	row.add_child(selector)
	return row


func _preference_options(employee: Dictionary) -> Array[Dictionary]:
	match String(employee.get("role", "")):
		"waiter":
			return [
				{"label": "Automatica", "value": "automatic"},
				{"label": "Standby in sala", "value": "dining"},
				{"label": "Standby vicino al pass", "value": "pass"},
				{"label": "Standby lato ingresso", "value": "entrance"},
			]
		"handyman":
			return [
				{"label": "Automatica", "value": "automatic"},
				{"label": "Priorità sala", "value": "dining"},
				{"label": "Priorità cucina", "value": "kitchen"},
				{"label": "Priorità stoviglie", "value": "dishes"},
				{"label": "Priorità emergenze e infestazioni", "value": "emergency"},
			]
		_:
			var result: Array[Dictionary] = [
				{"label": "Postazione automatica", "value": ""},
			]
			var station_ids: Array[String] = []
			for recipe: Dictionary in DataRegistry.recipes:
				for step: Dictionary in recipe.get("steps", []):
					var station_id := String(step.get("station", ""))
					if not station_id.is_empty() and not station_ids.has(station_id):
						station_ids.append(station_id)
			for station: Dictionary in DataRegistry.stations:
				var station_id := String(station.get("id", ""))
				if station_id in station_ids:
					result.append({
						"label": "Preferisci %s" % String(station.get("name", station_id)),
						"value": station_id,
					})
			return result


func _preference_dictionary(role: String, value: String) -> Dictionary:
	match role:
		"waiter":
			return {"role": role, "standby_zone": value}
		"handyman":
			return {"role": role, "priority": value}
		_:
			return {"role": role, "station": value}


func _preference_value(preference: Dictionary, role: String) -> String:
	match role:
		"waiter":
			return String(preference.get("standby_zone", "automatic"))
		"handyman":
			return String(preference.get("priority", "automatic"))
		_:
			return String(preference.get("station", ""))


func _preference_label(role: String) -> String:
	match role:
		"waiter":
			return "Zona di standby"
		"handyman":
			return "Priorità operativa"
		_:
			return "Postazione preferita"


func _specialty_text(employee: Dictionary) -> String:
	var best_id := ""
	var best_value := -INF
	for station_id: String in employee.get("skills", {}):
		var value := float(employee.get("skills", {}).get(station_id, 0.0))
		if value > best_value:
			best_value = value
			best_id = station_id
	if best_id.is_empty():
		return "generale"
	var definition: Dictionary = DataRegistry.stations_by_id.get(best_id, {})
	return "%s %.0f%%" % [
		String(definition.get("name", best_id.replace("_", " ").capitalize())),
		best_value * 100.0,
	]


func _request_fire(employee_id: String, employee_name: String) -> void:
	if not is_inside_tree():
		_fire_employee(employee_id)
		return
	var dialog := ConfirmationDialog.new()
	dialog.name = "FireConfirmation"
	dialog.title = "Conferma licenziamento"
	dialog.dialog_text = "Vuoi licenziare %s? Il ruolo non può essere convertito." % employee_name
	dialog.ok_button_text = "Licenzia"
	dialog.cancel_button_text = "Annulla"
	dialog.confirmed.connect(func() -> void: _fire_employee(employee_id); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


func _fire_employee(employee_id: String) -> void:
	if EconomyManager.fire(employee_id):
		_show_toast("Dipendente licenziato", "warning")


func _hire_candidate(candidate_id: String) -> void:
	if EconomyManager.hire(candidate_id):
		_show_toast("Nuovo dipendente assunto", "success")
	else:
		_show_toast("Fondi insufficienti per l'ingaggio", "warning")


func _show_toast(message: String, tone: String) -> void:
	if _ui != null and is_instance_valid(_ui) and _ui.has_method("show_toast"):
		_ui.call("show_toast", message, tone)
	else:
		GameState.toast_requested.emit(message, tone)


func _role_icon(role: String, minimum_size: Vector2) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = GameIcons.casual_system_icon(String(ROLE_ICONS.get(role, "role_chef")))
	icon.custom_minimum_size = minimum_size
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return icon


func _role_singular(role: String) -> String:
	return {
		"cook": "Cuoco",
		"waiter": "Cameriere",
		"handyman": "Manutentore",
	}.get(role, "Dipendente")


func _list_heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", GameFonts.bold())
	label.add_theme_font_size_override("font_size", 19)
	label.add_theme_color_override("font_color", Color("265b61"))
	return label


func _empty_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color("6f7e80"))
	return label


func _card() -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _panel_style(Color("fffdf8"), 10))
	return card


func _button(text: String, tone: String) -> Button:
	if _ui != null and is_instance_valid(_ui) and _ui.has_method("make_button"):
		var callback := func() -> void: pass
		return _ui.call("make_button", text, callback, tone) as Button
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(112, 46)
	button.add_theme_font_override("font", GameFonts.semibold())
	return button


func _panel_style(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color("d9cdb9")
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 13
	style.content_margin_right = 13
	style.content_margin_top = 11
	style.content_margin_bottom = 11
	return style


func _clear_rows(container: Node) -> void:
	for child: Node in container.get_children():
		container.remove_child(child)
		child.queue_free()
