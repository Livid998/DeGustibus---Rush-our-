class_name UIManager
extends CanvasLayer

signal start_pressed
signal prep_selected(profile: String)
signal prep_finished
signal briefing_confirmed(directives: Array[String])
signal interruption_choice(index: int, agent: Node)
signal summary_continue
signal debrief_choice(style: String)
signal restart_pressed
signal resume_pressed
signal settings_changed

var session: SessionState
var root: Control
var menu_layer: Control
var hud: Control
var orders_box: VBoxContainer
var staff_box: VBoxContainer
var timer_label: Label
var money_label: Label
var reputation_label: Label
var phase_label: Label
var anger_bar: ProgressBar
var anger_text: Label
var prompt_label: Label
var carried_label: Label
var recipe_label: Label
var subtitle_label: Label
var interaction_bar: ProgressBar
var interaction_label: Label
var prep_done_button: Button
var event_panel: PanelContainer
var event_agent: Node
var pause_panel: PanelContainer
var briefing_selected: Array[String] = []
var briefing_counter: Label
var briefing_buttons := {}
var toast_tween: Tween

const CREAM := Color("#fff1d0")
const INK := Color("#2b1715")
const RED := Color("#d94f42")
const ORANGE := Color("#f0a83f")
const GREEN := Color("#56a878")
const PANEL := Color("#4a2521e8")

func setup(value: SessionState) -> void:
	session = value
	layer = 10
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = _make_theme()
	add_child(root)
	_build_hud()
	show_main_menu()

func _make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 20
	theme.set_color("font_color", "Label", CREAM)
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", Color("#160c0b"))
	theme.set_color("font_pressed_color", "Button", Color("#160c0b"))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("#f1c36a")
	normal.corner_radius_top_left = 10
	normal.corner_radius_top_right = 10
	normal.corner_radius_bottom_left = 10
	normal.corner_radius_bottom_right = 10
	normal.content_margin_left = 18
	normal.content_margin_right = 18
	normal.content_margin_top = 11
	normal.content_margin_bottom = 11
	var hover := normal.duplicate()
	hover.bg_color = Color("#ffe096")
	var pressed := normal.duplicate()
	pressed.bg_color = Color("#d99a42")
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	return theme

func _clear_menu() -> void:
	if is_instance_valid(menu_layer):
		menu_layer.queue_free()
	menu_layer = Control.new()
	menu_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(menu_layer)

func _background() -> ColorRect:
	var bg := ColorRect.new()
	bg.color = Color("#21100eda")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu_layer.add_child(bg)
	return bg

func _center_panel(width: float, min_height: float) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-width * 0.5, -min_height * 0.5)
	panel.custom_minimum_size = Vector2(width, min_height)
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = Color("#f0a83f")
	style.set_border_width_all(2)
	style.set_corner_radius_all(22)
	style.set_content_margin_all(30)
	panel.add_theme_stylebox_override("panel", style)
	menu_layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	return box

func _title(text: String, size := 44) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", ORANGE)
	return label

func _copy(text: String, size := 20) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size)
	return label

func show_main_menu() -> void:
	_clear_menu()
	_background()
	hud.visible = false
	var box := _center_panel(690, 520)
	box.add_child(_title("DE GUSTIBUS", 64))
	var rush := _title("RUSH HOUR", 38)
	rush.add_theme_color_override("font_color", RED)
	box.add_child(rush)
	box.add_child(_copy("Cucina calda. Sala piena. Pazienza finita.", 23))
	var stats := _copy("Miglior punteggio  %d     Reputazione  %d" % [int(session.persistent.best_score), int(session.persistent.reputation)], 18)
	stats.add_theme_color_override("font_color", Color("#e3cfa7"))
	box.add_child(stats)
	var start := Button.new()
	start.text = "INIZIA IL TURNO"
	start.custom_minimum_size.y = 58
	start.pressed.connect(func(): start_pressed.emit())
	box.add_child(start)
	var controls := _copy("WASD muovi · Mouse camera · Shift corri · E interagisci\n1/2/3 ricetta · Q annulla · Click/Spazio slapstick · Esc pausa", 17)
	controls.add_theme_color_override("font_color", Color("#d4bea0"))
	box.add_child(controls)
	box.add_child(_copy("Vertical slice · Godot 4.7 · Nessun asset esterno", 14))

func show_prep_selection() -> void:
	_clear_menu()
	_background()
	var box := _center_panel(880, 610)
	box.add_child(_title("QUANTO PRIMA APRIAMO?", 42))
	box.add_child(_copy("La prep modifica costo, stress iniziale, basi pronte e disordine."))
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 14)
	box.add_child(cards)
	for key in ["breve", "standard", "lunga"]:
		var data: Dictionary = GameData.PREP_PROFILES[key]
		var button := Button.new()
		button.custom_minimum_size = Vector2(255, 325)
		button.text = "%s\n\n%s\n\nCosto  €%d\nStress  %d%%\nBasi pronte  %d\nDisordine  %d%%" % [data.label, data.subtitle, data.cost, int(data.stress), data.mise, int(data.disorder)]
		button.add_theme_font_size_override("font_size", 18)
		button.pressed.connect(func(): prep_selected.emit(key))
		cards.add_child(button)
	box.add_child(_copy("La prep lunga aiuta la produzione, ma la brigata arriva già stanca."))

func show_prep_hud() -> void:
	_clear_menu()
	menu_layer.visible = false
	hud.visible = true
	prep_done_button.visible = true
	phase_label.text = "PREPARAZIONE"
	toast("Prepara mise en place al frigo e riordina le postazioni. Quando vuoi, apri il briefing.", 6.0)

func show_briefing() -> void:
	_clear_menu()
	_background()
	hud.visible = false
	briefing_selected.clear()
	briefing_buttons.clear()
	var box := _center_panel(820, 650)
	box.add_child(_title("BRIEFING DI SALA", 42))
	box.add_child(_copy("Hai tempo per comunicare solo 3 direttive. Le altre restano implicite."))
	briefing_counter = _copy("0 / 3 DIRETTIVE", 19)
	briefing_counter.add_theme_color_override("font_color", ORANGE)
	box.add_child(briefing_counter)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 10)
	box.add_child(grid)
	for option in GameData.BRIEFING_OPTIONS:
		var button := Button.new()
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(355, 74)
		button.text = "%s\n%s" % [option.label, option.hint]
		var id: String = option.id
		button.toggled.connect(func(on: bool): _toggle_directive(id, on))
		grid.add_child(button)
		briefing_buttons[id] = button
	var go := Button.new()
	go.text = "APRITE LE PORTE"
	go.custom_minimum_size.y = 56
	go.pressed.connect(func(): briefing_confirmed.emit(briefing_selected.duplicate()))
	box.add_child(go)
	box.add_child(_copy("Quantità speciale: reale %d · stimata %d · comunicata dipende dal briefing · promessa nasce dagli ordini" % [session.special_real, session.special_estimated], 16))

func _toggle_directive(id: String, enabled: bool) -> void:
	if enabled:
		if briefing_selected.size() >= 3:
			briefing_buttons[id].set_pressed_no_signal(false)
			return
		briefing_selected.append(id)
	else:
		briefing_selected.erase(id)
	briefing_counter.text = "%d / 3 DIRETTIVE" % briefing_selected.size()

func show_service() -> void:
	_clear_menu()
	menu_layer.visible = false
	hud.visible = true
	prep_done_button.visible = false
	phase_label.text = "RUSH HOUR"
	toast("Comande aperte! 1 Burger · 2 Pasta · 3 Speciale. Segui le postazioni indicate.", 6.0)

func _build_hud() -> void:
	hud = Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(hud)
	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_bottom = 78
	top.add_theme_stylebox_override("panel", _panel_style(Color("#2c1715e8"), 0))
	hud.add_child(top)
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 26)
	top.add_child(top_row)
	phase_label = _copy("PREP", 22)
	phase_label.custom_minimum_size.x = 180
	phase_label.add_theme_color_override("font_color", ORANGE)
	top_row.add_child(phase_label)
	timer_label = _copy("07:00", 28)
	timer_label.custom_minimum_size.x = 130
	top_row.add_child(timer_label)
	money_label = _copy("INCASSO €0", 20)
	money_label.custom_minimum_size.x = 170
	top_row.add_child(money_label)
	reputation_label = _copy("REP 50", 20)
	reputation_label.custom_minimum_size.x = 120
	top_row.add_child(reputation_label)
	var anger_box := VBoxContainer.new()
	anger_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(anger_box)
	anger_text = _copy("RABBIA DELLO CHEF  0%", 16)
	anger_box.add_child(anger_text)
	anger_bar = ProgressBar.new()
	anger_bar.max_value = 100
	anger_bar.show_percentage = false
	anger_bar.custom_minimum_size.y = 18
	anger_box.add_child(anger_bar)

	var orders_panel := PanelContainer.new()
	orders_panel.position = Vector2(18, 96)
	orders_panel.custom_minimum_size = Vector2(335, 455)
	orders_panel.add_theme_stylebox_override("panel", _panel_style(PANEL, 16))
	hud.add_child(orders_panel)
	var orders_outer := VBoxContainer.new()
	orders_panel.add_child(orders_outer)
	var order_title := _title("COMANDE", 27)
	orders_outer.add_child(order_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	orders_outer.add_child(scroll)
	orders_box = VBoxContainer.new()
	orders_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	orders_box.add_theme_constant_override("separation", 8)
	scroll.add_child(orders_box)

	var staff_panel := PanelContainer.new()
	staff_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	staff_panel.position = Vector2(-284, 96)
	staff_panel.custom_minimum_size = Vector2(266, 250)
	staff_panel.add_theme_stylebox_override("panel", _panel_style(PANEL, 16))
	hud.add_child(staff_panel)
	staff_box = VBoxContainer.new()
	staff_panel.add_child(staff_box)
	staff_box.add_child(_title("BRIGATA", 25))

	var carried_panel := PanelContainer.new()
	carried_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	carried_panel.position = Vector2(-360, -178)
	carried_panel.custom_minimum_size = Vector2(342, 150)
	carried_panel.add_theme_stylebox_override("panel", _panel_style(PANEL, 16))
	hud.add_child(carried_panel)
	var carried_box := VBoxContainer.new()
	carried_panel.add_child(carried_box)
	recipe_label = _copy("RICETTA [1] BURGER", 19)
	recipe_label.add_theme_color_override("font_color", ORANGE)
	carried_box.add_child(recipe_label)
	carried_label = _copy("MANI LIBERE", 20)
	carried_box.add_child(carried_label)
	carried_box.add_child(_copy("1 Burger · 2 Pasta · 3 Speciale", 14))

	prompt_label = _copy("", 24)
	prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	prompt_label.position = Vector2(-330, -92)
	prompt_label.custom_minimum_size = Vector2(660, 50)
	prompt_label.add_theme_stylebox_override("normal", _panel_style(Color("#24110fe8"), 12))
	hud.add_child(prompt_label)
	interaction_bar = ProgressBar.new()
	interaction_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	interaction_bar.position = Vector2(-250, -142)
	interaction_bar.custom_minimum_size = Vector2(500, 22)
	interaction_bar.max_value = 1.0
	interaction_bar.visible = false
	hud.add_child(interaction_bar)
	interaction_label = _copy("", 16)
	interaction_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	interaction_label.position = Vector2(-250, -171)
	interaction_label.custom_minimum_size = Vector2(500, 28)
	interaction_label.visible = false
	hud.add_child(interaction_label)

	subtitle_label = _copy("", 20)
	subtitle_label.set_anchors_preset(Control.PRESET_CENTER)
	subtitle_label.position = Vector2(-390, 185)
	subtitle_label.custom_minimum_size = Vector2(780, 80)
	subtitle_label.add_theme_stylebox_override("normal", _panel_style(Color("#1c0d0ce8"), 12))
	subtitle_label.modulate.a = 0.0
	hud.add_child(subtitle_label)
	prep_done_button = Button.new()
	prep_done_button.text = "APRI IL BRIEFING  [INVIO]"
	prep_done_button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	prep_done_button.position = Vector2(18, -92)
	prep_done_button.custom_minimum_size = Vector2(320, 56)
	prep_done_button.pressed.connect(func(): prep_finished.emit())
	hud.add_child(prep_done_button)
	_build_event_panel()
	_build_pause_panel()
	hud.visible = false

func _build_event_panel() -> void:
	event_panel = PanelContainer.new()
	event_panel.set_anchors_preset(Control.PRESET_CENTER)
	event_panel.position = Vector2(-330, -210)
	event_panel.custom_minimum_size = Vector2(660, 420)
	event_panel.add_theme_stylebox_override("panel", _panel_style(Color("#4b2422f5"), 24))
	event_panel.visible = false
	hud.add_child(event_panel)

func show_interruption(agent: Node, event: Dictionary) -> void:
	event_agent = agent
	for child in event_panel.get_children(): child.queue_free()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	event_panel.add_child(box)
	box.add_child(_title(event.title, 34))
	box.add_child(_copy(event.line, 22))
	box.add_child(_copy("La persona è fisicamente alla cassa: mentre decidi, la sala continua.", 16))
	for i in event.choices.size():
		var button := Button.new()
		button.text = "%d  ·  %s" % [i + 1, event.choices[i]]
		button.pressed.connect(func(): interruption_choice.emit(i, event_agent))
		box.add_child(button)
	event_panel.visible = true

func hide_interruption() -> void:
	event_panel.visible = false
	event_agent = null

func _build_pause_panel() -> void:
	pause_panel = PanelContainer.new()
	pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	pause_panel.position = Vector2(-300, -280)
	pause_panel.custom_minimum_size = Vector2(600, 560)
	pause_panel.add_theme_stylebox_override("panel", _panel_style(Color("#3a1c1af8"), 24))
	pause_panel.visible = false
	root.add_child(pause_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	pause_panel.add_child(box)
	box.add_child(_title("PAUSA", 42))
	box.add_child(_copy("Comandi: WASD · Mouse · Shift · E · Q · 1/2/3 · Click/Spazio"))
	for setting_data in [["Musica", "music"], ["Effetti", "sfx"], ["Sensibilità camera", "camera_sensitivity"]]:
		var row := HBoxContainer.new()
		var label := _copy(setting_data[0], 18)
		label.custom_minimum_size.x = 220
		row.add_child(label)
		var slider := HSlider.new()
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.min_value = 0.0 if setting_data[1] != "camera_sensitivity" else 0.08
		slider.max_value = 1.0 if setting_data[1] != "camera_sensitivity" else 0.5
		slider.step = 0.01
		slider.value = float(session.settings[setting_data[1]])
		var key: String = setting_data[1]
		slider.value_changed.connect(func(value: float): session.settings[key] = value; settings_changed.emit())
		row.add_child(slider)
		box.add_child(row)
	var subtitles := CheckButton.new()
	subtitles.text = "Sottotitoli contestuali"
	subtitles.button_pressed = bool(session.settings.subtitles)
	subtitles.toggled.connect(func(on: bool): session.settings.subtitles = on; settings_changed.emit())
	box.add_child(subtitles)
	var resume := Button.new()
	resume.text = "RIPRENDI"
	resume.pressed.connect(func(): resume_pressed.emit())
	box.add_child(resume)

func set_paused(value: bool) -> void:
	pause_panel.visible = value

func update_hud() -> void:
	var seconds := session.prep_time_left if session.phase == SessionState.Phase.PREP else session.service_time_left
	timer_label.text = "%02d:%02d" % [int(seconds) / 60, int(seconds) % 60]
	money_label.text = "INCASSO  €%d" % session.money
	reputation_label.text = "REP  %d" % int(session.reputation)
	anger_bar.value = session.anger
	anger_text.text = "RABBIA DELLO CHEF  %d%%" % int(session.anger)
	anger_bar.modulate = Color("#ff4e43") if session.anger >= 75.0 else (ORANGE if session.anger >= 40.0 else GREEN)
	var recipe: Dictionary = GameData.RECIPES[session.selected_recipe]
	recipe_label.text = "RICETTA  %s  ·  %s" % [{"burger":"[1]", "pasta":"[2]", "special":"[3]"}[session.selected_recipe], recipe.short]
	carried_label.text = "MANI LIBERE" if session.carried_item.is_empty() else _friendly_item(session.carried_item)
	_update_staff()

func update_orders(orders: Array[Dictionary]) -> void:
	for child in orders_box.get_children(): child.queue_free()
	if orders.is_empty():
		orders_box.add_child(_copy("Nessuna comanda.\nRespira finché puoi.", 17))
		return
	for order in orders:
		var ticket := PanelContainer.new()
		ticket.add_theme_stylebox_override("panel", _panel_style(Color("#f5dfb9"), 9))
		var box := VBoxContainer.new()
		ticket.add_child(box)
		var header := Label.new()
		header.text = "T%d  ·  %s  ·  %ds" % [order.table, GameData.RECIPES[order.recipe].short, int(order.elapsed)]
		header.add_theme_color_override("font_color", INK)
		header.add_theme_font_size_override("font_size", 18)
		box.add_child(header)
		if not str(order.mod).is_empty():
			var mod := Label.new()
			mod.text = "+ %s%s" % [order.mod, "  ⚠" if order.invalid else ""]
			mod.add_theme_color_override("font_color", RED if order.invalid else Color("#4b5546"))
			mod.add_theme_font_size_override("font_size", 15)
			box.add_child(mod)
		var patience := ProgressBar.new()
		patience.max_value = order.max_patience
		patience.value = order.patience
		patience.show_percentage = false
		patience.custom_minimum_size.y = 9
		patience.modulate = RED if order.patience / order.max_patience < 0.33 else GREEN
		box.add_child(patience)
		orders_box.add_child(ticket)

func _update_staff() -> void:
	var existing := staff_box.get_children()
	for i in range(1, existing.size()):
		staff_box.remove_child(existing[i])
		existing[i].queue_free()
	for key in ["cassiera", "waiter", "assistant"]:
		var data: Dictionary = GameData.STAFF[key]
		var state: Dictionary = session.staff_state.get(key, {"stress": 0, "mood": data.mood})
		var row := VBoxContainer.new()
		var label := _copy("%s · %s   STRESS %d%%" % [data.name, data.role, int(state.stress)], 15)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_child(label)
		var bar := ProgressBar.new()
		bar.max_value = 100
		bar.value = state.stress
		bar.show_percentage = false
		bar.custom_minimum_size.y = 7
		bar.modulate = RED if state.stress >= 70 else ORANGE
		row.add_child(bar)
		staff_box.add_child(row)

func set_prompt(text: String) -> void:
	prompt_label.text = "[E]  %s" % text if not text.is_empty() else ""

func set_interaction(label: String, progress: float, visible: bool) -> void:
	interaction_bar.visible = visible
	interaction_label.visible = visible
	interaction_bar.value = progress
	interaction_label.text = "%s  ·  [Q] annulla" % label

func toast(text: String, duration := 3.5) -> void:
	if not bool(session.settings.subtitles):
		return
	if toast_tween and toast_tween.is_valid():
		toast_tween.kill()
	subtitle_label.text = text
	subtitle_label.modulate.a = 1.0
	toast_tween = create_tween()
	toast_tween.tween_interval(duration)
	toast_tween.tween_property(subtitle_label, "modulate:a", 0.0, 0.45)

func show_summary() -> void:
	_clear_menu()
	_background()
	hud.visible = false
	var box := _center_panel(820, 660)
	box.add_child(_title("FINE SERVIZIO", 43))
	var grade := "A" if session.score() >= 650 else ("B" if session.score() >= 400 else ("C" if session.score() >= 150 else "D"))
	box.add_child(_title("VOTO  %s" % grade, 54))
	var summary := GridContainer.new()
	summary.columns = 2
	box.add_child(summary)
	var rows := [
		["Incasso", "€%d" % session.money], ["Costi salariali", "-€%d" % session.labor_cost],
		["Sprechi", "-€%d" % session.waste_cost], ["Piatti riusciti / falliti", "%d / %d" % [session.dishes_succeeded, session.dishes_failed]],
		["Clienti soddisfatti / fuggiti", "%d / %d" % [session.customers_happy, session.customers_fled]],
		["Reputazione", "%d" % int(session.reputation)], ["Rabbia massima", "%d%%" % int(session.max_anger)],
		["Bersagli errati", "%d" % session.wrong_hits], ["Punteggio", "%d" % session.score()],
	]
	for row in rows:
		var left := _copy(row[0], 18); left.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; left.custom_minimum_size.x = 420
		var right := _copy(row[1], 18); right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; right.custom_minimum_size.x = 260
		summary.add_child(left); summary.add_child(right)
	var contract := "Nessun contratto catering"
	if not session.catering_contract.is_empty():
		contract = "Catering: %d persone · margine €%d · rischio %s · prep %dh" % [session.catering_contract.guests, session.catering_contract.margin, session.catering_contract.risk, session.catering_contract.prep_hours]
	box.add_child(_copy(contract, 18))
	var button := Button.new()
	button.text = "DEBRIEFING DELLA BRIGATA"
	button.pressed.connect(func(): summary_continue.emit())
	box.add_child(button)

func show_debrief() -> void:
	_clear_menu()
	_background()
	var box := _center_panel(860, 680)
	box.add_child(_title("DEBRIEFING", 43))
	var incident := {"actor": "assistant", "text": "Ha lasciato la postazione in disordine", "fault": true}
	if not session.incidents.is_empty():
		incident = session.incidents[-1]
	var actor_key: String = str(incident.get("actor", "assistant"))
	if not GameData.STAFF.has(actor_key): actor_key = "assistant"
	box.set_meta("actor", actor_key)
	box.add_child(_copy("EPISODIO: %s" % incident.get("text", "Servizio caotico"), 22))
	box.add_child(_copy("Scegli tono e chiarezza. L'effetto dipende da colpa reale, umore e apprendimento.", 17))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 10)
	box.add_child(grid)
	for style in ["Correttivo", "Aggressivo", "Comprensivo", "Sarcastico", "Nessun richiamo", "Riconoscimento positivo"]:
		var button := Button.new()
		button.text = style
		button.custom_minimum_size = Vector2(370, 54)
		button.pressed.connect(func(): debrief_choice.emit(style))
		grid.add_child(button)
	var result := _copy("Il risultato apparirà qui.", 18)
	result.name = "DebriefResult"
	box.add_child(result)
	var restart := Button.new()
	restart.name = "Restart"
	restart.text = "NUOVO TURNO"
	restart.visible = false
	restart.pressed.connect(func(): restart_pressed.emit())
	box.add_child(restart)

func show_debrief_result(text: String) -> void:
	var result := menu_layer.find_child("DebriefResult", true, false) as Label
	if result: result.text = text
	var restart := menu_layer.find_child("Restart", true, false) as Button
	if restart: restart.visible = true

func _friendly_item(item: String) -> String:
	return {
		"burger_raw": "CARNE + PANE", "burger_patty": "CARNE COTTA", "burger_components": "CARNE + PATATINE",
		"burger_ready": "BURGER IMPIATTATO", "pasta_raw": "PASTA SECCA", "pasta_cooked": "PASTA COTTA",
		"pasta_ready": "PASTA IMPIATTATA", "special_raw": "POLLO PORZIONATO", "special_crispy": "POLLO CROCCANTE",
		"special_ready": "SPECIALE IMPIATTATO",
	}.get(item, item.to_upper())

func _panel_style(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(12)
	return style
