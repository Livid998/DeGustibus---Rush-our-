class_name CustomerAgent
extends AnimatedAgent

var state := "entering"
var group_size := 1
var customer_type := "abituale"
var patience := 50.0
var budget := 40
var satisfaction := 1.0
var wait_time := 0.0
var state_elapsed := 0.0
var retry_time := 0.0
var eat_time := 0.0
var departure_failures := 0
var table: Dictionary = {}
var orders: Array[Dictionary] = []
var served_order_ids: Dictionary = {}
var group_models: Array[Node3D] = []

var _thought: Label3D
var _registered := false
var _seated := false
const CUSTOMER_APPEARANCES: Array[String] = [
	"Casual_Male", "Casual_Female", "Casual2_Male", "Casual2_Female", "Casual3_Male", "Casual3_Female",
	"Casual_Bald", "Suit_Male", "Suit_Female", "OldClassy_Male", "OldClassy_Female",
	"Doctor_Male_Young", "Doctor_Female_Young", "Doctor_Male_Old", "Doctor_Female_Old"
]
const MOBILE_CUSTOMER_APPEARANCES: Array[String] = [
	"Casual_Male", "Casual_Female", "Casual2_Male", "Casual2_Female",
	"Casual3_Male", "Casual3_Female", "Casual_Bald", "Suit_Female"
]


func setup(value_world: RestaurantWorld, size: int) -> void:
	world = value_world
	group_size = clampi(size, 1, 4)
	name = "CustomerGroup_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	customer_type = ["lavoratore", "famiglia", "studente", "gourmet", "abituale"].pick_random()
	patience = randf_range(42.0, 68.0)
	budget = randi_range(22, 48)
	movement_speed = randf_range(2.1, 2.65)
	configure_navigation(0.36 + float(group_size - 1) * 0.11, 1)
	# A group is represented by one navigation body.  Let the front of a wider
	# formation count as arrived instead of forcing its centre into an occupied
	# interaction point.
	arrival_tolerance = maxf(0.22, agent_radius * 0.65)
	global_position = world.find_safe_agent_position(global_position, self)
	_build_group_models()
	_create_thought()
	validate_animations()
	SimulationManager.register_customer(self)
	_registered = true
	_set_state("entering")
	if not move_to(world.waiting_position(self)):
		_set_state("waiting_table")
	else:
		play_animation("Walk")


func _exit_tree() -> void:
	if _registered and SimulationManager.customers.has(self):
		SimulationManager.unregister_customer(self, false)
	if world != null:
		world.release_table(self)
	super._exit_tree()


func _process(delta: float) -> void:
	var scaled := delta * SimulationManager.simulation_speed
	state_elapsed += scaled
	if GameState.restaurant_state == "closing" and not _seated and state in ["entering", "waiting_table", "walking_to_table"]:
		_leave_for_closing()
		return
	if state in ["waiting_table", "waiting_order", "waiting_food", "waiting_payment"]:
		wait_time += scaled
		var patience_pressure := clampf((state_elapsed - patience * 0.45) / maxf(patience, 1.0), 0.0, 1.0)
		satisfaction = maxf(satisfaction - scaled * (0.0015 + patience_pressure * 0.007), 0.3)
	if _seated and state in ["waiting_order", "waiting_food", "eating", "waiting_payment"]:
		_maintain_seated_pose()
	match state:
		"entering":
			if navigation_failed:
				_recover_at_waiting_position()
			elif advance_path(scaled):
				_find_table()
		"waiting_table":
			retry_time -= scaled
			if retry_time <= 0.0:
				retry_time = 1.0
				_find_table()
			if state == "waiting_table" and state_elapsed > patience * 1.25:
				_leave_lost("TROPPA ATTESA")
		"walking_to_table":
			if navigation_failed:
				_return_to_waiting_area()
			elif advance_path(scaled):
				_seat_group()
				play_animation("SitDown")
				_set_state("waiting_order")
				_thought.text = "MENU"
				_thought.visible = true
				SimulationManager.request_service(self, "take_order", get_service_position())
		"waiting_order":
			if state_elapsed > patience * 1.35:
				_leave_lost("NESSUN CAMERIERE")
		"waiting_food":
			if state_elapsed > patience * 2.15:
				_leave_lost("TROPPA ATTESA")
		"eating":
			eat_time -= scaled
			if eat_time <= 0.0:
				_thought.text = "CONTO"
				_thought.visible = true
				SimulationManager.request_service(self, "payment", get_service_position(), {"order_ids": orders.map(func(entry: Dictionary): return entry.id)})
				_set_state("waiting_payment")
		"waiting_payment":
			if state_elapsed > patience * 1.7:
				_leave_lost("CONTO IN RITARDO")
		"leaving":
			if _flat_distance(global_position, world.cell_to_world(world.entrance_cell)) <= RestaurantWorld.CELL_SIZE * 0.72:
				_finish_departure()
				return
			if navigation_failed:
				departure_failures += 1
				if departure_failures >= 3 or not move_to(world.cell_to_world(world.entrance_cell)):
					_finish_departure()
			elif advance_path(scaled):
				_finish_departure()


func service_completed(action: String, payload: Dictionary) -> void:
	match action:
		"take_order":
			if state != "waiting_order":
				return
			orders.clear()
			for _guest: int in group_size:
				var recipe := _choose_recipe()
				if recipe.is_empty():
					continue
				var order := SimulationManager.create_order(recipe.id, String(table.get("uid", "")), self)
				if not order.is_empty():
					orders.append(order)
			if orders.is_empty():
				_leave_lost("MENU NON DISPONIBILE")
				return
			_set_state("waiting_food")
			_thought.text = "%d COMANDE" % orders.size()
		"serve":
			if state != "waiting_food":
				return
			var order_id := String(payload.get("order_id", ""))
			if order_id.is_empty() or served_order_ids.has(order_id):
				return
			served_order_ids[order_id] = true
			_thought.text = "%d/%d SERVITI" % [served_order_ids.size(), orders.size()]
			if served_order_ids.size() >= orders.size():
				_set_state("eating")
				eat_time = randf_range(4.0, 7.0)
				_thought.text = "BUONO!"
		"payment":
			if state != "waiting_payment" or orders.is_empty():
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
			_begin_leaving(false)


func get_service_position() -> Vector3:
	if table.is_empty():
		return global_position
	return Vector3(table.get("service_position", global_position))


func _find_table() -> void:
	if state not in ["entering", "waiting_table"]:
		return
	table = world.request_table(self, group_size)
	if table.is_empty():
		_set_state("waiting_table", false)
		_thought.text = "ATTESA"
		_thought.visible = true
		return
	_set_state("walking_to_table")
	_thought.visible = false
	if not move_to(Vector3(table.approach_position)):
		_return_to_waiting_area()
	else:
		# Chaining entrance -> table happens in the same frame.  _complete_navigation
		# briefly selected Idle, so explicitly keep the legs walking across the
		# transition instead of letting the group slide for one rendered frame.
		play_animation("Walk")


func _return_to_waiting_area() -> void:
	world.release_table(self)
	table = {}
	_thought.text = "ATTESA"
	_thought.visible = true
	_set_state("entering")
	if not move_to(world.waiting_position(self)):
		_recover_at_waiting_position()
	else:
		play_animation("Walk")


func _recover_at_waiting_position() -> void:
	# Local avoidance can occasionally leave a large group on the wrong side of
	# a queue.  A failed route must never turn that group into a permanent
	# obstacle: give it a fresh reserved slot and settle it on the nearest safe
	# cell before resuming table search.
	world.release_waiting_position(self)
	var waiting_target := world.waiting_position(self)
	global_position = world.find_safe_agent_position(waiting_target, self)
	navigation_active = false
	navigation_failed = false
	velocity = Vector3.ZERO
	path.clear()
	path_index = 0
	_set_state("waiting_table")
	retry_time = 0.6
	play_animation("Idle")


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


func _leave_lost(message: String) -> void:
	if state == "leaving":
		return
	_thought.text = message
	_thought.visible = true
	SimulationManager.cancel_customer_work(self)
	if _registered:
		SimulationManager.unregister_customer(self, true)
		_registered = false
	_begin_leaving(true)


func _begin_leaving(_lost: bool) -> void:
	play_animation("StandUp")
	_stand_group_for_exit()
	# Once everyone has stood up, the chairs are available.  Keeping the table
	# reserved until the group reached the door stalled the entire dining room
	# whenever outgoing and incoming formations met in an aisle.
	world.release_table(self)
	table = {}
	_set_state("leaving")
	departure_failures = 0
	if not move_to(world.cell_to_world(world.entrance_cell)):
		departure_failures = 1
	else:
		play_animation("Walk")


func _leave_for_closing() -> void:
	if state == "leaving":
		return
	_thought.text = "CHIUSURA"
	_thought.visible = true
	SimulationManager.cancel_customer_work(self)
	_begin_leaving(false)


func _finish_departure() -> void:
	world.release_table(self)
	if _registered:
		SimulationManager.unregister_customer(self, false)
		_registered = false
	queue_free()


func _build_group_models() -> void:
	var available: Array[String] = []
	var appearance_pool := MOBILE_CUSTOMER_APPEARANCES if WebPlatformProfile.low_memory_mode() else CUSTOMER_APPEARANCES
	for appearance: String in appearance_pool:
		if ResourceLoader.exists("res://assets/characters/%s.gltf" % appearance):
			available.append(appearance)
	available.shuffle()
	for index: int in group_size:
		var appearance: String = available[index % available.size()] if not available.is_empty() else "Casual_Male"
		var tone: Color = SKIN_TONES.pick_random()
		var model: Node3D = add_character_model("res://assets/characters/%s.gltf" % appearance, Vector3.ZERO, tone)
		model.set_meta("appearance", appearance)
		model.set_meta("skin_tone", tone)
		group_models.append(model)
	_arrange_walking_formation()


func _arrange_walking_formation() -> void:
	for index: int in group_models.size():
		var row := index / 2
		var column := index % 2
		group_models[index].position = Vector3((float(column) - 0.5) * 0.74 if group_size > 1 else 0.0, 0.0, float(row) * 0.64)
		group_models[index].rotation = Vector3.ZERO


func _seat_group() -> void:
	var seats: Array = table.get("seat_positions", [])
	var center := Vector3(table.get("table_center", global_position))
	world.release_waiting_position(self)
	set_collision_enabled(false)
	global_position = center
	for index: int in mini(group_models.size(), seats.size()):
		var model := group_models[index]
		model.global_position = Vector3(seats[index]) + Vector3.UP * 0.015
		var direction := model.global_position.direction_to(center)
		model.global_rotation.y = atan2(direction.x, direction.z)
	_seated = true


func _stand_group_for_exit() -> void:
	var approach := Vector3(table.get("approach_position", global_position)) if not table.is_empty() else global_position
	global_position = world.find_safe_agent_position(approach, self)
	_arrange_walking_formation()
	set_collision_enabled(true)
	_seated = false


func _maintain_seated_pose() -> void:
	if state_elapsed < 0.7:
		return
	for player: AnimationPlayer in animation_players:
		var animation_name := resolve_animation(player, "SitDown")
		if animation_name.is_empty():
			continue
		if player.current_animation != animation_name:
			player.play(animation_name)
		var animation := player.get_animation(animation_name)
		if animation != null and (not player.is_playing() or player.current_animation_position >= animation.length - 0.04):
			player.seek(animation.length, true)
			player.pause()


func _set_state(value: String, reset_elapsed: bool = true) -> void:
	if state == value and not reset_elapsed:
		return
	state = value
	if reset_elapsed:
		state_elapsed = 0.0


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
