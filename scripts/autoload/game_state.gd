extends Node

signal money_changed(value: int)
signal reputation_changed(value: float)
signal restaurant_state_changed(value: String)
signal stock_changed(ingredient_id: String, amount: int)
signal menu_changed
signal employees_changed
signal layout_changed
signal toast_requested(message: String, tone: String)

const SAVE_VERSION := 5

var money: int = 10000
var reputation: float = 1.0
var restaurant_state: String = "closed"
var service_seconds: float = 0.0
var stock: Dictionary = {}
var menu: Dictionary = {}
var employees: Array = []
var candidates: Array = []
var layout: Array = []
var deliveries: Array = []
var purchased_preparations: Dictionary = {}
var progress: Dictionary = {"customers_served": 0, "desserts_served": 0, "services_started": 0}
var settings: Dictionary = {"music": true, "sound": true, "camera_zoom": 24.0}
var tutorial: Dictionary = {"step": 0, "skipped": false, "complete": false}


func _ready() -> void:
	reset_to_defaults(false)


func reset_to_defaults(emit_signals: bool = true) -> void:
	money = 10000
	reputation = 1.0
	restaurant_state = "closed"
	service_seconds = 0.0
	stock.clear()
	for ingredient: Dictionary in DataRegistry.ingredients:
		stock[ingredient.id] = {
			"amount": int(ingredient.get("stock", 0)),
			"unlocked": bool(ingredient.get("unlocked", false)),
			"average_cost": float(ingredient.get("cost", 0.0)),
			"supplier": String(ingredient.get("supplier", "wholesale")),
			"auto_reorder": false,
			"threshold": int(ingredient.get("reorder_threshold", 10)),
			"target": int(ingredient.get("stock_target", 30)),
			"lot": int(ingredient.get("lot", 10)),
			"quality": int(ingredient.get("quality", 2))
		}
	menu.clear()
	for recipe: Dictionary in DataRegistry.recipes:
		menu[recipe.id] = {
			"active": bool(recipe.get("active", false)),
			"unlocked": bool(recipe.get("unlocked", false)),
			"price": int(recipe.get("price", 10)),
			"sold_out": false
		}
	employees = DataRegistry.employee_data.get("hired", []).duplicate(true)
	candidates = DataRegistry.employee_data.get("candidates", []).duplicate(true)
	layout = _default_layout()
	deliveries.clear()
	purchased_preparations.clear()
	progress = {"customers_served": 0, "desserts_served": 0, "services_started": 0}
	settings = {"music": true, "sound": true, "camera_zoom": 24.0}
	tutorial = {"step": 0, "skipped": false, "complete": false}
	if emit_signals:
		_emit_all()


func _default_layout() -> Array:
	var result := [
		{"uid":"door_1","item":"door","cell":[8,0],"rotation":0},
		{"uid":"table_1","item":"table_medium","cell":[3,3],"rotation":0},
		{"uid":"chair_1","item":"chair","cell":[2,3],"rotation":1},
		{"uid":"chair_2","item":"chair","cell":[5,3],"rotation":3},
		{"uid":"chair_5","item":"chair","cell":[3,2],"rotation":2},
		{"uid":"chair_6","item":"chair","cell":[4,5],"rotation":0},
		{"uid":"table_2","item":"table_cloth","cell":[10,3],"rotation":0},
		{"uid":"chair_3","item":"chair","cell":[9,3],"rotation":1},
		{"uid":"chair_4","item":"chair","cell":[12,3],"rotation":3},
		{"uid":"chair_7","item":"chair","cell":[10,2],"rotation":2},
		{"uid":"chair_8","item":"chair","cell":[11,5],"rotation":0},
		{"uid":"fridge_1","item":"fridge","cell":[2,9],"rotation":0},
		{"uid":"storage_1","item":"storage","cell":[4,9],"rotation":0},
		{"uid":"prep_1","item":"prep_counter","cell":[6,9],"rotation":0},
		{"uid":"cut_1","item":"cutting_board","cell":[9,9],"rotation":0},
		{"uid":"cut_2","item":"cutting_board","cell":[10,9],"rotation":0},
		{"uid":"stove_1","item":"stove","cell":[11,9],"rotation":0},
		{"uid":"multi_1","item":"multi_stove","cell":[13,9],"rotation":0},
		{"uid":"pizza_1","item":"pizza_oven","cell":[2,12],"rotation":2},
		{"uid":"oven_1","item":"oven","cell":[5,12],"rotation":2},
		{"uid":"sink_1","item":"sink","cell":[7,12],"rotation":2},
		{"uid":"rack_1","item":"dish_rack","cell":[9,12],"rotation":2},
		{"uid":"pass_1","item":"pass","cell":[11,12],"rotation":2},
		{"uid":"dessert_1","item":"dessert","cell":[14,12],"rotation":2},
		{"uid":"dough_1","item":"dough","cell":[16,12],"rotation":2},
		{"uid":"plant_1","item":"plant","cell":[15,3],"rotation":0}
	]
	result.append_array(_initial_wall_records())
	return result


func can_afford(amount: int) -> bool:
	return money >= amount


func spend(amount: int, reason: String = "") -> bool:
	if amount < 0 or money < amount:
		return false
	money -= amount
	money_changed.emit(money)
	if not reason.is_empty():
		toast_requested.emit("-%d · %s" % [amount, reason], "cost")
	return true


func earn(amount: int, reason: String = "") -> void:
	money += max(amount, 0)
	money_changed.emit(money)
	if not reason.is_empty():
		toast_requested.emit("+%d · %s" % [amount, reason], "income")


func consume_stock(requirements: Dictionary) -> bool:
	for ingredient_id: String in requirements:
		if int(stock.get(ingredient_id, {}).get("amount", 0)) < int(requirements[ingredient_id]):
			return false
	for ingredient_id: String in requirements:
		stock[ingredient_id].amount -= int(requirements[ingredient_id])
		stock_changed.emit(ingredient_id, stock[ingredient_id].amount)
	return true


func add_stock(ingredient_id: String, amount: int, unit_cost: float = -1.0) -> void:
	if not stock.has(ingredient_id):
		return
	var entry: Dictionary = stock[ingredient_id]
	var old_amount := int(entry.amount)
	if unit_cost >= 0.0 and old_amount + amount > 0:
		entry.average_cost = ((float(entry.average_cost) * old_amount) + unit_cost * amount) / float(old_amount + amount)
	entry.amount = max(old_amount + amount, 0)
	stock_changed.emit(ingredient_id, int(entry.amount))


func set_restaurant_state(value: String) -> void:
	if restaurant_state == value:
		return
	restaurant_state = value
	restaurant_state_changed.emit(value)


func add_reputation(amount: float) -> void:
	var previous := reputation
	reputation = clampf(reputation + maxf(amount, 0.0), 1.0, 5.0)
	if not is_equal_approx(previous, reputation):
		reputation_changed.emit(reputation)


func unlock_ingredient(ingredient_id: String, reason: String = "", persist: bool = true) -> bool:
	if not stock.has(ingredient_id) or bool(stock[ingredient_id].unlocked):
		return false
	stock[ingredient_id].unlocked = true
	stock_changed.emit(ingredient_id, int(stock[ingredient_id].amount))
	var definition: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
	toast_requested.emit("Nuovo ingrediente: %s%s" % [definition.get("name", ingredient_id), " · " + reason if not reason.is_empty() else ""], "income")
	_sync_recipe_unlocks()
	if persist:
		SaveManager.save_game()
	return true


func record_completed_order(recipe_id: String, satisfaction: float) -> void:
	progress.customers_served = int(progress.get("customers_served", 0)) + 1
	if recipe_id in ["icecream_cone", "mixed_sundae"]:
		progress.desserts_served = int(progress.get("desserts_served", 0)) + 1
	add_reputation(0.04 * clampf(satisfaction, 0.45, 1.0))
	check_progression()


func check_progression(persist: bool = true) -> Array[String]:
	var unlocked: Array[String] = []
	if int(progress.get("customers_served", 0)) >= 25 and unlock_ingredient("veg_patty", "25 clienti serviti", false):
		unlocked.append("veg_patty")
	if reputation >= 2.0 and unlock_ingredient("ham", "Reputazione 2", false):
		unlocked.append("ham")
	if int(progress.get("services_started", 0)) >= 1 and unlock_ingredient("egg", "Primo servizio avviato", false):
		unlocked.append("egg")
	var dessert_stations := 0
	for record: Dictionary in layout:
		if String(record.get("item", "")) == "dessert":
			dessert_stations += 1
	if dessert_stations >= 2 and unlock_ingredient("ice_vanilla", "Seconda stazione dessert", false):
		unlocked.append("ice_vanilla")
	if reputation >= 3.0 and unlock_ingredient("ice_chocolate", "Reputazione 3", false):
		unlocked.append("ice_chocolate")
	if int(progress.get("desserts_served", 0)) >= 10 and unlock_ingredient("ice_strawberry", "10 dessert serviti", false):
		unlocked.append("ice_strawberry")
	if persist and not unlocked.is_empty():
		SaveManager.save_game()
	return unlocked


func _sync_recipe_unlocks() -> void:
	var requirements := {
		"pepperoni_pizza": ["pepperoni"],
		"veggie_burger": ["veg_patty"],
		"icecream_cone": ["ice_vanilla"],
		"mixed_sundae": ["ice_chocolate", "ice_strawberry"]
	}
	var changed := false
	for recipe_id: String in requirements:
		if not menu.has(recipe_id) or bool(menu[recipe_id].unlocked):
			continue
		var ready := true
		for ingredient_id: String in requirements[recipe_id]:
			if not stock.has(ingredient_id) or not bool(stock[ingredient_id].unlocked):
				ready = false
				break
		if ready:
			menu[recipe_id].unlocked = true
			changed = true
	if changed:
		menu_changed.emit()


func serialize() -> Dictionary:
	return {
		"save_version": SAVE_VERSION,
		"money": money,
		"reputation": reputation,
		"stock": stock,
		"menu": menu,
		"employees": employees,
		"candidates": candidates,
		"layout": layout,
		"settings": settings,
		"tutorial": tutorial,
		"purchased_preparations": purchased_preparations,
		"progress": progress
	}


func deserialize(data: Dictionary) -> void:
	var loaded_version := int(data.get("save_version", 0))
	if loaded_version > SAVE_VERSION:
		push_warning("Save file is from a newer version; loading known fields")
	money = int(data.get("money", money))
	reputation = float(data.get("reputation", reputation))
	stock.merge(data.get("stock", {}), true)
	menu.merge(data.get("menu", {}), true)
	employees = data.get("employees", employees).duplicate(true)
	candidates = data.get("candidates", candidates).duplicate(true)
	layout = data.get("layout", layout).duplicate(true)
	if loaded_version < 2:
		_migrate_seating_v2()
	if loaded_version < 3:
		_migrate_editable_shell_v3()
	if loaded_version < 4:
		_migrate_kitchen_capacity_v4()
	if loaded_version < 5:
		_migrate_edge_walls_v5()
	settings.merge(data.get("settings", {}), true)
	tutorial.merge(data.get("tutorial", {}), true)
	purchased_preparations.merge(data.get("purchased_preparations", {}), true)
	progress.merge(data.get("progress", {}), true)
	_sync_recipe_unlocks()
	set_restaurant_state("closed")
	_emit_all()


func _migrate_seating_v2() -> void:
	var records_by_uid: Dictionary = {}
	for record: Dictionary in layout:
		records_by_uid[String(record.get("uid", ""))] = record
	var additions := [
		{"table_uid":"table_1", "table_cell":[3, 3], "uid":"chair_5", "item":"chair", "cell":[3, 2], "rotation":2},
		{"table_uid":"table_1", "table_cell":[3, 3], "uid":"chair_6", "item":"chair", "cell":[4, 5], "rotation":0},
		{"table_uid":"table_2", "table_cell":[10, 3], "uid":"chair_7", "item":"chair", "cell":[10, 2], "rotation":2},
		{"table_uid":"table_2", "table_cell":[10, 3], "uid":"chair_8", "item":"chair", "cell":[11, 5], "rotation":0}
	]
	for addition: Dictionary in additions:
		if records_by_uid.has(addition.uid) or not records_by_uid.has(addition.table_uid):
			continue
		var table_record: Dictionary = records_by_uid[addition.table_uid]
		if table_record.get("cell", []) != addition.table_cell:
			continue
		var clean := addition.duplicate(true)
		clean.erase("table_uid")
		clean.erase("table_cell")
		layout.append(clean)


func _migrate_editable_shell_v3() -> void:
	var occupied_layout_cells: Dictionary = {}
	for record: Dictionary in layout:
		var cell: Array = record.get("cell", [-1, -1])
		occupied_layout_cells[Vector2i(int(cell[0]), int(cell[1]))] = true
	for wall_record: Dictionary in _initial_wall_records():
		var cell_data: Array = wall_record.cell
		var cell := Vector2i(int(cell_data[0]), int(cell_data[1]))
		if not occupied_layout_cells.has(cell):
			layout.append(wall_record)


func _migrate_kitchen_capacity_v4() -> void:
	for record: Dictionary in layout:
		if String(record.get("uid", "")) == "cut_2":
			return
	layout.append({"uid":"cut_2", "item":"cutting_board", "cell":[10, 9], "rotation":0})


func _migrate_edge_walls_v5() -> void:
	var has_divider_corner := false
	for record: Dictionary in layout:
		if String(record.get("uid", "")).begins_with("wall_divider_"):
			record.cell = [int(record.get("cell", [0, 7])[0]), 8]
			if String(record.get("uid", "")) == "wall_divider_0":
				has_divider_corner = true
	if not has_divider_corner:
		layout.append({"uid":"wall_divider_0", "item":"wall", "cell":[0, 8], "rotation":0})


func _initial_wall_records() -> Array:
	var records: Array = []
	for x: int in 18:
		if x == 8:
			continue
		records.append({"uid":"wall_top_%d" % x, "item":"wall_window" if x in [3, 4, 13, 14] else "wall", "cell":[x, 0], "rotation":0})
	for y: int in range(1, 14):
		records.append({"uid":"wall_left_%d" % y, "item":"wall", "cell":[0, y], "rotation":1})
	for x: int in range(0, 18):
		if x in [8, 9, 10, 11]:
			continue
		records.append({"uid":"wall_divider_%d" % x, "item":"wall", "cell":[x, 8], "rotation":0})
	return records


func _emit_all() -> void:
	money_changed.emit(money)
	reputation_changed.emit(reputation)
	restaurant_state_changed.emit(restaurant_state)
	menu_changed.emit()
	employees_changed.emit()
	layout_changed.emit()
