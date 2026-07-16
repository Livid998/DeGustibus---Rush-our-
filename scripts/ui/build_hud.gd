class_name BuildHUD
extends Control

var ui: RestaurantUI
var world: RestaurantWorld
var panel: PanelContainer
var category_row: HBoxContainer
var item_row: HBoxContainer
var action_row: HBoxContainer
var current_category := "Sala"
var is_open := false
var attachment_cycle_by_support: Dictionary = {}

const CATEGORIES := ["Strutture", "Sala", "Cucina", "Esterni"]


func setup(value_ui: RestaurantUI, value_world: RestaurantWorld) -> void:
	ui = value_ui
	world = value_world
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	offset_left = 14
	offset_right = -14
	offset_top = -262
	offset_bottom = -78
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	visible = false
	world.build_system.mode_changed.connect(func(_active: bool): refresh_actions())
	world.build_system.selection_changed.connect(func(_object: PlacedObject): refresh_actions())
	world.build_system.preview_changed.connect(func(_valid: bool, _reason: String, _cost: int): refresh_actions())


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
	content.add_theme_constant_override("separation", 7)
	panel.add_child(content)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	content.add_child(header)
	var title := Label.new()
	title.text = "COSTRUZIONE"
	title.add_theme_font_override("font", GameFonts.bold())
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("24474c"))
	title.custom_minimum_size.x = 150
	header.add_child(title)
	category_row = HBoxContainer.new()
	category_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	category_row.add_theme_constant_override("separation", 6)
	header.add_child(category_row)
	for category: String in CATEGORIES:
		var category_name := category
		var button := ui.make_button(category, func(): current_category = category_name; refresh_catalog(), "ghost")
		button.custom_minimum_size = Vector2(108, 36)
		category_row.add_child(button)
	var close := ui.make_button("Chiudi", close_builder, "ghost")
	close.custom_minimum_size = Vector2(84, 36)
	header.add_child(close)
	action_row = HBoxContainer.new()
	action_row.custom_minimum_size.y = 46
	action_row.add_theme_constant_override("separation", 8)
	content.add_child(action_row)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	item_row = HBoxContainer.new()
	item_row.add_theme_constant_override("separation", 8)
	scroll.add_child(item_row)


func refresh_catalog() -> void:
	_clear(item_row)
	for definition: Dictionary in DataRegistry.build_catalog:
		if bool(definition.get("catalog_hidden", false)):
			continue
		if String(definition.category) != current_category:
			continue
		if GameState.restaurant_state == "open" and not world.build_system.can_edit_definition(definition):
			continue
		var item_id := String(definition.id)
		var button := ui.make_button("%s\n%d ●" % [definition.name, int(definition.price)], func(): world.build_system.start_place(item_id), "blue")
		button.custom_minimum_size = Vector2(146, 64)
		button.tooltip_text = "%s · ingombro %s" % [definition.name, definition.footprint]
		item_row.add_child(button)
	for index: int in category_row.get_child_count():
		var button := category_row.get_child(index) as Button
		button.disabled = GameState.restaurant_state == "open" and button.text != "Sala"
		button.add_theme_stylebox_override("normal", ui._button_style("yellow" if button.text == current_category else "ghost"))


func refresh_actions() -> void:
	if action_row == null:
		return
	_clear(action_row)
	var build := world.build_system
	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color("294b50"))
	if build.active:
		var cost := 0 if build.move_source else int(build.current_definition.get("price", 0))
		label.text = "%s  ·  %s%s" % [build.current_definition.get("name", "Oggetto"), build.reason, "  ·  %d ●" % cost if cost > 0 else ""]
		action_row.add_child(label)
		if world.is_edge_placement(build.current_definition) or String(build.current_definition.get("placement", "cell")) == "wall_mount":
			action_row.add_child(_action_button("◀ Bordo", build.rotate_preview_back, "ghost"))
			action_row.add_child(_action_button("Bordo ▶", build.rotate_preview, "yellow"))
		else:
			action_row.add_child(_action_button("Ruota 90°", build.rotate_preview, "yellow"))
		var confirm := _action_button("Conferma", build.confirm, "green")
		confirm.disabled = not build.placement_valid
		action_row.add_child(confirm)
		action_row.add_child(_action_button("Annulla", build.cancel_preview, "red"))
	elif build.selected_object and is_instance_valid(build.selected_object):
		var selected := build.selected_object
		var editable := build.can_edit_definition(selected.definition)
		label.text = "%s  ·  cella %d,%d%s" % [selected.definition.name, selected.grid_cell.x, selected.grid_cell.y, "  ·  bloccato durante il servizio" if not editable else ""]
		action_row.add_child(label)
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
			var sell_label := "Rimuovi · %d ●" % removal_cost if removal_cost > 0 else "Vendi 60%"
			action_row.add_child(_action_button(sell_label, build.sell_selected, "red"))
		action_row.add_child(_action_button("Deseleziona", build.clear_selection, "ghost"))
	else:
		label.text = "Trascina per muovere la mappa · rotella/pinch per zoom · tocca un oggetto per modificarlo"
		action_row.add_child(label)


func _action_button(text_value: String, callback: Callable, tone: String) -> Button:
	var button := ui.make_button(text_value, callback, tone)
	button.custom_minimum_size = Vector2(116, 42)
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
