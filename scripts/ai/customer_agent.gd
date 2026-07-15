class_name CustomerAgent
extends AnimatedAgent

var state := "entering"
var group_size := 1
var customer_type := "abituale"
var patience := 50.0
var budget := 40
var satisfaction := 1.0
var wait_time := 0.0
var eat_time := 0.0
var table: Dictionary = {}
var orders: Array[Dictionary] = []
var served_order_ids: Dictionary = {}
var group_models: Array[Node3D] = []

var _thought: Label3D
var _appearance_names := ["Casual_Male", "Casual_Female", "Casual2_Male", "Casual2_Female", "Casual3_Male", "Casual3_Female"]


func setup(value_world: RestaurantWorld, size: int) -> void:
	world = value_world
	group_size = clampi(size, 1, 4)
	name = "CustomerGroup_%d" % Time.get_ticks_msec()
	customer_type = ["lavoratore", "famiglia", "studente", "gourmet", "abituale"].pick_random()
	patience = randf_range(42.0, 68.0)
	budget = randi_range(22, 48)
	movement_speed = randf_range(2.1, 2.65)
	_build_group_models()
	_create_thought()
	validate_animations()
	SimulationManager.register_customer(self)
	move_to(world.waiting_position(self))


func _exit_tree() -> void:
	if SimulationManager.customers.has(self):
		SimulationManager.unregister_customer(self, false)


func _process(delta: float) -> void:
	var scaled := delta * SimulationManager.simulation_speed
	if state in ["waiting_table", "waiting_order", "waiting_food"]:
		wait_time += scaled
		if wait_time > patience:
			satisfaction = maxf(satisfaction - scaled * 0.006, 0.45)
	match state:
		"entering":
			if advance_path(scaled):
				_find_table()
		"waiting_table":
			if wait_time > 4.0:
				_find_table()
			if wait_time > patience * 1.35:
				_leave_lost()
		"walking_to_table":
			if advance_path(scaled):
				_seat_group()
				play_animation("SitDown")
				state = "waiting_order"
				_thought.text = "MENU"
				_thought.visible = true
				SimulationManager.request_service(self, "take_order", get_service_position())
		"waiting_food":
			pass
		"eating":
			eat_time -= scaled
			if eat_time <= 0.0:
				_thought.text = "CONTO"
				_thought.visible = true
				SimulationManager.request_service(self, "payment", get_service_position(), {"order_ids": orders.map(func(entry: Dictionary): return entry.id)})
				state = "waiting_payment"
		"leaving":
			if advance_path(scaled):
				world.release_table(self)
				SimulationManager.unregister_customer(self, false)
				queue_free()


func service_completed(action: String, payload: Dictionary) -> void:
	match action:
		"take_order":
			orders.clear()
			for _guest: int in group_size:
				var recipe := _choose_recipe()
				if recipe.is_empty():
					continue
				orders.append(SimulationManager.create_order(recipe.id, String(table.uid), self))
			if orders.is_empty():
				_leave_lost()
				return
			state = "waiting_food"
			_thought.text = "%d COMANDE" % orders.size()
		"serve":
			var order_id := String(payload.get("order_id", ""))
			if order_id.is_empty() or served_order_ids.has(order_id):
				return
			served_order_ids[order_id] = true
			_thought.text = "%d/%d SERVITI" % [served_order_ids.size(), orders.size()]
			if served_order_ids.size() >= orders.size():
				state = "eating"
				eat_time = randf_range(4.0, 7.0)
				_thought.text = "BUONO!"
		"payment":
			if orders.is_empty():
				return
			var total := 0
			for order: Dictionary in orders:
				SimulationManager.complete_order_payment(order.id, satisfaction)
				total += int(GameState.menu[order.recipe_id].price)
			_thought.text = "+%d" % total
			var coin_tween := create_tween()
			coin_tween.set_parallel(true)
			coin_tween.tween_property(_thought, "position:y", 3.15, 0.8).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			coin_tween.tween_property(_thought, "modulate:a", 0.0, 0.8).set_delay(0.25)
			AudioManager.play_feedback("income")
			play_animation("StandUp")
			_arrange_walking_formation()
			state = "leaving"
			move_to(world.cell_to_world(world.entrance_cell))


func get_service_position() -> Vector3:
	if table.is_empty():
		return global_position
	return Vector3(table.service_position)


func _find_table() -> void:
	table = world.request_table(self, group_size)
	if table.is_empty():
		state = "waiting_table"
		_thought.text = "ATTESA"
		_thought.visible = true
		return
	state = "walking_to_table"
	_thought.visible = false
	move_to(Vector3(table.seat_position))


func _choose_recipe() -> Dictionary:
	var candidates: Array = []
	var weights: Array[float] = []
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		var price := int(GameState.menu[recipe.id].price)
		if price <= budget and not bool(GameState.menu[recipe.id].sold_out):
			candidates.append(recipe)
			var weight := float(recipe.get("popularity", 1.0))
			var recipe_id := String(recipe.id)
			match customer_type:
				"famiglia":
					if "pizza" in recipe_id or "burger" in recipe_id:
						weight *= 1.7
				"studente":
					weight *= clampf(32.0 / maxf(float(price), 1.0), 0.7, 1.8)
				"gourmet":
					if recipe_id in ["beef_stew", "steak_plate", "mixed_sundae"]:
						weight *= 1.8
				"lavoratore":
					var duration := 0.0
					for step: Dictionary in recipe.steps:
						duration += float(step.get("time", 0.0))
					weight *= clampf(12.0 / maxf(duration, 1.0), 0.75, 1.5)
			weights.append(weight)
	if candidates.is_empty():
		return {}
	var total := 0.0
	for weight: float in weights:
		total += weight
	var roll := randf() * total
	for index: int in candidates.size():
		roll -= weights[index]
		if roll <= 0.0:
			return candidates[index]
	return candidates.back()


func _leave_lost() -> void:
	state = "leaving"
	_thought.text = "TROPPA ATTESA"
	_thought.visible = true
	world.release_table(self)
	SimulationManager.unregister_customer(self, true)
	_arrange_walking_formation()
	move_to(world.cell_to_world(world.entrance_cell))


func _build_group_models() -> void:
	for index: int in group_size:
		var model := add_character_model("res://assets/characters/%s.gltf" % _appearance_names.pick_random())
		group_models.append(model)
	_arrange_walking_formation()


func _arrange_walking_formation() -> void:
	for index: int in group_models.size():
		var row := index / 2
		var column := index % 2
		group_models[index].position = Vector3((float(column) - 0.5) * 0.72 if group_size > 1 else 0.0, 0, float(row) * 0.62)
		group_models[index].rotation = Vector3.ZERO


func _seat_group() -> void:
	var seats: Array = table.get("seat_positions", [])
	var center := Vector3(table.get("table_center", global_position))
	for index: int in mini(group_models.size(), seats.size()):
		var model := group_models[index]
		model.global_position = Vector3(seats[index])
		var direction := model.global_position.direction_to(center)
		model.global_rotation.y = atan2(direction.x, direction.z)


func _create_thought() -> void:
	_thought = Label3D.new()
	_thought.font = GameFonts.medium()
	_thought.position = Vector3(0, 2.35, 0)
	_thought.font_size = 21
	_thought.outline_size = 9
	_thought.modulate = Color("fff8e8")
	_thought.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_thought.no_depth_test = true
	add_child(_thought)
