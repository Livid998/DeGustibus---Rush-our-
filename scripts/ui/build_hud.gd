class_name BuildHUD
extends Control

var ui: RestaurantUI
var world: RestaurantWorld
var panel: PanelContainer
var category_row: HBoxContainer
var item_row: HBoxContainer
var action_row: HBoxContainer
var status_label: Label
var search_input: LineEdit
var filter_select: OptionButton
var result_label: Label
var page_label: Label
var previous_page_button: Button
var next_page_button: Button
var undo_button: Button
var redo_button: Button
var current_category := "Sala"
var current_page := 0
var is_open := false
var attachment_cycle_by_support: Dictionary = {}

const CATEGORIES := ["Strutture", "Sala", "Cucina", "Esterni"]
const FILTERS := ["Tutti", "A terra", "Agganci", "Strutture", "Operativi"]
const PAGE_SIZE := 6
const MIN_TOUCH_TARGET := 44.0


func setup(value_ui: RestaurantUI, value_world: RestaurantWorld) -> void:
	ui = value_ui
	world = value_world
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	offset_left = 14
	offset_right = -14
	offset_top = -560
	offset_bottom = -78
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_unhandled_key_input(true)
	_build()
	visible = false
	world.build_system.mode_changed.connect(func(_active: bool): refresh_actions())
	world.build_system.selection_changed.connect(func(_object: PlacedObject): refresh_actions())
	world.build_system.preview_changed.connect(func(_valid: bool, _reason: String, _cost: int): refresh_actions())
	world.build_system.history_changed.connect(func(_can_undo: bool, _can_redo: bool, _undo_label: String, _redo_label: String): _refresh_history_buttons())


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_open or not event is InputEventKey or not event.pressed or event.echo:
		return
	var key_event := event as InputEventKey
	if not (key_event.ctrl_pressed or key_event.meta_pressed):
		return
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		return
	if key_event.keycode == KEY_Z and not key_event.shift_pressed:
		world.build_system.undo()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == KEY_Y or (key_event.keycode == KEY_Z and key_event.shift_pressed):
		world.build_system.redo()
		get_viewport().set_input_as_handled()


func open() -> void:
	if GameState.restaurant_state == "closing":
		ui.show_toast("Attendi la chiusura prima di modificare il locale", "warning")
		return
	if GameState.restaurant_state == "open":
		current_category = "Sala"
	is_open = true
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	ui.close_screen()
	ui._update_world_actions()
	world.set_grid_visible(true)
	refresh_catalog()
	refresh_actions()


func close_builder(cancel_active: bool = true) -> void:
	if cancel_active and world.build_system.active:
		world.build_system.cancel_preview()
	world.build_system.clear_selection()
	is_open = false
	visible = false
	world.set_grid_visible(world.show_grid)
	ui._update_world_actions()


func _build() -> void:
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", ui._panel_style(Color("f6f1e9f7"), 16))
	add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	panel.add_child(content)

	var header := HBoxContainer.new()
	header.custom_minimum_size.y = MIN_TOUCH_TARGET
	header.add_theme_constant_override("separation", 6)
	content.add_child(header)
	var title := Label.new()
	title.text = "COSTRUZIONE"
	title.add_theme_font_override("font", GameFonts.bold())
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("24474c"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	undo_button = ui.make_button("Annulla", world.build_system.undo, "ghost")
	undo_button.custom_minimum_size = Vector2(82, MIN_TOUCH_TARGET)
	header.add_child(undo_button)
	redo_button = ui.make_button("Ripeti", world.build_system.redo, "ghost")
	redo_button.custom_minimum_size = Vector2(82, MIN_TOUCH_TARGET)
	header.add_child(redo_button)
	var close := ui.make_button("Chiudi", close_builder, "ghost")
	close.custom_minimum_size = Vector2(78, MIN_TOUCH_TARGET)
	header.add_child(close)

	category_row = HBoxContainer.new()
	category_row.custom_minimum_size.y = MIN_TOUCH_TARGET
	category_row.add_theme_constant_override("separation", 6)
	content.add_child(category_row)
	for category: String in CATEGORIES:
		var category_name := category
		var button := ui.make_button(category, func(): _select_category(category_name), "ghost")
		button.custom_minimum_size = Vector2(72, MIN_TOUCH_TARGET)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		category_row.add_child(button)

	var filter_row := HBoxContainer.new()
	filter_row.custom_minimum_size.y = MIN_TOUCH_TARGET
	filter_row.add_theme_constant_override("separation", 8)
	content.add_child(filter_row)
	search_input = LineEdit.new()
	search_input.name = "CatalogSearch"
	search_input.placeholder_text = "Cerca nome, supporto o funzione"
	search_input.clear_button_enabled = true
	search_input.custom_minimum_size = Vector2(180, MIN_TOUCH_TARGET)
	search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_input.add_theme_font_override("font", GameFonts.medium())
	search_input.text_changed.connect(func(_value: String): current_page = 0; refresh_catalog())
	filter_row.add_child(search_input)
	filter_select = OptionButton.new()
	filter_select.name = "CatalogFilter"
	filter_select.custom_minimum_size = Vector2(142, MIN_TOUCH_TARGET)
	filter_select.add_theme_font_override("font", GameFonts.semibold())
	for filter_name: String in FILTERS:
		filter_select.add_item(filter_name)
	filter_select.item_selected.connect(func(_index: int): current_page = 0; refresh_catalog())
	filter_row.add_child(filter_select)

	var navigation_row := HBoxContainer.new()
	navigation_row.custom_minimum_size.y = MIN_TOUCH_TARGET
	navigation_row.add_theme_constant_override("separation", 6)
	content.add_child(navigation_row)
	result_label = Label.new()
	result_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	result_label.add_theme_font_override("font", GameFonts.medium())
	result_label.add_theme_color_override("font_color", Color("45636a"))
	navigation_row.add_child(result_label)
	previous_page_button = ui.make_button("Precedenti", _previous_page, "ghost")
	previous_page_button.custom_minimum_size = Vector2(104, MIN_TOUCH_TARGET)
	navigation_row.add_child(previous_page_button)
	page_label = Label.new()
	page_label.custom_minimum_size = Vector2(62, MIN_TOUCH_TARGET)
	page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	page_label.add_theme_font_override("font", GameFonts.semibold())
	navigation_row.add_child(page_label)
	next_page_button = ui.make_button("Successivi", _next_page, "ghost")
	next_page_button.custom_minimum_size = Vector2(104, MIN_TOUCH_TARGET)
	navigation_row.add_child(next_page_button)

	status_label = Label.new()
	status_label.custom_minimum_size.y = 26
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.add_theme_font_override("font", GameFonts.semibold())
	status_label.add_theme_color_override("font_color", Color("294b50"))
	content.add_child(status_label)

	var action_scroll := ScrollContainer.new()
	action_scroll.custom_minimum_size.y = 50
	action_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	action_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(action_scroll)
	action_row = HBoxContainer.new()
	action_row.custom_minimum_size.y = 48
	action_row.add_theme_constant_override("separation", 8)
	action_scroll.add_child(action_row)

	var catalog_scroll := ScrollContainer.new()
	catalog_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	catalog_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	catalog_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(catalog_scroll)
	item_row = HBoxContainer.new()
	item_row.add_theme_constant_override("separation", 8)
	catalog_scroll.add_child(item_row)
	_refresh_history_buttons()


func _select_category(category_name: String) -> void:
	current_category = category_name
	current_page = 0
	refresh_catalog()


func refresh_catalog() -> void:
	if item_row == null:
		return
	_clear(item_row)
	var definitions := _filtered_definitions()
	var page_count := maxi(ceili(float(definitions.size()) / float(PAGE_SIZE)), 1)
	current_page = clampi(current_page, 0, page_count - 1)
	var start := current_page * PAGE_SIZE
	var end := mini(start + PAGE_SIZE, definitions.size())
	for index: int in range(start, end):
		_add_catalog_card(definitions[index])
	result_label.text = "%d elementi | anteprime renderizzate solo per questa pagina" % definitions.size()
	page_label.text = "%d / %d" % [current_page + 1, page_count]
	previous_page_button.disabled = current_page <= 0
	next_page_button.disabled = current_page >= page_count - 1
	for index: int in category_row.get_child_count():
		var button := category_row.get_child(index) as Button
		button.disabled = GameState.restaurant_state == "open" and button.text != "Sala"
		button.add_theme_stylebox_override("normal", ui._button_style("yellow" if button.text == current_category else "ghost"))


func _filtered_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var query := search_input.text.strip_edges().to_lower() if search_input != null else ""
	var filter_index := filter_select.selected if filter_select != null else 0
	for definition: Dictionary in DataRegistry.build_catalog:
		if bool(definition.get("catalog_hidden", false)) or String(definition.get("category", "")) != current_category:
			continue
		if GameState.restaurant_state == "open" and not world.build_system.can_edit_definition(definition):
			continue
		if not _definition_matches_filter(definition, filter_index):
			continue
		var haystack := "%s %s %s %s" % [definition.get("name", ""), definition.get("id", ""), definition.get("requires_support", ""), definition.get("station", "")]
		if not query.is_empty() and not query in haystack.to_lower():
			continue
		result.append(definition)
	return result


func _definition_matches_filter(definition: Dictionary, filter_index: int) -> bool:
	var placement := String(definition.get("placement", "cell"))
	var item_id := String(definition.get("id", ""))
	match filter_index:
		1:
			return placement == "cell" and not item_id.begins_with("floor_")
		2:
			return placement in ["seat", "surface", "wall_mount", "overhead"]
		3:
			return placement == "edge" or item_id.begins_with("floor_")
		4:
			return not String(definition.get("station", "")).is_empty() or not String(definition.get("support_kind", "")).is_empty()
	return true


func _add_catalog_card(definition: Dictionary) -> void:
	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(166, 160)
	card.add_theme_constant_override("separation", 2)
	item_row.add_child(card)
	var preview := ModelPreview.new()
	preview.auto_rotate = false
	preview.custom_minimum_size = Vector2(166, 66)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(preview)
	preview.call_deferred("set_build_definition", definition.duplicate(true))
	var item_id := String(definition.get("id", ""))
	var footprint: Array = definition.get("footprint", [1, 1])
	var requirement := _support_requirement(definition)
	var detail := "%dx%d | %s\n%s" % [int(footprint[0]), int(footprint[1]), requirement, _front_short(definition)]
	var button := ui.make_button(
		"%s\n%s\n%d monete" % [definition.get("name", item_id), detail, int(definition.get("price", 0))],
		func(): world.build_system.start_place(item_id),
		"blue"
	)
	button.custom_minimum_size = Vector2(166, 92)
	button.tooltip_text = "%s\nIngombro: %dx%d\n%s\nNon valido se: %s" % [
		definition.get("name", item_id), int(footprint[0]), int(footprint[1]),
		_front_description(definition), _invalidity_hint(definition),
	]
	card.add_child(button)


func _support_requirement(definition: Dictionary) -> String:
	var placement := String(definition.get("placement", "cell"))
	match placement:
		"seat": return "tavolo"
		"surface": return "piano lavoro"
		"wall_mount": return "muro"
		"overhead": return "fornello"
		"edge": return "bordo"
	if String(definition.get("id", "")).begins_with("floor_"):
		return "pavimento"
	return "a terra"


func _front_description(definition: Dictionary) -> String:
	if not String(definition.get("station", "")).is_empty():
		return "Fronte operativo: evidenziato nella preview e ruotabile"
	if String(definition.get("placement", "cell")) == "seat":
		return "Orientamento: automatico verso il tavolo"
	return "Orientamento: ruotabile di 90 gradi"


func _front_short(definition: Dictionary) -> String:
	if not String(definition.get("station", "")).is_empty():
		return "Fronte operativo ruotabile"
	if String(definition.get("placement", "cell")) == "seat":
		return "Fronte automatico"
	return "Rotazione 90 gradi"


func _invalidity_hint(definition: Dictionary) -> String:
	var placement := String(definition.get("placement", "cell"))
	if bool(definition.get("replaces_wall", false)):
		return "sul bordo non esiste un muro sostituibile"
	match placement:
		"seat": return "non trova uno slot libero rivolto verso un tavolo"
		"surface": return "il banco compatibile non ha abbastanza slot liberi"
		"wall_mount": return "il bordo non contiene un muro pieno"
		"overhead": return "il fornello non e compatibile o ha gia una cappa"
		"edge": return "il bordo e occupato o blocca un accesso necessario"
	if String(definition.get("id", "")).begins_with("floor_"):
		return "la cella e fuori dall'area costruibile"
	return "occupa celle, corsie o fronti operativi necessari"


func _previous_page() -> void:
	current_page = maxi(current_page - 1, 0)
	refresh_catalog()


func _next_page() -> void:
	current_page += 1
	refresh_catalog()


func refresh_actions() -> void:
	if action_row == null:
		return
	_clear(action_row)
	var build := world.build_system
	if build.active:
		var cost := 0 if build.move_source else int(build.current_definition.get("price", 0))
		var preview_beauty := world.beauty_preview(build.current_definition, build.preview_cell, build.move_source)
		var beauty_suffix := ""
		if float(preview_beauty.get("item_beauty", 0.0)) > 0.0:
			beauty_suffix = " | Bellezza %.0f -> %.0f (%+.1f)" % [float(preview_beauty.get("before", 0.0)), float(preview_beauty.get("after", 0.0)), float(preview_beauty.get("delta", 0.0))]
		var pin_hint := " | tocca la mappa per fissare" if not build.preview_pinned else ""
		status_label.text = "%s | %s%s%s%s" % [build.current_definition.get("name", "Oggetto"), build.reason, " | %d monete" % cost if cost > 0 else "", beauty_suffix, pin_hint]
		if world.is_edge_placement(build.current_definition) or String(build.current_definition.get("placement", "cell")) == "wall_mount":
			action_row.add_child(_action_button("Bordo precedente", build.rotate_preview_back, "ghost"))
			action_row.add_child(_action_button("Bordo successivo", build.rotate_preview, "yellow"))
		else:
			action_row.add_child(_action_button("Ruota 90 gradi", build.rotate_preview, "yellow"))
		if build.preview_pinned:
			action_row.add_child(_action_button("Riposiziona", build.unpin_preview, "ghost"))
		var confirm := _action_button("Conferma", build.confirm, "green")
		confirm.disabled = not build.placement_valid or not build.preview_pinned
		action_row.add_child(confirm)
		action_row.add_child(_action_button("Annulla", build.cancel_preview, "red"))
	elif build.selected_object and is_instance_valid(build.selected_object):
		var selected := build.selected_object
		var editable := build.can_edit_definition(selected.definition)
		var selected_beauty := float(selected.definition.get("beauty", 0.0))
		status_label.text = "%s | cella %d,%d%s%s" % [selected.definition.name, selected.grid_cell.x, selected.grid_cell.y, " | +%s bellezza" % str(snappedf(selected_beauty, 0.1)) if selected_beauty > 0.0 else "", " | bloccato durante il servizio" if not editable else ""]
		var support := world.placed_objects.get(selected.support_uid) as PlacedObject
		var attachments := world.attached_objects(selected.uid)
		if not attachments.is_empty():
			action_row.add_child(_action_button("Agganci (%d)" % attachments.size(), func(): _select_next_attachment(selected.uid, attachments), "blue"))
		elif support != null:
			action_row.add_child(_action_button("Supporto", func(): build.select_object(support), "blue"))
		if editable:
			var removal_cost := int(selected.definition.get("removal_cost", 0))
			if removal_cost <= 0:
				action_row.add_child(_action_button("Sposta", build.move_selected, "yellow"))
				action_row.add_child(_action_button("Ruota", build.rotate_selected, "yellow"))
			var sell_label := "Rimuovi | %d monete" % removal_cost if removal_cost > 0 else "Vendi al 60%"
			action_row.add_child(_action_button(sell_label, build.sell_selected, "red"))
		action_row.add_child(_action_button("Deseleziona", build.clear_selection, "ghost"))
	else:
		var ambience := world.ambience_snapshot()
		status_label.text = "Seleziona un oggetto oppure scegli dal catalogo | Ambiente %.0f | Pulizia %.0f" % [float(ambience.get("beauty_score", 0.0)), float(ambience.get("cleanliness_score", 100.0))]
	_refresh_history_buttons()


func _refresh_history_buttons() -> void:
	if undo_button == null or redo_button == null:
		return
	undo_button.disabled = not world.build_system.can_undo()
	redo_button.disabled = not world.build_system.can_redo()
	undo_button.tooltip_text = "Annulla %s" % world.build_system.undo_label() if world.build_system.can_undo() else "Nessuna modifica da annullare"
	redo_button.tooltip_text = "Ripeti %s" % world.build_system.redo_label() if world.build_system.can_redo() else "Nessuna modifica da ripetere"


func _action_button(text_value: String, callback: Callable, tone: String) -> Button:
	var button := ui.make_button(text_value, callback, tone)
	button.custom_minimum_size = Vector2(122, 48)
	return button


func _select_next_attachment(support_uid: String, attachments: Array[PlacedObject]) -> void:
	if attachments.is_empty():
		return
	var next_index := posmod(int(attachment_cycle_by_support.get(support_uid, -1)) + 1, attachments.size())
	attachment_cycle_by_support[support_uid] = next_index
	world.build_system.select_object(attachments[next_index])


func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
