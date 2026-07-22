extends Node

const CAPTURE_DIR := "res://artifacts/m10-acceptance"
const DESKTOP_SIZE := Vector2i(1366, 768)
const LANDSCAPE_SIZE := Vector2i(1280, 720)
const PHONE_SIZE := Vector2i(390, 844)
const FIXTURE_DAY := 7

var checks := 0
var failures: Array[String] = []
var captured_files: Array[String] = []
var validated_states: Array[String] = []
var _main: Node
var _cycle: Node
var _render_captures := true
var _orphan_baseline := PackedInt64Array()


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	seed(20260718)
	_render_captures = DisplayServer.get_name() != "headless"
	SaveManager.writes_enabled = false
	_orphan_baseline = Node.get_orphan_node_ids()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_DIR))
	if _render_captures:
		_clear_previous_captures()

	GameState.reset_to_defaults(false)
	GameState.tutorial.skipped = true
	GameState.tutorial.complete = true
	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	_expect(main_scene != null, "la scena principale reale e caricabile")
	if main_scene == null:
		await _finish()
		return
	_main = main_scene.instantiate()
	add_child(_main)
	await _wait_frames(50)

	# main.gd loads the user's save during _ready(). Replace it only after the
	# production hierarchy exists, then rebuild the actual runtime world.
	GameState.reset_to_defaults(false)
	GameState.tutorial.skipped = true
	GameState.tutorial.complete = true
	_main.world.load_layout()
	_main.world.spawn_staff()
	_main.ui._update_tutorial()
	_main.ui.close_screen()
	_main.world.set_process_unhandled_input(false)
	SimulationManager.close_immediately()
	EconomyManager.set_process(false)
	_cycle = get_tree().root.get_node_or_null("DayCycleManager")
	_expect(_cycle != null, "il DayCycleManager di produzione e disponibile")
	if _cycle != null:
		_cycle.set_process(false)
		_cycle.call("set_paused", true, false)
	get_window().min_size = Vector2i(320, 320)
	await _set_window_size(LANDSCAPE_SIZE)

	await _capture_day_cycle_states()
	await _capture_reviews()
	await _capture_album()
	await _capture_locked_recipe()
	await _capture_storage_and_delivery()
	await _capture_staff()
	await _capture_ventilation_comparison()
	await _capture_tabletop_icecream_machine()
	await _capture_dirty_pest_state()
	await _capture_profile()
	await _capture_phone_portrait()
	await _finish()


func _capture_day_cycle_states() -> void:
	_main.ui.close_screen()
	_main.world.camera_rig.zoom = 23.0
	_focus_cell(Vector2i(9, 7))

	_set_clock(720.0)
	_expect(
		String(_cycle.get("current_period_id")) == "lunch"
		and "12:00" in _main.ui.clock_label.text,
		"la cattura giorno usa il clock e l'indicatore periodo reali"
	)
	await _capture("01-day.png", LANDSCAPE_SIZE)

	_set_clock(1320.0)
	_expect(
		String(_cycle.get("current_period_id")) == "night"
		and "22:00" in _main.ui.clock_label.text,
		"la cattura notte usa il profilo luce e il clock reali"
	)
	await _capture("02-night.png", LANDSCAPE_SIZE)

	var rush_windows: Array[Dictionary] = _cycle.call("configured_rush_windows")
	var first_rush: Dictionary = rush_windows[0] if not rush_windows.is_empty() else {}
	var rush_start := float(first_rush.get("start", 720.0))
	var minutes_per_real_second := 1440.0 / maxf(
		float(DataRegistry.balance_value("day_cycle.real_seconds_at_1x", 1.0)),
		0.001
	)
	var warning_minutes := float(
		DataRegistry.balance_value("day_cycle.rush_warning_seconds", 0.0)
	) * minutes_per_real_second
	_set_clock(rush_start - warning_minutes * 0.5)
	var warning_status: Dictionary = _cycle.call("rush_status", 1.0)
	_expect(
		String(warning_status.get("phase", "")) == "warning"
		and "Rush" in _main.ui.rush_status_label.text,
		"il pre-rush deriva dalla finestra naturale configurata"
	)
	await _capture("03-pre-rush.png", LANDSCAPE_SIZE)

	var rush_end := float(first_rush.get("end", rush_start + 120.0))
	_set_clock(lerpf(rush_start, rush_end, 0.375))
	var rush_status: Dictionary = _cycle.call("rush_status", 1.0)
	_expect(
		String(rush_status.get("phase", "")) == "active"
		and "RUSH" in _main.ui.rush_status_label.text,
		"il rush deriva dalla finestra naturale configurata"
	)
	await _capture("04-rush.png", LANDSCAPE_SIZE)


func _capture_reviews() -> void:
	var reviews: Array[Dictionary] = [
		_review("acceptance_review_1", 5, 94, 18, "Una cena splendida: piatti curati e servizio rapido.", ["food_quality", "waiter_service"], []),
		_review("acceptance_review_2", 4, 86, 9, "Locale accogliente e personale gentile.", ["beauty", "waiter_service"], []),
		_review("acceptance_review_3", 3, 69, 2, "Buon cibo, ma l'attesa e stata un po' lunga.", ["food_quality"], ["food_wait"]),
		_review("acceptance_review_4", 2, 48, 0, "La sala aveva bisogno di piu attenzione.", [], ["cleanliness"]),
		_review("acceptance_review_5", 5, 97, 21, "Torneremo sicuramente.", ["food_quality", "beauty"], []),
	]
	GameState.reviews.clear()
	for review: Dictionary in reviews:
		GameState.append_review(review)
	GameState.set_reputation_value(4.2)
	GameState.set_review_reward_progress(4)
	await _show_screen("Statistiche", DESKTOP_SIZE)
	var reviews_screen := _main.ui.screen_page("Statistiche").find_child(
		"ReviewsScreen",
		true,
		false
	) as ReviewsScreen
	_expect(
		reviews_screen != null
		and reviews_screen.visible_history_count() == reviews.size()
		and int(reviews_screen.summary_snapshot().get("count", 0)) == reviews.size(),
		"la schermata recensioni legge lo storico reale di GameState"
	)
	await _capture("05-reviews.png", DESKTOP_SIZE)


func _capture_album() -> void:
	var amounts := [9, 6, 4, 8, 3, 7, 5, 6, 8, 4, 2, 5]
	for index: int in mini(amounts.size(), DataRegistry.ingredients.size()):
		var ingredient: Dictionary = DataRegistry.ingredients[index]
		var ingredient_id := String(ingredient.get("id", ""))
		GameState.set_album_discovered(ingredient_id, true)
		GameState.set_album_ingredient_amount(ingredient_id, int(amounts[index]))
	GameState.set_review_reward_progress(4)
	await _show_screen("Album", DESKTOP_SIZE)
	var album_page: Node = _main.ui.screen_page("Album")
	_expect(
		album_page != null
		and _tree_has_label_text(album_page, "x9")
		and _tree_has_label_text(album_page, "I TUOI INGREDIENTI"),
		"l'Album reale mostra quantita collezione e progresso"
	)
	await _capture("06-album-quantities.png", DESKTOP_SIZE)


func _capture_locked_recipe() -> void:
	var recipe_id := "margherita"
	GameState.set_recipe_active(recipe_id, false)
	GameState.set_recipe_unlocked(recipe_id, false)
	for ingredient_id: String in DataRegistry.recipes_by_id[recipe_id].get("unlock_cost", {}):
		GameState.set_album_discovered(ingredient_id, true)
		GameState.set_album_ingredient_amount(ingredient_id, 0)
	GameState.menu_changed.emit()
	await _show_screen("Menu", DESKTOP_SIZE)
	var menu_page: Node = _main.ui.screen_page("Menu")
	_expect(
		menu_page != null
		and _tree_has_label_text(menu_page, "COSTO ALBUM")
		and _tree_has_text_fragment(menu_page, "/1"),
		"la ricetta bloccata usa il pannello costi Album reale"
	)
	await _capture("07-locked-recipe-costs.png", DESKTOP_SIZE)


func _capture_storage_and_delivery() -> void:
	# A real storage_crate is placed through RestaurantWorld. This changes the
	# authoritative layout capacity and, after the physical-fill integration,
	# also drives the visible stock props attached to storage providers.
	var crate_definition: Dictionary = DataRegistry.build_by_id.get("storage_crate", {})
	var crate_cell := _first_valid_preferred_cell(
		crate_definition,
		[
			Vector2i(4, 10),
			Vector2i(5, 10),
			Vector2i(4, 11),
			Vector2i(5, 11),
			Vector2i(1, 10),
			Vector2i(1, 11),
		],
		Vector2i(1, 8),
		Vector2i(17, 14)
	)
	_expect(crate_cell.x >= 0, "esiste una cella valida per la cassa dispensa")
	var storage_crate: PlacedObject
	if crate_cell.x >= 0:
		storage_crate = _main.world.add_layout_object("storage_crate", crate_cell, 0)
	_expect(storage_crate != null, "la cassa dispensa e un vero PlacedObject del layout")

	for ingredient_id: String in GameState.stock:
		var current_amount := int(GameState.stock[ingredient_id].get("amount", 0))
		GameState.add_stock(ingredient_id, -current_amount)
	for stock_fixture: Dictionary in [
		{"id": "tomato", "amount": 48},
		{"id": "potato", "amount": 34},
		{"id": "bun", "amount": 22},
		{"id": "carrot", "amount": 36},
		{"id": "cheese", "amount": 32},
		{"id": "patty", "amount": 28},
	]:
		GameState.add_stock(String(stock_fixture.id), int(stock_fixture.amount))
	StorageManager.recalculate_layout_capacity()
	var capacity: Dictionary = StorageManager.capacity_snapshot()
	await _wait_frames(4)
	var fill_snapshot: Dictionary = _main.world.storage_fill_snapshot()
	var ambient_fill: Dictionary = fill_snapshot.get("ambient", {})
	var refrigerated_fill: Dictionary = fill_snapshot.get("refrigerated", {})
	var ambient_crate_nodes: Array[Node] = _main.world.storage_fill_visualizer.find_children(
		"AmbientStockCrate_*",
		"Node3D",
		false,
		false
	)
	_expect(
		int(capacity.get("ambient", 0)) >= 280
		and int(capacity.get("refrigerated", 0)) >= 240,
		"la cassa aumenta la capacita ambient senza sostituire il frigorifero"
	)
	_expect(
		storage_crate != null
		and int(ambient_fill.get("crate_count", 0)) == ambient_crate_nodes.size()
		and ambient_crate_nodes.size() > 0
		and String(ambient_fill.get("display_provider_uid", "")) == storage_crate.uid
		and String(ambient_fill.get("display_mode", "")) == "floor_stack"
		and int(refrigerated_fill.get("indicator_count", 0)) > 0,
		"il visualizer pubblico ancora lo stack fisico alla cassa a pavimento e mostra il freddo"
	)

	await _show_screen("Magazzino", DESKTOP_SIZE)
	var stock_page: Node = _main.ui.screen_page("Magazzino")
	_expect(
		stock_page != null
		and _tree_has_label_text(stock_page, "CAPACIT")
		and _tree_has_text_fragment(stock_page, "Ambiente"),
		"il Magazzino mostra la capacita derivata dal layout"
	)
	await _capture("08-warehouse-capacity.png", DESKTOP_SIZE)

	_main.ui.close_screen()
	await _set_window_size(LANDSCAPE_SIZE)
	_main.world.camera_rig.zoom = 13.5
	var storage_object := storage_crate
	if storage_object != null:
		_focus_cell(storage_object.grid_cell)
	_expect(
		storage_object != null
		and storage_crate != null
		and _main.world.has_method("storage_fill_snapshot"),
		"la prova fisica usa scaffale e cassa reali"
	)
	await _capture("09-warehouse-physical-crates.png", LANDSCAPE_SIZE)

	EconomyManager.clear_delivery_cart()
	GameState.set_pending_delivery_batch({
		"id": "",
		"items": {},
		"remaining": 300.0,
		"paid": false,
	})
	_expect(EconomyManager.add_to_delivery_cart("tomato", 20), "il pomodoro entra nel carrello reale")
	_expect(EconomyManager.add_to_delivery_cart("carrot", 15), "la carota entra nel carrello reale")
	_expect(EconomyManager.confirm_delivery_cart(false), "il carrello crea un batch reale in arrivo")
	var batch: Dictionary = EconomyManager.normal_batch_snapshot()
	_expect(
		not (batch.get("items", {}) as Dictionary).is_empty()
		and float(batch.get("remaining", -1.0)) > 0.0,
		"la consegna in arrivo ha articoli e countdown positivi"
	)
	await _show_screen("Magazzino", DESKTOP_SIZE)
	stock_page = _main.ui.screen_page("Magazzino")
	_expect(
		_tree_has_text_fragment(stock_page, "prossimo batch")
		and _tree_has_text_fragment(stock_page, "normali"),
		"il countdown del batch e leggibile nella UI reale"
	)
	await _capture("10-incoming-delivery.png", DESKTOP_SIZE)


func _capture_staff() -> void:
	await _show_screen("Personale", DESKTOP_SIZE)
	var staff_screen := _main.ui.screen_page("Personale").find_child(
		"StaffScreen",
		true,
		false
	) as StaffScreen
	_expect(
		staff_screen != null
		and not staff_screen.visible_employee_ids().is_empty()
		and not staff_screen.visible_candidate_ids().is_empty(),
		"il tab Personale usa dipendenti e candidati reali separati per ruolo"
	)
	await _capture("11-staff.png", DESKTOP_SIZE)


func _capture_ventilation_comparison() -> void:
	_main.ui.close_screen()
	await _set_window_size(LANDSCAPE_SIZE)
	_main.ui.open_builder()
	_main.ui.build_hud.current_category = "Cucina"
	_main.ui.build_hud.refresh_catalog()
	var stove := _main.world.placed_objects.get("stove_1") as PlacedObject
	var hood := _main.world.placed_objects.get("hood_stove_1") as PlacedObject
	if stove == null:
		stove = _main.world.add_layout_object("stove", Vector2i(9, 12), 2)
	if stove != null and hood == null:
		hood = _main.world.add_layout_object("extractor_hood", stove.grid_cell, stove.rotation_steps, stove.uid, 0)
	_expect(stove != null and hood != null, "fornello e cappa reali sono presenti nel layout iniziale")
	if stove == null:
		return
	_main.world.camera_rig.zoom = 12.5
	_focus_cell(stove.grid_cell)
	_main.world.build_system.select_object(stove)
	_main.ui.build_hud.refresh_actions()
	_expect(
		_main.world.ventilation_hood_for(stove) == hood and stove.is_operational(),
		"il fornello con cappa e operativo"
	)
	await _capture("12-stove-with-hood.png", LANDSCAPE_SIZE)

	if hood != null:
		_main.world.remove_placed_object(hood, true)
	await _wait_frames(8)
	_main.world.build_system.select_object(stove)
	_main.ui.build_hud.refresh_actions()
	_expect(
		_main.world.ventilation_hood_for(stove) == null and not stove.is_operational(),
		"lo stesso fornello senza cappa resta visibile ma non operativo"
	)
	await _capture("13-stove-without-hood.png", LANDSCAPE_SIZE)


func _capture_tabletop_icecream_machine() -> void:
	var dessert := _main.world.placed_objects.get("dessert_1") as PlacedObject
	var worktop: PlacedObject
	if dessert != null:
		worktop = _main.world.placed_objects.get(dessert.support_uid) as PlacedObject
	else:
		worktop = _main.world.add_layout_object("worktable", Vector2i(12, 12), 2)
		if worktop != null:
			dessert = _main.world.add_layout_object("dessert", worktop.grid_cell, worktop.rotation_steps, worktop.uid, 0)
	_expect(dessert != null and worktop != null, "la gelatiera reale conserva il proprio tavolo di supporto")
	if dessert == null or worktop == null:
		return
	var definition: Dictionary = DataRegistry.build_by_id.get("dessert", {})
	var bounds := ModelFactory.calculate_visual_bounds(dessert.visual_model, true)
	var expected_size := Vector3(2.0, 2.404, 2.03)
	_expect(
		String(definition.get("placement", "")) == "surface"
		and String(definition.get("requires_support", "")) == "worktop"
		and int(definition.get("surface_span", 0)) == 1
		and not bool(definition.get("blocking", true))
		and not definition.has("model_scale"),
		"punto 19: la gelatiera resta da tavolo, uno slot, non bloccante e senza scala aggiunta"
	)
	_expect(
		_vector_approx(bounds.size, expected_size, 0.004)
		and dessert.support_uid == worktop.uid,
		"punto 19: la gelatiera conserva esattamente 2.000 x 2.404 x 2.030 e il support_uid"
	)
	_main.world.camera_rig.zoom = 11.5
	_focus_cell(dessert.grid_cell)
	_main.world.build_system.select_object(dessert)
	_main.ui.build_hud.refresh_actions()
	await _capture("14-tabletop-icecream-machine.png", LANDSCAPE_SIZE)
	_main.world.build_system.clear_selection()
	_main.ui.build_hud.close_builder(false)


func _capture_dirty_pest_state() -> void:
	SimulationManager.close_immediately()
	_main.ui.close_screen()
	_main.world.kitchen_dirt = 36.0
	_main.world.call("_refresh_kitchen_dirt_visuals")
	for _index: int in 3:
		_main.world.call("_spawn_service_spill")
	_main.world.call("_refresh_ambience")
	_main.world.call("_on_pest_spawn_requested", "mouse", {
		"incident_id": "acceptance_mouse",
	})
	await _wait_frames(6)
	var pest_record: Dictionary = _main.world.pest_visuals.get("acceptance_mouse", {})
	var pest_cell: Vector2i = pest_record.get("cell", Vector2i(10, 9))
	_main.world.camera_rig.zoom = 13.0
	_focus_cell(pest_cell)
	var ambience: Dictionary = _main.world.ambience_snapshot()
	var cleanliness: Dictionary = ambience.get("cleanliness", {})
	var pest: Dictionary = ambience.get("pest", {})
	_expect(
		_main.world.kitchen_dirt_visuals.size() >= 4
		and _main.world.spill_records.size() >= 1
		and _main.world.pest_visuals.has("acceptance_mouse")
		and "mouse" in (pest.get("visible_kinds", []) as Array),
		"sporco, macchie e infestazione sono istanze runtime reali e registrate"
	)
	_expect(
		float(cleanliness.get("kitchen_dirt", 0.0)) >= 36.0
		and float(ambience.get("cleanliness_score", 100.0)) < 60.0,
		"la cattura sporca deriva dal calcolo pulizia reale"
	)
	await _capture("15-dirty-restaurant-pest.png", LANDSCAPE_SIZE)


func _capture_profile() -> void:
	GameState.set_restaurant_profile({
		"player_name": "Livia",
		"restaurant_name": "DeGustibus",
		"avatar_appearance": "Chef_Male",
		"badge_id": "starter",
		"uniform_variant": 0,
	})
	await _show_screen("Impostazioni", DESKTOP_SIZE)
	var profile := _main.ui.screen_page("Impostazioni").find_child(
		"ProfileScreen",
		true,
		false
	) as ProfileScreen
	_expect(
		profile != null
		and String(profile.current_profile().get("player_name", "")) == "Livia"
		and profile.preset_count() > 1,
		"profilo, preset avatar e identita ristorante provengono dalla schermata reale"
	)
	await _capture("16-profile-avatar.png", DESKTOP_SIZE)


func _capture_phone_portrait() -> void:
	await _show_screen("Menu", PHONE_SIZE)
	_expect(
		_main.ui.is_phone_layout()
		and Vector2i(_main.ui.root.size) == PHONE_SIZE
		and _main.ui.screen_panel.visible,
		"il portrait usa la gerarchia responsive reale a 390 x 844"
	)
	await _capture("17-smartphone-portrait.png", PHONE_SIZE)


func _show_screen(screen_name: String, size: Vector2i) -> void:
	await _set_window_size(size)
	_main.ui.show_screen(screen_name, false)
	_main.ui.refresh_screen()
	_main.ui._apply_responsive_layout(Vector2(size))
	if _main.ui.screen_scroll != null:
		_main.ui.screen_scroll.scroll_vertical = 0
	await _wait_frames(12)


func _set_clock(minute: float) -> void:
	if _cycle == null:
		return
	_cycle.call("force_rush_debug", false)
	_cycle.call("set_clock", FIXTURE_DAY, minute, false)
	_main.world.call("_apply_day_cycle_lighting")
	_main.ui.call("_update_top_bar")


func _set_window_size(size: Vector2i) -> void:
	get_window().size = size
	await _wait_frames(5)
	_main.ui._apply_responsive_layout(Vector2(size))
	await _wait_frames(4)


func _focus_cell(cell: Vector2i) -> void:
	var target: Vector3 = _main.world.cell_to_world(cell)
	_main.world.camera_rig.target = target
	_main.world.camera_rig.global_position = target


func _first_valid_cell(
	definition: Dictionary,
	from_cell: Vector2i,
	to_exclusive: Vector2i
) -> Vector2i:
	for y: int in range(from_cell.y, to_exclusive.y):
		for x: int in range(from_cell.x, to_exclusive.x):
			var cell := Vector2i(x, y)
			var validation: Dictionary = _main.world.validate_placement(
				definition,
				cell,
				0
			)
			if bool(validation.get("valid", false)):
				return cell
	return Vector2i(-1, -1)


func _first_valid_preferred_cell(
	definition: Dictionary,
	preferred_cells: Array[Vector2i],
	from_cell: Vector2i,
	to_exclusive: Vector2i
) -> Vector2i:
	for cell: Vector2i in preferred_cells:
		var validation: Dictionary = _main.world.validate_placement(
			definition,
			cell,
			0
		)
		if bool(validation.get("valid", false)):
			return cell
	return _first_valid_cell(definition, from_cell, to_exclusive)


func _review(
	id: String,
	stars: int,
	satisfaction: int,
	tip: int,
	text: String,
	positive: Array[String],
	negative: Array[String]
) -> Dictionary:
	return {
		"id": id,
		"day": FIXTURE_DAY,
		"minute": 720 + captured_files.size() * 7,
		"stars": stars,
		"satisfaction": satisfaction,
		"customer_type": "famiglia",
		"tip": tip,
		"text": text,
		"positive_tags": positive,
		"negative_tags": negative,
		"recipe_ids": ["margherita"],
		"incident_ids": [],
	}


func _tree_has_label_text(root: Node, needle: String) -> bool:
	for child: Node in root.find_children("*", "Label", true, false):
		if needle in String((child as Label).text):
			return true
	return false


func _tree_has_text_fragment(root: Node, needle: String) -> bool:
	var normalized := needle.to_lower()
	for child: Node in root.find_children("*", "Label", true, false):
		if normalized in String((child as Label).text).to_lower():
			return true
	for child: Node in root.find_children("*", "Button", true, false):
		if normalized in String((child as Button).text).to_lower():
			return true
	return false


func _capture(filename: String, expected_size: Vector2i) -> void:
	await _wait_frames(5)
	_expect(
		Vector2i(_main.ui.root.size) == expected_size,
		"%s usa la gerarchia UI reale alla risoluzione %s" % [filename, expected_size]
	)
	validated_states.append(filename)
	if not _render_captures:
		print("VALIDATED %s | headless state only" % filename)
		return
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s" % [CAPTURE_DIR, filename]
	var error := image.save_png(path)
	var actual_size := image.get_size()
	_expect(error == OK, "%s viene salvata senza errori" % filename)
	_expect(actual_size == expected_size, "%s conserva la risoluzione %s" % [filename, expected_size])
	_expect(not image.is_empty(), "%s contiene un frame renderizzato" % filename)
	if error == OK:
		captured_files.append(filename)
	print("CAPTURED %s | %s" % [path, actual_size])


func _clear_previous_captures() -> void:
	var directory := DirAccess.open(CAPTURE_DIR)
	if directory == null:
		return
	directory.list_dir_begin()
	var filename := directory.get_next()
	while not filename.is_empty():
		if not directory.current_is_dir() and (
			filename.get_extension().to_lower() == "png"
			or filename in ["capture-report.txt", "capture-index.json"]
		):
			directory.remove(filename)
		filename = directory.get_next()
	directory.list_dir_end()


func _wait_frames(count: int) -> void:
	for _frame: int in count:
		await get_tree().process_frame


func _vector_approx(a: Vector3, b: Vector3, tolerance: float) -> bool:
	return (
		absf(a.x - b.x) <= tolerance
		and absf(a.y - b.y) <= tolerance
		and absf(a.z - b.z) <= tolerance
	)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)


func _finish() -> void:
	_expect(validated_states.size() == 17, "tutti i 17 stati visuali obbligatori ed extra sono attraversati")
	var index_entries: Array[Dictionary] = []
	if _render_captures:
		for filename: String in captured_files:
			var absolute_path := ProjectSettings.globalize_path("%s/%s" % [CAPTURE_DIR, filename])
			var image := Image.load_from_file(absolute_path)
			index_entries.append({
				"file": filename,
				"width": image.get_width(),
				"height": image.get_height(),
				"bytes": FileAccess.get_file_as_bytes(absolute_path).size(),
			})
		var index_file := FileAccess.open(
			"%s/capture-index.json" % CAPTURE_DIR,
			FileAccess.WRITE
		)
		if index_file != null:
			index_file.store_string(JSON.stringify({
				"fixture_seed": 20260718,
				"save_writes_enabled": false,
				"captures": index_entries,
				"point_19": {
					"item": "dessert",
					"placement": "surface",
					"support": "worktop",
					"scale": "1:1",
					"visual_size": [2.0, 2.404, 2.03],
				},
			}, "\t"))
			index_file.close()
	var result := "M10 ACCEPTANCE CAPTURES: %s | mode=%s states=%d captures=%d checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		"render" if _render_captures else "headless-validation",
		validated_states.size(),
		captured_files.size(),
		checks,
		failures.size(),
		"\n".join(failures),
	]
	if _render_captures:
		var report := FileAccess.open("%s/capture-report.txt" % CAPTURE_DIR, FileAccess.WRITE)
		if report != null:
			report.store_string(result)
			report.close()
	var test_result := FileAccess.open(
		"res://tests/m10-acceptance-capture-result.txt",
		FileAccess.WRITE
	)
	if test_result != null:
		test_result.store_string(result)
		test_result.close()
	print(result.strip_edges())
	if _cycle != null:
		_cycle.call("set_paused", false, false)
	var exit_code := 0 if failures.is_empty() else 1
	await _teardown_fixture()
	var quit_timer := get_tree().create_timer(0.15)
	quit_timer.timeout.connect(Callable(get_tree(), "quit").bind(exit_code))
	queue_free()


func _teardown_fixture() -> void:
	SimulationManager.close_immediately()
	SimulationManager.bind_world(null)
	SimulationManager.tasks.clear()
	SimulationManager.orders.clear()
	SimulationManager.service_tasks.clear()
	SimulationManager.maintenance_tasks.clear()
	SimulationManager.stations.clear()
	SimulationManager.customers.clear()
	StorageManager.reset_runtime_reservations()
	if _main != null and is_instance_valid(_main):
		_main.set_process(false)
		if is_instance_valid(_main.ui):
			_main.ui.set_process(false)
			if is_instance_valid(_main.ui.root):
				_main.ui.root.theme = null
			_main.ui._theme = null
		if is_instance_valid(_main.world):
			_main.world.set_process(false)
		_main.queue_free()
	_main = null
	for _frame: int in 6:
		await get_tree().process_frame
	for instance_id: int in Node.get_orphan_node_ids():
		if instance_id in _orphan_baseline:
			continue
		var object := instance_from_id(instance_id)
		if is_instance_valid(object) and object is Node:
			(object as Node).free()
	GameIcons._scaled_cache = {}
	GameFonts._medium = null
	GameFonts._semibold = null
	GameFonts._bold = null
	ModelFactory._cache = {}
	AnimatedAgent._skin_material_cache = {}
	AnimatedAgent._face_material_cache = {}
	for _frame: int in 4:
		await get_tree().process_frame
