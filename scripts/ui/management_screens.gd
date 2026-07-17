class_name ManagementScreens
extends RefCounted


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
	balance.add_theme_color_override("font_color", Color("3f8f5f") if "equilibrato" in balance.text else Color("b35d50"))
	content.add_child(balance)
	var grid := GridContainer.new()
	grid.columns = 1 if ui.root.size.y > ui.root.size.x else 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	content.add_child(grid)
	for recipe: Dictionary in DataRegistry.recipes:
		var state: Dictionary = GameState.menu[recipe.id]
		var card := ui.make_card()
		card.custom_minimum_size.y = 154
		var body := HBoxContainer.new()
		body.add_theme_constant_override("separation", 12)
		card.add_child(body)
		var dish_icon := _new_icon(GameIcons.recipe_icon(recipe), Vector2(142, 132), not bool(state.unlocked))
		dish_icon.tooltip_text = String(recipe.name)
		body.add_child(dish_icon)
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_child(box)
		var top := HBoxContainer.new()
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
		price.disabled = not bool(state.unlocked)
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
		cart_description.text = "%s\nCosto normale %d monete · previsto Ambiente %d/%d · Refrigerato %d/%d" % [
			", ".join(item_names),
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
	content.add_child(cart_card)

	var grid := GridContainer.new()
	grid.columns = 1 if ui.root.size.y > ui.root.size.x else 2
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
		var supplier := OptionButton.new()
		var selected_index := 0
		for index: int in DataRegistry.suppliers.size():
			var supplier_definition: Dictionary = DataRegistry.suppliers[index]
			supplier.add_item(supplier_definition.name)
			supplier.set_item_metadata(index, supplier_definition.id)
			if supplier_definition.id == entry.supplier:
				selected_index = index
		supplier.select(selected_index)
		supplier.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		supplier.item_selected.connect(func(index: int): StorageManager.set_supplier(ingredient_id, String(supplier.get_item_metadata(index))))
		purchase.add_child(supplier)
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
	var detail_label := Label.new()
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.add_theme_color_override("font_color", Color("405f65"))
	detail_card.add_child(detail_label)
	content.add_child(detail_card)
	var grid := GridContainer.new()
	grid.columns = 2 if ui.root.size.x < 520.0 else 3 if ui.root.size.y > ui.root.size.x else 6
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 12)
	content.add_child(grid)
	for ingredient: Dictionary in DataRegistry.ingredients:
		var ingredient_id := String(ingredient.id)
		var amount := int(GameState.album_inventory.get(ingredient_id, 0))
		var discovered := bool(GameState.album_discovered.get(ingredient_id, false)) or amount > 0
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(155, 160)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var card_style := StyleBoxFlat.new()
		card_style.bg_color = Color("fffdf7")
		card_style.border_color = Color("a9cad5") if discovered else Color("c8c3b8")
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
		name.text = String(ingredient.name) if discovered else "???"
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
		ingredient_icon.tooltip_text = String(ingredient.name) if discovered else "Ingrediente da scoprire"
		if not discovered:
			ingredient_icon.modulate = Color(0.10, 0.14, 0.15, 0.62)
		visual.add_child(ingredient_icon)
		var inspect_button := Button.new()
		inspect_button.flat = true
		inspect_button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		inspect_button.tooltip_text = "Dettagli %s" % (ingredient.name if discovered else "ingrediente da scoprire")
		var ingredient_ref := ingredient
		var amount_ref := amount
		var discovered_ref := discovered
		inspect_button.pressed.connect(func(): detail_label.text = _album_detail_text(ingredient_ref, amount_ref, discovered_ref))
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
		var first_id := String(first.id)
		detail_label.text = _album_detail_text(first, int(GameState.album_inventory.get(first_id, 0)), bool(GameState.album_discovered.get(first_id, false)))


static func _legacy_album(content: VBoxContainer, ui: RestaurantUI) -> void:
	var unlocked := 0
	for entry: Dictionary in GameState.stock.values():
		if bool(entry.unlocked):
			unlocked += 1
	content.add_child(ui.make_section("Album ingredienti", "Collezione permanente %d/%d · lo sblocco non viene perso quando le scorte finiscono." % [unlocked, DataRegistry.ingredients.size()]))
	var body: BoxContainer
	if ui.root.size.y > ui.root.size.x:
		body = VBoxContainer.new()
	else:
		body = HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	content.add_child(body)
	var grid := GridContainer.new()
	grid.columns = 2 if ui.root.size.y > ui.root.size.x else 4
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
	preview.visible = ui.root.size.x >= ui.root.size.y
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
			var reorder: BoxContainer
			if ui.root.size.y > ui.root.size.x:
				reorder = VBoxContainer.new()
			else:
				reorder = HBoxContainer.new()
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
			var supplier_row := HBoxContainer.new()
			var supplier := OptionButton.new()
			var selected_index := 0
			for index: int in DataRegistry.suppliers.size():
				var supplier_definition: Dictionary = DataRegistry.suppliers[index]
				supplier.add_item(supplier_definition.name)
				supplier.set_item_metadata(index, supplier_definition.id)
				if supplier_definition.id == entry.supplier:
					selected_index = index
			supplier.select(selected_index)
			supplier.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			supplier.item_selected.connect(func(index: int): GameState.stock[ingredient_id].supplier = supplier.get_item_metadata(index))
			supplier_row.add_child(supplier)
			supplier_row.add_child(ui.make_button("Ordine urgente", func(): EconomyManager.order_stock(ingredient_id, int(GameState.stock[ingredient_id].lot), true), "red"))
			box.add_child(supplier_row)
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
	offer_grid.columns = 1 if ui.root.size.y > ui.root.size.x else 2
	offer_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	offer_grid.add_theme_constant_override("h_separation", 10)
	offer_grid.add_theme_constant_override("v_separation", 10)
	content.add_child(offer_grid)
	for offer: Dictionary in ui.market_provider.get_offers():
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
		label.text = "%s\n%s x%d · Qualità %d/3 · %.1f cad. · %ds" % [offer.seller, offer.name, int(offer.amount), int(offer.quality), float(offer.unit_price), int(offer.remaining)]
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(label)
		var offer_id := String(offer.id)
		row.add_child(ui.make_button("Compra", func(): ui.market_provider.buy_offer(offer_id); ui.refresh_screen(), "green"))
		offer_grid.add_child(card)
	var total_preparations := 0
	for amount: int in GameState.purchased_preparations.values():
		total_preparations += amount
	content.add_child(ui.make_section("Negozi NPC", "%d semilavorati disponibili: quelli acquistati sostituiscono realmente le fasi preparabili delle ricette." % total_preparations))
	var shop_grid := GridContainer.new()
	shop_grid.columns = 1 if ui.root.size.y > ui.root.size.x else 2
	shop_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shop_grid.add_theme_constant_override("h_separation", 10)
	content.add_child(shop_grid)
	var shops := [
		{"name":"PANETTIERE", "description":"Impasti e pane pronti", "ids":["dough_base", "bun_split"]},
		{"name":"LABORATORIO GASTRONOMICO", "description":"Tagli e preparazioni professionali", "ids":["tomato_sauce", "tomato_slices", "mushroom_cut", "onion_chopped", "cheese_grated", "cheese_slice", "burger_cooked", "veg_burger_cooked", "lettuce_cut", "potato_cut", "steak_pieces"]}
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
	content.add_child(ui.make_section("Brigata", "%d dipendenti assunti · ruoli e preferenze modificabili anche durante il servizio." % GameState.employees.size()))
	for employee: Dictionary in GameState.employees:
		var card := ui.make_card()
		var box := VBoxContainer.new()
		card.add_child(box)
		var title := Label.new()
		title.text = "%s · %s · %d monete/turno" % [employee.name, _role_name(String(employee.role)), int(employee.salary)]
		box.add_child(title)
		var stats := Label.new()
		stats.text = "Velocità %.0f%% · Precisione %.0f%% · Ordine %.0f%% · Resistenza %.0f%%" % [float(employee.speed)*100, float(employee.precision)*100, float(employee.order)*100, float(employee.stamina)*100]
		stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		stats.add_theme_color_override("font_color", Color("52686b"))
		box.add_child(stats)
		var row := HBoxContainer.new()
		var role := OptionButton.new()
		for role_name: String in ["cook", "waiter", "handyman"]:
			role.add_item({"cook":"Cuoco", "waiter":"Cameriere", "handyman":"Tuttofare"}[role_name])
			role.set_item_metadata(role.item_count - 1, role_name)
			if role_name == employee.role:
				role.select(role.item_count - 1)
		var employee_ref := employee
		role.item_selected.connect(func(index: int): employee_ref.role = role.get_item_metadata(index); ui.world.spawn_staff())
		role.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(role)
		var employee_id := String(employee.id)
		row.add_child(ui.make_button("Licenzia", func(): _confirm_fire(ui, employee_id, employee.name), "red"))
		box.add_child(row)
		var preference := OptionButton.new()
		preference.add_item("Postazione preferita: automatica")
		preference.set_item_metadata(0, "")
		var preferred := String(employee.get("preferred_station", ""))
		for station: Dictionary in DataRegistry.stations:
			preference.add_item("Preferenza: %s" % station.name)
			preference.set_item_metadata(preference.item_count - 1, station.id)
			if String(station.id) == preferred:
				preference.select(preference.item_count - 1)
		preference.item_selected.connect(func(index: int): employee_ref.preferred_station = preference.get_item_metadata(index))
		box.add_child(preference)
		content.add_child(card)
	content.add_child(ui.make_section("Candidati", "Assumi senza sistemi punitivi: il costo è immediato, il salario è informativo nella demo."))
	for candidate: Dictionary in GameState.candidates:
		var card := ui.make_card()
		var row := HBoxContainer.new()
		card.add_child(row)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text = "%s · %s\nIngaggio %d monete · salario %d · velocità %.0f%%" % [candidate.name, String(candidate.role).capitalize(), int(candidate.hire_cost), int(candidate.salary), float(candidate.speed)*100]
		row.add_child(label)
		var candidate_id := String(candidate.id)
		row.add_child(ui.make_button("Assumi", func(): EconomyManager.hire(candidate_id); ui.refresh_screen(), "green"))
		content.add_child(card)


static func _statistics(content: VBoxContainer, ui: RestaurantUI) -> void:
	var summary := SimulationManager.summary()
	content.add_child(ui.make_section("Statistiche di servizio", "Aggiornamento continuo; code e capacità provengono dalla task board reale."))
	var overview := ui.make_card()
	var text := Label.new()
	text.text = "Ricavi %d monete · Ingredienti %d monete · Personale %d monete · Utile %d monete\nServiti %d · Persi %d · Soddisfazione %.0f%% · Tempo medio %.1fs\nPiù venduto: %s · Meno venduto: %s · Spreco %d · Terminati: %s" % [summary.revenue, summary.ingredient_cost, summary.labor_cost, summary.profit, summary.customers_served, summary.customers_lost, float(summary.satisfaction)*100, float(summary.average_time), summary.top_recipe, summary.low_recipe, summary.waste, ", ".join(summary.ingredients_out) if not summary.ingredients_out.is_empty() else "nessuno"]
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overview.add_child(text)
	content.add_child(overview)
	content.add_child(ui.make_section("Produttività brigata", "Task cucina e servizio completati nella sessione corrente."))
	var productivity := ui.make_card()
	var productivity_box := VBoxContainer.new()
	productivity.add_child(productivity_box)
	for employee: Dictionary in GameState.employees:
		var employee_row := HBoxContainer.new()
		var employee_name := Label.new()
		employee_name.text = "%s · %s" % [employee.name, _role_name(String(employee.role))]
		employee_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		employee_row.add_child(employee_name)
		var completed := int(summary.employee_tasks.get(String(employee.id), 0))
		var completed_label := Label.new()
		completed_label.text = "%d task · stress %.0f%%" % [completed, float(employee.get("stress", 0.0)) * 100.0]
		employee_row.add_child(completed_label)
		productivity_box.add_child(employee_row)
	content.add_child(productivity)
	content.add_child(ui.make_section("Carico postazioni", "Previsto dal menu · attuale dal tempo occupato · coda dai task in attesa."))
	for metric: Dictionary in SimulationManager.station_metrics():
		if int(metric.capacity) == 0 and float(metric.predicted) <= 0.0:
			continue
		var card := ui.make_card()
		var box := VBoxContainer.new()
		card.add_child(box)
		var status := "SOVRACCARICO" if float(metric.predicted) > 100.0 else "elevato" if float(metric.predicted) > 80.0 else "regolare" if float(metric.predicted) > 45.0 else "sottoutilizzato"
		var label := Label.new()
		label.text = "%s · previsto %.0f%% (%s) · attuale %.0f%%\nCoda %d · attivi %d/%d · attesa media %.1fs · completati %d · bloccati %d" % [metric.name, float(metric.predicted), status, float(metric.utilization), int(metric.queue), int(metric.busy), int(metric.capacity), float(metric.average_wait), int(metric.completed), int(metric.blocked)]
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", Color("b94e48") if float(metric.predicted) > 100.0 else Color("9b761e") if float(metric.predicted) > 80.0 else Color("376c4a"))
		box.add_child(label)
		var bar := ProgressBar.new()
		bar.max_value = 150
		bar.value = minf(float(metric.predicted), 150.0)
		bar.show_percentage = true
		box.add_child(bar)
		content.add_child(card)


static func _settings(content: VBoxContainer, ui: RestaurantUI) -> void:
	content.add_child(ui.make_section("Impostazioni", "Preferenze salvate insieme al ristorante e applicate immediatamente."))

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
	var quality_presets := [
		{"id":"auto", "name":"Automatica (consigliata)"},
		{"id":"low", "name":"Bassa"},
		{"id":"balanced", "name":"Bilanciata"},
		{"id":"high", "name":"Alta"},
		{"id":"ultra", "name":"Massima · PC"}
	]
	var selected_quality := String(GameState.settings.get("graphics_quality", "auto"))
	for index: int in quality_presets.size():
		quality.add_item(String(quality_presets[index].name))
		quality.set_item_metadata(index, String(quality_presets[index].id))
		if String(quality_presets[index].id) == selected_quality:
			quality.select(index)
	general_box.add_child(quality)
	var quality_detail := Label.new()
	quality_detail.text = "Scala 3D, antialiasing, ombre e limite FPS. Su iPad usa Automatica o Bilanciata; Massima è pensata per PC."
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
	var sound := CheckBox.new()
	sound.text = "Effetti sonori"
	sound.button_pressed = bool(GameState.settings.get("sound", true))
	sound.toggled.connect(func(value: bool):
		GameState.settings.sound = value
		SaveManager.save_game()
	)
	general_box.add_child(sound)
	var zoom_label := Label.new()
	zoom_label.text = "Zoom iniziale e corrente della camera"
	zoom_label.add_theme_color_override("font_color", Color("52686b"))
	general_box.add_child(zoom_label)
	var zoom := HSlider.new()
	zoom.min_value = 13.0
	zoom.max_value = 34.0
	zoom.step = 1.0
	zoom.value = ui.world.camera_rig.zoom
	zoom.custom_minimum_size.y = 34
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
		GameState.tutorial = {"step": 0, "skipped": false, "complete": false}
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


static func _format_countdown(seconds: float) -> String:
	var rounded := maxi(int(ceil(maxf(seconds, 0.0))), 0)
	return "%02d:%02d" % [rounded / 60, rounded % 60]


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
