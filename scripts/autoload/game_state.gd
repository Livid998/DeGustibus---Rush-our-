extends Node

signal money_changed(value: int)
signal reputation_changed(value: float)
signal restaurant_state_changed(value: String)
signal stock_changed(ingredient_id: String, amount: int)
signal menu_changed
signal employees_changed
signal layout_changed
signal toast_requested(message: String, tone: String)

const SAVE_VERSION := 8

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
var settings: Dictionary = {"music": true, "sound": true, "camera_zoom": 24.0, "graphics_quality": "auto"}
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
	settings = {"music": true, "sound": true, "camera_zoom": 24.0, "graphics_quality": "auto"}
	tutorial = {"step": 0, "skipped": false, "complete": false}
	if emit_signals:
		_emit_all()


func _default_layout() -> Array:
	var result := [
		{"uid":"door_1","item":"door","cell":[8,0],"rotation":0},
		{"uid":"table_1","item":"table_medium","cell":[3,3],"rotation":0},
		{"uid":"chair_1","item":"chair","cell":[3,3],"rotation":3,"support_uid":"table_1","attachment_slot":1},
		{"uid":"chair_2","item":"chair","cell":[3,3],"rotation":1,"support_uid":"table_1","attachment_slot":3},
		{"uid":"chair_5","item":"chair","cell":[3,3],"rotation":0,"support_uid":"table_1","attachment_slot":0},
		{"uid":"chair_6","item":"chair","cell":[3,3],"rotation":2,"support_uid":"table_1","attachment_slot":2},
		{"uid":"table_2","item":"table_cloth","cell":[10,3],"rotation":0},
		{"uid":"chair_3","item":"chair","cell":[10,3],"rotation":3,"support_uid":"table_2","attachment_slot":1},
		{"uid":"chair_4","item":"chair","cell":[10,3],"rotation":1,"support_uid":"table_2","attachment_slot":3},
		{"uid":"chair_7","item":"chair","cell":[10,3],"rotation":0,"support_uid":"table_2","attachment_slot":0},
		{"uid":"chair_8","item":"chair","cell":[10,3],"rotation":2,"support_uid":"table_2","attachment_slot":2},
		{"uid":"fridge_1","item":"fridge","cell":[2,9],"rotation":0},
		{"uid":"storage_1","item":"storage","cell":[4,8],"rotation":0,"support_uid":"wall_divider_4","attachment_slot":0},
		{"uid":"prep_1","item":"prep_counter","cell":[6,9],"rotation":0},
		{"uid":"prep_bowl_1","item":"prep_bowl","cell":[6,9],"rotation":0,"support_uid":"prep_1","attachment_slot":0},
		{"uid":"support_cut_1","item":"prep_counter","cell":[9,9],"rotation":0},
		{"uid":"cut_1","item":"cutting_board","cell":[9,9],"rotation":0,"support_uid":"support_cut_1","attachment_slot":0},
		{"uid":"support_cut_2","item":"prep_counter","cell":[14,9],"rotation":0},
		{"uid":"cut_2","item":"cutting_board","cell":[14,9],"rotation":0,"support_uid":"support_cut_2","attachment_slot":0},
		{"uid":"stove_1","item":"stove","cell":[11,9],"rotation":0},
		{"uid":"multi_1","item":"multi_stove","cell":[13,9],"rotation":0},
		{"uid":"support_pizza_1","item":"prep_counter","cell":[2,12],"rotation":2},
		{"uid":"pizza_1","item":"pizza_oven","cell":[2,12],"rotation":2,"support_uid":"support_pizza_1","attachment_slot":0},
		{"uid":"support_oven_1","item":"worktable","cell":[5,12],"rotation":2},
		{"uid":"oven_1","item":"oven","cell":[5,12],"rotation":2,"support_uid":"support_oven_1","attachment_slot":0},
		{"uid":"sink_1","item":"sink","cell":[7,12],"rotation":2},
		{"uid":"support_rack_1","item":"worktable","cell":[9,12],"rotation":2},
		{"uid":"rack_1","item":"dish_rack","cell":[9,12],"rotation":2,"support_uid":"support_rack_1","attachment_slot":0},
		{"uid":"pass_1","item":"pass","cell":[11,12],"rotation":2},
		{"uid":"pass_tray_1","item":"pass_tray","cell":[11,12],"rotation":2,"support_uid":"pass_1","attachment_slot":0},
		{"uid":"dessert_1","item":"dessert","cell":[14,12],"rotation":2},
		{"uid":"support_dough_1","item":"worktable","cell":[16,12],"rotation":2},
		{"uid":"dough_1","item":"dough","cell":[16,12],"rotation":2,"support_uid":"support_dough_1","attachment_slot":0},
		{"uid":"plant_1","item":"plant","cell":[15,3],"rotation":0}
	]
	result.append_array(_initial_wall_records())
	result.append_array(_initial_exterior_records())
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
	if loaded_version < 6:
		_migrate_attachments_v6()
	if loaded_version < 7:
		_migrate_attachment_integrity_v7()
	if loaded_version < 8:
		_migrate_exterior_v8()
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


func _migrate_attachments_v6() -> void:
	var records_by_uid: Dictionary = {}
	var tables: Array[Dictionary] = []
	var walls: Array[Dictionary] = []
	for record: Dictionary in layout:
		records_by_uid[String(record.get("uid", ""))] = record
		var item_id := String(record.get("item", ""))
		if item_id.begins_with("table"):
			tables.append(record)
		elif item_id == "wall":
			walls.append(record)
	var additions: Array[Dictionary] = []
	for record: Dictionary in layout:
		if not String(record.get("support_uid", "")).is_empty():
			continue
		var item_id := String(record.get("item", ""))
		var cell_data: Array = record.get("cell", [0, 0])
		var cell := Vector2(int(cell_data[0]), int(cell_data[1]))
		if item_id in ["chair", "stool"]:
			var best_table: Dictionary = {}
			var best_distance := INF
			for table: Dictionary in tables:
				var table_cell_data: Array = table.get("cell", [0, 0])
				var table_cell := Vector2(int(table_cell_data[0]), int(table_cell_data[1]))
				var table_definition: Dictionary = DataRegistry.build_by_id.get(String(table.get("item", "")), {})
				var raw: Array = table_definition.get("footprint", [1, 1])
				var size := Vector2(int(raw[0]), int(raw[1]))
				if int(table.get("rotation", 0)) % 2 == 1:
					size = Vector2(size.y, size.x)
				var center := table_cell + (size - Vector2.ONE) * 0.5
				var distance := cell.distance_to(center)
				if distance < best_distance:
					best_distance = distance
					best_table = table
			if not best_table.is_empty() and best_distance <= 3.0:
				var table_cell_data: Array = best_table.get("cell", [0, 0])
				var table_cell := Vector2(int(table_cell_data[0]), int(table_cell_data[1]))
				var definition: Dictionary = DataRegistry.build_by_id.get(String(best_table.get("item", "")), {})
				var raw: Array = definition.get("footprint", [1, 1])
				var size := Vector2(int(raw[0]), int(raw[1]))
				if int(best_table.get("rotation", 0)) % 2 == 1:
					size = Vector2(size.y, size.x)
				var delta := cell - (table_cell + (size - Vector2.ONE) * 0.5)
				var local_delta := delta.rotated(float(int(best_table.get("rotation", 0))) * PI * 0.5)
				var slot := (1 if local_delta.x < 0.0 else 3) if absf(local_delta.x) > absf(local_delta.y) else (0 if local_delta.y < 0.0 else 2)
				record.support_uid = String(best_table.uid)
				record.attachment_slot = slot
				record.cell = best_table.cell.duplicate()
				record.rotation = posmod([0, 3, 2, 1][slot] + int(best_table.get("rotation", 0)), 4)
		elif item_id in ["cutting_board", "dish_rack", "dough", "oven", "pizza_oven"]:
			var support_uid := "support_%s" % String(record.uid)
			var support_item := "prep_counter" if item_id in ["cutting_board", "pizza_oven"] else "worktable"
			var support_origin := _migration_find_surface_origin(Vector2i(int(cell.x), int(cell.y)), support_item, int(record.get("rotation", 0)), String(record.uid), additions)
			additions.append({"uid":support_uid, "item":support_item, "cell":[support_origin.x, support_origin.y], "rotation":int(record.get("rotation", 0))})
			record.support_uid = support_uid
			record.attachment_slot = 0
			record.cell = [support_origin.x, support_origin.y]
		elif item_id == "prep_counter":
			additions.append({"uid":"prep_tool_%s" % String(record.uid), "item":"prep_bowl", "cell":[int(cell.x), int(cell.y)], "rotation":int(record.get("rotation", 0)), "support_uid":String(record.uid), "attachment_slot":0})
		elif item_id == "pass":
			additions.append({"uid":"pass_tool_%s" % String(record.uid), "item":"pass_tray", "cell":[int(cell.x), int(cell.y)], "rotation":int(record.get("rotation", 0)), "support_uid":String(record.uid), "attachment_slot":0})
		elif item_id == "storage" and not walls.is_empty():
			var best_wall: Dictionary = walls[0]
			var best_distance := INF
			for wall: Dictionary in walls:
				var wall_cell_data: Array = wall.get("cell", [0, 0])
				var distance := cell.distance_to(Vector2(int(wall_cell_data[0]), int(wall_cell_data[1])))
				if distance < best_distance:
					best_distance = distance
					best_wall = wall
			record.support_uid = String(best_wall.uid)
			record.attachment_slot = 0
			record.cell = best_wall.cell.duplicate()
			record.rotation = int(best_wall.get("rotation", 0))
	layout.append_array(additions)


func _migration_find_surface_origin(preferred: Vector2i, support_item: String, rotation_steps: int, ignored_uid: String, additions: Array[Dictionary]) -> Vector2i:
	var candidates: Array[Vector2i] = []
	for x: int in range(preferred.x, 18):
		candidates.append(Vector2i(x, preferred.y))
	for x: int in range(0, preferred.x):
		candidates.append(Vector2i(x, preferred.y))
	for y: int in range(8, 14):
		if y == preferred.y:
			continue
		for x: int in range(0, 18):
			candidates.append(Vector2i(x, y))
	var support_definition: Dictionary = DataRegistry.build_by_id.get(support_item, {})
	var support_raw: Array = support_definition.get("footprint", [1, 1])
	var support_size := Vector2i(int(support_raw[0]), int(support_raw[1]))
	if rotation_steps % 2 == 1:
		support_size = Vector2i(support_size.y, support_size.x)
	for candidate: Vector2i in candidates:
		if candidate.x < 0 or candidate.y < 0 or candidate.x + support_size.x > 18 or candidate.y + support_size.y > 14:
			continue
		var free := true
		for other: Dictionary in layout + additions:
			if String(other.get("uid", "")) == ignored_uid:
				continue
			var other_definition: Dictionary = DataRegistry.build_by_id.get(String(other.get("item", "")), {})
			if other_definition.is_empty() or not bool(other_definition.get("blocking", true)) or String(other_definition.get("placement", "cell")) != "cell":
				continue
			var other_cell_data: Array = other.get("cell", [-99, -99])
			var other_origin := Vector2i(int(other_cell_data[0]), int(other_cell_data[1]))
			var other_raw: Array = other_definition.get("footprint", [1, 1])
			var other_size := Vector2i(int(other_raw[0]), int(other_raw[1]))
			if int(other.get("rotation", 0)) % 2 == 1:
				other_size = Vector2i(other_size.y, other_size.x)
			var candidate_rect := Rect2i(candidate, support_size)
			if candidate_rect.intersects(Rect2i(other_origin, other_size)):
				free = false
				break
		if free:
			return candidate
	return preferred


func _migrate_attachment_integrity_v7() -> void:
	var records_by_uid: Dictionary = {}
	for record: Dictionary in layout:
		records_by_uid[String(record.get("uid", ""))] = record
	var additions: Array[Dictionary] = []
	var used_slots: Dictionary = {}
	for record: Dictionary in layout:
		var definition: Dictionary = DataRegistry.build_by_id.get(String(record.get("item", "")), {})
		if definition.is_empty():
			continue
		var placement := String(definition.get("placement", "cell"))
		if placement == "cell" and record.has("support_uid"):
			record.erase("support_uid")
			record.erase("attachment_slot")
			continue
		if placement != "surface":
			continue
		var support_uid := String(record.get("support_uid", ""))
		var support: Dictionary = records_by_uid.get(support_uid, {})
		var slot := int(record.get("attachment_slot", 0))
		var slots := _layout_surface_slots(definition, support, slot, int(record.get("rotation", 0)))
		if not support.is_empty() and _layout_slots_available(support_uid, slots, used_slots):
			_layout_mark_slots(support_uid, slots, used_slots)
			record.cell = support.get("cell", record.get("cell", [0, 0])).duplicate()
			continue
		var record_cell_data: Array = record.get("cell", [0, 0])
		var record_cell := Vector2i(int(record_cell_data[0]), int(record_cell_data[1]))
		var found_support: Dictionary = {}
		var found_slot := -1
		for candidate: Dictionary in layout + additions:
			var candidate_definition: Dictionary = DataRegistry.build_by_id.get(String(candidate.get("item", "")), {})
			if String(candidate_definition.get("support_kind", "")) != "worktop" or candidate.get("cell", []) != record.get("cell", []):
				continue
			var capacity_raw: Array = candidate_definition.get("footprint", [1, 1])
			for candidate_slot: int in int(capacity_raw[0]) * int(capacity_raw[1]):
				var candidate_slots := _layout_surface_slots(definition, candidate, candidate_slot, int(record.get("rotation", 0)))
				var candidate_uid := String(candidate.get("uid", ""))
				if not candidate_slots.is_empty() and _layout_slots_available(candidate_uid, candidate_slots, used_slots):
					found_support = candidate
					found_slot = candidate_slot
					break
			if not found_support.is_empty():
				break
		if found_support.is_empty():
			var item_raw: Array = definition.get("footprint", [1, 1])
			var support_item := "prep_counter" if int(item_raw[0]) > 1 or int(item_raw[1]) > 1 else "worktable"
			var support_origin := _migration_find_surface_origin(record_cell, support_item, int(record.get("rotation", 0)), String(record.get("uid", "")), additions)
			support_uid = "auto_support_%s" % String(record.get("uid", "tool"))
			var suffix := 2
			while records_by_uid.has(support_uid):
				support_uid = "auto_support_%s_%d" % [String(record.get("uid", "tool")), suffix]
				suffix += 1
			found_support = {"uid":support_uid, "item":support_item, "cell":[support_origin.x, support_origin.y], "rotation":int(record.get("rotation", 0))}
			additions.append(found_support)
			records_by_uid[support_uid] = found_support
			found_slot = 0
		support_uid = String(found_support.uid)
		slots = _layout_surface_slots(definition, found_support, found_slot, int(record.get("rotation", 0)))
		record.support_uid = support_uid
		record.attachment_slot = found_slot
		record.cell = found_support.cell.duplicate()
		_layout_mark_slots(support_uid, slots, used_slots)
	layout.append_array(additions)


func _layout_surface_slots(definition: Dictionary, support_record: Dictionary, attachment_slot: int, rotation_steps: int) -> Array[int]:
	var result: Array[int] = []
	if support_record.is_empty():
		return result
	var support_definition: Dictionary = DataRegistry.build_by_id.get(String(support_record.get("item", "")), {})
	if String(support_definition.get("support_kind", "")) != String(definition.get("requires_support", "")):
		return result
	var support_raw: Array = support_definition.get("footprint", [1, 1])
	var support_width := maxi(int(support_raw[0]), 1)
	var support_height := maxi(int(support_raw[1]), 1)
	var item_raw: Array = definition.get("footprint", [1, 1])
	var item_width := maxi(int(item_raw[0]), 1)
	var item_height := maxi(int(item_raw[1]), 1)
	if posmod(rotation_steps - int(support_record.get("rotation", 0)), 2) == 1:
		var swap := item_width
		item_width = item_height
		item_height = swap
	if attachment_slot < 0:
		return result
	var start_x := attachment_slot % support_width
	var start_y := attachment_slot / support_width
	if start_x + item_width > support_width or start_y + item_height > support_height:
		return result
	for y: int in item_height:
		for x: int in item_width:
			result.append((start_y + y) * support_width + start_x + x)
	return result


func _layout_slots_available(support_uid: String, slots: Array[int], used_slots: Dictionary) -> bool:
	if slots.is_empty():
		return false
	var occupied: Dictionary = used_slots.get(support_uid, {})
	for slot: int in slots:
		if occupied.has(slot):
			return false
	return true


func _layout_mark_slots(support_uid: String, slots: Array[int], used_slots: Dictionary) -> void:
	if not used_slots.has(support_uid):
		used_slots[support_uid] = {}
	for slot: int in slots:
		used_slots[support_uid][slot] = true


func _migrate_exterior_v8() -> void:
	var existing_uids: Dictionary = {}
	for record: Dictionary in layout:
		existing_uids[String(record.get("uid", ""))] = true
	for exterior_record: Dictionary in _initial_exterior_records():
		var uid := String(exterior_record.get("uid", ""))
		if uid.is_empty() or existing_uids.has(uid):
			continue
		layout.append(exterior_record.duplicate(true))
		existing_uids[uid] = true


func _initial_exterior_records() -> Array:
	# The sidewalk and road occupy y=-1..-3. Keep the initial clearing work
	# around the other three sides of the lot so it never blocks the queue.
	return [
		{"uid":"exterior_obstacle_tree_1", "item":"exterior_obstacle_tree_a", "cell":[-3, 2], "rotation":0},
		{"uid":"exterior_obstacle_tree_2", "item":"exterior_obstacle_tree_b", "cell":[23, 2], "rotation":1},
		{"uid":"exterior_obstacle_tree_3", "item":"exterior_obstacle_tree_c", "cell":[-3, 14], "rotation":2},
		{"uid":"exterior_obstacle_bush_1", "item":"exterior_obstacle_bush_a", "cell":[23, 15], "rotation":0},
		{"uid":"exterior_obstacle_bush_2", "item":"exterior_obstacle_bush_b", "cell":[5, 16], "rotation":3},
		{"uid":"exterior_obstacle_rock_1", "item":"exterior_obstacle_rock", "cell":[17, 16], "rotation":0}
	]


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
