class_name ManagementScreens
extends RefCounted

const OPERATIONAL_STATISTICS_SCREEN := preload(
	"res://scripts/ui/screens/operational_statistics_screen.gd"
)


static func populate(screen_name: String, content: VBoxContainer, ui: RestaurantUI) -> void:
	match screen_name:
		"Ristorante": _restaurant(content, ui)
		"Menu": _menu(content, ui)
		"Album": _album(content, ui)
		"Magazzino": _stock(content, ui)
		"Mercato": _market(content, ui)
		"Personale": _staff(content, ui)
		"Statistiche": _statistics(content, ui)
		"Impostazioni": _settings(content, ui)


static func refresh(screen_name: String, content: VBoxContainer, ui: RestaurantUI) -> void:
	if screen_name == "Personale":
		var staff := content.find_child("StaffScreen", true, false) as StaffScreen
		if staff != null:
			staff.refresh_from_state()
			return
	elif screen_name == "Statistiche":
		var reviews := content.find_child("ReviewsScreen", true, false) as ReviewsScreen
		if reviews != null:
			reviews.refresh()
		var operations := content.find_child(
			"OperationalStatisticsScreen",
			true,
			false
		)
		if operations != null:
			operations.call("refresh")
			return
	elif screen_name == "Impostazioni":
		var profile := content.find_child("ProfileScreen", true, false) as ProfileScreen
		if profile != null:
			profile.refresh()
			return
	_clear(content)
	populate(screen_name, content, ui)


static func apply_responsive_layout(content: Control, ui: RestaurantUI) -> void:
	if content == null:
		return
	var phone := ui.is_phone_layout()
	var portrait := ui.is_portrait_layout()
	for child: Node in content.find_children("*", "GridContainer", true, false):
		var grid := child as GridContainer
		match String(grid.get_meta("responsive_grid", "")):
			"album":
				grid.columns = 2 if phone else 3 if portrait else 6
			"legacy_album":
				grid.columns = 2 if portrait else 4
			"landscape_two":
				grid.columns = 1 if portrait else 2
			"menu_card":
				grid.columns = 1 if phone else 2
			"menu_controls":
				grid.columns = 1 if phone else 2
	for child: Node in content.find_children("*", "Control", true, false):
		var control := child as Control
		match String(control.get_meta("responsive_control", "")):
			"menu_card":
				control.custom_minimum_size.y = 0.0 if phone else 154.0
			"menu_icon":
				control.custom_minimum_size = Vector2(112, 104) if phone else Vector2(142, 132)
	var operations := content.find_child(
		"OperationalStatisticsScreen",
		true,
		false
	)
	if operations != null:
		operations.call("apply_responsive_layout", phone, portrait)
	var reviews := content.find_child("ReviewsScreen", true, false) as ReviewsScreen
	if reviews != null:
		reviews.apply_responsive_layout_for_width(ui.responsive_viewport_size().x)


static func update_market_countdowns(content: Control, provider: MockMarketProvider) -> void:
	if content == null or provider == null:
		return
	var offers_by_id: Dictionary = {}
	for offer: Dictionary in provider.get_offers():
		offers_by_id[String(offer.get("id", ""))] = offer
	for child: Node in content.find_children("*", "Label", true, false):
		if not child.has_meta("market_offer_id"):
			continue
		var offer: Dictionary = offers_by_id.get(
			String(child.get_meta("market_offer_id")),
			{}
		)
		if not offer.is_empty():
			(child as Label).text = _market_offer_text(offer)


static func _restaurant(content: VBoxContainer, ui: RestaurantUI) -> void:
	var state_text: String = {
		"closed":"Costruzione completa disponibile. Tocca un oggetto sulla griglia per spostarlo o venderlo.",
		"open":"Il locale lavora autonomamente. Layout operativo bloccato; menu, scorte e priorità restano modificabili.",
		"closing":"Nessun nuovo ingresso. I clienti presenti termineranno il servizio."
	}.get(GameState.restaurant_state, "")
	content.add_child(ui.make_section("Ristorante", state_text))
	if GameState.restaurant_state != "closed":
		var lock := Label.new()
		lock.text = "La sala è operativa. Chiudi il ristorante per modificare il layout."
		lock.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.add_child(lock)
		return
	var build_card := ui.make_card()
	var build_box := VBoxContainer.new()
	build_card.add_child(build_box)
	var summary := Label.new()
	summary.text = "%d elementi · %d tavoli · %d postazioni operative" % [ui.world.placed_objects.size(), ui.world.table_occupants.size(), SimulationManager.stations.size()]
	summary.add_theme_color_override("font_color", Color("52686b"))
	build_box.add_child(summary)
	var build_button := ui.make_button("Apri modalità costruzione", func(): ui.open_builder(); ui.advance_tutorial_to(0), "yellow")
	build_button.custom_minimum_size.y = 56
	build_box.add_child(build_button)
	var hint := Label.new()
	hint.text = "Nel builder puoi trascinare la mappa, selezionare gli oggetti, spostarli, ruotarli o venderli. Ogni conferma verifica ingombri e percorsi."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color("52686b"))
	build_box.add_child(hint)
	content.add_child(build_card)


static func _menu(content: VBoxContainer, ui: RestaurantUI) -> void:
	content.add_child(ui.make_section("Menu personalizzabile", "Impara le ricette con la collezione Album, poi usa le scorte fisiche per cucinarle. Puoi attivare fino a 8 piatti."))
	var active_count := DataRegistry.active_recipes(GameState.menu).size()
	var balance := Label.new()
	balance.text = "%d/8 piatti attivi · %s" % [active_count, _menu_balance_text()]
	balance.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	balance.add_theme_color_override("font_color", Color("3f8f5f") if "equilibrato" in balance.text else Color("b35d50"))
	content.add_child(balance)
	var grid := GridContainer.new()
	grid.name = "MenuGrid"
	grid.set_meta("responsive_grid", "landscape_two")
	grid.columns = 1 if ui.is_portrait_layout() else 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	content.add_child(grid)
	for recipe: Dictionary in DataRegistry.recipes:
		var state: Dictionary = GameState.menu[recipe.id]
		var card := ui.make_card()
		card.custom_minimum_size.y = 154
		card.set_meta("responsive_control", "menu_card")
		var body := GridContainer.new()
		body.name = "MenuCardLayout"
		body.set_meta("responsive_grid", "menu_card")
		body.columns = 1 if ui.is_phone_layout() else 2
		body.add_theme_constant_override("h_separation", 12)
		body.add_theme_constant_override("v_separation", 8)
		card.add_child(body)
		var dish_icon := _new_icon(GameIcons.recipe_icon(recipe), Vector2(142, 132), not bool(state.unlocked))
		dish_icon.name = "MenuDishIcon"
		dish_icon.set_meta("responsive_control", "menu_icon")
		if ui.is_phone_layout():
			dish_icon.custom_minimum_size = Vector2(112, 104)
		dish_icon.tooltip_text = String(recipe.name)
		body.add_child(dish_icon)
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_child(box)
		var top := GridContainer.new()
		top.name = "MenuCardControls"
		top.set_meta("responsive_grid", "menu_controls")
		top.columns = 1 if ui.is_phone_layout() else 2
		top.add_theme_constant_override("h_separation", 8)
		top.add_theme_constant_override("v_separation", 5)
		var toggle := CheckBox.new()
		toggle.text = String(recipe.name)
		toggle.button_pressed = bool(state.active)
		toggle.disabled = not bool(state.unlocked)
		toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var recipe_id := String(recipe.id)
		toggle.toggled.connect(func(enabled: bool):
			if enabled and DataRegistry.active_recipes(GameState.menu).size() >= 8:
				ui.show_toast("Massimo 8 piatti attivi", "warning")
				ui.refresh_screen()
				return
			GameState.set_recipe_active(recipe_id, enabled)
			ui.advance_tutorial_to(2)
		)
		if not bool(state.unlocked):
			var recipe_lock := _new_icon(GameIcons.lock_icon(), Vector2(24, 24))
			recipe_lock.tooltip_text = "Ricetta bloccata"
			top.add_child(recipe_lock)
		top.add_child(toggle)
		var price := SpinBox.new()
		price.min_value = 5
		price.max_value = 80
		price.value = float(state.price)
		price.suffix = " monete"
		price.custom_minimum_size.x = 105
		price.editable = bool(state.unlocked)
		if not price.editable:
			price.mouse_filter = Control.MOUSE_FILTER_IGNORE
			price.focus_mode = Control.FOCUS_NONE
		price.value_changed.connect(func(value: float): GameState.set_recipe_price(recipe_id, int(value)))
		top.add_child(price)
		box.add_child(top)
		if not bool(state.unlocked):
			_add_recipe_unlock_panel(box, ui, recipe)
			grid.add_child(card)
			continue
		var cost := DataRegistry.estimate_recipe_cost(recipe)
		var margin := float(state.price) - cost
		var stations := DataRegistry.required_station_ids(recipe)
		var total_time := 0.0
		for step: Dictionary in recipe.steps:
			total_time += float(step.get("time", 0.0))
		var missing := _missing_ingredients(recipe)
		var hottest := _recipe_hottest_station(recipe)
		var detail := Label.new()
		detail.text = "Costo %.1f · Margine %.1f · Popolarità %.0f%% · Tempo %.1fs\nPostazioni: %s\n%s" % [cost, margin, float(recipe.popularity) * 100.0, total_time, ", ".join(_station_names(stations)), "SCORTE FISICHE · Mancano: %s" % ", ".join(missing) if not missing.is_empty() else "SCORTE FISICHE · Disponibile · carico più alto: %s %.0f%%" % [hottest.name, hottest.load]]
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.add_theme_color_override("font_color", Color("52686b"))
		box.add_child(detail)
		var sold_out := CheckBox.new()
		sold_out.text = "Pausa manuale"
		sold_out.button_pressed = bool(state.get("manual_paused", state.get("sold_out", false)))
		sold_out.toggled.connect(func(value: bool): GameState.set_recipe_manual_paused(recipe_id, value))
		box.add_child(sold_out)
		if bool(state.get("auto_sold_out", false)):
			var automatic := Label.new()
			automatic.text = "ESAURITA AUTOMATICAMENTE · tornerà disponibile all'arrivo delle scorte"
			automatic.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			automatic.add_theme_color_override("font_color", Color("b94e48"))
			box.add_child(automatic)
		grid.add_child(card)


static func _add_recipe_unlock_panel(box: VBoxContainer, ui: RestaurantUI, recipe: Dictionary) -> void:
	var heading := Label.new()
	heading.text = "COSTO ALBUM"
	heading.add_theme_font_override("font", GameFonts.bold())
	heading.add_theme_color_override("font_color", Color("8f6423"))
	box.add_child(heading)
	var costs := HFlowContainer.new()
	costs.add_theme_constant_override("h_separation", 8)
	costs.add_theme_constant_override("v_separation", 5)
	box.add_child(costs)
	for ingredient_id: String in recipe.get("unlock_cost", {}):
		var ingredient: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
		var required := int(recipe.unlock_cost[ingredient_id])
		var owned := int(GameState.album_inventory.get(ingredient_id, 0))
		var chip := PanelContainer.new()
		var chip_style := StyleBoxFlat.new()
		chip_style.bg_color = Color("edf7f2") if owned >= required else Color("fff0e8")
		chip_style.border_color = Color("8bc8ae") if owned >= required else Color("df8f78")
		chip_style.set_border_width_all(1)
		chip_style.set_corner_radius_all(7)
		chip_style.content_margin_left = 5
		chip_style.content_margin_right = 7
		chip_style.content_margin_top = 3
		chip_style.content_margin_bottom = 3
		chip.add_theme_stylebox_override("panel", chip_style)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		chip.add_child(row)
		var ingredient_icon := _new_icon(GameIcons.ingredient_icon(ingredient), Vector2(30, 30), not bool(GameState.album_discovered.get(ingredient_id, false)))
		ingredient_icon.tooltip_text = String(ingredient.get("name", ingredient_id))
		row.add_child(ingredient_icon)
		var count := Label.new()
		count.text = "%s  %d/%d" % [String(ingredient.get("name", ingredient_id)), owned, required]
		count.add_theme_font_override("font", GameFonts.semibold())
		count.add_theme_color_override("font_color", Color("30705a") if owned >= required else Color("a84f43"))
		row.add_child(count)
		costs.add_child(chip)
	var recipe_id := String(recipe.id)
	var learn := ui.make_button("Impara ricetta", func():
		if not CollectionManager.unlock_recipe(recipe_id):
			ui.show_toast(_recipe_unlock_missing_text(recipe), "warning")
	, "green" if _can_unlock_recipe(recipe) else "yellow")
	learn.icon = GameIcons.lock_icon()
	learn.expand_icon = true
	learn.add_theme_constant_override("icon_max_width", 24)
	learn.custom_minimum_size.y = 42
	box.add_child(learn)


static func _can_unlock_recipe(recipe: Dictionary) -> bool:
	for ingredient_id: String in recipe.get("unlock_cost", {}):
		if int(GameState.album_inventory.get(ingredient_id, 0)) < int(recipe.unlock_cost[ingredient_id]):
			return false
	return not recipe.get("unlock_cost", {}).is_empty()


static func _recipe_unlock_missing_text(recipe: Dictionary) -> String:
	var missing: Array[String] = []
	for ingredient_id: String in recipe.get("unlock_cost", {}):
		var required := int(recipe.unlock_cost[ingredient_id])
		var owned := int(GameState.album_inventory.get(ingredient_id, 0))
		if owned < required:
			var ingredient_name := String(DataRegistry.ingredients_by_id.get(ingredient_id, {"name": ingredient_id}).name)
			missing.append("%s %d/%d" % [ingredient_name, owned, required])
	return "Mancano: %s" % ", ".join(missing) if not missing.is_empty() else "La ricetta non può essere imparata"


static func _stock(content: VBoxContainer, ui: RestaurantUI) -> void:
	StorageManager.recalculate_layout_capacity()
	var unlocked_count := 0
	var low_count := 0
	for ingredient: Dictionary in DataRegistry.ingredients:
		var state: Dictionary = GameState.stock[ingredient.id]
		if bool(state.unlocked):
			unlocked_count += 1
			if StorageManager.available_amount(String(ingredient.id)) <= int(state.threshold):
				low_count += 1
	var normal_batch := EconomyManager.normal_batch_snapshot()
	var urgent_batch := EconomyManager.urgent_batch_snapshot()
	var normal_count := _delivery_item_count(normal_batch.get("items", {}))
	var urgent_count := _delivery_item_count(urgent_batch.get("items", {}))
	content.add_child(ui.make_section(
		"Magazzino operativo",
		"%d ingredienti fisici · %d sotto soglia · prossimo batch tra %s · %d normali + %d urgenti" % [
			unlocked_count,
			low_count,
			_format_countdown(float(normal_batch.get("remaining", 0.0))),
			normal_count,
			urgent_count
		]
	))

	var capacity_card := ui.make_card()
	var capacity_box := VBoxContainer.new()
	capacity_box.add_theme_constant_override("separation", 9)
	capacity_card.add_child(capacity_box)
	var capacity_title := Label.new()
	capacity_title.text = "CAPACITÀ DAL LAYOUT"
	capacity_title.add_theme_font_override("font", GameFonts.bold())
	capacity_title.add_theme_font_size_override("font_size", 19)
	capacity_box.add_child(capacity_title)
	var capacity_row := HBoxContainer.new()
	capacity_row.add_theme_constant_override("separation", 14)
	capacity_box.add_child(capacity_row)
	for storage_type: String in ["ambient", "refrigerated"]:
		var capacity_group := HBoxContainer.new()
		capacity_group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var capacity_icon := _new_icon(GameIcons.casual_system_icon("storage_%s" % storage_type), Vector2(48, 48))
		capacity_icon.tooltip_text = _storage_type_name(storage_type)
		capacity_group.add_child(capacity_icon)
		var capacity_label := Label.new()
		capacity_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var used := StorageManager.used_for(storage_type)
		var capacity := StorageManager.capacity_for(storage_type)
		var overflow_text := "\nSOVRACCARICO: nuovi acquisti bloccati" if StorageManager.is_overflowing(storage_type) else ""
		capacity_label.text = "%s\n%d / %d unità%s" % [_storage_type_name(storage_type), used, capacity, overflow_text]
		capacity_label.add_theme_font_override("font", GameFonts.semibold())
		capacity_label.add_theme_color_override("font_color", Color("b94e48") if StorageManager.is_overflowing(storage_type) else Color("35685d"))
		capacity_group.add_child(capacity_label)
		capacity_row.add_child(capacity_group)
	content.add_child(capacity_card)

	var integrity := StorageManager.soft_lock_snapshot()
	if bool(integrity.get("soft_locked", false)):
		var recovery_card := ui.make_card()
		var recovery_box := VBoxContainer.new()
		recovery_box.add_theme_constant_override("separation", 8)
		recovery_card.add_child(recovery_box)
		var recovery_title := Label.new()
		recovery_title.text = "RECUPERO PARTITA NECESSARIO"
		recovery_title.add_theme_font_override("font", GameFonts.bold())
		recovery_title.add_theme_color_override("font_color", Color("b94e48"))
		recovery_box.add_child(recovery_title)
		var recovery_plan: Dictionary = integrity.get("recovery_plan", {})
		var recipe_name := String(DataRegistry.recipes_by_id.get(String(recovery_plan.get("recipe_id", "")), {"name":"una ricetta sbloccata"}).name)
		var recovery_text := Label.new()
		recovery_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		recovery_text.text = "Nessuna ricetta attiva può essere prodotta o rifornita. Il recupero annulla le consegne eccedenti, libera il minimo stock necessario e garantisce una porzione di %s." % recipe_name
		recovery_box.add_child(recovery_text)
		var recovery_button := ui.make_button("Mostra e applica recupero", func(): _confirm_storage_recovery(ui, recovery_plan), "red")
		recovery_button.disabled = not bool(recovery_plan.get("eligible", false))
		recovery_box.add_child(recovery_button)
		content.add_child(recovery_card)

	var cart_card := ui.make_card()
	var cart_box := VBoxContainer.new()
	cart_box.add_theme_constant_override("separation", 8)
	cart_card.add_child(cart_box)
	var cart_header := HBoxContainer.new()
	var delivery_icon := _new_icon(GameIcons.casual_system_icon("delivery_truck"), Vector2(44, 44))
	delivery_icon.tooltip_text = "Prossima consegna"
	cart_header.add_child(delivery_icon)
	var cart_title := Label.new()
	cart_title.text = "CARRELLO PROSSIMO BATCH"
	cart_title.add_theme_font_override("font", GameFonts.bold())
	cart_title.add_theme_font_size_override("font_size", 19)
	cart_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cart_header.add_child(cart_title)
	cart_box.add_child(cart_header)
	var cart_items := EconomyManager.delivery_cart_snapshot()
	var normal_preview := EconomyManager.delivery_preview(cart_items, false)
	var urgent_preview := EconomyManager.delivery_preview(cart_items, true)
	var cart_description := Label.new()
	cart_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if cart_items.is_empty():
		cart_description.text = "Carrello vuoto. Aggiungi lotti dalle schede qui sotto."
	else:
		var item_names: Array[String] = []
		for ingredient_id: String in cart_items:
			var ingredient_name := String(DataRegistry.ingredients_by_id.get(ingredient_id, {"name": ingredient_id}).name)
			item_names.append("%s x%d" % [ingredient_name, int(cart_items[ingredient_id])])
		var forecast: Dictionary = normal_preview.forecast
		var accepted_text := _format_delivery_items(normal_preview.get("accepted_items", {}))
		var rejected_text := _format_delivery_items(normal_preview.get("rejected_items", {}))
		cart_description.text = "%s\nAccettato: %s%s\nCosto normale %d monete · previsto Ambiente %d/%d · Refrigerato %d/%d" % [
			", ".join(item_names),
			accepted_text if not accepted_text.is_empty() else "nessun articolo",
			" · resta nel carrello: %s" % rejected_text if not rejected_text.is_empty() else "",
			int(normal_preview.cost),
			int(forecast.get("ambient", 0)),
			StorageManager.capacity_for("ambient"),
			int(forecast.get("refrigerated", 0)),
			StorageManager.capacity_for("refrigerated")
		]
	cart_description.add_theme_color_override("font_color", Color("52686b"))
	cart_box.add_child(cart_description)
	var cart_controls := HBoxContainer.new()
	var confirm_normal := ui.make_button("Conferma nel batch", func():
		if EconomyManager.confirm_delivery_cart(false):
			ui.show_toast("Carrello aggiunto alla prossima consegna", "income")
		ui.refresh_screen()
	, "green")
	confirm_normal.icon = GameIcons.casual_system_icon("delivery_truck")
	confirm_normal.disabled = cart_items.is_empty() or not bool(normal_preview.valid)
	confirm_normal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cart_controls.add_child(confirm_normal)
	var confirm_urgent := ui.make_button("Urgente · %d monete" % int(urgent_preview.cost), func():
		if EconomyManager.confirm_delivery_cart(true):
			ui.show_toast("Consegna urgente confermata", "income")
		ui.refresh_screen()
	, "red")
	confirm_urgent.icon = GameIcons.casual_system_icon("delivery_truck")
	confirm_urgent.disabled = cart_items.is_empty() or not bool(urgent_preview.valid)
	confirm_urgent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cart_controls.add_child(confirm_urgent)
	var clear_cart := ui.make_button("Svuota", func():
		EconomyManager.clear_delivery_cart()
		ui.refresh_screen()
	, "ghost")
	clear_cart.disabled = cart_items.is_empty()
	cart_controls.add_child(clear_cart)
	cart_box.add_child(cart_controls)
	if normal_count > 0 or urgent_count > 0:
		var cancel_controls := HBoxContainer.new()
		if normal_count > 0:
			cancel_controls.add_child(ui.make_button("Annulla batch · rimborso 80%", func(): _confirm_cancel_delivery(ui, "normal"), "ghost"))
		if urgent_count > 0:
			cancel_controls.add_child(ui.make_button("Annulla urgente · rimborso 80%", func(): _confirm_cancel_delivery(ui, "urgent"), "ghost"))
		cart_box.add_child(cancel_controls)
	content.add_child(cart_card)

	var grid := GridContainer.new()
	grid.name = "WarehouseGrid"
	grid.set_meta("responsive_grid", "landscape_two")
	grid.columns = 1 if ui.is_portrait_layout() else 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	content.add_child(grid)
	for ingredient: Dictionary in DataRegistry.ingredients:
		var entry: Dictionary = GameState.stock[ingredient.id]
		if not bool(entry.unlocked):
			continue
		var ingredient_id := String(ingredient.id)
		var card := ui.make_card()
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 7)
		card.add_child(box)
		var heading := HBoxContainer.new()
		var metadata := StorageManager.storage_metadata(ingredient_id)
		var storage_type := String(metadata.storage_type)
		heading.add_child(_warehouse_ingredient_icon(ingredient, storage_type))
		var name := Label.new()
		name.text = String(ingredient.name)
		name.add_theme_font_override("font", GameFonts.semibold())
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name.add_theme_font_size_override("font_size", 18)
		heading.add_child(name)
		var amount := Label.new()
		amount.text = "x%d" % int(entry.amount)
		amount.add_theme_font_override("font", GameFonts.bold())
		amount.add_theme_font_size_override("font_size", 20)
		amount.add_theme_color_override("font_color", Color("c95360") if StorageManager.available_amount(ingredient_id) <= int(entry.threshold) else Color("1d8065"))
		heading.add_child(amount)
		box.add_child(heading)
		var progress := ProgressBar.new()
		progress.min_value = 0
		progress.max_value = maxi(int(entry.target), 1)
		progress.value = int(entry.amount)
		progress.show_percentage = false
		progress.custom_minimum_size.y = 12
		box.add_child(progress)
		var stock_meta := Label.new()
		var reserved := StorageManager.reserved_amount(ingredient_id)
		var available := StorageManager.available_amount(ingredient_id)
		stock_meta.text = "Disponibili %d · Riservati %d · Totale fisico %d\n%s · %d/%d unità · lotto %d" % [
			available,
			reserved,
			int(entry.amount),
			_storage_type_name(storage_type),
			StorageManager.used_for(storage_type),
			StorageManager.capacity_for(storage_type),
			int(entry.lot)
		]
		stock_meta.add_theme_color_override("font_color", Color("60767a"))
		stock_meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(stock_meta)
		var incoming := StorageManager.pending_delivery_summary(ingredient_id)
		var incoming_label := Label.new()
		if int(incoming.amount) > 0:
			incoming_label.text = "Prossima consegna: +%d tra %s%s" % [
				int(incoming.amount),
				_format_countdown(float(incoming.remaining)),
				" · urgente" if String(incoming.kind) == "urgent" else ""
			]
		else:
			incoming_label.text = "Prossima consegna: nessuna quantità prenotata"
		incoming_label.add_theme_color_override("font_color", Color("4a7277"))
		box.add_child(incoming_label)
		var linked_sold_out := _linked_auto_sold_out_recipes(ingredient_id)
		var sold_out_label := Label.new()
		sold_out_label.text = "Esaurimento automatico: %s" % (", ".join(linked_sold_out) if not linked_sold_out.is_empty() else "nessuna ricetta collegata")
		sold_out_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sold_out_label.add_theme_color_override("font_color", Color("b94e48") if not linked_sold_out.is_empty() else Color("60767a"))
		box.add_child(sold_out_label)
		var controls := HBoxContainer.new()
		var auto := CheckBox.new()
		auto.text = "Riordino auto"
		auto.button_pressed = bool(entry.auto_reorder)
		auto.toggled.connect(func(value: bool):
			StorageManager.set_auto_reorder(ingredient_id, value)
			if ingredient_id == "tomato" and value:
				ui.advance_tutorial_to(3)
		)
		controls.add_child(auto)
		var threshold := SpinBox.new()
		threshold.min_value = 0
		threshold.max_value = 100
		threshold.value = int(entry.threshold)
		threshold.prefix = "Soglia "
		threshold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		threshold.value_changed.connect(func(value: float): StorageManager.set_reorder_threshold(ingredient_id, int(value)))
		controls.add_child(threshold)
		var target := SpinBox.new()
		target.min_value = 1
		target.max_value = 150
		target.value = int(entry.target)
		target.prefix = "Target "
		target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		target.value_changed.connect(func(value: float): StorageManager.set_stock_target(ingredient_id, int(value)))
		controls.add_child(target)
		box.add_child(controls)
		var purchase := HBoxContainer.new()
		var lot := SpinBox.new()
		lot.min_value = 1
		lot.max_value = 100
		lot.value = int(entry.lot)
		lot.prefix = "Lotto "
		lot.custom_minimum_size.x = 115
		lot.value_changed.connect(func(value: float): StorageManager.set_lot_size(ingredient_id, int(value)))
		purchase.add_child(lot)
		var remove_cart := ui.make_button("- Lotto", func():
			EconomyManager.remove_from_delivery_cart(ingredient_id, int(GameState.stock[ingredient_id].lot))
			ui.refresh_screen()
		, "ghost")
		remove_cart.custom_minimum_size = Vector2(92, 42)
		purchase.add_child(remove_cart)
		var add_cart := ui.make_button("+ Lotto", func():
			EconomyManager.add_to_delivery_cart(ingredient_id, int(GameState.stock[ingredient_id].lot))
			ui.refresh_screen()
		, "yellow")
		add_cart.custom_minimum_size = Vector2(92, 42)
		purchase.add_child(add_cart)
		box.add_child(purchase)
		var stock_actions := HBoxContainer.new()
		var orderable := Label.new()
		orderable.text = "Ordinabili ora: max %d" % StorageManager.max_orderable_amount(ingredient_id, EconomyManager.delivery_cart_snapshot())
		orderable.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		orderable.add_theme_color_override("font_color", Color("60767a"))
		stock_actions.add_child(orderable)
		var dispose_amount := SpinBox.new()
		dispose_amount.min_value = 1
		dispose_amount.max_value = maxi(available, 1)
		dispose_amount.value = mini(maxi(int(entry.lot), 1), maxi(available, 1))
		dispose_amount.prefix = "Quantità "
		dispose_amount.custom_minimum_size.x = 130
		dispose_amount.editable = available > 0
		stock_actions.add_child(dispose_amount)
		var dispose_button := ui.make_button("Smaltisci · recupera 20%", func():
			var summary := EconomyManager.discard_stock(ingredient_id, int(dispose_amount.value))
			if bool(summary.get("success", false)):
				ui.show_toast("Stock smaltito · +%d monete" % int(summary.get("refund", 0)), "income")
			else:
				ui.show_toast("Quantità non disponibile: lo stock riservato non può essere smaltito", "warning")
			ui.refresh_screen()
		, "red")
		dispose_button.disabled = available <= 0
		stock_actions.add_child(dispose_button)
		box.add_child(stock_actions)
		grid.add_child(card)


static func _album(content: VBoxContainer, ui: RestaurantUI) -> void:
	var discovered_count := 0
	for ingredient: Dictionary in DataRegistry.ingredients:
		var ingredient_id := String(ingredient.id)
		if bool(GameState.album_discovered.get(ingredient_id, false)) or int(GameState.album_inventory.get(ingredient_id, 0)) > 0:
			discovered_count += 1
	var banner := PanelContainer.new()
	var banner_style := StyleBoxFlat.new()
	banner_style.bg_color = Color("d98224")
	banner_style.set_corner_radius_all(12)
	banner_style.content_margin_left = 18
	banner_style.content_margin_right = 18
	banner_style.content_margin_top = 10
	banner_style.content_margin_bottom = 10
	banner.add_theme_stylebox_override("panel", banner_style)
	var banner_row := HBoxContainer.new()
	banner.add_child(banner_row)
	var title := Label.new()
	title.text = "I TUOI INGREDIENTI"
	title.add_theme_font_override("font", GameFonts.bold())
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color.WHITE)
	banner_row.add_child(title)
	var progress := Label.new()
	progress.text = "%d / %d" % [discovered_count, DataRegistry.ingredients.size()]
	progress.add_theme_font_override("font", GameFonts.bold())
	progress.add_theme_font_size_override("font_size", 20)
	progress.add_theme_color_override("font_color", Color.WHITE)
	banner_row.add_child(progress)
	content.add_child(banner)
	var hint := Label.new()
	hint.text = "Collezione permanente separata dal magazzino · le stelle indicano la rarità · spendi questi ingredienti soltanto per imparare ricette."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color("52686b"))
	content.add_child(hint)
	var reward_card := ui.make_card()
	var reward_box := VBoxContainer.new()
	reward_card.add_child(reward_box)
	var review_target := maxi(int(DataRegistry.balance_value("album.positive_reviews_per_reward", 5)), 1)
	var reward_label := Label.new()
	reward_label.text = "PROSSIMO PREMIO RECENSIONI · %d/%d recensioni positive" % [int(GameState.review_reward_progress), review_target]
	reward_label.add_theme_font_override("font", GameFonts.semibold())
	reward_box.add_child(reward_label)
	var reward_progress := ProgressBar.new()
	reward_progress.max_value = review_target
	reward_progress.value = mini(int(GameState.review_reward_progress), review_target)
	reward_progress.show_percentage = false
	reward_progress.custom_minimum_size.y = 12
	reward_box.add_child(reward_progress)
	var detail_card := ui.make_card()
	var detail_box := VBoxContainer.new()
	detail_box.add_theme_constant_override("separation", 8)
	detail_card.add_child(detail_box)
	var detail_label := Label.new()
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.add_theme_color_override("font_color", Color("405f65"))
	detail_box.add_child(detail_label)
	var unlock_button: Button
	unlock_button = ui.make_button("Sblocca ingrediente", func():
		var ingredient_id := String(unlock_button.get_meta("ingredient_id", ""))
		if ingredient_id.is_empty():
			return
		if GameState.purchase_ingredient_unlock(ingredient_id):
			ui.refresh_screen()
		else:
			ui.show_toast("Sblocco non disponibile: controlla fondi e requisito.", "warning")
	, "yellow")
	unlock_button.visible = false
	detail_box.add_child(unlock_button)
	content.add_child(detail_card)
	var grid := GridContainer.new()
	grid.name = "AlbumGrid"
	grid.set_meta("responsive_grid", "album")
	grid.columns = 2 if ui.is_phone_layout() else 3 if ui.is_portrait_layout() else 6
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 12)
	content.add_child(grid)
	for ingredient: Dictionary in DataRegistry.ingredients:
		var ingredient_id := String(ingredient.id)
		var amount := int(GameState.album_inventory.get(ingredient_id, 0))
		var discovered := bool(GameState.album_discovered.get(ingredient_id, false)) or amount > 0
		var known := discovered or String(DataRegistry.ingredient_unlock_rule(ingredient).get("type", "")) == "album_purchase"
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(155, 160)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var card_style := StyleBoxFlat.new()
		card_style.bg_color = Color("fffdf7")
		card_style.border_color = Color("a9cad5") if known else Color("c8c3b8")
		card_style.set_border_width_all(2)
		card_style.set_corner_radius_all(9)
		card_style.content_margin_left = 7
		card_style.content_margin_right = 7
		card_style.content_margin_top = 7
		card_style.content_margin_bottom = 7
		card.add_theme_stylebox_override("panel", card_style)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		card.add_child(box)
		var name := Label.new()
		name.text = String(ingredient.name) if known else "???"
		name.add_theme_font_override("font", GameFonts.semibold())
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name.add_theme_font_size_override("font_size", 15)
		name.add_theme_color_override("font_color", Color("607f88"))
		box.add_child(name)
		var visual := Control.new()
		visual.custom_minimum_size = Vector2(138, 98)
		visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(visual)
		visual.clip_contents = true
		var ingredient_icon := _new_icon(GameIcons.ingredient_icon(ingredient), Vector2(138, 98))
		ingredient_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ingredient_icon.tooltip_text = String(ingredient.name) if known else "Ingrediente da scoprire"
		if not known:
			ingredient_icon.modulate = Color(0.10, 0.14, 0.15, 0.62)
		visual.add_child(ingredient_icon)
		var inspect_button := Button.new()
		inspect_button.flat = true
		inspect_button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		inspect_button.tooltip_text = "Dettagli %s" % (ingredient.name if known else "ingrediente da scoprire")
		var ingredient_ref := ingredient
		inspect_button.pressed.connect(func(): _configure_album_detail(detail_label, unlock_button, ingredient_ref, ui))
		visual.add_child(inspect_button)
		var quantity := Label.new()
		quantity.add_theme_font_override("font", GameFonts.bold())
		quantity.anchor_left = 1
		quantity.anchor_right = 1
		quantity.offset_left = -48
		quantity.offset_right = -4
		quantity.offset_top = 4
		quantity.offset_bottom = 30
		quantity.text = "x%d" % amount
		quantity.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		quantity.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		quantity.add_theme_color_override("font_color", Color("31535a"))
		quantity.add_theme_stylebox_override("normal", ui._panel_style(Color("eff8f5ee"), 5))
		quantity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		visual.add_child(quantity)
		var rarity := int(ingredient.get("rarity", 1))
		var stars := _new_icon(GameIcons.rarity_icon(rarity), Vector2(132, 24))
		stars.tooltip_text = "Rarità %d/5" % rarity
		box.add_child(stars)
		grid.add_child(card)
	if not DataRegistry.ingredients.is_empty():
		var first: Dictionary = DataRegistry.ingredients[0]
		for ingredient: Dictionary in DataRegistry.ingredients:
			if bool(GameState.album_discovered.get(String(ingredient.id), false)):
				first = ingredient
				break
		_configure_album_detail(detail_label, unlock_button, first, ui)


static func _configure_album_detail(detail_label: Label, unlock_button: Button, ingredient: Dictionary, ui: RestaurantUI) -> void:
	var ingredient_id := String(ingredient.get("id", ""))
	var amount := int(GameState.album_inventory.get(ingredient_id, 0))
	var discovered := bool(GameState.album_discovered.get(ingredient_id, false)) or amount > 0
	var rule := DataRegistry.ingredient_unlock_rule(ingredient)
	var purchase_unlock := String(rule.get("type", "")) == "album_purchase"
	detail_label.text = "%s\nSblocco magazzino: %s" % [_album_detail_text(ingredient, amount, discovered or purchase_unlock), _ingredient_unlock_progress_text(ingredient_id)]
	unlock_button.visible = purchase_unlock and not bool(GameState.stock.get(ingredient_id, {}).get("unlocked", false))
	unlock_button.disabled = not GameState.can_afford(int(rule.get("cost", 0)))
	unlock_button.set_meta("ingredient_id", ingredient_id)
	if unlock_button.visible:
		ui.set_button_content(unlock_button, "Sblocca nel magazzino · %d monete" % int(rule.get("cost", 0)))


static func _ingredient_unlock_progress_text(ingredient_id: String) -> String:
	var status := GameState.ingredient_unlock_status(ingredient_id)
	if bool(status.get("unlocked", false)):
		return "disponibile"
	var rule: Dictionary = status.get("rule", {})
	var current := float(status.get("current", 0.0))
	var target := float(status.get("target", 0.0))
	match String(rule.get("type", "")):
		"album_purchase":
			return "acquisto Album · %d monete · fondi %d/%d" % [int(target), int(current), int(target)]
		"customers_served":
			return "clienti serviti · %d/%d" % [int(current), int(target)]
		"desserts_served":
			return "dessert serviti · %d/%d" % [int(current), int(target)]
		"services_started":
			return "servizi avviati · %d/%d" % [int(current), int(target)]
		"reputation":
			return "reputazione · %.1f/%.1f" % [current, target]
		"build_count":
			var item_id := String(rule.get("item", ""))
			var item_name := String(DataRegistry.build_by_id.get(item_id, {}).get("name", item_id))
			return "%s costruite · %d/%d" % [item_name, int(current), int(target)]
	return "sbloccato inizialmente"


static func _legacy_album(content: VBoxContainer, ui: RestaurantUI) -> void:
	var unlocked := 0
	for entry: Dictionary in GameState.stock.values():
		if bool(entry.unlocked):
			unlocked += 1
	content.add_child(ui.make_section("Album ingredienti", "Collezione permanente %d/%d · lo sblocco non viene perso quando le scorte finiscono." % [unlocked, DataRegistry.ingredients.size()]))
	var body: BoxContainer
	if ui.is_portrait_layout():
		body = VBoxContainer.new()
	else:
		body = HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	content.add_child(body)
	var grid := GridContainer.new()
	grid.name = "LegacyAlbumGrid"
	grid.set_meta("responsive_grid", "legacy_album")
	grid.columns = 2 if ui.is_portrait_layout() else 4
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	body.add_child(grid)
	var detail_card := ui.make_card()
	detail_card.custom_minimum_size.x = 310
	var detail_box := VBoxContainer.new()
	detail_card.add_child(detail_box)
	var preview := ModelPreview.new()
	preview.custom_minimum_size = Vector2(280, 210)
	detail_box.add_child(preview)
	var detail_title := Label.new()
	detail_title.add_theme_font_override("font", GameFonts.bold())
	detail_title.add_theme_font_size_override("font_size", 21)
	detail_box.add_child(detail_title)
	var detail_text := Label.new()
	detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_text.add_theme_color_override("font_color", Color("52686b"))
	detail_box.add_child(detail_text)
	var unlock_button: Button
	unlock_button = ui.make_button("Sblocca", func():
		var ingredient_id := String(unlock_button.get_meta("ingredient_id", ""))
		var cost := int(unlock_button.get_meta("unlock_cost", 0))
		if not ingredient_id.is_empty() and cost > 0 and GameState.spend(cost, "Sblocco album"):
			GameState.unlock_ingredient(ingredient_id, "Acquisto album")
			ui.refresh_screen(), "yellow")
	unlock_button.visible = false
	detail_box.add_child(unlock_button)
	body.add_child(detail_card)
	for ingredient: Dictionary in DataRegistry.ingredients:
		var ingredient_id := String(ingredient.id)
		var entry: Dictionary = GameState.stock[ingredient_id]
		var is_unlocked := bool(entry.unlocked)
		var card_text := "%s\n%s" % [ingredient.name if is_unlocked else "Ingrediente misterioso", "%s · stock %d" % [ingredient.category, int(entry.amount)] if is_unlocked else String(ingredient.get("unlock", "Da scoprire"))]
		var select := ui.make_button(card_text, func():
			var selected: Dictionary = DataRegistry.ingredients_by_id[ingredient_id]
			var state: Dictionary = GameState.stock[ingredient_id]
			var available := bool(state.unlocked)
			preview.set_model(String(selected.model) if available else "")
			detail_title.text = String(selected.name) if available else "Ingrediente bloccato"
			detail_text.text = "%s\n%s\nRicette compatibili: %d" % [selected.category, selected.get("unlock", "Sbloccato inizialmente"), _compatible_recipe_count(ingredient_id)]
			var cost := int(selected.get("unlock_cost", 0))
			unlock_button.visible = not available and cost > 0
			ui.set_button_content(unlock_button, "Sblocca una tantum · %d [coin]" % cost)
			unlock_button.set_meta("ingredient_id", ingredient_id)
			unlock_button.set_meta("unlock_cost", cost), "green" if is_unlocked else "ghost")
		select.custom_minimum_size = Vector2(170, 82)
		grid.add_child(select)
	var first: Dictionary = DataRegistry.ingredients[0]
	preview.set_model.call_deferred(String(first.model))
	detail_title.text = String(first.name)
	detail_text.text = "%s\nSbloccato inizialmente\nRicette compatibili: %d" % [first.category, _compatible_recipe_count(String(first.id))]


static func _compatible_recipe_count(ingredient_id: String) -> int:
	var count := 0
	for recipe: Dictionary in DataRegistry.recipes:
		var found := false
		for step: Dictionary in recipe.steps:
			if step.get("inputs", {}).has(ingredient_id):
				found = true
				break
		if found:
			count += 1
	return count


static func _album_detail_text(ingredient: Dictionary, amount_or_entry: Variant = 0, discovered_override: Variant = null) -> String:
	var amount := 0
	var discovered := false
	if amount_or_entry is Dictionary:
		# Compatibility for the unused legacy builder below; the live Album never
		# passes a stock entry and reads only album_inventory/album_discovered.
		amount = int(amount_or_entry.get("amount", 0))
		discovered = bool(amount_or_entry.get("unlocked", false))
	else:
		amount = int(amount_or_entry)
		discovered = amount > 0 if discovered_override == null else bool(discovered_override)
	var rarity := int(ingredient.get("rarity", 1))
	var recipes: Array[String] = []
	for recipe: Dictionary in DataRegistry.recipes:
		if recipe.get("unlock_cost", {}).has(ingredient.id):
			recipes.append(String(recipe.name))
	var display_name := String(ingredient.name) if discovered else "INGREDIENTE DA SCOPRIRE"
	return "%s · %s · Album x%d · rarità %d/5\nServe per imparare: %s\nFonti principali: %s" % [
		display_name,
		String(ingredient.category),
		amount,
		rarity,
		", ".join(recipes) if not recipes.is_empty() else "nessuna ricetta attuale",
		CollectionManager.reward_sources_text(String(ingredient.id)),
	]


static func _missing_ingredients(recipe: Dictionary) -> Array[String]:
	var required := DataRegistry.recipe_raw_requirements(recipe)
	var missing: Array[String] = []
	for ingredient_id: String in required:
		var entry: Dictionary = GameState.stock.get(ingredient_id, {})
		if not bool(entry.get("unlocked", false)) or StorageManager.available_amount(ingredient_id) < int(required[ingredient_id]):
			missing.append(String(DataRegistry.ingredients_by_id.get(ingredient_id, {"name": ingredient_id}).name))
	return missing


static func _recipe_hottest_station(recipe: Dictionary) -> Dictionary:
	var result := {"name": "N/D", "load": 0.0}
	for station_id: String in DataRegistry.required_station_ids(recipe):
		var load := SimulationManager.predicted_station_load(station_id)
		if load > float(result.load):
			result.load = load
			result.name = String(DataRegistry.stations_by_id.get(station_id, {"name": station_id}).name)
	return result


static func _legacy_stock(content: VBoxContainer, ui: RestaurantUI) -> void:
	content.add_child(ui.make_section("Album ingredienti", "Lo sblocco è permanente; lo stock è consumabile. Tocca il nome per ruotare il modello reale."))
	var preview := ModelPreview.new()
	preview.visible = not ui.is_portrait_layout()
	content.add_child(preview)
	var first_path := ""
	for ingredient: Dictionary in DataRegistry.ingredients:
		var entry: Dictionary = GameState.stock[ingredient.id]
		if first_path.is_empty() and bool(entry.unlocked):
			first_path = ingredient.model
		var card := ui.make_card()
		var box := VBoxContainer.new()
		card.add_child(box)
		var top := HBoxContainer.new()
		var ingredient_path := String(ingredient.model)
		var select := ui.make_button(("[lock] " if not entry.unlocked else "") + ingredient.name, func(): preview.set_model(ingredient_path), "yellow" if not entry.unlocked else "blue")
		select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top.add_child(select)
		var amount := Label.new()
		amount.text = "Stock %d" % int(entry.amount)
		amount.custom_minimum_size.x = 92
		amount.add_theme_color_override("font_color", Color("304e52"))
		top.add_child(amount)
		box.add_child(top)
		var detail := Label.new()
		detail.text = "%s · Qualità %d/3 · %s" % [ingredient.category, int(entry.quality), ingredient.get("unlock", "Sbloccato inizialmente")]
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.add_theme_color_override("font_color", Color("52686b"))
		box.add_child(detail)
		var ingredient_id := String(ingredient.id)
		if bool(entry.unlocked):
			var reorder := HFlowContainer.new()
			var auto := CheckBox.new()
			auto.text = "Auto"
			auto.button_pressed = bool(entry.auto_reorder)
			auto.toggled.connect(func(value: bool): GameState.stock[ingredient_id].auto_reorder = value; if ingredient_id == "tomato" and value: ui.advance_tutorial_to(3))
			reorder.add_child(auto)
			var threshold := SpinBox.new()
			threshold.min_value = 0
			threshold.max_value = 100
			threshold.value = int(entry.threshold)
			threshold.prefix = "Soglia "
			threshold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			threshold.value_changed.connect(func(value: float): GameState.stock[ingredient_id].threshold = int(value))
			reorder.add_child(threshold)
			var target := SpinBox.new()
			target.min_value = 1
			target.max_value = 150
			target.value = int(entry.target)
			target.prefix = "Obiettivo "
			target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			target.value_changed.connect(func(value: float): GameState.stock[ingredient_id].target = int(value))
			reorder.add_child(target)
			box.add_child(reorder)
			box.add_child(ui.make_button("Ordine urgente", func(): EconomyManager.order_stock(ingredient_id, int(GameState.stock[ingredient_id].lot), true), "red"))
		else:
			box.add_child(ui.make_button("Sblocca una tantum · 350 [coin]", func(): if GameState.spend(350, "Sblocco %s" % ingredient.name): GameState.stock[ingredient_id].unlocked = true; ui.refresh_screen(), "yellow"))
		content.add_child(card)
	preview.set_model.call_deferred(first_path)


static func _market(content: VBoxContainer, ui: RestaurantUI) -> void:
	var market_header := HBoxContainer.new()
	var market_title := ui.make_section("Mercato locale simulato", "Offerte limitate con qualità, scadenza e venditori fittizi; il provider resta sostituibile da un backend futuro.")
	market_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	market_header.add_child(market_title)
	var refresh := ui.make_button("Aggiorna offerte", func(): ui.market_provider.refresh(); ui.refresh_screen(), "yellow")
	refresh.size_flags_horizontal = Control.SIZE_SHRINK_END
	market_header.add_child(refresh)
	content.add_child(market_header)
	var offer_grid := GridContainer.new()
	offer_grid.name = "MarketOfferGrid"
	offer_grid.set_meta("responsive_grid", "landscape_two")
	offer_grid.columns = 1 if ui.is_portrait_layout() else 2
	offer_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	offer_grid.add_theme_constant_override("h_separation", 10)
	offer_grid.add_theme_constant_override("v_separation", 10)
	content.add_child(offer_grid)
	for offer: Dictionary in ui.market_provider.get_offers():
		if not DataRegistry.is_market_preparation(String(offer.get("preparation_id", ""))):
			continue
		var card := ui.make_card()
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		card.add_child(row)
		var offered_preparation: Dictionary = DataRegistry.preparations_by_id.get(String(offer.get("preparation_id", "")), {})
		var offer_icon := _new_icon(GameIcons.preparation_icon(offered_preparation), Vector2(58, 58))
		offer_icon.tooltip_text = String(offer.name)
		row.add_child(offer_icon)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.name = "MarketOfferLabel_%s" % String(offer.get("id", "")).validate_node_name()
		label.set_meta("market_offer_id", String(offer.get("id", "")))
		label.text = _market_offer_text(offer)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(label)
		var offer_id := String(offer.id)
		row.add_child(ui.make_button("Compra", func(): ui.market_provider.buy_offer(offer_id); ui.refresh_screen(), "green"))
		offer_grid.add_child(card)
	var total_preparations := 0
	for preparation_id: String in DataRegistry.market_preparation_ids():
		total_preparations += int(GameState.purchased_preparations.get(preparation_id, 0))
	content.add_child(ui.make_section("Negozi NPC", "%d semilavorati disponibili: quelli acquistati sostituiscono realmente le fasi preparabili delle ricette." % total_preparations))
	var shop_grid := GridContainer.new()
	shop_grid.name = "MarketShopGrid"
	shop_grid.set_meta("responsive_grid", "landscape_two")
	shop_grid.columns = 1 if ui.is_portrait_layout() else 2
	shop_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shop_grid.add_theme_constant_override("h_separation", 10)
	content.add_child(shop_grid)
	var shops := [
		{"name":"PANETTIERE", "description":"Impasti e pane pronti", "ids":["dough_base", "bun_split"]},
		{"name":"LABORATORIO GASTRONOMICO", "description":"Preparazioni realmente utilizzabili", "ids":["tomato_sauce", "cheese_grated", "potato_cut"]}
	]
	for shop: Dictionary in shops:
		var shop_card := ui.make_card()
		var shop_box := VBoxContainer.new()
		shop_card.add_child(shop_box)
		var shop_title := Label.new()
		shop_title.text = "%s · %s" % [shop.name, shop.description]
		shop_title.add_theme_color_override("font_color", Color("265b61"))
		shop_box.add_child(shop_title)
		for prep_id_value: String in shop.ids:
			if not DataRegistry.is_market_preparation(prep_id_value):
				continue
			var prep: Dictionary = DataRegistry.preparations_by_id[prep_id_value]
			var prep_row := HBoxContainer.new()
			prep_row.add_theme_constant_override("separation", 8)
			var prep_icon := _new_icon(GameIcons.preparation_icon(prep), Vector2(42, 42))
			prep_icon.tooltip_text = String(prep.name)
			prep_row.add_child(prep_icon)
			var prep_label := Label.new()
			prep_label.text = "%s · %.1f monete · disponibili %d" % [prep.name, float(prep.market_price), int(GameState.purchased_preparations.get(prep_id_value, 0))]
			prep_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			prep_row.add_child(prep_label)
			var prep_id := prep_id_value
			var buy := ui.make_button("Compra x5", func(): EconomyManager.buy_preparation(prep_id, 5); ui.refresh_screen(), "green")
			buy.custom_minimum_size = Vector2(116, 38)
			prep_row.add_child(buy)
			shop_box.add_child(prep_row)
		shop_grid.add_child(shop_card)


static func _staff(content: VBoxContainer, ui: RestaurantUI) -> void:
	content.add_child(StaffScreen.create(ui))


static func _statistics(content: VBoxContainer, ui: RestaurantUI) -> void:
	content.add_child(ReviewsScreen.create())
	content.add_child(OPERATIONAL_STATISTICS_SCREEN.create(ui))


static func _settings(content: VBoxContainer, ui: RestaurantUI) -> void:
	content.add_child(ui.make_section("Impostazioni", "Preferenze salvate insieme al ristorante e applicate immediatamente."))
	content.add_child(ProfileScreen.create())
	content.add_child(PersistenceDiagnosticsPanel.create(ui))

	if PwaUpdateManager.is_available():
		var update_card := ui.make_card()
		var update_box := VBoxContainer.new()
		update_box.add_theme_constant_override("separation", 10)
		update_card.add_child(update_box)
		var update_title := Label.new()
		update_title.text = "AGGIORNAMENTI PWA"
		update_title.add_theme_font_override("font", GameFonts.bold())
		update_title.add_theme_font_size_override("font_size", 19)
		update_box.add_child(update_title)
		var update_description := Label.new()
		update_description.text = "L'app installata resta nella Home. Le nuove build vengono scaricate in background e applicate con un solo riavvio."
		update_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		update_description.add_theme_color_override("font_color", Color("52686b"))
		update_box.add_child(update_description)
		update_box.add_child(ui.make_button("Controlla aggiornamenti", func():
			ui.show_toast(PwaUpdateManager.check_for_updates(), "info")
		, "green"))
		content.add_child(update_card)

	var general := ui.make_card()
	var general_box := VBoxContainer.new()
	general_box.add_theme_constant_override("separation", 12)
	general.add_child(general_box)
	var quality_title := Label.new()
	quality_title.text = "QUALITÀ GRAFICA"
	quality_title.add_theme_font_override("font", GameFonts.bold())
	general_box.add_child(quality_title)
	var quality := OptionButton.new()
	quality.name = "GraphicsQuality"
	quality.custom_minimum_size.y = 44
	var quality_presets := [
		{"id":"auto", "name":"Automatica (consigliata)"},
		{"id":"low", "name":"Bassa"},
		{"id":"medium", "name":"Media"},
		{"id":"high", "name":"Alta"}
	]
	var selected_quality := WebPlatformProfile.normalize_preset(String(GameState.settings.get("graphics_quality", "auto")))
	for index: int in quality_presets.size():
		quality.add_item(String(quality_presets[index].name))
		quality.set_item_metadata(index, String(quality_presets[index].id))
		if String(quality_presets[index].id) == selected_quality:
			quality.select(index)
	general_box.add_child(quality)
	var quality_detail := Label.new()
	quality_detail.text = "Scala 3D, antialiasing, ombre e limite FPS. Automatica adatta il carico al dispositivo; Alta privilegia la resa su PC."
	quality_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quality_detail.add_theme_color_override("font_color", Color("52686b"))
	general_box.add_child(quality_detail)
	quality.item_selected.connect(func(index: int):
		var preset := String(quality.get_item_metadata(index))
		GameState.settings.graphics_quality = preset
		WebPlatformProfile.apply_quality(preset)
		SaveManager.save_game()
		ui.show_toast("Qualità grafica: %s" % quality.get_item_text(index), "info")
	)
	var music := CheckBox.new()
	music.name = "MusicEnabled"
	music.text = "Musica"
	music.custom_minimum_size.y = 44
	music.button_pressed = bool(GameState.settings.get("music", true))
	music.toggled.connect(func(value: bool):
		GameState.settings.music = value
		AudioManager.apply_settings()
		SaveManager.save_game()
	)
	general_box.add_child(music)
	var sound := CheckBox.new()
	sound.name = "SoundEnabled"
	sound.text = "Effetti sonori"
	sound.custom_minimum_size.y = 44
	sound.button_pressed = bool(GameState.settings.get("sound", true))
	sound.toggled.connect(func(value: bool):
		GameState.settings.sound = value
		AudioManager.apply_settings()
		SaveManager.save_game()
	)
	general_box.add_child(sound)
	for volume_definition: Dictionary in [
		{"label":"Musica", "bus":AudioManager.BUS_MUSIC, "key":"music_volume"},
		{"label":"Ambiente", "bus":AudioManager.BUS_AMBIENCE, "key":"ambience_volume"},
		{"label":"Effetti", "bus":AudioManager.BUS_SFX, "key":"sfx_volume"},
		{"label":"Interfaccia", "bus":AudioManager.BUS_UI, "key":"ui_volume"},
	]:
		var volume_row := HBoxContainer.new()
		var volume_label := Label.new()
		volume_label.text = String(volume_definition.label)
		volume_label.custom_minimum_size.x = 92
		volume_row.add_child(volume_label)
		var volume_slider := HSlider.new()
		volume_slider.name = "%sVolume" % String(volume_definition.bus)
		volume_slider.min_value = 0.0
		volume_slider.max_value = 1.0
		volume_slider.step = 0.05
		volume_slider.value = float(GameState.settings.get(String(volume_definition.key), 0.8))
		volume_slider.custom_minimum_size = Vector2(180, 44)
		volume_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		volume_slider.value_changed.connect(func(value: float): AudioManager.set_bus_volume(String(volume_definition.bus), value))
		volume_slider.drag_ended.connect(func(value_changed: bool): if value_changed: SaveManager.save_game())
		volume_row.add_child(volume_slider)
		general_box.add_child(volume_row)
	var contrast := CheckBox.new()
	contrast.name = "HighContrast"
	contrast.text = "Contrasto elevato"
	contrast.custom_minimum_size.y = 44
	contrast.button_pressed = bool(GameState.settings.get("high_contrast", false))
	contrast.toggled.connect(func(value: bool):
		GameState.settings.high_contrast = value
		ui.apply_accessibility_settings()
		SaveManager.save_game()
	)
	general_box.add_child(contrast)
	var reduced_motion := CheckBox.new()
	reduced_motion.name = "ReducedMotion"
	reduced_motion.text = "Riduci animazioni interfaccia e camera"
	reduced_motion.custom_minimum_size.y = 44
	reduced_motion.button_pressed = bool(GameState.settings.get("reduced_motion", false))
	reduced_motion.toggled.connect(func(value: bool):
		GameState.settings.reduced_motion = value
		ui.apply_accessibility_settings()
		SaveManager.save_game()
	)
	general_box.add_child(reduced_motion)
	var zoom_label := Label.new()
	zoom_label.text = "Zoom iniziale e corrente della camera"
	zoom_label.add_theme_color_override("font_color", Color("52686b"))
	general_box.add_child(zoom_label)
	var zoom := HSlider.new()
	zoom.min_value = 13.0
	zoom.max_value = 34.0
	zoom.step = 1.0
	zoom.value = ui.world.camera_rig.zoom
	zoom.custom_minimum_size.y = 44
	zoom.value_changed.connect(func(value: float):
		ui.world.camera_rig.zoom = value
		GameState.settings.camera_zoom = value
	)
	zoom.drag_ended.connect(func(value_changed: bool):
		if value_changed:
			SaveManager.save_game()
	)
	general_box.add_child(zoom)
	var camera_row := HBoxContainer.new()
	camera_row.add_child(ui.make_button("Centra la mappa", func(): ui.world.camera_rig.target = Vector3.ZERO, "blue"))
	camera_row.add_child(ui.make_button("Zoom predefinito", func(): zoom.value = 24.0; SaveManager.save_game(), "ghost"))
	general_box.add_child(camera_row)
	content.add_child(general)

	var tutorial := ui.make_card()
	var tutorial_box := VBoxContainer.new()
	tutorial.add_child(tutorial_box)
	var tutorial_status := Label.new()
	tutorial_status.text = "Tutorial: %s" % ("completato" if bool(GameState.tutorial.get("complete", false)) else "saltato" if bool(GameState.tutorial.get("skipped", false)) else "in corso")
	tutorial_status.add_theme_color_override("font_color", Color("52686b"))
	tutorial_box.add_child(tutorial_status)
	var restart := ui.make_button("Ricomincia il tutorial", func():
		TutorialManager.restart()
		SaveManager.save_game()
		ui._update_tutorial()
		ui.show_toast("Tutorial riavviato")
	, "yellow")
	tutorial_box.add_child(restart)
	var save_now := ui.make_button("Salva ora", func():
		if SaveManager.save_game():
			ui.show_toast("Partita salvata", "income")
		else:
			ui.show_toast("Salvataggio non riuscito", "warning")
	, "green")
	tutorial_box.add_child(save_now)
	content.add_child(tutorial)


static func _confirm_storage_recovery(ui: RestaurantUI, plan: Dictionary) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Ripara il salvataggio"
	var recipe_name := String(DataRegistry.recipes_by_id.get(String(plan.get("recipe_id", "")), {"name":"ricetta sbloccata"}).name)
	dialog.dialog_text = "Questa operazione è eseguibile una sola volta.\n\nRicetta garantita: %s\nConsegne annullate: %d\nStock da liberare: %s\nIngredienti di emergenza: %s\n\nIl salvataggio corrente verrà aggiornato soltanto se l'intera riparazione riesce." % [
		recipe_name,
		(plan.get("cancel_batches", []) as Array).size(),
		_format_delivery_items(plan.get("discard_items", {})),
		_format_delivery_items(plan.get("grant_items", {})),
	]
	dialog.confirmed.connect(func():
		var result := EconomyManager.apply_recovery_plan()
		if bool(result.get("success", false)):
			SaveManager.save_game()
			ui.show_toast("Salvataggio riparato: il servizio può ripartire", "income")
		else:
			ui.show_toast("Il piano di recupero non è più valido; controlla di nuovo lo stock", "warning")
		ui.refresh_screen()
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	ui.root.add_child(dialog)
	dialog.popup_centered(Vector2i(620, 430))


static func _confirm_cancel_delivery(ui: RestaurantUI, batch_kind: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Annulla consegna"
	dialog.dialog_text = "Annullare %s? Verrà rimborsato l'80%% dell'importo pagato." % ("la consegna urgente" if batch_kind == "urgent" else "il prossimo batch")
	dialog.confirmed.connect(func():
		var result := EconomyManager.cancel_pending_batch(batch_kind)
		if bool(result.get("success", false)):
			ui.show_toast("Consegna annullata · +%d monete" % int(result.get("refund", 0)), "income")
		else:
			ui.show_toast("La consegna non è più disponibile", "warning")
		ui.refresh_screen()
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	ui.root.add_child(dialog)
	dialog.popup_centered()


static func _confirm_fire(ui: RestaurantUI, employee_id: String, employee_name: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Conferma licenziamento"
	dialog.dialog_text = "Licenziare %s?" % employee_name
	dialog.confirmed.connect(func(): EconomyManager.fire(employee_id); ui.world.spawn_staff(); ui.refresh_screen(); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	ui.root.add_child(dialog)
	dialog.popup_centered()


static func _new_icon(texture: Texture2D, minimum_size: Vector2, locked: bool = false) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = texture
	icon.custom_minimum_size = minimum_size
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if locked:
		icon.modulate = Color("686868")
	return icon


static func _warehouse_ingredient_icon(ingredient: Dictionary, storage_type: String) -> Control:
	var stack := Control.new()
	stack.custom_minimum_size = Vector2(72, 72)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var background := TextureRect.new()
	background.texture = GameIcons.casual_system_icon("storage_%s" % storage_type)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	background.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	background.modulate = Color(1.0, 1.0, 1.0, 0.92)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(background)
	var foreground := TextureRect.new()
	foreground.texture = GameIcons.ingredient_icon(ingredient)
	foreground.position = Vector2(16, 13)
	foreground.size = Vector2(40, 40)
	foreground.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	foreground.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	foreground.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	foreground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(foreground)
	stack.tooltip_text = "%s · %s" % [String(ingredient.get("name", "")), _storage_type_name(storage_type)]
	return stack


static func _delivery_item_count(items: Variant) -> int:
	if not items is Dictionary:
		return 0
	var total := 0
	for ingredient_id: String in items:
		var value: Variant = (items as Dictionary)[ingredient_id]
		total += maxi(int((value as Dictionary).get("amount", 0)) if value is Dictionary else int(value), 0)
	return total


static func _format_delivery_items(items: Variant) -> String:
	if not items is Dictionary or (items as Dictionary).is_empty():
		return "nessuno"
	var labels: Array[String] = []
	var ingredient_ids: Array = (items as Dictionary).keys()
	ingredient_ids.sort()
	for ingredient_id_value: Variant in ingredient_ids:
		var ingredient_id := String(ingredient_id_value)
		var raw: Variant = (items as Dictionary)[ingredient_id]
		var amount := int((raw as Dictionary).get("amount", 0)) if raw is Dictionary else int(raw)
		if amount <= 0:
			continue
		var name := String(DataRegistry.ingredients_by_id.get(ingredient_id, {"name":ingredient_id}).name)
		labels.append("%s x%d" % [name, amount])
	return ", ".join(labels)


static func _format_countdown(seconds: float) -> String:
	var rounded := maxi(int(ceil(maxf(seconds, 0.0))), 0)
	return "%02d:%02d" % [rounded / 60, rounded % 60]


static func _market_offer_text(offer: Dictionary) -> String:
	return "%s\n%s x%d · Qualità %d/3 · %.1f cad. · %ds" % [
		String(offer.get("seller", "")),
		String(offer.get("name", "")),
		int(offer.get("amount", 0)),
		int(offer.get("quality", 0)),
		float(offer.get("unit_price", 0.0)),
		maxi(int(ceil(float(offer.get("remaining", 0.0)))), 0),
	]


static func _storage_type_name(storage_type: String) -> String:
	return "Refrigerato" if storage_type == "refrigerated" else "Ambiente"


static func _linked_auto_sold_out_recipes(ingredient_id: String) -> Array[String]:
	var result: Array[String] = []
	for recipe: Dictionary in DataRegistry.recipes:
		if not DataRegistry.recipe_raw_requirements(recipe).has(ingredient_id):
			continue
		var state: Dictionary = GameState.menu.get(String(recipe.id), {})
		if bool(state.get("auto_sold_out", false)):
			result.append(String(recipe.name))
	return result


static func _station_names(station_ids: Array) -> Array[String]:
	var names: Array[String] = []
	for station_id: String in station_ids:
		names.append(String(DataRegistry.stations_by_id.get(station_id, {"name": station_id}).name))
	return names


static func _role_name(role_id: String) -> String:
	return {"cook":"Cuoco", "waiter":"Cameriere", "handyman":"Tuttofare"}.get(role_id, role_id.capitalize())


static func _menu_balance_text() -> String:
	var active := DataRegistry.active_recipes(GameState.menu)
	var used: Dictionary = {}
	var hottest_name := ""
	var hottest_load := 0.0
	for recipe: Dictionary in active:
		for station_id: String in DataRegistry.required_station_ids(recipe):
			used[station_id] = true
	for station_id: String in used:
		var load := SimulationManager.predicted_station_load(station_id)
		if load > hottest_load:
			hottest_load = load
			hottest_name = String(DataRegistry.stations_by_id.get(station_id, {"name": station_id}).name)
	if hottest_load > 100.0:
		return "menu sbilanciato: %s %.0f%%" % [hottest_name, hottest_load]
	return "menu equilibrato su %d postazioni" % used.size() if used.size() >= 4 else "menu concentrato su poche postazioni"


static func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
