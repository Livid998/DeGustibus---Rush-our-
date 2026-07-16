class_name CustomerPersonAgent
extends AnimatedAgent

## One physical/navigation agent per visible diner.  CustomerAgent owns the
## party-level order lifecycle; this node owns one body, one route and one
## animation timeline.

var party: Node
var member_index := 0
var visual_model: Node3D
var phase := "idle"
var target_tag := ""
var route_retries := 0
var reaction_delay := 0.0
var transition_remaining := 0.0
var seated := false
var meal_present := false
var seat_assignment: Dictionary = {}

var _local_target := Vector3.ZERO
var _seat_center := Vector3.ZERO
var _seat_facing := 0.0
var _seated_mode := "waiting"
var _phase_seed := 0.0


func setup_person(value_party: Node, value_world: RestaurantWorld, index: int, appearance: String, skin_tone: Color) -> void:
	party = value_party
	world = value_world
	member_index = index
	name = "Guest_%d_%d" % [value_party.get_instance_id(), index]
	movement_speed = randf_range(2.12, 2.58)
	movement_acceleration = randf_range(9.5, 12.5)
	arrival_tolerance = 0.13
	_phase_seed = randf_range(0.0, TAU)
	visual_model = add_character_model("res://assets/characters/%s.gltf" % appearance, Vector3.ZERO, skin_tone)
	configure_navigation(0.31, 2)
	validate_animations()
	_randomize_idle_phase()


func walk_to_position(target: Vector3, tag: String, delay: float = 0.0, ignore_furniture_during_first_step: bool = false) -> bool:
	target_tag = tag
	navigation_priority = 1 if tag.begins_with("seat_stage") or tag.begins_with("exit_") else (5 if tag == "queue" else 3)
	phase = "walking"
	route_retries = 0
	reaction_delay = maxf(delay, 0.0)
	seated = false
	if ignore_furniture_during_first_step:
		collision_mask = 0
	else:
		# Moving diners still collide with the environment (layer 1), while
		# person-to-person clearance is enforced by RestaurantWorld.can_agent_step.
		# Letting both systems solve the same contact made a FIFO line deadlock:
		# Godot's capsule recovery rejected a step *away* from a nearby diner even
		# though the deterministic avoidance solver correctly approved it.
		collision_mask = 1
	var accepted := move_to(target)
	if not accepted and navigation_failed:
		phase = "route_failed"
	return accepted


func tick_motion(delta: float) -> void:
	match phase:
		"walking":
			if reaction_delay > 0.0:
				reaction_delay -= delta
				velocity = Vector3.ZERO
				play_animation("Idle")
				return
			if navigation_failed:
				if route_retries < 3:
					route_retries += 1
					repath_cooldown = 0.0
					_repath()
				else:
					phase = "route_failed"
				return
			if advance_path(delta):
				# find_path can deliberately end at the nearest reachable fallback.
				# That is not arrival at a seat/door and must never advance the FSM.
				phase = "arrived" if _flat_distance(global_position, destination) <= 0.78 else "route_failed"
				collision_mask = 3
				play_animation("Idle")
		"moving_to_seat":
			_tick_local_seat(delta)
		"moving_from_seat":
			_tick_local_leave(delta)
		"sit_transition":
			transition_remaining -= delta
			if transition_remaining <= 0.0:
				_lock_animation_pose("SitDown", 1.0)
				phase = "seated"
				seated = true
				collision_mask = 3
		"seated":
			_maintain_seated_pose()
		"stand_transition":
			transition_remaining -= delta
			if transition_remaining <= 0.0:
				phase = "standing_ready"
				seated = false
				play_animation("Idle")


func begin_seating(assignment: Dictionary, table_center: Vector3) -> void:
	seat_assignment = assignment.duplicate(true)
	_seat_center = table_center
	_local_target = Vector3(assignment.get("position", global_position))
	_local_target.y = 0.0
	var direction := _local_target.direction_to(_seat_center)
	_seat_facing = atan2(direction.x, direction.z)
	phase = "moving_to_seat"
	# The short chair-to-seat transition intentionally ignores the chair/table
	# physics body.  This diner remains an avoidance obstacle for everybody else.
	collision_mask = 0
	play_animation("Walk")


func _tick_local_seat(delta: float) -> void:
	var distance := _flat_distance(global_position, _local_target)
	if distance > 0.025:
		var direction := global_position.direction_to(_local_target)
		global_position = global_position.move_toward(_local_target, minf(distance, movement_speed * delta * 0.72))
		rotation.y = lerp_angle(rotation.y, atan2(direction.x, direction.z), 1.0 - exp(-delta * 12.0))
		return
	global_position = _local_target
	rotation.y = _seat_facing
	velocity = Vector3.ZERO
	phase = "sit_transition"
	play_animation("SitDown")
	transition_remaining = _animation_length("SitDown", 0.96)


func set_seated_mode(value: String, has_meal: bool = false) -> void:
	_seated_mode = value
	meal_present = has_meal
	if phase == "seated":
		_maintain_seated_pose()


func begin_standing() -> void:
	if phase == "stand_transition" or phase == "standing_ready":
		return
	seated = true
	phase = "stand_transition"
	rotation.y = _seat_facing
	play_animation("StandUp")
	transition_remaining = _animation_length("StandUp", 1.30)


func leave_seat_to_staging(target: Vector3) -> void:
	_local_target = Vector3(target.x, 0.0, target.z)
	# Local chair transitions do not go through move_to(), therefore keep the
	# canonical destination in sync for is_at("exit_stage") and diagnostics.
	destination = _local_target
	target_tag = "exit_stage"
	phase = "moving_from_seat"
	collision_mask = 0
	play_animation("Walk")


func _tick_local_leave(delta: float) -> void:
	var distance := _flat_distance(global_position, _local_target)
	if distance > 0.025:
		var direction := global_position.direction_to(_local_target)
		global_position = global_position.move_toward(_local_target, minf(distance, movement_speed * delta * 0.72))
		rotation.y = lerp_angle(rotation.y, atan2(direction.x, direction.z), 1.0 - exp(-delta * 12.0))
		return
	global_position = _local_target
	velocity = Vector3.ZERO
	phase = "arrived"
	collision_mask = 3
	play_animation("Idle")


func _maintain_seated_pose() -> void:
	global_position = Vector3(Vector3(seat_assignment.get("position", global_position)).x, 0.0, Vector3(seat_assignment.get("position", global_position)).z)
	var yaw_offset := 0.0
	if _seated_mode in ["waiting", "conversation"] and party != null and int(party.get("group_size")) > 1:
		yaw_offset = sin(Time.get_ticks_msec() * 0.00055 + _phase_seed) * 0.085
	elif _seated_mode == "eating" and meal_present:
		yaw_offset = sin(Time.get_ticks_msec() * 0.00042 + _phase_seed) * 0.025
	rotation.y = _seat_facing + yaw_offset
	_lock_animation_pose("SitDown", 1.0)


func _animation_length(requested: String, fallback: float) -> float:
	var result := fallback
	for player: AnimationPlayer in animation_players:
		var resolved := resolve_animation(player, requested)
		if resolved.is_empty():
			continue
		var animation := player.get_animation(resolved)
		if animation != null:
			result = maxf(result, animation.length)
	return result


func _lock_animation_pose(requested: String, normalized_time: float) -> void:
	current_animation = requested
	for player: AnimationPlayer in animation_players:
		var resolved := resolve_animation(player, requested)
		if resolved.is_empty():
			continue
		var animation := player.get_animation(resolved)
		if animation == null:
			continue
		if player.current_animation != resolved:
			player.play(resolved, 0.08)
		player.seek(animation.length * clampf(normalized_time, 0.0, 1.0), true)
		player.pause()


func _randomize_idle_phase() -> void:
	for player: AnimationPlayer in animation_players:
		var resolved := resolve_animation(player, "Idle")
		if resolved.is_empty():
			continue
		var animation := player.get_animation(resolved)
		if animation != null and animation.length > 0.1:
			player.seek(randf_range(0.0, animation.length), true)


func is_at(tag: String) -> bool:
	return phase == "arrived" and target_tag == tag and _flat_distance(global_position, destination) <= 0.78


func is_transitioning() -> bool:
	return phase in ["moving_to_seat", "moving_from_seat", "sit_transition", "stand_transition"]


func get_avoidance_points() -> Array[Vector3]:
	return [global_position]
