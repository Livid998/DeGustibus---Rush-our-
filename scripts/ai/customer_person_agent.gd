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
var _seated_clock := 0.0
var _bite_elapsed := 0.0
var _bite_duration := 1.0
var _next_bite_in := 1.0
var _bite_active := false
var _bite_count := 0
var _skeleton: Skeleton3D
var _bone_indices: Dictionary = {}
var _utensil_attachment: BoneAttachment3D
var _utensil_model: Node3D
var _utensil_kind := "fork"


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
	_configure_seated_rig()
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
			_maintain_seated_pose(delta)
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


func set_seated_mode(value: String, has_meal: bool = false, utensil_kind: String = "fork") -> void:
	var mode_changed := _seated_mode != value or meal_present != has_meal
	_seated_mode = value
	meal_present = has_meal
	_utensil_kind = utensil_kind
	if mode_changed:
		_bite_active = false
		_bite_elapsed = 0.0
		_next_bite_in = randf_range(1.0, 2.2)
		if _seated_mode == "eating" and meal_present:
			_show_utensil()
		else:
			_hide_utensil()
	if phase == "seated":
		_maintain_seated_pose(0.0)


func begin_standing() -> void:
	if phase == "stand_transition" or phase == "standing_ready":
		return
	_hide_utensil()
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


func _maintain_seated_pose(delta: float = 0.0) -> void:
	global_position = Vector3(Vector3(seat_assignment.get("position", global_position)).x, 0.0, Vector3(seat_assignment.get("position", global_position)).z)
	rotation.y = _seat_facing
	_lock_animation_pose("SitDown", 1.0)
	_seated_clock += delta
	if _seated_mode == "eating" and meal_present:
		_update_eating_gesture(delta)
		_keep_utensil_above_table()
	else:
		_bite_active = false
		_apply_conversation_gesture()


func _configure_seated_rig() -> void:
	for candidate: Node in visual_model.find_children("*", "Skeleton3D", true, false):
		_skeleton = candidate as Skeleton3D
		break
	if _skeleton == null:
		return
	for bone_name: String in ["Head", "Torso", "UpperArm.R", "LowerArm.R", "Fist.R", "UpperArm.L", "LowerArm.L"]:
		_bone_indices[bone_name] = _skeleton.find_bone(bone_name)
	if int(_bone_indices.get("Fist.R", -1)) >= 0:
		_utensil_attachment = BoneAttachment3D.new()
		_utensil_attachment.name = "DiningUtensilAnchor"
		_utensil_attachment.bone_name = "Fist.R"
		_skeleton.add_child(_utensil_attachment)


func _update_eating_gesture(delta: float) -> void:
	if not _bite_active:
		_next_bite_in -= delta
		if _next_bite_in <= 0.0:
			_bite_active = true
			_bite_elapsed = 0.0
			_bite_duration = randf_range(0.88, 1.24)
			_bite_count += 1
	if not _bite_active:
		# A quiet seated idle between bites: breathing and a tiny glance, not a
		# permanent loop of the same eating motion.
		_apply_bone_delta("Head", Vector3.UP, sin(_seated_clock * 0.72 + _phase_seed) * 0.025)
		_apply_bone_delta("Torso", Vector3.RIGHT, sin(_seated_clock * 1.05 + _phase_seed) * 0.012)
		return
	_bite_elapsed += delta
	var progress := clampf(_bite_elapsed / maxf(_bite_duration, 0.01), 0.0, 1.0)
	# Smooth anticipation -> bite -> recovery. The arm reaches the face only in
	# the middle third; head and torso meet it slightly instead of hinging as one.
	var weight := sin(progress * PI)
	var anticipation := smoothstep(0.0, 0.35, progress) * (1.0 - smoothstep(0.68, 1.0, progress))
	_apply_bone_delta("UpperArm.R", Vector3.RIGHT, -0.72 * weight)
	_apply_bone_delta("LowerArm.R", Vector3.RIGHT, -0.92 * weight)
	_apply_bone_delta("Fist.R", Vector3.FORWARD, 0.18 * weight)
	_apply_bone_delta("Torso", Vector3.RIGHT, -0.09 * anticipation)
	_apply_bone_delta("Head", Vector3.RIGHT, 0.08 * anticipation)
	_apply_bone_delta("Head", Vector3.UP, sin(progress * PI * 2.0) * 0.018)
	if progress >= 1.0:
		_bite_active = false
		_bite_elapsed = 0.0
		_next_bite_in = randf_range(1.35, 3.10)


func _apply_conversation_gesture() -> void:
	if party == null or int(party.get("group_size")) <= 1:
		_apply_bone_delta("Torso", Vector3.RIGHT, sin(_seated_clock * 0.9 + _phase_seed) * 0.012)
		return
	var glance := sin(_seated_clock * 0.58 + _phase_seed)
	var emphasis := pow(absf(sin(_seated_clock * 0.31 + _phase_seed * 0.7)), 7.0)
	_apply_bone_delta("Head", Vector3.UP, glance * 0.10)
	_apply_bone_delta("Torso", Vector3.UP, glance * 0.035)
	_apply_bone_delta("UpperArm.L", Vector3.FORWARD, emphasis * 0.10)
	_apply_bone_delta("LowerArm.L", Vector3.RIGHT, -emphasis * 0.12)


func _apply_bone_delta(bone_name: String, axis: Vector3, angle: float) -> void:
	if _skeleton == null:
		return
	var bone_index := int(_bone_indices.get(bone_name, -1))
	if bone_index < 0:
		return
	var base := _skeleton.get_bone_pose_rotation(bone_index)
	_skeleton.set_bone_pose_rotation(bone_index, base * Quaternion(axis.normalized(), angle))


func _show_utensil() -> void:
	if _utensil_attachment == null:
		return
	_hide_utensil()
	var path := "res://assets/equipment/utensil_spoon.glb" if _utensil_kind == "spoon" else "res://assets/equipment/utensil_fork.glb"
	if not ResourceLoader.exists(path):
		return
	# The previous utensil was technically attached but too small and buried in
	# the fist. A readable silhouette is more important than literal real scale
	# at the game's isometric camera distance.
	_utensil_model = Node3D.new()
	_utensil_model.name = "DiningUtensil"
	var visual := ModelFactory.instantiate_model(path, 0.62)
	visual.name = "UtensilVisual"
	_utensil_model.add_child(visual)
	_align_utensil_handle(visual)
	_utensil_model.position = Vector3(-0.02, -0.01, -0.16)
	_utensil_model.rotation = Vector3(-PI * 0.46, 0.0, PI * 0.08)
	ModelFactory.set_shadow_casting(_utensil_model, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	_utensil_attachment.add_child(_utensil_model)
	_keep_utensil_above_table()


func _align_utensil_handle(visual: Node3D) -> void:
	var bounds := ModelFactory.calculate_visual_bounds(visual, true)
	if bounds.size.is_zero_approx():
		return
	var center := bounds.get_center()
	# Forks/spoons are authored along local X. Put the very end of the handle in
	# the fist and let the utensil extend outwards; centering it made the hand
	# visibly grab the middle of the shaft.
	visual.position += Vector3(-center.x + bounds.size.x * 0.44, -center.y, -center.z)


func _keep_utensil_above_table() -> void:
	if _utensil_model == null or not is_instance_valid(_utensil_model):
		return
	var table_y := 1.0
	if party != null:
		var party_table: Dictionary = party.get("table")
		table_y = float(party_table.get("table_surface_y", table_y))
	var position := _utensil_model.global_position
	position.y = maxf(position.y, table_y + 0.10)
	_utensil_model.global_position = position


func _hide_utensil() -> void:
	if _utensil_model != null and is_instance_valid(_utensil_model):
		_utensil_model.queue_free()
	_utensil_model = null


func is_biting() -> bool:
	return _bite_active and meal_present and _seated_mode == "eating"


func bite_count() -> int:
	return _bite_count


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
