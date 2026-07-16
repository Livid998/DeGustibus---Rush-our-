class_name CustomerAgent
extends AnimatedAgent

## Party controller.  Every visible guest is a CustomerPersonAgent with its own
## body, route and animation timeline; this node owns only the shared table,
## orders, patience and lifecycle barriers.

var state := "queueing"
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
var people: Array[CustomerPersonAgent] = []
var dish_models: Dictionary = {}

var _thought: Label3D
var _registered := false
var _seated := false
var _lost_departure := false
var _take_order_committed := false
var _payment_committed := false
var _service_request_ids: Dictionary = {}
var _queue_refresh := 0.0
var _launch_cursor := 0
var _launch_clock := 0.0
var _seat_cursor := 0
var _active_seating := -1
var _exit_cursor := 0
var _exit_stage := ""
var _door_released := false
var _outside_departure := false
var _dirty_transferred := false
var _diner_eat_remaining: Dictionary = {}
var _diner_finished: Dictionary = {}

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
	name = "CustomerParty_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	customer_type = ["lavoratore", "famiglia", "studente", "gourmet", "abituale"].pick_random()
	patience = randf_range(58.0, 82.0)
	budget = randi_range(22, 48)
	world.enqueue_customer(self)
	_build_people()
	_create_thought()
	SimulationManager.register_customer(self)
	_registered = true
	_set_state("queueing")
	_refresh_queue_targets(true)


func _exit_tree() -> void:
	if world != null:
		world.dequeue_customer(self)
		world.finish_customer_exit(self)
		if not _dirty_transferred:
			_clear_dishes()
		world.release_table(self)
	if _registered and SimulationManager.customers.has(self):
		SimulationManager.unregister_customer(self, false)
	_registered = false
	for person: CustomerPersonAgent in people:
		if is_instance_valid(person):
			person.shutdown_navigation()
	super._exit_tree()


func _process(delta: float) -> void:
	var scaled := delta * SimulationManager.simulation_speed
	state_elapsed += scaled
	for person: CustomerPersonAgent in people:
		if is_instance_valid(person):
			person.tick_motion(scaled)
	_update_controller_anchor()
	if GameState.restaurant_state == "closing" and state in ["queueing", "waiting_table", "admitting"] and not _seated:
		_leave_for_closing()
	if state in ["queueing", "waiting_table", "waiting_order", "waiting_food", "eating", "waiting_payment"]:
		wait_time += scaled
		var pressure := clampf((state_elapsed - patience * 0.55) / maxf(patience, 1.0), 0.0, 1.0)
		satisfaction = maxf(satisfaction - scaled * (0.0012 + pressure * 0.0055), 0.3)
	match state:
		"queueing", "waiting_table":
			_update_queue(scaled)
		"admitting", "walking_to_table", "seating":
			_update_admission_and_seating(scaled)
		"waiting_order":
			_set_people_mode("conversation", false)
			if state_elapsed > patience * 1.45:
				_leave_lost("NESSUN CAMERIERE")
		"waiting_food", "eating":
			_update_dining(scaled)
			if state == "waiting_food" and state_elapsed > patience * 2.4:
				_leave_lost("TROPPA ATTESA")
		"waiting_payment":
			_set_people_mode("conversation", false)
			if state_elapsed > patience * 1.8:
				_leave_lost("CONTO IN RITARDO")
		"waiting_exit_door":
			if world.try_begin_customer_exit(self):
				_begin_exit_sequence()
		"leaving":
			_update_exit_sequence()


func _build_people() -> void:
	var pool := MOBILE_CUSTOMER_APPEARANCES if WebPlatformProfile.low_memory_mode() else CUSTOMER_APPEARANCES
	var available: Array[String] = []
	for appearance: String in pool:
		if ResourceLoader.exists("res://assets/characters/%s.gltf" % appearance):
			available.append(appearance)
	available.shuffle()
	var queue_targets := world.customer_queue_positions(self)
	var spawn: Vector3 = Vector3(queue_targets[0]) if not queue_targets.is_empty() else world.customer_spawn_position(self)
	global_position = spawn
	for index: int in group_size:
		var person := CustomerPersonAgent.new()
		add_child(person)
		person.top_level = true
		var member_target: Vector3 = Vector3(queue_targets[index]) if index < queue_targets.size() else spawn + Vector3(float(index) * RestaurantWorld.CELL_SIZE, 0.0, 0.0)
		person.global_position = member_target + Vector3(0.72, 0.0, 0.0)
		var appearance: String = available[index % available.size()] if not available.is_empty() else "Casual_Male"
		var tone: Color = SKIN_TONES.pick_random()
		person.setup_person(self, world, index, appearance, tone)
		person.visual_model.set_meta("appearance", appearance)
		person.visual_model.set_meta("skin_tone", tone)
		people.append(person)
		group_models.append(person.visual_model)


func _update_controller_anchor() -> void:
	if people.is_empty() or not is_instance_valid(people[0]):
		return
	global_position = people[0].global_position


func _refresh_queue_targets(force: bool = false) -> void:
	var positions := world.customer_queue_positions(self)
	for index: int in mini(positions.size(), people.size()):
		var person := people[index]
		var target := Vector3(positions[index])
		if force or person.phase == "route_failed" or person.target_tag != "queue" or _flat_distance(person.destination, target) > 0.18:
			person.walk_to_position(target, "queue", float(index) * 0.12)


func _update_queue(delta: float) -> void:
	_queue_refresh -= delta
	if _queue_refresh <= 0.0:
		_queue_refresh = 0.45
		_refresh_queue_targets()
	if not _all_people_near(world.customer_queue_positions(self), 0.28):
		return
	if not world.customer_is_queue_head(self):
		_set_state("queueing", false)
		return
	if table.is_empty():
		table = world.request_table(self, group_size)
	if table.is_empty():
		_set_state("waiting_table", false)
		_thought.text = "ATTESA TAVOLO"
		_thought.visible = true
		if state_elapsed > patience * 1.35:
			_leave_lost("TROPPA ATTESA")
		return
	if not world.try_begin_customer_entry(self):
		_thought.text = "ATTENDO USCITA"
		_thought.visible = true
		return
	_begin_admission()


func _begin_admission() -> void:
	var assignments: Array = table.get("seat_assignments", [])
	assignments.sort_custom(func(a: Dictionary, b: Dictionary):
		return Vector3(a.get("staging_position", a.position)).distance_to(world.cell_to_world(world.entrance_cell)) > Vector3(b.get("staging_position", b.position)).distance_to(world.cell_to_world(world.entrance_cell)))
	table.seat_assignments = assignments
	var seat_positions: Array[Vector3] = []
	for assignment: Dictionary in assignments:
		seat_positions.append(Vector3(assignment.position))
	table.seat_positions = seat_positions
	_launch_cursor = 0
	_launch_clock = 0.0
	_seat_cursor = 0
	_active_seating = -1
	_door_released = false
	_thought.visible = false
	_set_state("admitting")


func _update_admission_and_seating(delta: float) -> void:
	var assignments: Array = table.get("seat_assignments", [])
	if assignments.size() != people.size() or not _owns_reserved_table():
		_return_to_queue()
		return
	# Admit exactly one body through the threshold at a time.  Only after that
	# person reaches the inside waypoint may it continue to its own chair and
	# the next party member receive the doorway.
	if _launch_cursor < people.size():
		var entering_person := people[_launch_cursor]
		var outside_tag := "entry_outside_%d" % _launch_cursor
		var entry_tag := "entry_door_%d" % _launch_cursor
		if entering_person.target_tag != outside_tag and entering_person.target_tag != entry_tag:
			entering_person.walk_to_position(world.customer_outside_door_position(_launch_cursor), outside_tag, randf_range(0.04, 0.12))
		elif entering_person.is_at(outside_tag):
			entering_person.walk_to_position(world.customer_inside_door_position(_launch_cursor), entry_tag, randf_range(0.04, 0.12))
		elif entering_person.is_at(entry_tag):
			var assignment: Dictionary = assignments[_launch_cursor]
			var target := Vector3(assignment.get("staging_position", assignment.position))
			entering_person.walk_to_position(target, "seat_stage_%d" % _launch_cursor, randf_range(0.05, 0.14))
			_launch_cursor += 1
			_set_state("walking_to_table", false)
		elif entering_person.phase == "route_failed":
			var retry_target := world.customer_inside_door_position(_launch_cursor) if entering_person.target_tag == entry_tag else world.customer_outside_door_position(_launch_cursor)
			entering_person.walk_to_position(retry_target, entering_person.target_tag, 0.18)
	if not _door_released and _launch_cursor == people.size():
		var everybody_inside := true
		for person: CustomerPersonAgent in people:
			if not world.position_is_inside_restaurant(person.global_position):
				everybody_inside = false
				break
		if everybody_inside:
			world.dequeue_customer(self)
			world.finish_customer_entry(self)
			_door_released = true
	if _active_seating >= 0:
		var active := people[_active_seating]
		if active.phase == "seated":
			_active_seating = -1
			_seat_cursor += 1
	if _active_seating < 0 and _seat_cursor < people.size():
		var candidate := people[_seat_cursor]
		if candidate.is_at("seat_stage_%d" % _seat_cursor):
			candidate.begin_seating(assignments[_seat_cursor], Vector3(table.table_center))
			_active_seating = _seat_cursor
			_set_state("seating", false)
		elif candidate.phase == "route_failed":
			candidate.walk_to_position(Vector3(assignments[_seat_cursor].staging_position), "seat_stage_%d" % _seat_cursor, 0.18)
	if _seat_cursor >= people.size() and people.all(func(person: CustomerPersonAgent): return person.phase == "seated"):
		_complete_seating()


func _complete_seating() -> void:
	if _seated:
		return
	world.finish_customer_entry(self)
	_seated = true
	_set_people_mode("conversation", false)
	_set_state("waiting_order")
	_thought.text = "MENU"
	_thought.visible = true
	_request_service_once("take_order")


func _return_to_queue() -> void:
	world.finish_customer_entry(self)
	world.release_table(self)
	table = {}
	world.enqueue_customer(self)
	_set_state("queueing")
	_refresh_queue_targets(true)


func service_completed(action: String, payload: Dictionary) -> void:
	match action:
		"take_order":
			if state != "waiting_order" or not _seated or _take_order_committed or not _owns_reserved_table():
				return
			_take_order_committed = true
			orders.clear()
			served_order_ids.clear()
			_diner_eat_remaining.clear()
			_diner_finished.clear()
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
			if state not in ["waiting_food", "eating"] or not _seated or not _owns_reserved_table():
				return
			var order_id := String(payload.get("order_id", ""))
			var order := _local_order(order_id)
			if order.is_empty() or served_order_ids.has(order_id) or not _order_is_ready_to_serve(order_id):
				return
			served_order_ids[order_id] = true
			_show_dish(order)
			var diner_index := int(order.get("diner_index", 0))
			_diner_eat_remaining[diner_index] = randf_range(5.2, 8.0) + float(diner_index) * randf_range(0.12, 0.32)
			people[diner_index].set_seated_mode("eating", true)
			_set_state("eating", false)
			_thought.text = "%d/%d SERVITI" % [served_order_ids.size(), orders.size()]
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
			_thought.visible = true
			AudioManager.play_feedback("income")
			_begin_leaving(false)


func _update_dining(delta: float) -> void:
	for order: Dictionary in orders:
		var diner_index := int(order.get("diner_index", 0))
		if not _diner_eat_remaining.has(diner_index) or _diner_finished.has(diner_index):
			continue
		_diner_eat_remaining[diner_index] = float(_diner_eat_remaining[diner_index]) - delta
		if float(_diner_eat_remaining[diner_index]) <= 0.0:
			_diner_finished[diner_index] = true
			people[diner_index].set_seated_mode("conversation", false)
			_replace_dish_with_dirty(String(order.id))
	if served_order_ids.size() == orders.size() and not orders.is_empty() and _diner_finished.size() == orders.size() and not _payment_committed:
		_set_state("waiting_payment")
		_thought.text = "CONTO"
		_thought.visible = true
		_request_service_once("payment", {"order_ids": orders.map(func(entry: Dictionary): return entry.id)})


func get_service_position() -> Vector3:
	if table.is_empty() or not _owns_reserved_table():
		return global_position
	return Vector3(table.get("service_position", global_position))


func accepts_service_action(action: String, payload: Dictionary = {}) -> bool:
	match action:
		"take_order": return state == "waiting_order" and _seated and not _take_order_committed and _owns_reserved_table()
		"serve":
			var order_id := String(payload.get("order_id", ""))
			return state in ["waiting_food", "eating"] and _seated and _owns_reserved_table() and not served_order_ids.has(order_id) and not _local_order(order_id).is_empty() and _order_is_ready_to_serve(order_id)
		"payment": return state == "waiting_payment" and _seated and not _payment_committed and served_order_ids.size() == orders.size() and not orders.is_empty()
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


func _choose_recipe() -> Dictionary:
	var candidates: Array = []
	var weights: Array[float] = []
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		var price := int(GameState.menu[recipe.id].price)
		if price > budget or bool(GameState.menu[recipe.id].sold_out):
			continue
		candidates.append(recipe)
		var weight := float(recipe.get("popularity", 1.0))
		match customer_type:
			"famiglia":
				if "pizza" in String(recipe.id) or "burger" in String(recipe.id): weight *= 1.7
			"studente": weight *= clampf(32.0 / maxf(float(price), 1.0), 0.7, 1.8)
			"gourmet":
				if String(recipe.id) in ["beef_stew", "steak_plate", "mixed_sundae"]: weight *= 1.8
		weights.append(weight)
	if candidates.is_empty():
		return {}
	var total := 0.0
	for weight: float in weights: total += weight
	var roll := randf() * total
	for index: int in candidates.size():
		roll -= weights[index]
		if roll <= 0.0: return candidates[index]
	return candidates.back()


func _leave_lost(message: String) -> void:
	if state in ["standing_to_leave", "waiting_exit_door", "leaving"]:
		return
	_thought.text = message
	_thought.visible = true
	SimulationManager.cancel_customer_work(self)
	_begin_leaving(true)


func _leave_for_closing() -> void:
	if state in ["standing_to_leave", "waiting_exit_door", "leaving"]:
		return
	_thought.text = "CHIUSURA"
	_thought.visible = true
	SimulationManager.cancel_customer_work(self)
	_begin_leaving(false)


func _begin_leaving(lost: bool) -> void:
	_lost_departure = _lost_departure or lost
	world.dequeue_customer(self)
	if not _seated:
		world.finish_customer_entry(self)
		world.release_table(self)
		table = {}
		_outside_departure = true
		_set_state("leaving")
		for index: int in people.size():
			people[index].walk_to_position(world.customer_despawn_position(index), "despawn", float(index) * 0.16)
		return
	# Reserve exit priority while everybody is still correctly seated. Guests
	# stand one at a time only after this party owns the doorway.
	world.register_customer_exit(self)
	_set_state("waiting_exit_door")


func _begin_exit_sequence() -> void:
	_exit_cursor = 0
	_exit_stage = "stand"
	_door_released = false
	_set_state("leaving")
	_start_current_exit_leg()


func _start_current_exit_leg() -> void:
	if _exit_cursor >= people.size():
		return
	var person := people[_exit_cursor]
	var assignment: Dictionary = table.get("seat_assignments", [])[_exit_cursor]
	match _exit_stage:
		"stand": person.begin_standing()
		"seat": person.leave_seat_to_staging(Vector3(assignment.staging_position))
		"door": person.walk_to_position(world.customer_inside_door_position(_exit_cursor), "exit_door")
		"outside": person.walk_to_position(world.customer_outside_door_position(_exit_cursor), "exit_outside")


func _update_exit_sequence() -> void:
	if _outside_departure:
		if people.all(func(person: CustomerPersonAgent): return person.is_at("despawn") or person.phase == "route_failed"):
			_finish_departure()
		return
	if _exit_cursor < people.size():
		var person := people[_exit_cursor]
		if person.phase == "route_failed":
			_start_current_exit_leg()
			return
		if _exit_stage == "stand" and person.phase == "standing_ready":
			_exit_stage = "seat"
			_start_current_exit_leg()
		elif _exit_stage == "seat" and person.is_at("exit_stage"):
			_exit_stage = "door"
			_start_current_exit_leg()
		elif _exit_stage == "door" and person.is_at("exit_door"):
			_exit_stage = "outside"
			_start_current_exit_leg()
		elif _exit_stage == "outside" and person.is_at("exit_outside"):
			person.walk_to_position(world.customer_despawn_position(_exit_cursor), "despawn", 0.0)
			_exit_cursor += 1
			_exit_stage = "stand"
			_start_current_exit_leg()
	if _exit_cursor >= people.size():
		if not _door_released:
			_transfer_dirty_table()
			world.release_table(self)
			world.finish_customer_exit(self)
			_door_released = true
			table = {}
		if people.all(func(candidate: CustomerPersonAgent): return candidate.is_at("despawn") or candidate.phase == "route_failed"):
			_finish_departure()


func _transfer_dirty_table() -> void:
	if _dirty_transferred or table.is_empty() or dish_models.is_empty():
		return
	world.adopt_dirty_table(self, String(table.uid), dish_models.values())
	dish_models.clear()
	_dirty_transferred = true


func _finish_departure() -> void:
	world.finish_customer_entry(self)
	world.finish_customer_exit(self)
	world.release_table(self)
	# queue_free is deferred. Remove child bodies from traffic immediately so
	# the next FIFO party never sees an already-departed invisible obstacle.
	for person: CustomerPersonAgent in people:
		if is_instance_valid(person):
			person.shutdown_navigation()
			person.set_collision_enabled(false)
	if _registered:
		SimulationManager.unregister_customer(self, _lost_departure)
		_registered = false
	queue_free()


func _seat_group() -> bool:
	if not _table_seats_are_valid():
		return false
	var assignments: Array = table.get("seat_assignments", [])
	for index: int in people.size():
		var person := people[index]
		person.seat_assignment = assignments[index]
		person.global_position = Vector3(assignments[index].position)
		person._seat_center = Vector3(table.table_center)
		var direction := person.global_position.direction_to(Vector3(table.table_center))
		person._seat_facing = atan2(direction.x, direction.z)
		person.rotation.y = person._seat_facing
		person.phase = "seated"
		person.seated = true
		person._lock_animation_pose("SitDown", 1.0)
	_seated = true
	world.dequeue_customer(self)
	world.finish_customer_entry(self)
	return true


func _table_seats_are_valid() -> bool:
	if not _owns_reserved_table(): return false
	var assignments: Array = table.get("seat_assignments", [])
	if assignments.size() != group_size: return false
	for assignment: Dictionary in assignments:
		var chair := world.placed_objects.get(String(assignment.get("chair_uid", ""))) as PlacedObject
		if chair == null or not is_instance_valid(chair) or chair.support_uid != String(table.uid): return false
	return true


func _all_people_near(targets: Array, tolerance: float) -> bool:
	if targets.size() != people.size(): return false
	for index: int in people.size():
		# A body may intentionally stop at capsule clearance from the exact queue
		# marker.  Reaching the final path waypoint is the authoritative result.
		if people[index].is_at("queue"):
			continue
		if _flat_distance(people[index].global_position, Vector3(targets[index])) > tolerance: return false
	return true


func _set_people_mode(mode: String, has_meal: bool) -> void:
	for person: CustomerPersonAgent in people:
		person.set_seated_mode(mode, has_meal)


func _show_dish(order: Dictionary) -> void:
	var order_id := String(order.get("id", ""))
	if order_id.is_empty() or dish_models.has(order_id): return
	var recipe: Dictionary = DataRegistry.recipes_by_id.get(String(order.get("recipe_id", "")), {})
	var model_path := ""
	var steps: Array = recipe.get("steps", [])
	for index: int in range(steps.size() - 1, -1, -1):
		model_path = String(steps[index].get("model", ""))
		if not model_path.is_empty(): break
	if model_path.is_empty(): return
	var dish := ModelFactory.instantiate_model(model_path, 0.55)
	ModelFactory.align_visual_to_grid_origin(dish)
	add_child(dish)
	dish.top_level = true
	var diner_index := clampi(int(order.get("diner_index", 0)), 0, group_size - 1)
	var assignments: Array = table.get("seat_assignments", [])
	var center := Vector3(table.get("table_center", global_position))
	var seat_position := Vector3(assignments[diner_index].position)
	var dish_position := center.lerp(seat_position, 0.43)
	dish_position.y = float(table.get("table_surface_y", 1.0))
	dish.global_position = dish_position
	ModelFactory.set_shadow_casting(dish, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	dish_models[order_id] = dish


func _replace_dish_with_dirty(order_id: String) -> void:
	var old := dish_models.get(order_id) as Node3D
	if old == null or not is_instance_valid(old): return
	var transform := old.global_transform
	old.queue_free()
	var dirty_path := "res://assets/equipment/plate_dirty.gltf"
	var dirty := ModelFactory.instantiate_model(dirty_path, 0.55)
	ModelFactory.align_visual_to_grid_origin(dirty)
	add_child(dirty)
	dirty.top_level = true
	dirty.global_transform = transform
	ModelFactory.set_shadow_casting(dirty, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	dish_models[order_id] = dirty


func _clear_dishes() -> void:
	for dish: Node3D in dish_models.values():
		if is_instance_valid(dish): dish.queue_free()
	dish_models.clear()


func _local_order(order_id: String) -> Dictionary:
	for order: Dictionary in orders:
		if String(order.get("id", "")) == order_id: return order
	return {}


func _order_is_ready_to_serve(order_id: String) -> bool:
	if not SimulationManager.orders.has(order_id): return false
	var order: Dictionary = SimulationManager.orders[order_id]
	return order.get("customer") == self and bool(order.get("ready", false)) and String(order.get("state", "")) == "at_pass"


func _owns_reserved_table() -> bool:
	return world != null and world.customer_owns_table(self, String(table.get("uid", "")))


func _set_state(value: String, reset_elapsed: bool = true) -> void:
	if state == "leaving" and value != "leaving": return
	if state in ["standing_to_leave", "waiting_exit_door"] and value not in ["standing_to_leave", "waiting_exit_door", "leaving"]: return
	if state == value and not reset_elapsed: return
	state = value
	if reset_elapsed: state_elapsed = 0.0


func get_avoidance_points() -> Array[Vector3]:
	var result: Array[Vector3] = []
	for person: CustomerPersonAgent in people:
		if is_instance_valid(person): result.append(person.global_position)
	return result


func _create_thought() -> void:
	_thought = Label3D.new()
	_thought.font = GameFonts.medium()
	_thought.position = Vector3(0, 2.35, 0)
	_thought.font_size = 21
	_thought.outline_size = 9
	_thought.modulate = Color("fff8e8")
	_thought.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_thought.no_depth_test = true
	_thought.visible = false
	add_child(_thought)
