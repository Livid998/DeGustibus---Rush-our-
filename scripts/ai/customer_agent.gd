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
var table_route_failures := 0
var table: Dictionary = {}
var orders: Array[Dictionary] = []
var served_order_ids: Dictionary = {}
var group_models: Array[Node3D] = []
var dish_models: Dictionary = {}

var _thought: Label3D
var _registered := false
var _seated := false
var _lost_departure := false
var _take_order_committed := false
var _payment_committed := false
var _service_request_ids: Dictionary = {}
var _position_trail: Array[Vector3] = []
var _seated_pose_locked := false

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
	# The controller represents the party leader, not a circular body as wide
	# as the whole group. Followers use the leader's trail visually.
	# Every visible party member contributes its own avoidance point; the leader
	# no longer pretends to be one oversized circular group.
	configure_navigation(0.37, 1)
	arrival_tolerance = 0.24
	global_position = world.find_safe_agent_position(global_position, self)
	_build_group_models()
	# Re-evaluate the spawn after the followers exist, so the whole visible party
	# starts in free space instead of validating only its invisible controller.
	global_position = world.find_safe_agent_position(global_position, self)
	_arrange_waiting_formation(true)
	_create_thought()
	validate_animations()
	_randomize_animation_phases()
	_reset_position_trail()
	SimulationManager.register_customer(self)
	_registered = true
	_set_state("entering")
	if not move_to(world.waiting_position(self)):
		_recover_at_waiting_position()
	else:
		play_animation("Walk")


func _exit_tree() -> void:
	_clear_dishes()
	if _registered and SimulationManager.customers.has(self):
		SimulationManager.unregister_customer(self, false)
	if world != null:
		world.release_table(self)
	super._exit_tree()


func _process(delta: float) -> void:
	var scaled := delta * SimulationManager.simulation_speed
	state_elapsed += scaled
	if GameState.restaurant_state == "closing" and not _seated and state in ["entering", "waiting_table", "walking_to_table", "retrying_table_route", "seating"]:
		_leave_for_closing()
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
				_handle_table_route_failure()
			elif advance_path(scaled):
				_arrive_at_reserved_table()
		"retrying_table_route":
			retry_time -= scaled
			if retry_time <= 0.0:
				_retry_reserved_table_route()
		"seating":
			if not _owns_reserved_table() or not _table_seats_are_valid():
				_return_to_waiting_area()
			elif _advance_seating(scaled):
				_complete_seating()
		"waiting_order":
			if state_elapsed > patience * 1.35:
				_leave_lost("NESSUN CAMERIERE")
		"waiting_food":
			if state_elapsed > patience * 2.15:
				_leave_lost("TROPPA ATTESA")
		"eating":
			eat_time -= scaled
			if eat_time <= 0.0 and not _payment_committed:
				_thought.text = "CONTO"
				_thought.visible = true
				_set_state("waiting_payment")
				_request_service_once("payment", {"order_ids": orders.map(func(entry: Dictionary): return entry.id)})
		"waiting_payment":
			if state_elapsed > patience * 1.7:
				_leave_lost("CONTO IN RITARDO")
		"standing_to_leave":
			if state_elapsed >= 0.72:
				_start_exit_walk()
		"leaving":
			if _flat_distance(global_position, world.cell_to_world(world.entrance_cell)) <= RestaurantWorld.CELL_SIZE * 0.72:
				_finish_departure()
				return
			if navigation_failed:
				departure_failures += 1
				if departure_failures >= 3 or not move_to(world.cell_to_world(world.entrance_cell)):
					_finish_departure()
					return
				play_animation("Walk")
			elif advance_path(scaled):
				_finish_departure()
				return
	_update_group_visuals(scaled)


func service_completed(action: String, payload: Dictionary) -> void:
	match action:
		"take_order":
			if state != "waiting_order" or not _seated or _take_order_committed or not _owns_reserved_table():
				return
			_take_order_committed = true
			orders.clear()
			served_order_ids.clear()
			_clear_dishes()
			for guest_index: int in group_size:
				var recipe := _choose_recipe()
				if recipe.is_empty():
					continue
				var order := SimulationManager.create_order(recipe.id, String(table.get("uid", "")), self)
				if not order.is_empty():
					order.diner_index = guest_index
					orders.append(order)
			if orders.size() != group_size:
				_leave_lost("MENU NON DISPONIBILE")
				return
			_set_state("waiting_food")
			_thought.text = "%d COMANDE" % orders.size()
		"serve":
			if state != "waiting_food" or not _seated or not _owns_reserved_table():
				return
			var order_id := String(payload.get("order_id", ""))
			var order := _local_order(order_id)
			if order.is_empty() or served_order_ids.has(order_id):
				return
			if not _order_is_ready_to_serve(order_id):
				return
			served_order_ids[order_id] = true
			_show_dish(order)
			_thought.text = "%d/%d SERVITI" % [served_order_ids.size(), orders.size()]
			if served_order_ids.size() == orders.size():
				_set_state("eating")
				eat_time = randf_range(4.0, 7.0)
				_thought.text = "BUONO!"
		"payment":
			if state != "waiting_payment" or orders.is_empty() or _payment_committed or served_order_ids.size() != orders.size():
				return
			_payment_committed = true
			var total := 0
			for order: Dictionary in orders:
				if SimulationManager.orders.has(String(order.id)):
					SimulationManager.complete_order_payment(String(order.id), satisfaction)
				total += int(GameState.menu.get(String(order.recipe_id), {}).get("price", 0))
			_thought.text = "+%d" % total
			var coin_tween := create_tween()
			coin_tween.set_parallel(true)
			coin_tween.tween_property(_thought, "position:y", 3.15, 0.8).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			coin_tween.tween_property(_thought, "modulate:a", 0.0, 0.8).set_delay(0.25)
			AudioManager.play_feedback("income")
			_begin_leaving(false)


func get_service_position() -> Vector3:
	if table.is_empty() or not _owns_reserved_table():
		return global_position
	return Vector3(table.get("service_position", global_position))


func accepts_service_action(action: String, payload: Dictionary = {}) -> bool:
	match action:
		"take_order":
			return state == "waiting_order" and _seated and not _take_order_committed and _owns_reserved_table()
		"serve":
			var order_id := String(payload.get("order_id", ""))
			return state == "waiting_food" and _seated and _owns_reserved_table() and not served_order_ids.has(order_id) and not _local_order(order_id).is_empty() and _order_is_ready_to_serve(order_id)
		"payment":
			return state == "waiting_payment" and _seated and not _payment_committed and served_order_ids.size() == orders.size() and not orders.is_empty()
	return false


func _request_service_once(action: String, payload: Dictionary = {}) -> void:
	var previous_id := String(_service_request_ids.get(action, ""))
	if not previous_id.is_empty() and SimulationManager.service_tasks.has(previous_id):
		var previous: Dictionary = SimulationManager.service_tasks[previous_id]
		if String(previous.get("state", "")) not in ["completed", "cancelled"]:
			return
	var task := SimulationManager.request_service(self, action, get_service_position(), payload)
	if not task.is_empty():
		_service_request_ids[action] = String(task.id)


func _find_table() -> void:
	if state not in ["entering", "waiting_table"] or GameState.restaurant_state != "open":
		return
	table = world.request_table(self, group_size)
	if table.is_empty():
		_set_state("waiting_table", false)
		_thought.text = "ATTESA"
		_thought.visible = true
		return
	table_route_failures = 0
	_set_state("walking_to_table")
	# A customer with a reserved chair has right of way over staff in the aisle.
	# World/furniture collisions remain active; only temporary agent blocking is soft.
	collision_mask = 1
	_thought.visible = false
	if not move_to(Vector3(table.approach_position)):
		_handle_table_route_failure()
	else:
		play_animation("Walk")


func _arrive_at_reserved_table() -> void:
	if not _owns_reserved_table() or not _table_seats_are_valid():
		_return_to_waiting_area()
		return
	if not _begin_seating():
		_return_to_waiting_area()
		return
	_set_state("seating")
	play_animation("Walk")


func _handle_table_route_failure() -> void:
	table_route_failures += 1
	navigation_active = false
	navigation_failed = false
	velocity = Vector3.ZERO
	play_animation("Idle")
	if table_route_failures > 3 or not _owns_reserved_table():
		_return_to_waiting_area()
		return
	_set_state("retrying_table_route")
	retry_time = 0.55 + float(table_route_failures) * 0.3


func _retry_reserved_table_route() -> void:
	if not _owns_reserved_table() or table_route_failures > 3:
		_return_to_waiting_area()
		return
	_set_state("walking_to_table")
	if not move_to(Vector3(table.approach_position)):
		_handle_table_route_failure()
	else:
		play_animation("Walk")


func _return_to_waiting_area() -> void:
	world.release_table(self)
	collision_mask = 3
	table = {}
	table_route_failures = 0
	_thought.text = "ATTESA"
	_thought.visible = true
	_set_state("entering")
	if not move_to(world.waiting_position(self)):
		_recover_at_waiting_position()
	else:
		play_animation("Walk")


func _recover_at_waiting_position() -> void:
	collision_mask = 3
	world.release_waiting_position(self)
	var waiting_target := world.waiting_position(self)
	global_position = world.find_safe_agent_position(waiting_target, self)
	navigation_active = false
	navigation_failed = false
	velocity = Vector3.ZERO
	path.clear()
	path_index = 0
	_reset_position_trail()
	_set_state("waiting_table")
	retry_time = 0.7
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
	if state in ["standing_to_leave", "leaving"]:
		return
	_thought.text = message
	_thought.visible = true
	SimulationManager.cancel_customer_work(self)
	_begin_leaving(true)


func _begin_leaving(lost: bool) -> void:
	if state in ["standing_to_leave", "leaving"]:
		return
	_lost_departure = _lost_departure or lost
	_clear_dishes()
	if _seated:
		play_animation("StandUp")
		_set_state("standing_to_leave")
		return
	_start_exit_walk()


func _leave_for_closing() -> void:
	if state in ["standing_to_leave", "leaving"]:
		return
	_thought.text = "CHIUSURA"
	_thought.visible = true
	SimulationManager.cancel_customer_work(self)
	_begin_leaving(false)


func _start_exit_walk() -> void:
	if _seated:
		_stand_group_for_exit()
	else:
		world.release_waiting_position(self)
		_arrange_waiting_formation(true)
	world.release_table(self)
	table = {}
	_set_state("leaving")
	departure_failures = 0
	set_collision_enabled(true)
	collision_mask = 3
	_reset_position_trail()
	if not move_to(world.cell_to_world(world.entrance_cell)):
		departure_failures = 1
	else:
		play_animation("Walk")


func _finish_departure() -> void:
	world.release_table(self)
	_clear_dishes()
	if _registered:
		SimulationManager.unregister_customer(self, _lost_departure)
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
		model.top_level = true
		model.set_meta("appearance", appearance)
		model.set_meta("skin_tone", tone)
		group_models.append(model)
	_arrange_waiting_formation(true)


func _randomize_animation_phases() -> void:
	for player: AnimationPlayer in animation_players:
		if player.current_animation.is_empty():
			continue
		var animation := player.get_animation(player.current_animation)
		if animation != null and animation.length > 0.15:
			player.seek(randf_range(0.0, minf(animation.length * 0.8, 0.65)), true)


func _reset_position_trail() -> void:
	_position_trail.clear()
	var forward := Vector3(sin(rotation.y), 0.0, cos(rotation.y))
	for index: int in 36:
		# Seed an actual queue behind the leader. Repeating the same point made
		# followers 2 and 4 overlap until enough live trail samples accumulated.
		_position_trail.append(global_position - forward * float(35 - index) * 0.055)


func _update_group_visuals(delta: float) -> void:
	if group_models.is_empty():
		return
	if state == "seating":
		return
	if _seated:
		_enforce_seat_alignment()
		return
	if navigation_active and state in ["entering", "walking_to_table", "leaving"]:
		if _position_trail.is_empty() or _position_trail.back().distance_to(global_position) >= 0.055:
			_position_trail.append(global_position)
			while _position_trail.size() > 64:
				_position_trail.pop_front()
		var last := _position_trail.size() - 1
		for index: int in group_models.size():
			var trail_index := maxi(last - index * 14, 0)
			var target := _position_trail[trail_index]
			var before := _position_trail[maxi(trail_index - 1, 0)]
			var after := _position_trail[mini(trail_index + 1, last)]
			var direction := before.direction_to(after)
			direction.y = 0.0
			if direction.length_squared() <= 0.001:
				direction = Vector3(sin(rotation.y), 0.0, cos(rotation.y))
			var lateral := Vector3(-direction.z, 0.0, direction.x)
			if index > 0:
				target += lateral * (0.20 if index % 2 == 0 else -0.20)
			_move_group_model_toward(group_models[index], target, direction, delta, false)
	else:
		_arrange_waiting_formation(false, delta)


func get_avoidance_points() -> Array[Vector3]:
	var result: Array[Vector3] = []
	if _seated or not is_collision_enabled():
		return result
	for model: Node3D in group_models:
		if is_instance_valid(model) and model.visible:
			result.append(model.global_position)
	if result.is_empty():
		result.append(global_position)
	return result


func _move_group_model_toward(model: Node3D, target: Vector3, direction: Vector3, delta: float, snap: bool = false) -> void:
	target.y = CHARACTER_FOOT_LIFT
	if snap:
		model.global_position = target
	else:
		var travel := minf(model.global_position.distance_to(target), movement_speed * delta * 1.15)
		var steps := maxi(ceili(travel / 0.16), 1)
		for _step: int in steps:
			var candidate := model.global_position.move_toward(target, travel / float(steps))
			if world != null and not world.can_visual_person_step(self, model.global_position, candidate, agent_radius):
				break
			model.global_position = candidate
	if direction.length_squared() > 0.001:
		model.global_rotation.y = lerp_angle(model.global_rotation.y, atan2(direction.x, direction.z), 1.0 - exp(-delta * 12.0))


func _arrange_waiting_formation(instant: bool = false, delta: float = 0.1) -> void:
	var offsets := [Vector3.ZERO, Vector3(-0.72, 0.0, -0.52), Vector3(0.72, 0.0, -0.52), Vector3(0.0, 0.0, -1.18)]
	for index: int in group_models.size():
		var target: Vector3 = global_position + Vector3(offsets[index]).rotated(Vector3.UP, rotation.y)
		var direction := Vector3(sin(rotation.y), 0.0, cos(rotation.y))
		_move_group_model_toward(group_models[index], target, direction, delta, instant)


func _table_seats_are_valid() -> bool:
	if not _owns_reserved_table():
		return false
	var assignments: Array = table.get("seat_assignments", [])
	if assignments.size() != group_size:
		return false
	for assignment: Dictionary in assignments:
		var chair := world.placed_objects.get(String(assignment.get("chair_uid", ""))) as PlacedObject
		if chair == null or not is_instance_valid(chair) or chair.support_uid != String(table.uid):
			return false
	return true


func _seat_group() -> bool:
	if not _table_seats_are_valid():
		return false
	world.release_waiting_position(self)
	set_collision_enabled(false)
	global_position = Vector3(table.table_center)
	_seated = true
	_enforce_seat_alignment()
	return true


func _begin_seating() -> bool:
	if not _table_seats_are_valid():
		return false
	world.release_waiting_position(self)
	set_collision_enabled(false)
	velocity = Vector3.ZERO
	return true


func _advance_seating(delta: float) -> bool:
	var assignments: Array = table.get("seat_assignments", [])
	var center := Vector3(table.get("table_center", global_position))
	var all_arrived := assignments.size() == group_models.size()
	for index: int in mini(group_models.size(), assignments.size()):
		var model := group_models[index]
		var target := Vector3(assignments[index].position)
		target.y = CHARACTER_FOOT_LIFT
		var distance := model.global_position.distance_to(target)
		if distance > 0.045:
			all_arrived = false
			model.global_position = model.global_position.move_toward(target, minf(distance, movement_speed * delta * 0.92))
		var direction := model.global_position.direction_to(center)
		if direction.length_squared() > 0.001:
			model.global_rotation.y = lerp_angle(model.global_rotation.y, atan2(direction.x, direction.z), 1.0 - exp(-delta * 10.0))
	return all_arrived


func _complete_seating() -> void:
	global_position = Vector3(table.table_center)
	_seated = true
	_seated_pose_locked = false
	_enforce_seat_alignment()
	play_animation("SitDown")
	_set_state("waiting_order")
	_thought.text = "MENU"
	_thought.visible = true
	_request_service_once("take_order")


func _enforce_seat_alignment() -> void:
	var assignments: Array = table.get("seat_assignments", [])
	var center := Vector3(table.get("table_center", global_position))
	for index: int in mini(group_models.size(), assignments.size()):
		var model := group_models[index]
		var position := Vector3(assignments[index].position)
		position.y = CHARACTER_FOOT_LIFT
		model.global_position = position
		var direction := position.direction_to(center)
		var facing := atan2(direction.x, direction.z)
		# While there is no food, diners stay in a settled seated pose and make
		# small conversational turns. No eating/pick-up loop is played without a dish.
		if state in ["waiting_order", "waiting_food"] and group_size > 1:
			facing += sin(state_elapsed * 0.72 + float(index) * 1.9) * 0.105
		model.global_rotation.y = facing


func _stand_group_for_exit() -> void:
	var approach := Vector3(table.get("approach_position", global_position))
	_seated = false
	set_collision_enabled(true)
	global_position = approach
	_arrange_waiting_formation(true)
	global_position = world.find_safe_agent_position(approach, self)
	_arrange_waiting_formation(true)
	_reset_position_trail()


func _maintain_seated_pose() -> void:
	_enforce_seat_alignment()
	if state == "standing_to_leave" or state_elapsed < 0.7:
		return
	var all_locked := true
	for player: AnimationPlayer in animation_players:
		var animation_name := resolve_animation(player, "SitDown")
		if animation_name.is_empty():
			continue
		if not _seated_pose_locked and player.current_animation != animation_name:
			player.play(animation_name)
		var animation := player.get_animation(animation_name)
		if animation != null and (not player.is_playing() or player.current_animation_position >= animation.length - 0.04):
			player.seek(animation.length, true)
			player.pause()
		elif not _seated_pose_locked:
			all_locked = false
	if all_locked:
		_seated_pose_locked = true


func _show_dish(order: Dictionary) -> void:
	var order_id := String(order.get("id", ""))
	if order_id.is_empty() or dish_models.has(order_id):
		return
	var recipe: Dictionary = DataRegistry.recipes_by_id.get(String(order.get("recipe_id", "")), {})
	var model_path := ""
	var steps: Array = recipe.get("steps", [])
	for index: int in range(steps.size() - 1, -1, -1):
		model_path = String(steps[index].get("model", ""))
		if not model_path.is_empty():
			break
	if model_path.is_empty():
		return
	var dish := ModelFactory.instantiate_model(model_path, 0.55)
	ModelFactory.align_visual_to_grid_origin(dish)
	add_child(dish)
	dish.top_level = true
	var diner_index := clampi(int(order.get("diner_index", 0)), 0, group_size - 1)
	var assignments: Array = table.get("seat_assignments", [])
	var center := Vector3(table.get("table_center", global_position))
	var seat_position := Vector3(assignments[diner_index].position) if diner_index < assignments.size() else center
	var dish_position := center.lerp(seat_position, 0.43)
	dish_position.y = float(table.get("table_surface_y", 1.0))
	dish.global_position = dish_position
	dish.global_rotation.y = atan2(center.direction_to(seat_position).x, center.direction_to(seat_position).z)
	ModelFactory.set_shadow_casting(dish, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	dish_models[order_id] = dish


func _clear_dishes() -> void:
	for dish: Node3D in dish_models.values():
		if is_instance_valid(dish):
			dish.queue_free()
	dish_models.clear()


func _local_order(order_id: String) -> Dictionary:
	for order: Dictionary in orders:
		if String(order.get("id", "")) == order_id:
			return order
	return {}


func _order_is_ready_to_serve(order_id: String) -> bool:
	if not SimulationManager.orders.has(order_id):
		return false
	var order: Dictionary = SimulationManager.orders[order_id]
	return order.get("customer") == self and bool(order.get("ready", false)) and String(order.get("state", "")) == "at_pass"


func _owns_reserved_table() -> bool:
	return world != null and world.customer_owns_table(self, String(table.get("uid", "")))


func _set_state(value: String, reset_elapsed: bool = true) -> void:
	# Departure is terminal. No delayed waiter callback, failed route or table
	# retry may ever put a customer back into the dining lifecycle.
	if state == "leaving" and value != "leaving":
		return
	if state == "standing_to_leave" and value not in ["standing_to_leave", "leaving"]:
		return
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
