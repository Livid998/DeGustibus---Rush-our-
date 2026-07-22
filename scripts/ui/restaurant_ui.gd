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
var readiness_dialog: ConfirmationDialog
var readiness_cta_button: Button
var _readiness_cta_action := ""
var money_label: Label
var reputation_label: Label
var state_button: Button
var clock_label: Label
var period_icon_rect: TextureRect
var rush_status_label: Label
var rush_progress: ProgressBar
var customer_label: Label
var speed_icon_rect: TextureRect
var speed_selector: OptionButton
var top_bar_flow: HFlowContainer
var money_group: HBoxContainer
var reputation_group: HBoxContainer
var clock_stack: VBoxContainer
var build_hud: BuildHUD
var nav_buttons: Dictionary = {}
var nav_panel: PanelContainer
var nav_row: HBoxContainer
var more_button: Button
var more_sheet: PanelContainer
var more_sheet_grid: GridContainer
var more_sheet_buttons: Dictionary = {}
var screen_title_label: Label
var screen_close_button: Button
var world_action_panel: PanelContainer
var world_build_button: Button
var profile_summary_button: Button
var camera_controls: PanelContainer
var wall_visibility_button: Button
var current_screen := "Ristorante"
var market_provider := MockMarketProvider.new()
var _refresh_clock := 0.0
var _pass_refresh_clock := 0.0
var _toast_tween: Tween
var _market_refresh_clock := 0.0
var _theme: Theme
var _orientation_initialized := false
var _was_portrait := false
var _layout_viewport_size := Vector2(1280, 720)
var _screen_pages: Dictionary = {}
var _screen_scroll_positions: Dictionary = {}
var _screen_build_counts: Dictionary = {}
var _dirty_screens: Dictionary = {}

const SCREENS := ["Ristorante", "Menu", "Album", "Magazzino", "Mercato", "Personale", "Statistiche", "Impostazioni"]
const PHONE_PRIMARY_SCREENS := ["Ristorante", "Menu", "Magazzino", "Mercato"]
const PHONE_MORE_SCREENS := ["Album", "Personale", "Statistiche", "Impostazioni"]
const PHONE_NAV_LABELS := {
	"Ristorante": "Risto",
	"Menu": "Menu",
	"Magazzino": "Scorte",
	"Mercato": "Mercato",
}
const COMPACT_NAV_LABELS := {
	"Ristorante": "Risto",
	"Menu": "Menu",
	"Album": "Album",
	"Magazzino": "Scorte",
	"Mercato": "Mercato",
	"Personale": "Staff",
	"Statistiche": "Dati",
	"Impostazioni": "Opzioni",
}
const QUALITY_DEFECT_LABELS := {
	"small_portion": "Porzione piccola",
	"undercooked": "Cottura insufficiente",
	"overcooked": "Cottura eccessiva",
	"burned": "Piatto bruciato",
	"poor_presentation": "Presentazione debole",
}
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_theme()
	_build_shell()
	_connect_state()
	_connect_day_cycle()
	_update_top_bar()
	_update_pass()
	_update_tutorial()


func setup(value_world: RestaurantWorld) -> void:
	world = value_world
	world.build_system.selection_changed.connect(_on_selection_changed)
	world.build_system.preview_changed.connect(_on_preview_changed)
	world.layout_object_moved.connect(_on_layout_object_moved)
	world.layout_object_added.connect(_on_layout_object_added)
	world.camera_rig.view_changed.connect(func(_quadrant: int): _refresh_camera_controls())
	build_hud.setup(self, world)
	_refresh_camera_controls()
	show_screen("Ristorante")


func _on_layout_object_moved(object: PlacedObject, previous_cell: Vector2i) -> void:
	if object != null and is_instance_valid(object) and object.item_id.begins_with("table") and object.grid_cell != previous_cell:
		TutorialManager.record_event("table_moved", {"uid": object.uid})


func _on_layout_object_added(object: PlacedObject) -> void:
	if object != null and is_instance_valid(object) and object.item_id in ["chair", "stool"] and not object.support_uid.is_empty():
		TutorialManager.record_event("chair_placed", {"uid": object.uid, "table_uid": object.support_uid})


func _process(delta: float) -> void:
	var cycle := _day_cycle()
	var simulation_paused := cycle != null and bool(cycle.get("paused"))
	var market_changed := market_provider.tick(0.0 if simulation_paused else delta * SimulationManager.simulation_speed)
	_market_refresh_clock -= delta
	_refresh_clock += delta
	_pass_refresh_clock += delta
	if _refresh_clock >= 0.5:
		_refresh_clock = 0.0
		_update_top_bar()
	if _pass_refresh_clock >= 1.0:
		_pass_refresh_clock = 0.0
		if current_screen == "Ristorante":
			_update_pass()
		var market_page: VBoxContainer = _screen_pages.get("Mercato")
		if market_page != null:
			ManagementScreens.update_market_countdowns(market_page, market_provider)
	if market_changed:
		_mark_screen_dirty("Mercato")
		if current_screen == "Mercato" and screen_panel.visible:
			refresh_screen()
	elif current_screen == "Mercato" and _market_refresh_clock <= 0.0:
		_market_refresh_clock = 1.0
		var visible_market_page: VBoxContainer = _screen_pages.get("Mercato")
		if visible_market_page != null:
			ManagementScreens.update_market_countdowns(visible_market_page, market_provider)
	if OS.is_debug_build() and debug_panel != null and Input.is_action_just_pressed("toggle_debug"):
		debug_panel.visible = not debug_panel.visible
	if Input.is_action_just_pressed("speed_1"):
		_select_simulation_speed(1.0)
	if Input.is_action_just_pressed("speed_2"):
		_select_simulation_speed(2.0)
	if Input.is_action_just_pressed("speed_4"):
		_select_simulation_speed(4.0)


func show_screen(screen_name: String, sound: bool = true) -> void:
	if screen_name not in SCREENS:
		return
	if build_hud and build_hud.is_open:
		build_hud.close_builder()
	_store_current_scroll()
	_close_more_sheet()
	current_screen = screen_name
	if screen_name == "Ristorante":
		close_screen()
		if sound:
			AudioManager.play_feedback()
		return
	var page := _ensure_screen_page(screen_name)
	if _dirty_screens.has(screen_name):
		_refresh_screen_page(screen_name, page)
		_dirty_screens.erase(screen_name)
	_show_only_screen_page(page)
	ManagementScreens.apply_responsive_layout(page, self)
	screen_title_label.text = screen_name.to_upper()
	var animate_open := sound or not screen_panel.visible
	screen_panel.visible = true
	if animate_open and not reduced_motion_enabled():
		screen_panel.modulate.a = 0.0
		create_tween().tween_property(screen_panel, "modulate:a", 1.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	else:
		screen_panel.modulate.a = 1.0
	_update_nav_selection()
	_update_world_actions()
	_update_pass()
	_restore_current_scroll(screen_name)
	if sound:
		AudioManager.play_ui("page")
	if screen_name == "Statistiche":
		TutorialManager.record_event("station_load_viewed")


func close_screen() -> void:
	_store_current_scroll()
	_close_more_sheet()
	current_screen = "Ristorante"
	screen_panel.visible = false
	_update_nav_selection()
	_update_world_actions()
	_update_pass()


func open_builder() -> void:
	build_hud.open()


func refresh_screen() -> void:
	if current_screen == "Ristorante":
		return
	var page := _ensure_screen_page(current_screen)
	_store_current_scroll()
	_refresh_screen_page(current_screen, page)
	_dirty_screens.erase(current_screen)
	_restore_current_scroll(current_screen)


func screen_page(screen_name: String) -> VBoxContainer:
	return _screen_pages.get(screen_name)


func screen_build_count(screen_name: String) -> int:
	return int(_screen_build_counts.get(screen_name, 0))


func is_phone_layout() -> bool:
	return _layout_viewport_size.x <= 600.0


func is_portrait_layout() -> bool:
	return _layout_viewport_size.y > _layout_viewport_size.x


func responsive_viewport_size() -> Vector2:
	return _layout_viewport_size


func _ensure_screen_page(screen_name: String) -> VBoxContainer:
	var existing: VBoxContainer = _screen_pages.get(screen_name)
	if is_instance_valid(existing):
		return existing
	var page := VBoxContainer.new()
	page.name = "%sPage" % screen_name.validate_node_name()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 10)
	page.visible = false
	screen_content.add_child(page)
	ManagementScreens.populate(screen_name, page, self)
	GameFonts.sanitize_control_tree(page)
	_enforce_touch_targets(page)
	_screen_pages[screen_name] = page
	_screen_build_counts[screen_name] = int(_screen_build_counts.get(screen_name, 0)) + 1
	return page


func _refresh_screen_page(screen_name: String, page: VBoxContainer) -> void:
	if not is_instance_valid(page):
		return
	ManagementScreens.refresh(screen_name, page, self)
	GameFonts.sanitize_control_tree(page)
	ManagementScreens.apply_responsive_layout(page, self)
	_enforce_touch_targets(page)


func _show_only_screen_page(page: VBoxContainer) -> void:
	for candidate: VBoxContainer in _screen_pages.values():
		if is_instance_valid(candidate):
			candidate.visible = candidate == page


func _store_current_scroll() -> void:
	if (
		screen_scroll == null
		or current_screen == "Ristorante"
		or not screen_panel.visible
	):
		return
	_screen_scroll_positions[current_screen] = screen_scroll.scroll_vertical


func _restore_current_scroll(screen_name: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if screen_scroll == null or current_screen != screen_name or not screen_panel.visible:
		return
	screen_scroll.scroll_vertical = int(_screen_scroll_positions.get(screen_name, 0))


func _mark_screen_dirty(screen_name: String) -> void:
	if screen_name in SCREENS and screen_name != "Ristorante":
		_dirty_screens[screen_name] = true


func _request_screen_update(screen_name: String) -> void:
	_mark_screen_dirty(screen_name)
	if current_screen == screen_name and screen_panel.visible:
		refresh_screen()


func make_button(text: String, callback: Callable, tone: String = "blue") -> Button:
	var button := Button.new()
	set_button_content(button, text)
	button.custom_minimum_size = Vector2(112, 48)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.set_meta("ui_tone", tone)
	button.pressed.connect(func(): AudioManager.play_ui("tap"))
	button.pressed.connect(callback)
	button.add_theme_stylebox_override("normal", _button_style(tone))
	button.add_theme_stylebox_override("hover", _button_style("green" if tone != "red" else "yellow"))
	button.add_theme_stylebox_override("pressed", _button_style("yellow"))
	return button


func set_button_content(button: Button, value: String) -> void:
	var display_text := value
	var icon_texture: Texture2D
	var tooltip := value
	if "[coin]" in display_text:
		icon_texture = GameIcons.currency_icon()
		display_text = display_text.replace("[coin]", "").strip_edges()
		tooltip = tooltip.replace("[coin]", "monete")
	elif "[lock]" in display_text:
		icon_texture = GameIcons.lock_icon()
		display_text = display_text.replace("[lock]", "").strip_edges()
		tooltip = tooltip.replace("[lock]", "Bloccato")
	button.text = GameFonts.web_safe_text(display_text)
	button.tooltip_text = GameFonts.web_safe_text(tooltip)
	button.icon = GameIcons.scaled_icon(icon_texture, 24) if icon_texture else null
	button.expand_icon = icon_texture != null
	if icon_texture:
		button.add_theme_constant_override("icon_max_width", 24)


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
	panel.set_meta("accessible_card", true)
	panel.add_theme_stylebox_override("panel", _card_style())
	return panel


func show_toast(message: String, tone: String = "info") -> void:
	toast_label.text = GameFonts.web_safe_text(message)
	toast_label.visible = true
	toast_label.modulate = Color.WHITE
	toast_label.add_theme_color_override("font_color", {
		"income": Color("d9ffd7"), "cost": Color("ffe0bb"), "warning": Color("ffd4c8")
	}.get(tone, Color.WHITE))
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	AudioManager.play_event({"income":"income", "warning":"warning", "cost":"warning"}.get(tone, "notification"))
	_toast_tween.tween_interval(2.25 if reduced_motion_enabled() else 1.8)
	if not reduced_motion_enabled():
		_toast_tween.tween_property(toast_label, "modulate:a", 0.0, 0.45)
	_toast_tween.tween_callback(func(): toast_label.visible = false)


func advance_tutorial_to(step: int) -> void:
	TutorialManager.record_legacy_step(step)


func _build_shell() -> void:
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _theme
	add_child(root)
	_build_top_bar()
	_build_bottom_nav()
	_build_more_sheet()
	_build_screen_panel()
	_build_world_actions()
	_build_pass_panel()
	if OS.is_debug_build():
		_build_debug_panel()
	_build_toast()
	_build_tutorial()
	_build_readiness_dialog()
	build_hud = BuildHUD.new()
	root.add_child(build_hud)
	_build_camera_controls()
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
	top_bar_flow = HFlowContainer.new()
	top_bar_flow.name = "TopBarFlow"
	top_bar_flow.add_theme_constant_override("h_separation", 12)
	top_bar_flow.add_theme_constant_override("v_separation", 6)
	margin.add_child(top_bar_flow)
	money_label = Label.new()
	money_label.add_theme_font_override("font", GameFonts.bold())
	money_label.add_theme_color_override("font_color", Color("f5fbf9"))
	money_group = HBoxContainer.new()
	money_group.custom_minimum_size.x = 118
	money_group.add_theme_constant_override("separation", 5)
	money_group.add_child(_top_bar_icon(GameIcons.currency_icon()))
	money_group.add_child(money_label)
	reputation_label = Label.new()
	reputation_label.add_theme_font_override("font", GameFonts.bold())
	reputation_label.add_theme_color_override("font_color", Color("f5fbf9"))
	reputation_group = HBoxContainer.new()
	reputation_group.custom_minimum_size.x = 82
	reputation_group.add_theme_constant_override("separation", 5)
	reputation_group.add_child(_top_bar_icon(GameIcons.reputation_icon()))
	reputation_group.add_child(reputation_label)
	state_button = make_button("CHIUSO", _toggle_restaurant, "red")
	state_button.custom_minimum_size.x = 250
	clock_label = Label.new()
	clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	clock_label.add_theme_color_override("font_color", Color("f5fbf9"))
	clock_label.add_theme_font_override("font", GameFonts.bold())
	rush_status_label = Label.new()
	rush_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rush_status_label.add_theme_font_size_override("font_size", 11)
	rush_status_label.add_theme_color_override("font_color", Color("b9d9d4"))
	rush_progress = ProgressBar.new()
	rush_progress.custom_minimum_size.y = 5
	rush_progress.max_value = 1.0
	rush_progress.show_percentage = false
	clock_stack = VBoxContainer.new()
	clock_stack.custom_minimum_size.x = 220
	clock_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clock_stack.add_theme_constant_override("separation", 1)
	clock_stack.add_child(clock_label)
	clock_stack.add_child(rush_status_label)
	clock_stack.add_child(rush_progress)
	period_icon_rect = _top_bar_icon(GameIcons.casual_system_icon("sun"))
	customer_label = Label.new()
	customer_label.add_theme_color_override("font_color", Color("f5fbf9"))
	speed_selector = OptionButton.new()
	for label: String in ["0x", "1x", "2x", "4x"]:
		speed_selector.add_item(label)
	speed_icon_rect = _top_bar_icon(GameIcons.speed_icon(0))
	speed_selector.item_selected.connect(_on_speed_selected)
	top_bar_flow.add_child(money_group)
	top_bar_flow.add_child(reputation_group)
	top_bar_flow.add_child(state_button)
	top_bar_flow.add_child(period_icon_rect)
	top_bar_flow.add_child(clock_stack)
	top_bar_flow.add_child(customer_label)
	top_bar_flow.add_child(speed_icon_rect)
	top_bar_flow.add_child(speed_selector)


func _top_bar_icon(texture: Texture2D) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = texture
	icon.custom_minimum_size = Vector2(28, 28)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return icon


func _day_cycle() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("DayCycleManager")


func _connect_day_cycle() -> void:
	var cycle := _day_cycle()
	if cycle == null:
		return
	_connect_cycle_signal(cycle, "minute_changed", "_on_day_cycle_minute_changed")
	_connect_cycle_signal(cycle, "period_changed", "_on_day_cycle_period_changed")
	_connect_cycle_signal(cycle, "rush_warning", "_on_day_cycle_rush_warning")
	_connect_cycle_signal(cycle, "rush_started", "_on_day_cycle_rush_changed")
	_connect_cycle_signal(cycle, "rush_ended", "_on_day_cycle_rush_changed")
	_connect_cycle_signal(cycle, "pause_changed", "_on_day_cycle_pause_changed")


func _connect_cycle_signal(cycle: Node, signal_name: String, method_name: String) -> void:
	if not cycle.has_signal(signal_name):
		return
	var callback := Callable(self, method_name)
	if not cycle.is_connected(signal_name, callback):
		cycle.connect(signal_name, callback)


func _on_day_cycle_minute_changed(_day: int, _minute: int) -> void:
	_update_top_bar()


func _on_day_cycle_period_changed(_period_id: String) -> void:
	_update_top_bar()


func _on_day_cycle_rush_warning(_rush_id: String, _seconds_remaining: float) -> void:
	_update_top_bar()


func _on_day_cycle_rush_changed(_rush_id: String) -> void:
	_update_top_bar()


func _on_day_cycle_pause_changed(_paused: bool) -> void:
	_update_top_bar()


func _on_speed_selected(index: int) -> void:
	var cycle := _day_cycle()
	if index == 0:
		if cycle != null and cycle.has_method("set_paused"):
			cycle.call("set_paused", true)
		_sync_speed_controls()
		return
	_select_simulation_speed([1.0, 2.0, 4.0][clampi(index - 1, 0, 2)])


func _select_simulation_speed(speed: float) -> void:
	var cycle := _day_cycle()
	if cycle != null and cycle.has_method("set_paused"):
		cycle.call("set_paused", false)
	SimulationManager.set_speed(speed)
	_sync_speed_controls()
	_update_top_bar()


func _sync_speed_controls() -> void:
	if speed_selector == null or speed_icon_rect == null:
		return
	var cycle := _day_cycle()
	var is_paused := cycle != null and bool(cycle.get("paused"))
	if is_paused:
		speed_selector.select(0)
		speed_icon_rect.texture = GameIcons.pause_icon()
		return
	var speed_index := 0
	if SimulationManager.simulation_speed >= 3.0:
		speed_index = 2
	elif SimulationManager.simulation_speed >= 1.5:
		speed_index = 1
	speed_selector.select(speed_index + 1)
	speed_icon_rect.texture = GameIcons.speed_icon(speed_index)


func _build_bottom_nav() -> void:
	nav_panel = PanelContainer.new()
	nav_panel.name = "PrimaryNavigation"
	nav_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	nav_panel.offset_top = -68
	nav_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	nav_panel.add_theme_stylebox_override("panel", _panel_style(Color("173f45f2"), 0))
	root.add_child(nav_panel)
	nav_row = HBoxContainer.new()
	nav_row.name = "PrimaryNavigationRow"
	nav_row.alignment = BoxContainer.ALIGNMENT_CENTER
	nav_row.add_theme_constant_override("separation", 8)
	nav_panel.add_child(nav_row)
	for screen_name: String in SCREENS:
		var button := make_button(screen_name, func(): show_screen(screen_name), "blue")
		button.name = "Nav_%s" % screen_name.validate_node_name()
		button.custom_minimum_size = Vector2(92, 46)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 14)
		button.icon = GameIcons.navigation_icon(screen_name)
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 34)
		button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.tooltip_text = screen_name
		nav_buttons[screen_name] = button
		nav_row.add_child(button)
	more_button = make_button("Altro", _toggle_more_sheet, "blue")
	more_button.name = "Nav_Altro"
	more_button.custom_minimum_size = Vector2(92, 46)
	more_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	more_button.add_theme_font_size_override("font_size", 14)
	more_button.icon = GameIcons.navigation_icon("Impostazioni")
	more_button.expand_icon = true
	more_button.add_theme_constant_override("icon_max_width", 34)
	more_button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	more_button.tooltip_text = "Altre sezioni"
	more_button.visible = false
	nav_row.add_child(more_button)


func _build_more_sheet() -> void:
	more_sheet = PanelContainer.new()
	more_sheet.name = "MoreNavigationSheet"
	more_sheet.anchor_left = 0.0
	more_sheet.anchor_right = 1.0
	more_sheet.anchor_top = 1.0
	more_sheet.anchor_bottom = 1.0
	more_sheet.offset_left = 8
	more_sheet.offset_right = -8
	more_sheet.offset_top = -338
	more_sheet.offset_bottom = -76
	more_sheet.mouse_filter = Control.MOUSE_FILTER_STOP
	more_sheet.z_index = 40
	more_sheet.add_theme_stylebox_override(
		"panel",
		_panel_style(Color("173f45fa"), 18)
	)
	root.add_child(more_sheet)
	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", 10)
	more_sheet.add_child(shell)
	var heading_row := HBoxContainer.new()
	shell.add_child(heading_row)
	var title := Label.new()
	title.text = "ALTRE SEZIONI"
	title.add_theme_font_override("font", GameFonts.bold())
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color("fffaf0"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_row.add_child(title)
	var close := make_button("Chiudi", _close_more_sheet, "ghost")
	close.custom_minimum_size = Vector2(96, 42)
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	heading_row.add_child(close)
	more_sheet_grid = GridContainer.new()
	more_sheet_grid.name = "MoreNavigationGrid"
	more_sheet_grid.columns = 2
	more_sheet_grid.add_theme_constant_override("h_separation", 10)
	more_sheet_grid.add_theme_constant_override("v_separation", 10)
	shell.add_child(more_sheet_grid)
	for screen_name: String in PHONE_MORE_SCREENS:
		var button := make_button(
			screen_name,
			func(): show_screen(screen_name),
			"blue"
		)
		button.name = "MoreNav_%s" % screen_name.validate_node_name()
		button.custom_minimum_size = Vector2(150, 72)
		button.icon = GameIcons.navigation_icon(screen_name)
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 40)
		button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.tooltip_text = "Apri %s" % screen_name
		more_sheet_buttons[screen_name] = button
		more_sheet_grid.add_child(button)
	more_sheet.visible = false


func _toggle_more_sheet() -> void:
	if more_sheet == null or not is_phone_layout():
		return
	more_sheet.visible = not more_sheet.visible
	_update_nav_selection()
	if more_sheet.visible:
		AudioManager.play_feedback()


func _close_more_sheet() -> void:
	if more_sheet != null:
		more_sheet.visible = false
	_update_nav_selection()


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
	screen_close_button = make_button("Torna alla mappa", close_screen, "ghost")
	screen_close_button.name = "ManagementCloseButton"
	screen_close_button.custom_minimum_size = Vector2(160, 42)
	screen_close_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	header.add_child(screen_close_button)
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
	world_action_panel.offset_right = 420
	world_action_panel.offset_top = -132
	world_action_panel.offset_bottom = -78
	world_action_panel.add_theme_stylebox_override("panel", _panel_style(Color("173f45e8"), 12))
	root.add_child(world_action_panel)
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	world_action_panel.add_child(action_row)
	world_build_button = make_button("Costruisci e modifica", open_builder, "yellow")
	world_build_button.custom_minimum_size = Vector2(180, 44)
	action_row.add_child(world_build_button)
	profile_summary_button = make_button("", func(): show_screen("Impostazioni"), "ghost")
	profile_summary_button.custom_minimum_size = Vector2(170, 44)
	profile_summary_button.icon = GameIcons.casual_system_icon("profile_avatar")
	profile_summary_button.expand_icon = true
	profile_summary_button.add_theme_constant_override("icon_max_width", 32)
	profile_summary_button.tooltip_text = "Apri il profilo del ristorante"
	action_row.add_child(profile_summary_button)
	_update_profile_summary()


func _update_profile_summary() -> void:
	if profile_summary_button == null:
		return
	var restaurant_name := String(GameState.restaurant_profile.get("restaurant_name", "DeGustibus")).strip_edges()
	if restaurant_name.is_empty():
		restaurant_name = "DeGustibus"
	profile_summary_button.text = GameFonts.web_safe_text(restaurant_name)


func _build_camera_controls() -> void:
	camera_controls = PanelContainer.new()
	camera_controls.offset_left = 14
	camera_controls.offset_right = 326
	camera_controls.offset_top = 80
	camera_controls.offset_bottom = 142
	camera_controls.mouse_filter = Control.MOUSE_FILTER_STOP
	camera_controls.add_theme_stylebox_override("panel", _panel_style(Color("173f45e8"), 12))
	root.add_child(camera_controls)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 7)
	camera_controls.add_child(row)
	var rotate_left_button := make_button("", func(): if world: world.camera_rig.rotate_left(), "blue")
	rotate_left_button.icon = GameIcons.rotate_left_icon()
	rotate_left_button.expand_icon = true
	rotate_left_button.add_theme_constant_override("icon_max_width", 30)
	rotate_left_button.custom_minimum_size = Vector2(54, 48)
	rotate_left_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	rotate_left_button.tooltip_text = "Ruota la mappa a sinistra"
	rotate_left_button.add_theme_font_size_override("font_size", 25)
	row.add_child(rotate_left_button)
	wall_visibility_button = make_button("Muri ridotti", _toggle_reduced_walls, "ghost")
	wall_visibility_button.custom_minimum_size = Vector2(148, 48)
	wall_visibility_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	wall_visibility_button.tooltip_text = "Alterna muri interi e muretti bassi sui lati non nascosti"
	wall_visibility_button.add_theme_font_size_override("font_size", 14)
	row.add_child(wall_visibility_button)
	var rotate_right_button := make_button("", func(): if world: world.camera_rig.rotate_right(), "blue")
	rotate_right_button.icon = GameIcons.rotate_right_icon()
	rotate_right_button.expand_icon = true
	rotate_right_button.add_theme_constant_override("icon_max_width", 30)
	rotate_right_button.custom_minimum_size = Vector2(54, 48)
	rotate_right_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	rotate_right_button.tooltip_text = "Ruota la mappa a destra"
	rotate_right_button.add_theme_font_size_override("font_size", 25)
	row.add_child(rotate_right_button)


func _toggle_reduced_walls() -> void:
	if world == null:
		return
	world.toggle_reduced_walls()
	_refresh_camera_controls()
	AudioManager.play_feedback()


func _refresh_camera_controls() -> void:
	if camera_controls == null:
		return
	camera_controls.visible = current_screen == "Ristorante" and not screen_panel.visible
	if wall_visibility_button and world:
		wall_visibility_button.text = "Muri ridotti" if world.reduced_walls else "Muri normali"


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
	var skip := make_button("Salta", TutorialManager.skip, "ghost")
	skip.custom_minimum_size = Vector2(68, 34)
	skip.size_flags_horizontal = Control.SIZE_SHRINK_END
	box.add_child(skip)


func _build_readiness_dialog() -> void:
	readiness_dialog = ConfirmationDialog.new()
	readiness_dialog.title = "Checklist prima dell'apertura"
	readiness_dialog.exclusive = true
	readiness_dialog.get_ok_button().text = "Chiudi"
	readiness_dialog.get_cancel_button().visible = false
	readiness_cta_button = readiness_dialog.add_button("Risolvi il primo problema", true)
	readiness_cta_button.pressed.connect(_activate_readiness_cta)
	root.add_child(readiness_dialog)


func _show_opening_readiness(readiness: Dictionary) -> void:
	if readiness_dialog == null:
		return
	var lines := PackedStringArray(["Prima di aprire risolvi questi punti:"])
	var blockers: Array = readiness.get("blockers", [])
	for issue: Dictionary in blockers:
		lines.append("- %s" % String(issue.get("message", "Problema non specificato")))
	var warnings: Array = readiness.get("warnings", [])
	if not warnings.is_empty():
		lines.append("")
		lines.append("Avvisi non bloccanti:")
		for issue: Dictionary in warnings:
			lines.append("- %s" % String(issue.get("message", "")))
	readiness_dialog.dialog_text = "\n".join(lines)
	_readiness_cta_action = ""
	if not blockers.is_empty():
		var cta: Dictionary = (blockers[0] as Dictionary).get("cta", {})
		_readiness_cta_action = String(cta.get("action", ""))
		readiness_cta_button.text = String(cta.get("label", "Risolvi il primo problema"))
	readiness_cta_button.visible = not _readiness_cta_action.is_empty()
	readiness_dialog.popup_centered(Vector2i(580, 420))


func _activate_readiness_cta() -> void:
	readiness_dialog.hide()
	if _readiness_cta_action == "builder":
		open_builder()
	elif _readiness_cta_action in SCREENS:
		show_screen(_readiness_cta_action)


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
		["Forza rush debug", func(): world.set_rush_mode(true); show_toast("Rush debug avviato", "warning")],
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
		"open":
			SimulationManager.request_close()
		"closing":
			show_toast("Il servizio termina con i clienti presenti")


func _update_top_bar() -> void:
	if money_label == null:
		return
	money_label.text = _format_number(GameState.money)
	reputation_label.text = "%.1f" % GameState.reputation
	var states := (
		{"closed":"CHIUSO", "open":"APERTO", "closing":"IN CHIUSURA"}
		if is_phone_layout()
		else {"closed":"RISTORANTE CHIUSO", "open":"RISTORANTE APERTO", "closing":"IN CHIUSURA"}
	)
	state_button.text = states.get(GameState.restaurant_state, GameState.restaurant_state)
	state_button.add_theme_stylebox_override("normal", _button_style("green" if GameState.restaurant_state == "open" else "yellow" if GameState.restaurant_state == "closing" else "red"))
	var cycle := _day_cycle()
	if cycle != null:
		var period_id := String(cycle.get("current_period_id"))
		var period_name := String(cycle.call("period_display_name", period_id))
		clock_label.text = (
			"G%d | %s | %s"
			if is_phone_layout()
			else "Giorno %d | %s | %s"
		) % [int(cycle.get("day")), String(cycle.call("formatted_time")), period_name]
		var rush: Dictionary = cycle.call("rush_status", SimulationManager.simulation_speed)
		var rush_phase := String(rush.get("phase", "idle"))
		var rush_id := String(rush.get("id", ""))
		var seconds_remaining := float(rush.get("seconds_remaining", -1.0))
		var traffic_warning := ""
		if world != null and world.has_method("traffic_flow_status"):
			traffic_warning = String((world.traffic_flow_status() as Dictionary).get("warning", ""))
		if rush_phase == "warning":
			rush_status_label.text = "Rush %s tra %ds" % [String(cycle.call("period_display_name", rush_id)), ceili(seconds_remaining)]
			rush_status_label.add_theme_color_override("font_color", Color("ffe48c"))
		elif rush_phase == "active":
			rush_status_label.text = "RUSH %s%s" % [
				String(cycle.call("period_display_name", rush_id)).to_upper(),
				" | %ds" % ceili(seconds_remaining) if seconds_remaining >= 0.0 else "",
			]
			rush_status_label.add_theme_color_override("font_color", Color("ffb17f"))
		elif not traffic_warning.is_empty():
			rush_status_label.text = traffic_warning
			rush_status_label.add_theme_color_override("font_color", Color("ffe48c"))
		else:
			rush_status_label.text = "Afflusso regolare"
			rush_status_label.add_theme_color_override("font_color", Color("b9d9d4"))
		rush_progress.visible = rush_phase in ["warning", "active"]
		rush_progress.value = float(rush.get("progress", 0.0))
		period_icon_rect.texture = GameIcons.casual_system_icon("rush" if rush_phase in ["warning", "active"] else "moon" if period_id == "night" else "sun")
	else:
		var minutes := int(GameState.service_seconds) / 60
		var seconds := int(GameState.service_seconds) % 60
		clock_label.text = "%02d:%02d" % [minutes, seconds]
		rush_status_label.text = "Ciclo giornaliero non disponibile"
		rush_progress.visible = false
		period_icon_rect.texture = GameIcons.casual_system_icon("sun")
	_sync_speed_controls()
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
		if String(order.get("state", "")) in ["paid", "cancelled"]:
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
		if order.has("quality_score"):
			var quality_box := VBoxContainer.new()
			quality_box.add_theme_constant_override("separation", 2)
			var quality_label := Label.new()
			quality_label.text = "Qualità %d · %s" % [
				int(order.get("quality_score", 0)),
				String(order.get("quality_tier", "normale")).capitalize(),
			]
			quality_label.add_theme_font_size_override("font_size", 11)
			quality_label.add_theme_color_override("font_color", Color("d7efea"))
			quality_box.add_child(quality_label)
			var quality_events: Array = order.get("quality_events", [])
			if not quality_events.is_empty() and quality_events.back() is Dictionary:
				var quality_event := quality_events.back() as Dictionary
				var icon_id := String(quality_event.get("icon_id", ""))
				var event_icon_texture := GameIcons.casual_system_icon(icon_id)
				if event_icon_texture != null:
					var event_icon := TextureRect.new()
					event_icon.texture = event_icon_texture
					event_icon.custom_minimum_size = Vector2(25, 25)
					event_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					event_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					event_icon.tooltip_text = String(
						QUALITY_DEFECT_LABELS.get(
							String(quality_event.get("id", "")),
							"Evento qualità"
						)
					)
					quality_box.add_child(event_icon)
			row.add_child(quality_box)
		var ticket_actions := VBoxContainer.new()
		ticket_actions.add_theme_constant_override("separation", 2)
		var suspended := bool(order.get("suspended", false))
		var suspend := make_button("", func(): SimulationManager.toggle_order_suspended(order_id), "green" if suspended else "ghost")
		suspend.icon = GameIcons.play_icon() if suspended else GameIcons.pause_icon()
		suspend.expand_icon = true
		suspend.add_theme_constant_override("icon_max_width", 20)
		suspend.tooltip_text = "Riprendi piatto" if bool(order.get("suspended", false)) else "Sospendi piatto"
		suspend.custom_minimum_size = Vector2(34, 28)
		suspend.size_flags_horizontal = Control.SIZE_SHRINK_END
		ticket_actions.add_child(suspend)
		var priority := make_button("", func(): SimulationManager.raise_order_priority(order_id), "yellow")
		priority.icon = GameIcons.priority_icon()
		priority.expand_icon = true
		priority.add_theme_constant_override("icon_max_width", 20)
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
	GameFonts.sanitize_control_tree(pass_content)
	var portrait := is_portrait_layout()
	pass_panel.visible = not portrait and current_screen == "Ristorante" and not screen_panel.visible and (GameState.restaurant_state in ["open", "closing"] or active_count > 0)


func _update_tutorial() -> void:
	if tutorial_panel == null:
		return
	var tutorial := TutorialManager.snapshot()
	var current_index := int(tutorial.get("current_index", 0))
	tutorial_panel.visible = (
		not bool(tutorial.get("skipped", false))
		and not bool(tutorial.get("complete", false))
		and current_index < int(tutorial.get("total_steps", 0))
	)
	if tutorial_panel.visible:
		var current: Dictionary = tutorial.get("current", {})
		tutorial_label.text = "ONBOARDING %d/%d - %s" % [
			current_index + 1,
			int(tutorial.get("total_steps", 0)),
			String(current.get("text", "")),
		]


func _connect_state() -> void:
	GameState.money_changed.connect(func(_value: int): _update_top_bar())
	GameState.reputation_changed.connect(func(_value: float): _update_top_bar())
	GameState.restaurant_state_changed.connect(func(_value: String):
		_update_top_bar()
		_update_world_actions()
		for screen_name: String in SCREENS:
			_mark_screen_dirty(screen_name)
		if current_screen != "Ristorante":
			refresh_screen()
	)
	GameState.stock_changed.connect(func(_id: String, _value: int):
		_request_screen_update("Magazzino")
		_mark_screen_dirty("Menu")
	)
	GameState.menu_changed.connect(func():
		_request_screen_update("Menu")
		_mark_screen_dirty("Statistiche")
	)
	GameState.album_inventory_changed.connect(func(_id: String, _value: int):
		_request_screen_update("Album")
	)
	GameState.album_discovered_changed.connect(func(_id: String, _value: bool):
		_request_screen_update("Album")
	)
	GameState.review_reward_progress_changed.connect(func(_value: int):
		_request_screen_update("Album")
	)
	# StaffScreen listens directly and refreshes only its role-filtered rows,
	# preserving the selected tab, scroll and focus instead of rebuilding the
	# entire management screen after every hire or dismissal.
	GameState.restaurant_profile_changed.connect(func(_value: Dictionary): _update_profile_summary())
	GameState.toast_requested.connect(show_toast)
	SimulationManager.order_created.connect(func(_order: Dictionary): _update_pass())
	SimulationManager.dish_ready.connect(func(_order: Dictionary): TutorialManager.record_event("first_dish_ready"); _update_pass())
	SimulationManager.restaurant_opening_blocked.connect(_show_opening_readiness)
	TutorialManager.state_changed.connect(func(_snapshot: Dictionary): _update_tutorial())


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


func _apply_responsive_layout(viewport_size: Vector2 = Vector2.ZERO) -> void:
	if root == null:
		return
	_layout_viewport_size = (
		viewport_size
		if viewport_size.x > 0.0 and viewport_size.y > 0.0
		else _detected_viewport_size()
	)
	var portrait := is_portrait_layout()
	var compact_phone := is_phone_layout()
	var compact_nav := not compact_phone and _layout_viewport_size.x <= 900.0
	var nav_height := 82.0 if compact_phone else 68.0
	var top_height := 148.0 if compact_phone else 124.0 if compact_nav else 68.0
	if top_bar != null:
		top_bar.offset_bottom = top_height
	if nav_panel != null:
		nav_panel.offset_top = -nav_height
	if more_sheet != null:
		more_sheet.visible = more_sheet.visible and compact_phone
		more_sheet.offset_top = -(nav_height + 270.0)
		more_sheet.offset_bottom = -(nav_height + 8.0)
	if money_group != null:
		money_group.custom_minimum_size.x = 82.0 if compact_phone else 118.0
	if reputation_group != null:
		reputation_group.custom_minimum_size.x = 66.0 if compact_phone else 82.0
	if state_button != null:
		state_button.custom_minimum_size.x = 168.0 if compact_phone else 250.0
		state_button.custom_minimum_size.y = 42.0 if compact_phone else 48.0
	if clock_stack != null:
		clock_stack.custom_minimum_size.x = 150.0 if compact_phone else 220.0
	if customer_label != null:
		customer_label.visible = not compact_phone
	if speed_icon_rect != null:
		speed_icon_rect.visible = not compact_phone
	if screen_close_button != null:
		screen_close_button.text = "Mappa" if compact_phone else "Torna alla mappa"
		screen_close_button.custom_minimum_size.x = 92.0 if compact_phone else 160.0
	if nav_row != null:
		nav_row.add_theme_constant_override("separation", 4 if compact_phone or compact_nav else 8)
	for screen_name: String in nav_buttons:
		var nav_button: Button = nav_buttons[screen_name]
		nav_button.visible = not compact_phone or screen_name in PHONE_PRIMARY_SCREENS
		nav_button.text = (
			String(PHONE_NAV_LABELS.get(screen_name, screen_name))
			if compact_phone
			else String(COMPACT_NAV_LABELS.get(screen_name, screen_name))
			if compact_nav
			else screen_name
		)
		nav_button.custom_minimum_size = Vector2(
			64.0 if compact_phone else 72.0 if compact_nav else 92.0,
			54.0 if compact_phone else 50.0 if compact_nav else 46.0
		)
		nav_button.add_theme_font_size_override(
			"font_size",
			10 if compact_phone else 12 if compact_nav else 14
		)
		nav_button.add_theme_constant_override(
			"icon_max_width",
			16 if compact_phone else 20 if compact_nav else 34
		)
		nav_button.icon_alignment = (
			HORIZONTAL_ALIGNMENT_CENTER
			if compact_phone
			else HORIZONTAL_ALIGNMENT_LEFT
		)
	if more_button != null:
		more_button.visible = compact_phone
		more_button.custom_minimum_size = Vector2(64, 54)
		more_button.add_theme_font_size_override("font_size", 10)
		more_button.add_theme_constant_override("icon_max_width", 16)
		more_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if profile_summary_button != null:
		profile_summary_button.visible = not compact_phone
	if world_action_panel != null:
		world_action_panel.offset_right = 222 if compact_phone else 420
		world_action_panel.offset_top = -(nav_height + 54.0)
		world_action_panel.offset_bottom = -(nav_height + 8.0)
	if camera_controls != null:
		camera_controls.offset_top = top_height + 12.0
		camera_controls.offset_bottom = top_height + 74.0
	screen_panel.anchor_left = 0
	screen_panel.anchor_right = 1
	screen_panel.offset_top = top_height + 8.0
	screen_panel.offset_bottom = -(nav_height + 10.0)
	screen_panel.offset_left = 8 if portrait else 14
	screen_panel.offset_right = -8 if portrait else -14
	if portrait:
		pass_panel.visible = false
	for page: VBoxContainer in _screen_pages.values():
		if is_instance_valid(page):
			ManagementScreens.apply_responsive_layout(page, self)
	_was_portrait = portrait
	_orientation_initialized = true
	_update_top_bar()
	_update_nav_selection()
	_enforce_touch_targets(root)


func _detected_viewport_size() -> Vector2:
	if DisplayServer.get_name() != "headless":
		var window_size := Vector2(get_window().size)
		if window_size.x > 0.0 and window_size.y > 0.0:
			return window_size
	if root != null and root.size.x > 0.0 and root.size.y > 0.0:
		return root.size
	return Vector2(1280, 720)


func reduced_motion_enabled() -> bool:
	return bool(GameState.settings.get("reduced_motion", false))


func apply_accessibility_settings() -> void:
	_build_theme()
	if root == null:
		return
	root.theme = _theme
	_refresh_accessible_styles(root)
	_enforce_touch_targets(root)


func _refresh_accessible_styles(node: Node) -> void:
	if node is Button and node.has_meta("ui_tone"):
		var button := node as Button
		var tone := String(button.get_meta("ui_tone", "blue"))
		button.add_theme_stylebox_override("normal", _button_style(tone))
		button.add_theme_stylebox_override("hover", _button_style("green" if tone != "red" else "yellow"))
		button.add_theme_stylebox_override("pressed", _button_style("yellow"))
	if node is PanelContainer and node.has_meta("accessible_card"):
		(node as PanelContainer).add_theme_stylebox_override("panel", _card_style())
	for child: Node in node.get_children():
		_refresh_accessible_styles(child)


func _enforce_touch_targets(node: Node) -> void:
	if node is BaseButton or node is LineEdit or node is SpinBox or node is HSlider or node is VSlider:
		var control := node as Control
		control.custom_minimum_size.y = maxf(control.custom_minimum_size.y, 44.0)
	for child: Node in node.get_children():
		_enforce_touch_targets(child)


func _build_theme() -> void:
	var high_contrast := bool(GameState.settings.get("high_contrast", false))
	_theme = Theme.new()
	_theme.default_font = GameFonts.medium()
	_theme.default_font_size = 16
	_theme.set_font("font", "Button", GameFonts.semibold())
	_theme.set_font("font", "OptionButton", GameFonts.semibold())
	_theme.set_font("font", "CheckBox", GameFonts.semibold())
	_theme.set_font("font", "TabBar", GameFonts.semibold())
	_theme.set_color("font_color", "Label", Color("10292e") if high_contrast else Color("29464b"))
	_theme.set_color("font_color", "Button", Color("fffaf0"))
	_theme.set_color("font_color", "CheckBox", Color("10292e") if high_contrast else Color("304e52"))
	_theme.set_color("font_hover_color", "CheckBox", Color("075f68") if high_contrast else Color("1d777f"))
	_theme.set_color("font_pressed_color", "CheckBox", Color("075f68") if high_contrast else Color("1d777f"))
	_theme.set_font_size("font_size", "Button", 17)
	_theme.set_font_size("font_size", "OptionButton", 16)
	_theme.set_constant("separation", "VBoxContainer", 8)
	var default_panel := StyleBoxFlat.new()
	default_panel.bg_color = Color("fffdf7f5") if high_contrast else Color("fffaf0e8")
	default_panel.border_color = Color("173f45") if high_contrast else Color("c9d9d7")
	default_panel.set_border_width_all(2 if high_contrast else 1)
	default_panel.set_corner_radius_all(12)
	_theme.set_stylebox("panel", "PanelContainer", default_panel)
	var focus := StyleBoxFlat.new()
	focus.bg_color = Color("00000000")
	focus.border_color = Color("fff1a8") if high_contrast else Color("8de0d4")
	focus.set_border_width_all(3)
	focus.set_corner_radius_all(10)
	focus.expand_margin_left = 2
	focus.expand_margin_right = 2
	focus.expand_margin_top = 2
	focus.expand_margin_bottom = 2
	_theme.set_stylebox("focus", "Button", focus)
	_theme.set_stylebox("focus", "OptionButton", focus)
	_theme.set_stylebox("focus", "CheckBox", focus)


func _button_style(tone: String) -> StyleBox:
	var high_contrast := bool(GameState.settings.get("high_contrast", false))
	var colors := ({
		"blue": Color("075f68"),
		"green": Color("087247"),
		"red": Color("9f2438"),
		"yellow": Color("9b5a00"),
		"ghost": Color("243f44")
	} if high_contrast else {
		"blue": Color("277985"),
		"green": Color("1d9b72"),
		"red": Color("c95360"),
		"yellow": Color("d59535"),
		"ghost": Color("44666b")
	})
	var style := StyleBoxFlat.new()
	style.bg_color = colors.get(tone, colors.blue)
	style.border_color = Color("fff8df") if high_contrast else Color("ffffff24")
	style.set_border_width_all(2 if high_contrast else 1)
	style.set_corner_radius_all(9)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


func _card_style() -> StyleBoxFlat:
	var high_contrast := bool(GameState.settings.get("high_contrast", false))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fffdf7") if high_contrast else Color("f5f0e7")
	style.border_color = Color("173f45") if high_contrast else Color("d4c9b7")
	style.set_border_width_all(2 if high_contrast else 1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style


func _phone_nav_style(tone: String) -> StyleBoxFlat:
	var style := _button_style(tone) as StyleBoxFlat
	style.content_margin_left = 3
	style.content_margin_right = 3
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	style.set_corner_radius_all(8)
	return style


func _update_nav_selection() -> void:
	var compact_nav := _layout_viewport_size.x <= 900.0
	for screen_name: String in nav_buttons:
		var button: Button = nav_buttons[screen_name]
		var tone := "yellow" if screen_panel.visible and screen_name == current_screen else "blue"
		button.add_theme_stylebox_override(
			"normal",
			_phone_nav_style(tone) if compact_nav else _button_style(tone)
		)
		if screen_name == "Ristorante" and not screen_panel.visible:
			button.add_theme_stylebox_override(
				"normal",
				_phone_nav_style("yellow") if compact_nav else _button_style("yellow")
			)
	for screen_name: String in more_sheet_buttons:
		var sheet_button: Button = more_sheet_buttons[screen_name]
		sheet_button.add_theme_stylebox_override(
			"normal",
			_button_style(
				"yellow"
				if screen_panel.visible and screen_name == current_screen
				else "blue"
			)
		)
	if more_button != null:
		var more_selected := (
			more_sheet != null
			and more_sheet.visible
			or screen_panel.visible and current_screen in PHONE_MORE_SCREENS
		)
		more_button.add_theme_stylebox_override(
			"normal",
			_phone_nav_style("yellow" if more_selected else "blue")
			if is_phone_layout()
			else _button_style("yellow" if more_selected else "blue")
		)


func _update_world_actions() -> void:
	if world_action_panel == null:
		return
	world_action_panel.visible = current_screen == "Ristorante" and not screen_panel.visible and GameState.restaurant_state in ["closed", "open"] and (build_hud == null or not build_hud.is_open)
	world_build_button.text = "Costruisci e modifica" if GameState.restaurant_state == "closed" else "Modifica decorazioni"
	_refresh_camera_controls()


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
		GameState.set_recipe_unlocked(recipe_id, true)
	refresh_screen()


func _debug_fill_stock(amount: int) -> void:
	for ingredient_id: String in GameState.stock:
		var current_amount := int(GameState.stock[ingredient_id].get("amount", 0))
		GameState.add_stock(ingredient_id, amount - current_amount)


func _debug_print_tasks() -> void:
	print("ACTIVE TASKS: ", SimulationManager.tasks)
	show_toast("Task stampati nella console")


func _debug_reset() -> void:
	SimulationManager.close_immediately()
	SaveManager.reset_save()
	world.load_layout()
	world.spawn_staff()
	refresh_screen()
