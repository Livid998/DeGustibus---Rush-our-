class_name CustomerAgent
extends AnimatedAgent

const TABLE_WAIT_PATIENCE_MULTIPLIER := 1.75
const EXIT_STAND_STAGGER := 0.18
const EXIT_LANE_SPACING := 0.68
const DECISION_STEP := 0.10
const MAX_DECISION_TICKS_PER_FRAME := 8

const LIFECYCLE_QUEUE := "queue"
const LIFECYCLE_ENTER := "enter"
const LIFECYCLE_TABLE := "table"
const LIFECYCLE_SEATING := "seating"
const LIFECYCLE_ORDER := "order"
const LIFECYCLE_WAIT_FOOD := "wait_food"
const LIFECYCLE_EATING := "eating"
const LIFECYCLE_PAYMENT := "payment"
const LIFECYCLE_LEAVING := "leaving"
const LIFECYCLE_DESPAWN := "despawn"
const LIFECYCLE_RANKS := {
	LIFECYCLE_QUEUE: 0,
	LIFECYCLE_ENTER: 1,
	LIFECYCLE_TABLE: 2,
	LIFECYCLE_SEATING: 3,
	LIFECYCLE_ORDER: 4,
	LIFECYCLE_WAIT_FOOD: 5,
	LIFECYCLE_EATING: 6,
	LIFECYCLE_PAYMENT: 7,
	LIFECYCLE_LEAVING: 8,
	LIFECYCLE_DESPAWN: 9,
}

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
var group_experience: Dictionary = {}
var lifecycle_state := LIFECYCLE_QUEUE
var lifecycle_history: Array[String] = []
var decision_tick_count := 0

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
var _diner_eat_total: Dictionary = {}
var _diner_finished: Dictionary = {}
var _dish_consumption_stage: Dictionary = {}
var _entry_leg_failures := 0
var _entry_leg_elapsed := 0.0
var _exit_leg_failures := 0
var _exit_leg_elapsed := 0.0
var _exit_member_states: Dictionary = {}
var _departed_members: Dictionary = {}
var _exit_sequence_elapsed := 0.0
var _exit_crossed_count := 0
var _exit_departure_times: Dictionary = {}
var _review_finalized := false
var _food_wait_recorded := false
var _quality_scores: Array[float] = []
var _service_scores: Array[float] = []
var _ambience_poll_clock := 0.0
var _seen_pest_incidents: Dictionary = {}
var _order_commit_token := ""
var _table_release_committed := false
var _departure_finished := false
var _decision_accumulator := 0.0
var _decision_phase_offset := 0.0
var _service_request_attempts := 0

static var _next_decision_slot := 0

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
	_order_commit_token = "%s:%d" % [name, get_instance_id()]
	lifecycle_state = LIFECYCLE_QUEUE
	lifecycle_history.assign([LIFECYCLE_QUEUE])
	_table_release_committed = false
	_departure_finished = false
	_decision_phase_offset = float(_next_decision_slot % 10) * (DECISION_STEP / 10.0)
	_next_decision_slot += 1
	_decision_accumulator = DECISION_STEP - _decision_phase_offset if _decision_phase_offset > 0.0 else 0.0
	decision_tick_count = 0
	customer_type = ["lavoratore", "famiglia", "studente", "gourmet", "abituale"].pick_random()
	patience = randf_range(58.0, 82.0)
	budget = randi_range(22, 48)
	group_experience = SimulationManager.begin_group_experience(name, {
		"customer_type": customer_type,
		"created_at": GameState.service_seconds,
		"stage": "arrived",
	})
	world.enqueue_customer(self)
	_build_people()
	_create_thought()
	SimulationManager.register_customer(self)
	_registered = true
	_set_state("queueing")
	_refresh_queue_targets(true)


func _exit_tree() -> void:
	var world_runtime_live := world != null and is_instance_valid(world) and world.is_inside_tree() and not world.is_queued_for_deletion()
	if world_runtime_live:
		world.dequeue_customer(self)
		world.finish_customer_exit(self)
		if _seated and not _dirty_transferred and not dish_models.is_empty() and _dishes_can_transfer():
			_transfer_dirty_table()
		elif not _dirty_transferred:
			_clear_dishes()
		_release_table_reservation(false)
	else:
		# Scene teardown has no live restaurant to adopt table props. Free them
		# locally and mark the release complete; during normal runtime the branch
		# above still transfers dirty dishes exactly once.
		_clear_dishes()
		_dirty_transferred = true
		_table_release_committed = true
		table = {}
	if _registered and SimulationManager.customers.has(self):
		SimulationManager.unregister_customer(self, false)
	_registered = false
	for person: CustomerPersonAgent in people:
		if is_instance_valid(person):
			person.shutdown_navigation()
	super._exit_tree()


func _process(delta: float) -> void:
	var scaled := delta * SimulationManager.simulation_speed
	for person: CustomerPersonAgent in people:
		if is_instance_valid(person):
			person.tick_motion(scaled)
	_update_controller_anchor()
	if delta <= 0.0:
		_decision_tick(0.0)
		return
	_decision_accumulator += scaled
	var processed := 0
	while _decision_accumulator + 0.000001 >= DECISION_STEP and processed < MAX_DECISION_TICKS_PER_FRAME:
		_decision_accumulator -= DECISION_STEP
		_decision_tick(DECISION_STEP)
		processed += 1


func _decision_tick(delta: float) -> void:
	decision_tick_count += 1
	state_elapsed += delta
	if _seated and state in ["waiting_order", "waiting_food", "eating", "waiting_payment", "change_order"]:
		_ambience_poll_clock -= delta
		if _ambience_poll_clock <= 0.0:
			_ambience_poll_clock = 0.5
			_update_visible_pest_experience()
	if GameState.restaurant_state == "closing" and _must_leave_for_closing():
		_leave_for_closing()
	if state in ["queueing", "waiting_table", "waiting_order", "waiting_food", "eating", "waiting_payment"]:
		wait_time += delta
		var pressure := clampf((state_elapsed - patience * 0.55) / maxf(patience, 1.0), 0.0, 1.0)
		satisfaction = maxf(satisfaction - delta * (0.0012 + pressure * 0.0055), 0.3)
	match state:
		"queueing", "waiting_table":
			_update_queue(delta)
		"admitting", "walking_to_table", "seating":
			_update_admission_and_seating(delta)
		"waiting_order":
			_set_people_mode("conversation", false)
			if state_elapsed > patience * 1.45:
				_leave_lost("NESSUN CAMERIERE")
		"waiting_food", "eating":
			_update_dining(delta)
			if served_order_ids.size() < orders.size() and state_elapsed > patience * 2.4:
				_leave_lost("TROPPA ATTESA")
		"waiting_payment":
			_set_people_mode("conversation", false)
			if state_elapsed > patience * 1.8:
				_leave_lost("CONTO IN RITARDO")
		"change_order":
			_set_people_mode("conversation", false)
			if state_elapsed > patience * 1.2:
				_leave_lost("CAMBIO ORDINE IN RITARDO")
		"waiting_exit_door":
			if world.try_begin_customer_exit(self):
				_begin_exit_sequence()
		"leaving":
			_update_exit_sequence(delta)


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
	for index: int in people.size():
		if _departed_members.has(index):
			continue
		var person := people[index]
		if is_instance_valid(person) and not person.is_queued_for_deletion():
			global_position = person.global_position
			return


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
	if table.is_empty():
		if not world.customer_can_request_table(self, group_size):
			_set_state("waiting_table", false)
			_thought.text = "ATTESA TURNO"
			_thought.visible = true
			if state_elapsed > patience * TABLE_WAIT_PATIENCE_MULTIPLIER:
				_leave_lost("TROPPA ATTESA")
			return
		table = world.request_table(self, group_size)
	if table.is_empty():
		_set_state("waiting_table", false)
		_thought.text = "ATTESA TAVOLO"
		_thought.visible = true
		if state_elapsed > patience * TABLE_WAIT_PATIENCE_MULTIPLIER:
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
	_entry_leg_failures = 0
	_entry_leg_elapsed = 0.0
	_thought.visible = false
	_set_state("admitting")
	# The traffic coordinator has granted the doorway to this party.  Play one
	# transition cue for the whole group instead of one sound per moving body.
	AudioManager.play_sfx("door")


func _update_admission_and_seating(delta: float) -> void:
	var assignments: Array = table.get("seat_assignments", [])
	if assignments.size() != people.size() or not _owns_reserved_table():
		_return_to_queue()
		return
	# Admit exactly one body through the threshold at a time.  Only after that
	# person reaches the inside waypoint may it continue to its own chair and
	# the next party member receive the doorway.
	if _launch_cursor < people.size():
		_entry_leg_elapsed += delta
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
			_entry_leg_failures = 0
			_entry_leg_elapsed = 0.0
			_set_state("walking_to_table", false)
		elif entering_person.phase == "route_failed":
			var retry_target := world.customer_inside_door_position(_launch_cursor) if entering_person.target_tag == entry_tag else world.customer_outside_door_position(_launch_cursor)
			_entry_leg_failures += 1
			if _entry_leg_elapsed >= AgentTrafficCoordinator.HARD_CANCEL_SECONDS:
				# Admission is optional; crossing furniture to save it is not. Cancel
				# the failed destination and let the whole party leave from its current
				# physical positions through the normal exit planner.
				entering_person.cancel_destination("customer_entry_timeout")
				_leave_lost("INGRESSO BLOCCATO")
				return
			if _entry_leg_failures >= 2:
				_retry_person_checkpoint(entering_person, retry_target, entering_person.target_tag)
				_entry_leg_failures = 0
			else:
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
	# Once admission has begun, returning to the public queue would permit the
	# same party to reserve and sit at another table. A lost reservation is a
	# controlled abandonment instead, preserving the monotone lifecycle.
	_leave_lost("TAVOLO NON DISPONIBILE")


func order_requires_change(order_id: String, _reason: String = "") -> void:
	if _local_order(order_id).is_empty() or state in ["standing_to_leave", "waiting_exit_door", "leaving"]:
		return
	_set_state("change_order")
	_set_people_mode("conversation", false)
	_thought.text = "CAMBIO ORDINE"
	_thought.visible = true


func service_completed(action: String, payload: Dictionary) -> void:
	_record_service_score(payload)
	match action:
		"take_order":
			if state != "waiting_order" or not _seated or _take_order_committed or not _owns_reserved_table():
				return
			SimulationManager.record_group_wait(group_experience, "order", state_elapsed)
			_take_order_committed = true
			orders.clear()
			served_order_ids.clear()
			_diner_eat_remaining.clear()
			_diner_eat_total.clear()
			_diner_finished.clear()
			for guest_index: int in group_size:
				var excluded: Dictionary = {}
				while excluded.size() < DataRegistry.recipes.size():
					var recipe := _choose_recipe(excluded)
					if recipe.is_empty():
						break
					var order_slot := "%s:%d" % [_order_commit_token, guest_index]
					var order := SimulationManager.create_order(
						recipe.id,
						String(table.get("uid", "")),
						self,
						order_slot
					)
					if not order.is_empty():
						order.diner_index = guest_index
						order.customer_budget = budget
						orders.append(order)
						SimulationManager.add_group_recipe(group_experience, String(recipe.id))
						break
					excluded[String(recipe.id)] = true
			if orders.size() != group_size:
				_leave_lost("MENU NON DISPONIBILE")
				return
			# A ticket exists only after every diner obtained an authoritative order.
			# Replayed service callbacks are rejected by _take_order_committed above.
			AudioManager.play_sfx("order_ticket")
			_set_state("waiting_food")
			_thought.text = "%d COMANDE" % orders.size()
		"serve":
			if state not in ["waiting_food", "eating"] or not _seated or not _owns_reserved_table():
				return
			var order_id := String(payload.get("order_id", ""))
			var order := _local_order(order_id)
			if order.is_empty() or served_order_ids.has(order_id) or not _order_is_ready_to_serve(order_id):
				return
			if not _food_wait_recorded:
				_food_wait_recorded = true
				SimulationManager.record_group_wait(group_experience, "food", state_elapsed)
			served_order_ids[order_id] = true
			_record_order_quality(order)
			_show_dish(order)
			var diner_index := int(order.get("diner_index", 0))
			# Keep dining readable without holding a table artificially long: the
			# procedural bite scheduler supplies pauses and variety inside this span.
			var eating_duration := randf_range(5.2, 8.0) + float(diner_index) * randf_range(0.12, 0.32)
			_diner_eat_remaining[diner_index] = eating_duration
			_diner_eat_total[diner_index] = eating_duration
			people[diner_index].set_seated_mode("eating", true, _utensil_for_recipe(String(order.get("recipe_id", ""))))
			_set_state("eating", false)
			_thought.text = "%d/%d SERVITI" % [served_order_ids.size(), orders.size()]
		"payment":
			if state != "waiting_payment" or orders.is_empty() or _payment_committed or served_order_ids.size() != orders.size():
				return
			_payment_committed = true
			SimulationManager.record_group_wait(group_experience, "bill", state_elapsed)
			if not _quality_scores.is_empty():
				SimulationManager.record_group_food_quality(group_experience, _average_float(_quality_scores))
			if not _service_scores.is_empty():
				SimulationManager.record_group_service(group_experience, _average_float(_service_scores))
			SimulationManager.record_group_ambience(group_experience)
			var order_ids: Array = orders.map(func(entry: Dictionary): return String(entry.id))
			var service_score := _average_float(_service_scores) if not _service_scores.is_empty() else 70.0
			var completion := SimulationManager.complete_group_payment(self, group_experience, order_ids, {
				"customer_type": customer_type,
				"service_tip_modifier": clampf((service_score - 50.0) / 50.0 * 0.02, -0.02, 0.02),
			})
			if not bool(completion.get("accepted", false)):
				_payment_committed = false
				_thought.text = "CONTO IN ATTESA"
				_thought.visible = true
				return
			_review_finalized = true
			var review: Dictionary = completion.get("review", {})
			var total := int(round(float(review.get("group_total", 0.0)))) + int(review.get("tip", 0))
			satisfaction = clampf(float(review.get("satisfaction", 70.0)) / 100.0, 0.0, 1.0)
			_thought.text = "+%d" % total
			_thought.visible = true
			AudioManager.play_feedback("income")
			_begin_leaving(false)
		"change_order":
			if state != "change_order" or not _seated or not _owns_reserved_table():
				return
			var order_id := String(payload.get("order_id", ""))
			var changed_order: Dictionary = SimulationManager.orders.get(order_id, {})
			if changed_order.is_empty() or String(changed_order.get("state", "")) != "change_order":
				return
			var alternatives := SimulationManager.order_change_alternatives(order_id, budget)
			if alternatives.is_empty():
				SimulationManager.cancel_order(order_id, "no_affordable_alternative")
				_leave_lost("NESSUNA ALTERNATIVA")
				return
			var delay := maxf(GameState.service_seconds - float(changed_order.get("change_requested_at", GameState.service_seconds)), 0.0)
			var replacement: Dictionary = SimulationManager.complete_order_change(order_id, String(alternatives[0].id), delay)
			if replacement.is_empty():
				SimulationManager.cancel_order(order_id, "replacement_reservation_failed")
				_leave_lost("NESSUNA ALTERNATIVA")
				return
			satisfaction = maxf(satisfaction - float(replacement.get("last_change_penalty", 0.0)), 0.25)
			SimulationManager.record_group_change_order(group_experience, delay, true)
			_thought.text = "CAMBIO ORDINE"
			_thought.visible = true
			_set_state("eating" if not served_order_ids.is_empty() else "waiting_food")


func _update_dining(delta: float) -> void:
	for order: Dictionary in orders:
		var diner_index := int(order.get("diner_index", 0))
		if not _diner_eat_remaining.has(diner_index) or _diner_finished.has(diner_index):
			continue
		_diner_eat_remaining[diner_index] = float(_diner_eat_remaining[diner_index]) - delta
		var remaining := maxf(float(_diner_eat_remaining[diner_index]), 0.0)
		var total := maxf(float(_diner_eat_total.get(diner_index, 1.0)), 0.01)
		# Visual portions advance only on an actual eating gesture. Time still
		# governs meal duration, but a plate never changes by itself between bites.
		_update_dish_consumption(String(order.id), remaining / total, people[diner_index].bite_count())
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
		"change_order":
			var order_id := String(payload.get("order_id", ""))
			return state == "change_order" and _seated and _owns_reserved_table() and not _local_order(order_id).is_empty() and String(SimulationManager.orders.get(order_id, {}).get("state", "")) == "change_order"
	return false


func _request_service_once(action: String, payload: Dictionary = {}) -> void:
	_service_request_attempts += 1
	var previous_id := String(_service_request_ids.get(action, ""))
	if not previous_id.is_empty() and SimulationManager.service_tasks.has(previous_id):
		var previous: Dictionary = SimulationManager.service_tasks[previous_id]
		if String(previous.get("state", "")) not in ["completed", "cancelled"]:
			return
	var task := SimulationManager.request_service(self, action, get_service_position(), payload)
	if not task.is_empty():
		_service_request_ids[action] = String(task.id)


func _choose_recipe(excluded: Dictionary = {}) -> Dictionary:
	var candidates: Array = []
	var weights: Array[float] = []
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		if excluded.has(String(recipe.id)):
			continue
		var price := int(GameState.menu[recipe.id].price)
		if price > budget or GameState.is_recipe_sold_out(String(recipe.id)):
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
	if lifecycle_state in [LIFECYCLE_LEAVING, LIFECYCLE_DESPAWN]:
		return
	_thought.text = message
	_thought.visible = true
	_finalize_abandoned_review()
	SimulationManager.cancel_customer_work(self)
	_begin_leaving(true)


func _leave_for_closing() -> void:
	if lifecycle_state in [LIFECYCLE_LEAVING, LIFECYCLE_DESPAWN]:
		return
	_thought.text = "CHIUSURA"
	_thought.visible = true
	_finalize_abandoned_review()
	SimulationManager.cancel_customer_work(self)
	_begin_leaving(false)


func _must_leave_for_closing() -> bool:
	if lifecycle_state in [LIFECYCLE_LEAVING, LIFECYCLE_DESPAWN]:
		return false
	if not _seated:
		return true
	# A fully served party is allowed to finish eating and pay. Everyone else
	# leaves through the normal route so closing cannot retain unserved guests.
	return orders.is_empty() or served_order_ids.size() < orders.size()


func _begin_leaving(lost: bool) -> void:
	if lifecycle_state in [LIFECYCLE_LEAVING, LIFECYCLE_DESPAWN]:
		return
	_lost_departure = _lost_departure or lost
	world.dequeue_customer(self)
	_thought.visible = false
	if not _seated:
		world.finish_customer_entry(self)
		_release_table_reservation(false)
		_outside_departure = true
		_set_state("leaving")
		_exit_member_states.clear()
		_departed_members.clear()
		_exit_sequence_elapsed = 0.0
		for index: int in people.size():
			_exit_member_states[index] = {"stage": "despawn", "elapsed": 0.0, "failures": 0}
			people[index].walk_to_position(_exit_gate_position(index), _exit_tag("despawn", index), float(index) * 0.08)
		return
	# The party reserves the doorway while everybody is still seated. Once it
	# owns the exit, members stand with a short *overlapping* stagger rather than
	# waiting for the previous diner to complete the entire route.
	world.register_customer_exit(self)
	_set_state("waiting_exit_door")


func _begin_exit_sequence() -> void:
	_exit_cursor = 0
	_exit_stage = "parallel"
	_door_released = false
	_exit_leg_failures = 0
	_exit_leg_elapsed = 0.0
	_exit_member_states.clear()
	_departed_members.clear()
	_exit_sequence_elapsed = 0.0
	_exit_crossed_count = 0
	_exit_departure_times.clear()
	for index: int in people.size():
		_exit_member_states[index] = {
			"stage": "queued",
			"launch_at": float(index) * EXIT_STAND_STAGGER,
			"elapsed": 0.0,
			"failures": 0,
			"lane": _exit_lane_offset(index),
		}
	# Exit ownership is granted once per party; member staggering must not ring
	# the same door repeatedly.
	AudioManager.play_sfx("door")
	_set_state("leaving")
	_update_exit_sequence(0.0)


func _start_current_exit_leg() -> void:
	# Compatibility shim for diagnostics/tests from older saves. Departure is no
	# longer cursor-driven; every member advances through its own FSM.
	if _exit_member_states.is_empty():
		_begin_exit_sequence()
	elif _exit_cursor >= people.size():
		return


func _update_exit_sequence(delta: float = 0.0) -> void:
	_exit_sequence_elapsed += maxf(delta, 0.0)
	if _outside_departure:
		_update_outside_departure(delta)
		if _departed_members.size() >= group_size:
			_finish_departure()
		return
	for index: int in people.size():
		if _departed_members.has(index):
			continue
		_update_exit_member(index, delta)
	_exit_cursor = _exit_crossed_count
	if _exit_crossed_count >= group_size:
		_release_exit_door_and_table()
	if _departed_members.size() >= group_size:
		_finish_departure()


func _current_exit_checkpoint() -> Dictionary:
	if _exit_cursor >= people.size() or table.is_empty():
		return {}
	var member_state: Dictionary = _exit_member_states.get(_exit_cursor, {})
	if member_state.is_empty():
		return {}
	return _exit_checkpoint(_exit_cursor, String(member_state.get("stage", "")))


func _update_exit_member(index: int, delta: float) -> void:
	if index >= people.size() or not is_instance_valid(people[index]):
		_mark_member_departed(index)
		return
	var person := people[index]
	var member_state: Dictionary = _exit_member_states.get(index, {})
	if member_state.is_empty():
		return
	member_state.elapsed = float(member_state.get("elapsed", 0.0)) + maxf(delta, 0.0)
	var stage := String(member_state.get("stage", "queued"))
	if person.phase == "route_cancelled":
		if _exit_sequence_elapsed >= float(member_state.get("retry_at", INF)):
			var retry_checkpoint := _exit_checkpoint(index, stage)
			if not retry_checkpoint.is_empty():
				_retry_person_checkpoint(person, Vector3(retry_checkpoint.position), String(retry_checkpoint.tag))
		return
	match stage:
		"queued":
			if _exit_sequence_elapsed + 0.0001 >= float(member_state.get("launch_at", 0.0)):
				person.begin_standing()
				_set_exit_member_stage(member_state, "stand")
		"stand":
			if person.phase == "standing_ready":
				var assignments: Array = table.get("seat_assignments", [])
				if index < assignments.size():
					person.leave_seat_to_staging(Vector3(assignments[index].staging_position))
					_set_exit_member_stage(member_state, "seat")
		"seat":
			if person.is_at("exit_stage"):
				person.walk_to_position(_exit_inside_position(index), _exit_tag("door", index))
				_set_exit_member_stage(member_state, "door")
		"door":
			if person.is_at(_exit_tag("door", index)):
				person.walk_to_position(_exit_outside_position(index), _exit_tag("outside", index), float(index) * 0.04)
				_set_exit_member_stage(member_state, "outside")
			elif person.phase == "route_failed":
				_recover_exit_member(index, person, member_state)
		"outside":
			if person.is_at(_exit_tag("outside", index)):
				member_state.crossed = true
				_exit_crossed_count += 1
				person.begin_linear_departure(_exit_gate_position(index), _exit_tag("despawn", index))
				_set_exit_member_stage(member_state, "despawn")
			elif person.phase == "route_failed":
				_recover_exit_member(index, person, member_state)
		"despawn":
			if person.is_at(_exit_tag("despawn", index)):
				_mark_member_departed(index)
	_exit_member_states[index] = member_state


func _update_outside_departure(delta: float) -> void:
	for index: int in people.size():
		if _departed_members.has(index):
			continue
		var person := people[index]
		var member_state: Dictionary = _exit_member_states.get(index, {"stage": "despawn", "elapsed": 0.0, "failures": 0})
		member_state.elapsed = float(member_state.get("elapsed", 0.0)) + maxf(delta, 0.0)
		var tag := _exit_tag("despawn", index)
		if person.is_at(tag):
			_mark_member_departed(index)
		elif person.phase == "route_cancelled":
			if _exit_sequence_elapsed >= float(member_state.get("retry_at", INF)):
				_retry_person_checkpoint(person, _exit_gate_position(index), tag)
		elif person.phase == "route_failed":
			_recover_exit_member(index, person, member_state)
		_exit_member_states[index] = member_state


func _recover_exit_member(index: int, person: CustomerPersonAgent, member_state: Dictionary) -> void:
	var stage := String(member_state.get("stage", ""))
	var checkpoint := _exit_checkpoint(index, stage)
	if checkpoint.is_empty():
		return
	member_state.failures = int(member_state.get("failures", 0)) + 1
	if float(member_state.get("elapsed", 0.0)) >= AgentTrafficCoordinator.HARD_CANCEL_SECONDS:
		# A hard timeout invalidates only this route lease. The body remains at its
		# real position and retries after a bounded backoff; no checkpoint teleport
		# or collision bypass is permitted.
		person.cancel_destination("customer_exit_timeout")
		member_state.retry_at = _exit_sequence_elapsed + minf(0.45 + float(member_state.failures) * 0.20, 1.8)
		member_state.elapsed = 0.0
		RuntimeDiagnostics.record_event("customer_exit_retry", {
			"party": String(name),
			"member": index,
			"stage": stage,
			"failures": int(member_state.failures),
		})
		return
	_retry_person_checkpoint(person, Vector3(checkpoint.position), String(checkpoint.tag))


func _set_exit_member_stage(member_state: Dictionary, stage: String) -> void:
	member_state.stage = stage
	member_state.elapsed = 0.0
	member_state.failures = 0


func _exit_checkpoint(index: int, stage: String) -> Dictionary:
	match stage:
		"door": return {"position": _exit_inside_position(index), "tag": _exit_tag("door", index)}
		"outside": return {"position": _exit_outside_position(index), "tag": _exit_tag("outside", index)}
		"despawn": return {"position": _exit_gate_position(index), "tag": _exit_tag("despawn", index)}
	return {}


func _exit_tag(stage: String, index: int) -> String:
	return "exit_%s_%d" % [stage, index]


func _exit_lane_offset(index: int) -> float:
	# EXIT_ROW is the sidewalk cell nearest the restaurant. Four lanes fan out
	# over both sidewalk rows, each wider than two guest radii, and never share a
	# final marker. This removes the single convergence point visible at the lot
	# boundary.
	return 0.52 - float(index) * EXIT_LANE_SPACING


func _exit_inside_position(index: int) -> Vector3:
	return world.customer_inside_door_position(index % 2)


func _exit_outside_position(index: int) -> Vector3:
	var base := world.customer_outside_door_position(0)
	return Vector3(base.x, 0.0, base.z + _exit_lane_offset(index))


func _exit_gate_position(index: int) -> Vector3:
	var base := world.customer_despawn_position(0)
	return Vector3(base.x, 0.0, base.z + _exit_lane_offset(index))


func _release_exit_door_and_table() -> void:
	if _door_released:
		return
	_release_table_reservation(true)
	world.finish_customer_exit(self)
	_door_released = true


func _mark_member_departed(index: int) -> void:
	if _departed_members.has(index):
		return
	_departed_members[index] = true
	_exit_departure_times[index] = _exit_sequence_elapsed
	if index < people.size() and is_instance_valid(people[index]):
		people[index].complete_individual_departure()


func _retry_person_checkpoint(person: CustomerPersonAgent, position: Vector3, tag: String) -> bool:
	if person == null or not is_instance_valid(person):
		return false
	var safe_position := world.find_safe_agent_position(position, person)
	# find_safe_agent_position chooses a reachable free endpoint; movement to it
	# still goes through normal pathfinding from the body's current transform.
	return person.walk_to_position(safe_position, tag, 0.12)


func _force_person_checkpoint(person: CustomerPersonAgent, position: Vector3, tag: String) -> void:
	# Backward-compatible diagnostic hook. Its old implementation teleported the
	# body; callers now receive the same controlled route recovery as production.
	_retry_person_checkpoint(person, position, tag)


func _transfer_dirty_table() -> void:
	if _dirty_transferred or table.is_empty() or dish_models.is_empty():
		return
	if world == null or not is_instance_valid(world) or not world.is_inside_tree() or world.is_queued_for_deletion() or not _dishes_can_transfer():
		_clear_dishes()
		_dirty_transferred = true
		return
	world.adopt_dirty_table(self, String(table.uid), dish_models.values())
	dish_models.clear()
	_dirty_transferred = true


func _dishes_can_transfer() -> bool:
	for dish_value: Variant in dish_models.values():
		var dish := dish_value as Node3D
		if dish == null or not is_instance_valid(dish) or not dish.is_inside_tree() or dish.is_queued_for_deletion():
			return false
	return true


func _release_table_reservation(transfer_dirty: bool) -> void:
	if _table_release_committed:
		return
	if transfer_dirty:
		_transfer_dirty_table()
	if world != null and not table.is_empty():
		world.release_table(self)
	_table_release_committed = true
	table = {}


func _finish_departure() -> void:
	if _departure_finished:
		return
	_departure_finished = true
	_set_state("despawn")
	world.finish_customer_entry(self)
	world.finish_customer_exit(self)
	_release_table_reservation(true)
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
	var recipe_id := String(order.get("recipe_id", ""))
	var dish := Node3D.new()
	dish.name = "TableDish_%s" % order_id
	# Table service always uses food-only geometry over one canonical container.
	# This guarantees that clean, partial and dirty plates have identical size.
	var content := FoodVisualFactory.instantiate_recipe_serving_food(recipe_id)
	content.name = "FoodContent"
	dish.add_child(content)
	_add_support_container(dish, recipe_id, true)
	add_child(dish)
	dish.top_level = true
	var diner_index := clampi(int(order.get("diner_index", 0)), 0, group_size - 1)
	var assignments: Array = table.get("seat_assignments", [])
	var center := Vector3(table.get("table_center", global_position))
	var seat_position := Vector3(assignments[diner_index].position)
	var dish_position := center.lerp(seat_position, 0.43)
	dish_position.y = float(table.get("table_surface_y", 1.0))
	dish.global_position = dish_position
	dish.rotation.y = people[diner_index]._seat_facing
	ModelFactory.set_shadow_casting(dish, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	dish.set_meta("recipe_id", recipe_id)
	_dish_consumption_stage[order_id] = 0
	dish_models[order_id] = dish


func _update_dish_consumption(order_id: String, remaining_ratio: float, bite_count: int = -1) -> void:
	var dish := dish_models.get(order_id) as Node3D
	if dish == null or not is_instance_valid(dish):
		return
	var desired_stage := 0
	if remaining_ratio <= 0.28:
		desired_stage = 2
	elif remaining_ratio <= 0.64:
		desired_stage = 1
	if bite_count >= 0:
		desired_stage = mini(desired_stage, clampi(bite_count, 0, 2))
	if int(_dish_consumption_stage.get(order_id, 0)) >= desired_stage:
		return
	_dish_consumption_stage[order_id] = desired_stage
	var recipe_id := String(dish.get_meta("recipe_id", ""))
	_add_support_container(dish, recipe_id, true)
	var content := dish.get_node_or_null("FoodContent") as Node3D
	if content != null:
		content.visible = false
	var previous := dish.get_node_or_null("FoodRemainder") as Node3D
	if previous != null:
		dish.remove_child(previous)
		previous.queue_free()
	var parts := FoodVisualFactory.consumption_parts(recipe_id, desired_stage)
	if not parts.is_empty():
		var remainder := FoodVisualFactory.instantiate_parts(parts, 1.0, 6)
		remainder.name = "FoodRemainder"
		dish.add_child(remainder)
		ModelFactory.set_shadow_casting(remainder, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)


func _add_support_container(dish: Node3D, recipe_id: String, make_visible: bool) -> void:
	var existing := dish.get_node_or_null("StableContainer") as Node3D
	if existing != null:
		existing.visible = make_visible
		return
	var kind := FoodVisualFactory.consumption_container(recipe_id)
	var container := FoodVisualFactory.instantiate_canonical_container(kind, false)
	container.name = "StableContainer"
	container.visible = make_visible
	dish.add_child(container)
	dish.move_child(container, 0)
	dish.set_meta("consumption_container", kind)
	var content := dish.get_node_or_null("FoodContent") as Node3D
	if make_visible and content != null and content.position.y < 0.05:
		content.position.y = 0.055


func _replace_dish_with_dirty(order_id: String) -> void:
	var dish := dish_models.get(order_id) as Node3D
	if dish == null or not is_instance_valid(dish): return
	for child: Node in dish.get_children():
		dish.remove_child(child)
		child.queue_free()
	var kind := String(dish.get_meta("consumption_container", "plate"))
	var dirty := FoodVisualFactory.instantiate_canonical_container(kind, true)
	dirty.name = "DirtyContainer"
	dish.add_child(dirty)
	_dish_consumption_stage[order_id] = 3


func _clear_dishes() -> void:
	for dish: Node3D in dish_models.values():
		if is_instance_valid(dish): dish.queue_free()
	dish_models.clear()
	_dish_consumption_stage.clear()


func _utensil_for_recipe(recipe_id: String) -> String:
	return "spoon" if recipe_id in ["beef_stew", "mixed_sundae", "icecream_cone"] else "fork"


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
	var target_lifecycle := _canonical_lifecycle_for_state(value)
	var current_rank := int(LIFECYCLE_RANKS.get(lifecycle_state, 0))
	var target_rank := int(LIFECYCLE_RANKS.get(target_lifecycle, current_rank))
	if target_rank < current_rank:
		RuntimeDiagnostics.record_event("customer_lifecycle_regression_rejected", {
			"party": String(name),
			"from": lifecycle_state,
			"to": target_lifecycle,
			"requested_state": value,
		})
		return
	if lifecycle_state == LIFECYCLE_DESPAWN and target_lifecycle != LIFECYCLE_DESPAWN:
		return
	# Replaying a completion callback must not reset patience or reopen work.
	if state == value:
		return
	if target_rank > current_rank:
		lifecycle_state = target_lifecycle
		lifecycle_history.append(target_lifecycle)
	state = value
	if reset_elapsed: state_elapsed = 0.0
	if not group_experience.is_empty():
		var experience_stage: String = {
			"queueing": "arrived",
			"waiting_table": "arrived",
			"waiting_order": "seated",
			"waiting_food": "ordered",
			"change_order": "ordered",
			"eating": "eating",
			"waiting_payment": "paying",
		}.get(value, "")
		if not String(experience_stage).is_empty():
			SimulationManager.set_group_experience_stage(group_experience, String(experience_stage))


func _canonical_lifecycle_for_state(value: String) -> String:
	match value:
		"queueing", "waiting_table":
			return LIFECYCLE_QUEUE
		"admitting":
			return LIFECYCLE_ENTER
		"walking_to_table":
			return LIFECYCLE_TABLE
		"seating":
			return LIFECYCLE_SEATING
		"waiting_order":
			return LIFECYCLE_ORDER
		"waiting_food":
			return LIFECYCLE_WAIT_FOOD
		"change_order":
			# A changed ticket for a diner who has already started eating does not
			# rewind the party's lifecycle.
			return lifecycle_state if int(LIFECYCLE_RANKS.get(lifecycle_state, 0)) >= int(LIFECYCLE_RANKS[LIFECYCLE_EATING]) else LIFECYCLE_WAIT_FOOD
		"eating":
			return LIFECYCLE_EATING
		"waiting_payment":
			return LIFECYCLE_PAYMENT
		"standing_to_leave", "waiting_exit_door", "leaving":
			return LIFECYCLE_LEAVING
		"despawn":
			return LIFECYCLE_DESPAWN
	return lifecycle_state


func lifecycle_snapshot() -> Dictionary:
	return {
		"state": lifecycle_state,
		"history": lifecycle_history.duplicate(),
		"order_committed": _take_order_committed,
		"payment_committed": _payment_committed,
		"orders": orders.size(),
		"served": served_order_ids.size(),
		"seated": _seated,
		"table_released": _table_release_committed,
		"decision_ticks": decision_tick_count,
		"decision_phase_offset": _decision_phase_offset,
		"service_request_attempts": _service_request_attempts,
	}


func _record_service_score(payload: Dictionary) -> void:
	var employee_id := String(payload.get("employee_id", ""))
	if employee_id.is_empty():
		return
	for employee: Dictionary in GameState.employees:
		if String(employee.get("id", "")) != employee_id:
			continue
		var service_skill := float(employee.get("skills", {}).get("service", 0.70))
		var precision := float(employee.get("precision", 0.80))
		var response_seconds := maxf(float(payload.get("response_seconds", 0.0)), 0.0)
		var responsiveness := lerpf(100.0, 55.0, clampf(response_seconds / 45.0, 0.0, 1.0))
		_service_scores.append(clampf((service_skill * 100.0 + precision * 100.0 + responsiveness) / 3.0, 0.0, 100.0))
		return


func _record_order_quality(order: Dictionary) -> void:
	_quality_scores.append(clampf(float(order.get("quality_score", 70.0)), 0.0, 100.0))
	var seen: Dictionary = {}
	var all_events: Array = []
	all_events.append_array(order.get("quality_event_history", []))
	all_events.append_array(order.get("quality_events", []))
	for event_value: Variant in all_events:
		if not event_value is Dictionary:
			continue
		var event := event_value as Dictionary
		var event_id := String(event.get("id", ""))
		if event_id.is_empty() or seen.has(event_id):
			continue
		seen[event_id] = true
		SimulationManager.record_group_quality_event(group_experience, event)
	if int(order.get("remake_attempts", 0)) > 0:
		SimulationManager.record_group_incident_resolution(
			group_experience,
			"remake_%s" % String(order.get("id", "")),
			maxf(GameState.service_seconds - float(order.get("created_at", GameState.service_seconds)), 0.0)
		)


func _update_visible_pest_experience() -> void:
	if world == null or group_experience.is_empty() or not world.has_method("visible_pest_incidents"):
		return
	var active_ids: Dictionary = {}
	var active_records: Array = world.call("visible_pest_incidents")
	for record_value: Variant in active_records:
		if not record_value is Dictionary:
			continue
		var record := record_value as Dictionary
		var incident_id := String(record.get("id", ""))
		var kind := String(record.get("kind", "insect"))
		if incident_id.is_empty():
			continue
		active_ids[incident_id] = true
		if _seen_pest_incidents.has(incident_id):
			continue
		_seen_pest_incidents[incident_id] = {
			"kind": kind,
			"seen_at": GameState.service_seconds,
			"resolved": false,
		}
		SimulationManager.record_group_visible_pest(group_experience, kind)
	for incident_id: String in _seen_pest_incidents.keys():
		var seen: Dictionary = _seen_pest_incidents[incident_id]
		if bool(seen.get("resolved", false)) or active_ids.has(incident_id):
			continue
		seen.resolved = true
		var response_seconds := maxf(
			GameState.service_seconds - float(seen.get("seen_at", GameState.service_seconds)),
			0.0
		)
		SimulationManager.record_group_incident_resolution(
			group_experience,
			"pest_%s" % incident_id,
			response_seconds
		)


func _finalize_abandoned_review() -> void:
	if _review_finalized or group_experience.is_empty():
		return
	if state == "waiting_order":
		SimulationManager.record_group_wait(group_experience, "order", state_elapsed)
	elif state in ["waiting_food", "eating", "change_order"]:
		if not _food_wait_recorded:
			SimulationManager.record_group_wait(group_experience, "food", state_elapsed)
	elif state == "waiting_payment":
		SimulationManager.record_group_wait(group_experience, "bill", state_elapsed)
	if not _quality_scores.is_empty():
		SimulationManager.record_group_food_quality(group_experience, _average_float(_quality_scores))
	if not _service_scores.is_empty():
		SimulationManager.record_group_service(group_experience, _average_float(_service_scores))
	SimulationManager.record_group_ambience(group_experience)
	var outcome := "abandoned" if _seated or not orders.is_empty() else "queue_abandoned"
	var completion := SimulationManager.complete_group_abandonment(group_experience, outcome, {
		"customer_type": customer_type,
	})
	_review_finalized = bool(completion.get("accepted", false)) or String(completion.get("reason", "")) in ["not_eligible", "duplicate_review"]


func _average_float(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value: float in values:
		total += value
	return total / float(values.size())


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
	var status_bubble := AgentStatusBubble.new()
	add_child(status_bubble)
	status_bubble.setup(_thought, world, "customer")
