class_name RestaurantUI
extends CanvasLayer

var world: RestaurantWorld
var root: Control
var top_bar: PanelContainer
var screen_panel: PanelContainer
var screen_scroll: ScrollContainer
var screen_content: VBoxContainer
var pass_panel: PanelContainer
var pass_content: VBoxContainer
var debug_panel: PanelContainer
var debug_content: VBoxContainer
var toast_label: Label
var tutorial_panel: PanelContainer
var tutorial_label: Label
var money_label: Label
var reputation_label: Label
var state_button: Button
var clock_label: Label
var customer_label: Label
var build_hud: BuildHUD
var nav_buttons: Dictionary = {}
var screen_title_label: Label
var world_action_panel: PanelContainer
var world_build_button: Button
var current_screen := "Ristorante"
var market_provider := MockMarketProvider.new()
var _refresh_clock := 0.0
var _toast_tween: Tween
var _market_refresh_clock := 0.0
var _theme: Theme
var _orientation_initialized := false
var _was_portrait := false

const SCREENS := ["Ristorante", "Menu", "Album", "Magazzino", "Mercato", "Personale", "Statistiche", "Impostazioni"]
const TUTORIAL_STEPS := [
	"Sposta un tavolo in modalità costruzione.",
	"Aggiungi una sedia alla sala.",
	"Controlla e bilancia il menu attivo.",
	"Attiva il riordino automatico del pomodoro.",
	"Apri il ristorante.",
	"Osserva il primo ticket al pass.",
	"Controlla il carico delle postazioni."
]


func _ready() -> void:
	_build_theme()
	_build_shell()
	_connect_state()
	_update_top_bar()
	_update_pass()
	_update_tutorial()


func setup(value_world: RestaurantWorld) -> void:
	world = value_world
	world.build_system.selection_changed.connect(_on_selection_changed)
	world.build_system.preview_changed.connect(_on_preview_changed)
	build_hud.setup(self, world)
	show_screen("Ristorante")


func _process(delta: float) -> void:
	var market_changed := market_provider.tick(delta * SimulationManager.simulation_speed)
	_market_refresh_clock -= delta
	_refresh_clock += delta
	if _refresh_clock >= 0.35:
		_refresh_clock = 0.0
		_update_top_bar()
		_update_pass()
		if current_screen == "Statistiche":
			show_screen("Statistiche", false)
	if current_screen == "Mercato" and (market_changed or _market_refresh_clock <= 0.0):
		_market_refresh_clock = 1.0
		show_screen("Mercato", false)
	if Input.is_action_just_pressed("toggle_debug"):
		debug_panel.visible = not debug_panel.visible
	if Input.is_action_just_pressed("speed_1"):
		SimulationManager.set_speed(1.0)
	if Input.is_action_just_pressed("speed_2"):
		SimulationManager.set_speed(2.0)
	if Input.is_action_just_pressed("speed_4"):
		SimulationManager.set_speed(4.0)


func show_screen(screen_name: String, sound: bool = true) -> void:
	if build_hud and build_hud.is_open:
		build_hud.close_builder()
	current_screen = screen_name
	if screen_name == "Ristorante":
		close_screen()
		if sound:
			AudioManager.play_feedback()
		return
	_clear(screen_content)
	ManagementScreens.populate(screen_name, screen_content, self)
	screen_title_label.text = screen_name.to_upper()
	var animate_open := sound or not screen_panel.visible
	screen_panel.visible = true
	if animate_open:
		screen_panel.modulate.a = 0.0
		create_tween().tween_property(screen_panel, "modulate:a", 1.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_update_nav_selection()
	_update_world_actions()
	_update_pass()
	if sound:
		AudioManager.play_feedback()
	if screen_name == "Statistiche" and not GameState.tutorial.complete:
		advance_tutorial_to(6)


func close_screen() -> void:
	current_screen = "Ristorante"
	screen_panel.visible = false
	_update_nav_selection()
	_update_world_actions()
	_update_pass()


func open_builder() -> void:
	build_hud.open()


func refresh_screen() -> void:
	show_screen(current_screen, false)


func make_button(text: String, callback: Callable, tone: String = "blue") -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(112, 48)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.tooltip_text = text
	button.pressed.connect(callback)
	button.add_theme_stylebox_override("normal", _button_style(tone))
	button.add_theme_stylebox_override("hover", _button_style("green" if tone != "red" else "yellow"))
	button.add_theme_stylebox_override("pressed", _button_style("yellow"))
	return button


func make_section(title: String, subtitle: String = "") -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	var label := Label.new()
	label.text = title
	label.add_theme_font_override("font", GameFonts.bold())
	label.add_theme_font_size_override("font_size", 23)
	label.add_theme_color_override("font_color", Color("243d42"))
	box.add_child(label)
	if not subtitle.is_empty():
		var sub := Label.new()
		sub.text = subtitle
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.add_theme_font_size_override("font_size", 15)
		sub.add_theme_color_override("font_color", Color("52686b"))
		box.add_child(sub)
	return box


func make_card() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f5f0e7")
	style.border_color = Color("d4c9b7")
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	return panel


func show_toast(message: String, tone: String = "info") -> void:
	toast_label.text = message
	toast_label.visible = true
	toast_label.modulate = Color.WHITE
	toast_label.add_theme_color_override("font_color", {
		"income": Color("d9ffd7"), "cost": Color("ffe0bb"), "warning": Color("ffd4c8")
	}.get(tone, Color.WHITE))
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.8)
	_toast_tween.tween_property(toast_label, "modulate:a", 0.0, 0.45)
	_toast_tween.tween_callback(func(): toast_label.visible = false)


func advance_tutorial_to(step: int) -> void:
	if bool(GameState.tutorial.get("skipped", false)) or bool(GameState.tutorial.get("complete", false)):
		return
	if step >= int(GameState.tutorial.step):
		GameState.tutorial.step = mini(step + 1, TUTORIAL_STEPS.size())
		if int(GameState.tutorial.step) >= TUTORIAL_STEPS.size():
			GameState.tutorial.complete = true
		_update_tutorial()


func _build_shell() -> void:
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _theme
	add_child(root)
	_build_top_bar()
	_build_bottom_nav()
	_build_screen_panel()
	_build_world_actions()
	_build_pass_panel()
	_build_debug_panel()
	_build_toast()
	_build_tutorial()
	build_hud = BuildHUD.new()
	root.add_child(build_hud)
	root.resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()


func _build_top_bar() -> void:
	top_bar = PanelContainer.new()
	top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_bottom = 68
	top_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	top_bar.add_theme_stylebox_override("panel", _panel_style(Color("173f45e8"), 0))
	root.add_child(top_bar)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	top_bar.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	margin.add_child(row)
	money_label = Label.new()
	money_label.add_theme_font_override("font", GameFonts.bold())
	money_label.custom_minimum_size.x = 118
	money_label.add_theme_color_override("font_color", Color("f5fbf9"))
	reputation_label = Label.new()
	reputation_label.add_theme_font_override("font", GameFonts.bold())
	reputation_label.custom_minimum_size.x = 82
	reputation_label.add_theme_color_override("font_color", Color("f5fbf9"))
	state_button = make_button("CHIUSO", _toggle_restaurant, "red")
	state_button.custom_minimum_size.x = 250
	clock_label = Label.new()
	clock_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	clock_label.add_theme_color_override("font_color", Color("f5fbf9"))
	customer_label = Label.new()
	customer_label.add_theme_color_override("font_color", Color("f5fbf9"))
	var speed := OptionButton.new()
	for label: String in ["1×", "2×", "4×"]:
		speed.add_item(label)
	speed.item_selected.connect(func(index: int): SimulationManager.set_speed([1.0, 2.0, 4.0][index]))
	row.add_child(money_label)
	row.add_child(reputation_label)
	row.add_child(state_button)
	row.add_child(clock_label)
	row.add_child(customer_label)
	row.add_child(speed)


func _build_bottom_nav() -> void:
	var nav_panel := PanelContainer.new()
	nav_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	nav_panel.offset_top = -68
	nav_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	nav_panel.add_theme_stylebox_override("panel", _panel_style(Color("173f45f2"), 0))
	root.add_child(nav_panel)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	nav_panel.add_child(row)
	for screen_name: String in SCREENS:
		var button := make_button(screen_name, func(): show_screen(screen_name), "blue")
		button.custom_minimum_size = Vector2(92, 46)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 14)
		button.icon = GameIcons.navigation_icon(screen_name)
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 34)
		button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		nav_buttons[screen_name] = button
		row.add_child(button)


func _build_screen_panel() -> void:
	screen_panel = PanelContainer.new()
	screen_panel.anchor_left = 0
	screen_panel.anchor_right = 1
	screen_panel.anchor_top = 0
	screen_panel.anchor_bottom = 1
	screen_panel.offset_top = 76
	screen_panel.offset_bottom = -78
	screen_panel.offset_left = 14
	screen_panel.offset_right = -14
	screen_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	screen_panel.add_theme_stylebox_override("panel", _panel_style(Color("eee8ddf5"), 16))
	root.add_child(screen_panel)
	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", 8)
	screen_panel.add_child(shell)
	var header := HBoxContainer.new()
	screen_title_label = Label.new()
	screen_title_label.text = "GESTIONE"
	screen_title_label.add_theme_font_override("font", GameFonts.bold())
	screen_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen_title_label.add_theme_font_size_override("font_size", 20)
	header.add_child(screen_title_label)
	var close := make_button("Torna alla mappa", close_screen, "ghost")
	close.custom_minimum_size = Vector2(160, 42)
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	header.add_child(close)
	shell.add_child(header)
	screen_scroll = ScrollContainer.new()
	screen_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	screen_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	shell.add_child(screen_scroll)
	screen_content = VBoxContainer.new()
	screen_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen_content.add_theme_constant_override("separation", 10)
	screen_scroll.add_child(screen_content)
	screen_panel.visible = false


func _build_world_actions() -> void:
	world_action_panel = PanelContainer.new()
	world_action_panel.anchor_top = 1
	world_action_panel.anchor_bottom = 1
	world_action_panel.offset_left = 14
	world_action_panel.offset_right = 222
	world_action_panel.offset_top = -132
	world_action_panel.offset_bottom = -78
	world_action_panel.add_theme_stylebox_override("panel", _panel_style(Color("173f45e8"), 12))
	root.add_child(world_action_panel)
	world_build_button = make_button("Costruisci e modifica", open_builder, "yellow")
	world_build_button.custom_minimum_size = Vector2(180, 44)
	world_action_panel.add_child(world_build_button)


func _build_pass_panel() -> void:
	pass_panel = PanelContainer.new()
	pass_panel.anchor_left = 1
	pass_panel.anchor_right = 1
	pass_panel.offset_left = -304
	pass_panel.offset_right = -14
	pass_panel.offset_top = 78
	pass_panel.offset_bottom = 342
	pass_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	pass_panel.add_theme_stylebox_override("panel", _panel_style(Color("173f45e8"), 14))
	root.add_child(pass_panel)
	var scroll := ScrollContainer.new()
	pass_panel.add_child(scroll)
	pass_content = VBoxContainer.new()
	pass_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pass_content)


func _build_debug_panel() -> void:
	debug_panel = PanelContainer.new()
	debug_panel.anchor_left = 1
	debug_panel.anchor_right = 1
	debug_panel.offset_left = -360
	debug_panel.offset_right = -14
	debug_panel.offset_top = 360
	debug_panel.offset_bottom = 690
	debug_panel.add_theme_stylebox_override("panel", _panel_style(Color("241e2be8"), 14))
	debug_panel.visible = false
	root.add_child(debug_panel)
	var scroll := ScrollContainer.new()
	debug_panel.add_child(scroll)
	debug_content = VBoxContainer.new()
	debug_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(debug_content)
	_build_debug_actions()


func _build_toast() -> void:
	toast_label = Label.new()
	toast_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_label.position = Vector2(-190, 76)
	toast_label.size = Vector2(380, 44)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast_label.add_theme_font_size_override("font_size", 18)
	toast_label.add_theme_font_override("font", GameFonts.semibold())
	toast_label.add_theme_stylebox_override("normal", _panel_style(Color("102c31e8"), 12))
	toast_label.visible = false
	root.add_child(toast_label)


func _build_tutorial() -> void:
	tutorial_panel = PanelContainer.new()
	tutorial_panel.anchor_left = 0.5
	tutorial_panel.anchor_right = 0.5
	tutorial_panel.offset_left = -210
	tutorial_panel.offset_right = 210
	tutorial_panel.offset_top = 74
	tutorial_panel.offset_bottom = 132
	tutorial_panel.add_theme_stylebox_override("panel", _panel_style(Color("fff3d9f2"), 14))
	root.add_child(tutorial_panel)
	var box := HBoxContainer.new()
	tutorial_panel.add_child(box)
	tutorial_label = Label.new()
	tutorial_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tutorial_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tutorial_label.add_theme_font_size_override("font_size", 14)
	tutorial_label.add_theme_color_override("font_color", Color("263f42"))
	box.add_child(tutorial_label)
	var skip := make_button("Salta", func(): GameState.tutorial.skipped = true; _update_tutorial(), "ghost")
	skip.custom_minimum_size = Vector2(68, 34)
	skip.size_flags_horizontal = Control.SIZE_SHRINK_END
	box.add_child(skip)


func _build_debug_actions() -> void:
	var title := Label.new()
	title.text = "DEBUG · F12"
	debug_content.add_child(title)
	var actions := [
		["+1.000 monete", func(): GameState.earn(1000, "Debug")],
		["Sblocca ingredienti", _debug_unlock_all],
		["Riempi magazzino", func(): _debug_fill_stock(99)],
		["Svuota magazzino", func(): _debug_fill_stock(0)],
		["Genera clienti", func(): world.spawn_customer_group()],
		["Rush hour", func(): world.set_rush_mode(true); show_toast("Rush hour avviata", "warning")],
		["Chiudi immediatamente", SimulationManager.close_immediately],
		["Mostra griglia", func(): world.toggle_debug_grid(); show_toast("Griglia logica: %s" % world.show_grid)],
		["Mostra percorsi", func(): world.toggle_debug_paths(); show_toast("Percorsi: %s" % world.show_paths)],
		["Mostra code postazioni", func(): world.toggle_station_queue_labels(); show_toast("Code postazioni: %s" % world.show_station_queues)],
		["Task attivi in console", _debug_print_tasks],
		["Reset salvataggio", _debug_reset]
	]
	for action: Array in actions:
		debug_content.add_child(make_button(action[0], action[1], "red" if "Reset" in action[0] else "blue"))


func _toggle_restaurant() -> void:
	match GameState.restaurant_state:
		"closed":
			SimulationManager.open_restaurant()
			advance_tutorial_to(4)
		"open":
			SimulationManager.request_close()
		"closing":
			show_toast("Il servizio termina con i clienti presenti")


func _update_top_bar() -> void:
	if money_label == null:
		return
	money_label.text = "● %s" % _format_number(GameState.money)
	reputation_label.text = "★ %.1f" % GameState.reputation
	var states := {"closed":"RISTORANTE CHIUSO", "open":"RISTORANTE APERTO", "closing":"IN CHIUSURA"}
	state_button.text = states.get(GameState.restaurant_state, GameState.restaurant_state)
	state_button.add_theme_stylebox_override("normal", _button_style("green" if GameState.restaurant_state == "open" else "yellow" if GameState.restaurant_state == "closing" else "red"))
	var minutes := int(GameState.service_seconds) / 60
	var seconds := int(GameState.service_seconds) % 60
	clock_label.text = "%02d:%02d · %.0f×" % [minutes, seconds, SimulationManager.simulation_speed]
	var guest_count := 0
	for customer: Node in SimulationManager.customers:
		guest_count += int(customer.get("group_size"))
	customer_label.text = "Clienti %d" % guest_count


func _update_pass() -> void:
	if pass_content == null:
		return
	_clear(pass_content)
	var title := Label.new()
	title.add_theme_font_override("font", GameFonts.bold())
	title.text = "PASS · TICKET ATTIVI"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("f2faf8"))
	pass_content.add_child(title)
	var waiting_groups := 0
	for customer: Node in SimulationManager.customers:
		if String(customer.get("state")) in ["entering", "waiting_table", "walking_to_table", "waiting_order"]:
			waiting_groups += 1
	var sold_out := 0
	for entry: Dictionary in GameState.menu.values():
		if bool(entry.get("sold_out", false)):
			sold_out += 1
	var hottest_id := ""
	var hottest_load := 0.0
	for station: Dictionary in DataRegistry.stations:
		var load := SimulationManager.predicted_station_load(String(station.id))
		if load > hottest_load:
			hottest_load = load
			hottest_id = String(station.name)
	var service_status := Label.new()
	service_status.text = "Attesa %d  ·  Esauriti %d%s" % [waiting_groups, sold_out, "  ·  %s %.0f%%" % [hottest_id, hottest_load] if hottest_load > 0.0 else ""]
	service_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	service_status.add_theme_font_size_override("font_size", 13)
	service_status.add_theme_color_override("font_color", Color("ffbd78") if hottest_load > 100.0 else Color("b9d9d4"))
	pass_content.add_child(service_status)
	var active_count := 0
	for order_id: String in SimulationManager.orders:
		var order: Dictionary = SimulationManager.orders[order_id]
		if order.state == "paid":
			continue
		active_count += 1
		var elapsed := GameState.service_seconds - float(order.created_at)
		var row := HBoxContainer.new()
		var recipe: Dictionary = DataRegistry.recipes_by_id.get(String(order.recipe_id), {})
		if not recipe.is_empty():
			var dish_icon := TextureRect.new()
			dish_icon.texture = GameIcons.recipe_icon(recipe)
			dish_icon.custom_minimum_size = Vector2(38, 38)
			dish_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			dish_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			dish_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(dish_icon)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var table_name := "Tavolo %s" % String(order.table_id).trim_prefix("table_")
		label.text = "%s · %s · %ds\n%s%s" % [order.id, table_name, int(elapsed), order.recipe_name, "\nManca: %s" % ", ".join(order.get("missing", [])) if not order.get("missing", []).is_empty() else ""]
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_color", Color("8ff0aa") if order.ready else Color("ff9b8f") if elapsed > 28 else Color("ffe48c") if elapsed > 16 else Color.WHITE)
		row.add_child(label)
		var ticket_actions := VBoxContainer.new()
		ticket_actions.add_theme_constant_override("separation", 2)
		var suspend := make_button("▶" if bool(order.get("suspended", false)) else "Ⅱ", func(): SimulationManager.toggle_order_suspended(order_id), "green" if bool(order.get("suspended", false)) else "ghost")
		suspend.tooltip_text = "Riprendi piatto" if bool(order.get("suspended", false)) else "Sospendi piatto"
		suspend.custom_minimum_size = Vector2(34, 28)
		suspend.size_flags_horizontal = Control.SIZE_SHRINK_END
		ticket_actions.add_child(suspend)
		var priority := make_button("↑", func(): SimulationManager.raise_order_priority(order_id), "yellow")
		priority.tooltip_text = "Aumenta priorità"
		priority.custom_minimum_size = Vector2(34, 28)
		priority.size_flags_horizontal = Control.SIZE_SHRINK_END
		ticket_actions.add_child(priority)
		row.add_child(ticket_actions)
		pass_content.add_child(row)
	if active_count == 0:
		var empty := Label.new()
		empty.text = "Nessuna comanda"
		empty.add_theme_color_override("font_color", Color("f2faf8"))
		pass_content.add_child(empty)
	var portrait := root.size.y > root.size.x
	for screen_name: String in nav_buttons:
		var nav_button: Button = nav_buttons[screen_name]
		nav_button.text = "" if portrait else screen_name
		nav_button.add_theme_constant_override("icon_max_width", 40 if portrait else 34)
	pass_panel.visible = not portrait and current_screen == "Ristorante" and not screen_panel.visible and (GameState.restaurant_state in ["open", "closing"] or active_count > 0)


func _update_tutorial() -> void:
	if tutorial_panel == null:
		return
	var step := int(GameState.tutorial.get("step", 0))
	tutorial_panel.visible = not bool(GameState.tutorial.get("skipped", false)) and not bool(GameState.tutorial.get("complete", false)) and step < TUTORIAL_STEPS.size()
	if tutorial_panel.visible:
		tutorial_label.text = "ONBOARDING %d/%d  ·  %s" % [step + 1, TUTORIAL_STEPS.size(), TUTORIAL_STEPS[step]]


func _connect_state() -> void:
	GameState.money_changed.connect(func(_value: int): _update_top_bar())
	GameState.reputation_changed.connect(func(_value: float): _update_top_bar())
	GameState.restaurant_state_changed.connect(func(_value: String): _update_top_bar(); _update_world_actions(); if current_screen != "Ristorante": refresh_screen())
	GameState.stock_changed.connect(func(_id: String, _value: int): if current_screen == "Magazzino": refresh_screen())
	GameState.menu_changed.connect(func(): if current_screen == "Menu": refresh_screen())
	GameState.employees_changed.connect(func(): if current_screen == "Personale": refresh_screen())
	GameState.toast_requested.connect(show_toast)
	SimulationManager.order_created.connect(func(_order: Dictionary): advance_tutorial_to(5); _update_pass())
	SimulationManager.dish_ready.connect(func(_order: Dictionary): _update_pass())


func _on_selection_changed(object: PlacedObject) -> void:
	if build_hud and build_hud.is_open:
		return
	if current_screen == "Ristorante":
		refresh_screen()


func _on_preview_changed(_valid: bool, _reason: String, _cost: int) -> void:
	if build_hud and build_hud.is_open:
		return
	if current_screen == "Ristorante":
		refresh_screen()


func _apply_responsive_layout() -> void:
	if root == null:
		return
	var portrait := root.size.y > root.size.x
	screen_panel.anchor_left = 0
	screen_panel.anchor_right = 1
	screen_panel.offset_left = 8 if portrait else 14
	screen_panel.offset_right = -8 if portrait else -14
	if portrait:
		pass_panel.visible = false
	if _orientation_initialized and portrait != _was_portrait and screen_panel.visible:
		show_screen.call_deferred(current_screen, false)
	_was_portrait = portrait
	_orientation_initialized = true


func _build_theme() -> void:
	_theme = Theme.new()
	_theme.default_font = GameFonts.medium()
	_theme.default_font_size = 16
	_theme.set_font("font", "Button", GameFonts.semibold())
	_theme.set_font("font", "OptionButton", GameFonts.semibold())
	_theme.set_font("font", "CheckBox", GameFonts.semibold())
	_theme.set_font("font", "TabBar", GameFonts.semibold())
	_theme.set_color("font_color", "Label", Color("29464b"))
	_theme.set_color("font_color", "Button", Color("fffaf0"))
	_theme.set_color("font_color", "CheckBox", Color("304e52"))
	_theme.set_color("font_hover_color", "CheckBox", Color("1d777f"))
	_theme.set_color("font_pressed_color", "CheckBox", Color("1d777f"))
	_theme.set_font_size("font_size", "Button", 17)
	_theme.set_font_size("font_size", "OptionButton", 16)
	_theme.set_constant("separation", "VBoxContainer", 8)


func _button_style(tone: String) -> StyleBox:
	var colors := {
		"blue": Color("277985"),
		"green": Color("1d9b72"),
		"red": Color("c95360"),
		"yellow": Color("d59535"),
		"ghost": Color("44666b")
	}
	var style := StyleBoxFlat.new()
	style.bg_color = colors.get(tone, colors.blue)
	style.border_color = Color("ffffff24")
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


func _update_nav_selection() -> void:
	for screen_name: String in nav_buttons:
		var button: Button = nav_buttons[screen_name]
		button.add_theme_stylebox_override("normal", _button_style("yellow" if screen_panel.visible and screen_name == current_screen else "blue"))
		if screen_name == "Ristorante" and not screen_panel.visible:
			button.add_theme_stylebox_override("normal", _button_style("yellow"))


func _update_world_actions() -> void:
	if world_action_panel == null:
		return
	world_action_panel.visible = current_screen == "Ristorante" and not screen_panel.visible and GameState.restaurant_state in ["closed", "open"] and (build_hud == null or not build_hud.is_open)
	world_build_button.text = "Costruisci e modifica" if GameState.restaurant_state == "closed" else "Modifica decorazioni"


func _panel_style(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style


func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()


func _format_number(value: int) -> String:
	var text := str(value)
	var result := ""
	while text.length() > 3:
		result = "." + text.right(3) + result
		text = text.left(text.length() - 3)
	return text + result


func _debug_unlock_all() -> void:
	for ingredient_id: String in GameState.stock:
		GameState.unlock_ingredient(ingredient_id, "Debug", false)
	for recipe_id: String in GameState.menu:
		GameState.menu[recipe_id].unlocked = true
	GameState.menu_changed.emit()
	refresh_screen()


func _debug_fill_stock(amount: int) -> void:
	for ingredient_id: String in GameState.stock:
		GameState.stock[ingredient_id].amount = amount
		GameState.stock_changed.emit(ingredient_id, amount)


func _debug_print_tasks() -> void:
	print("ACTIVE TASKS: ", SimulationManager.tasks)
	show_toast("Task stampati nella console")


func _debug_reset() -> void:
	SimulationManager.close_immediately()
	SaveManager.reset_save()
	world.load_layout()
	world.spawn_staff()
	refresh_screen()
