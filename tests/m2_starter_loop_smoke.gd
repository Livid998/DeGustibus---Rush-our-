extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	SimulationManager.close_immediately()
	var original_state := GameState.serialize().duplicate(true)
	GameState.reset_to_defaults(false)
	StorageManager.reset_runtime_reservations()
	StorageManager.recalculate_layout_capacity()

	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	main.world.load_layout()
	await get_tree().process_frame

	_test_economy_and_roster()
	_test_menu_and_stock()
	_test_layout_and_readiness(main.world)
	_test_existing_save_preservation()

	var result := "M2 STARTER LOOP: %s | checks=%d failures=%d" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
	]
	print(result)
	for failure: String in failures:
		print(failure)
	GameState.deserialize(original_state)
	main.queue_free()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_economy_and_roster() -> void:
	_expect(DataRegistry.gameplay_balance_valid, "la configurazione new_game supera la validazione dati")
	_expect(GameState.money == 1200, "una nuova partita parte con 1.200 monete")
	var roles := {"cook": 0, "waiter": 0, "handyman": 0}
	for employee: Dictionary in GameState.employees:
		var role := String(employee.get("role", ""))
		if roles.has(role):
			roles[role] = int(roles[role]) + 1
	_expect(GameState.employees.size() == 3 and roles == {"cook": 1, "waiter": 1, "handyman": 1}, "lo starter assume esattamente cuoco, cameriere e tuttofare")


func _test_menu_and_stock() -> void:
	var active_ids: Array[String] = []
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		active_ids.append(String(recipe.id))
	active_ids.sort()
	_expect(active_ids == ["margherita", "mixed_salad"], "il menu iniziale contiene solo margherita e insalata mista")

	var target_covers := maxi(int(DataRegistry.balance_value("new_game.target_cover_count", 12)), 1)
	var margin := maxf(float(DataRegistry.balance_value("new_game.stock_margin", 0.20)), 0.0)
	var planned_requirements: Dictionary = {}
	for recipe_index: int in active_ids.size():
		# The opening pantry covers a representative service split across the
		# whole starter menu, rather than enough stock to serve every cover as
		# either recipe (which would overfill and overfund the new game).
		var planned_servings := target_covers / active_ids.size()
		if recipe_index < target_covers % active_ids.size():
			planned_servings += 1
		for ingredient_id: String in DataRegistry.recipe_raw_requirements(active_ids[recipe_index]):
			planned_requirements[ingredient_id] = int(planned_requirements.get(ingredient_id, 0)) + int(DataRegistry.recipe_raw_requirements(active_ids[recipe_index])[ingredient_id]) * planned_servings
	for ingredient_id: String in planned_requirements:
		var required_amount := ceili(float(planned_requirements[ingredient_id]) * (1.0 + margin))
		_expect(int(GameState.stock[ingredient_id].amount) >= required_amount, "%s copre il servizio da %d posti con il 20%% di margine" % [ingredient_id, target_covers])

	var capacity := StorageManager.capacity_snapshot()
	var usage := StorageManager.usage_snapshot()
	_expect(int(usage.ambient) * 2 < int(capacity.ambient), "lo stock ambiente iniziale resta sotto il 50%")
	_expect(int(usage.refrigerated) * 2 < int(capacity.refrigerated), "lo stock refrigerato iniziale resta sotto il 50%")

	var useful_reward := false
	var active_requirements: Dictionary = {}
	for recipe_id: String in active_ids:
		for ingredient_id: String in DataRegistry.recipe_raw_requirements(recipe_id):
			active_requirements[ingredient_id] = true
	for ingredient_id: String in GameState.album_inventory:
		if int(GameState.album_inventory[ingredient_id]) > 0 and active_requirements.has(ingredient_id):
			useful_reward = true
			break
	_expect(useful_reward, "la prima dotazione Album contiene un ingrediente utilizzabile dal menu iniziale")


func _test_layout_and_readiness(world: RestaurantWorld) -> void:
	var dining_tables := GameState.layout.filter(func(record: Dictionary): return String(record.get("item", "")).begins_with("table"))
	var chairs := GameState.layout.filter(func(record: Dictionary): return String(record.get("item", "")) == "chair")
	_expect(dining_tables.size() == 1 and String(dining_tables[0].item) == "table_small", "il layout iniziale contiene un solo tavolo piccolo")
	_expect(chairs.size() == 2 and chairs.all(func(record: Dictionary): return String(record.get("support_uid", "")) == "table_1" and int(record.get("attachment_slot", -1)) in [0, 2]), "le due sedie sono agganciate a lati validi lasciando libero l'approccio di servizio")

	var required_items := ["door", "fridge", "storage", "prep_bowl", "cutting_board", "pizza_oven", "dough", "sink", "pass_tray"]
	for item_id: String in required_items:
		_expect(GameState.layout.any(func(record: Dictionary): return String(record.get("item", "")) == item_id), "la cucina minima include %s" % item_id)
	var pizza_record := _record("pizza_1")
	_expect(String(pizza_record.get("support_uid", "")) == "support_pizza_1" and String(_record("support_pizza_1").get("item", "")) == "prep_counter", "il forno pizza resta tabletop su un supporto da due slot")

	var readiness := OpeningReadinessService.evaluate(world)
	_expect(bool(readiness.get("ready", false)), "la checklist di apertura passa sul fresh save: %s" % _issue_ids(readiness.get("blockers", [])))
	var context: Dictionary = readiness.get("context", {})
	var operational: Array = (context.get("stations", {}) as Dictionary).get("operational", [])
	for station_id: String in ["dough", "prep_counter", "cutting_board", "pizza_oven", "pass"]:
		_expect(station_id in operational, "la postazione %s e operativa e raggiungibile" % station_id)


func _test_existing_save_preservation() -> void:
	var existing := GameState.serialize().duplicate(true)
	existing.save_version = GameState.SAVE_VERSION
	existing.money = 7777
	existing.layout = [{"uid":"preserved_table", "item":"table_medium", "cell":[6, 4], "rotation":2}]
	existing.employees = [{"id":"preserved_employee", "name":"Legacy", "role":"cook"}]
	existing.menu.margherita.active = false
	existing.menu.mixed_salad.active = false
	existing.menu.classic_burger.active = true
	existing.stock.tomato.amount = 7
	GameState.deserialize(existing)
	_expect(GameState.money == 7777 and GameState.layout == existing.layout, "un save v12 conserva denaro e layout senza ricevere lo starter")
	_expect(GameState.employees == existing.employees and bool(GameState.menu.classic_burger.active) and not bool(GameState.menu.margherita.active), "un save v12 conserva personale e menu")
	_expect(int(GameState.stock.tomato.amount) == 7, "un save v12 conserva lo stock")
	GameState.reset_to_defaults(false)
	StorageManager.recalculate_layout_capacity()


func _record(uid: String) -> Dictionary:
	for record: Dictionary in GameState.layout:
		if String(record.get("uid", "")) == uid:
			return record
	return {}


func _issue_ids(issues: Variant) -> String:
	if not issues is Array:
		return "invalid"
	return ", ".join((issues as Array).map(func(issue: Dictionary): return String(issue.get("id", "unknown"))))


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
