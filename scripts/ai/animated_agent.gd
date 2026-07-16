class_name AnimatedAgent
extends CharacterBody3D

const CHARACTER_FOOT_LIFT := 0.08
const TRAFFIC_REPATH_INTERVAL := 0.85
const RECOVERY_PROBE_TIME := 1.65
const HARD_NAVIGATION_TIMEOUT := 12.0

static var _next_route_ticket := 1

const SKIN_TONES: Array[Color] = [
	Color("e3b0ad"),
	Color("cf9698"),
	Color("b97d85"),
	Color("a26775"),
	Color("875164"),
	Color("663d50")
]

static var _face_shader: Shader
static var _skin_material_cache: Dictionary = {}
static var _face_material_cache: Dictionary = {}

var world: RestaurantWorld
var movement_speed := 2.5
var movement_acceleration := 12.0
var path: PackedVector3Array = PackedVector3Array()
var path_index := 0
var destination := Vector3.ZERO
var navigation_active := false
var navigation_failed := false
var navigation_priority := 1
var navigation_revision := -1
var agent_radius := 0.40
var arrival_tolerance := 0.16
var animation_players: Array[AnimationPlayer] = []
var current_animation := ""
var stuck_time := 0.0
var total_stuck_time := 0.0
var repath_cooldown := 0.0
var traffic_wait_time := 0.0
var traffic_denials := 0
var route_ticket := 0
var recovery_count := 0
var _collision_shape: CollisionShape3D
var _animation_resolution_cache: Dictionary = {}
var _traffic_repath_clock := 0.0
var _corridor_bypass_path_index := -1
var _traffic_pullout_active := false
var _traffic_pullout_position := Vector3.ZERO


func configure_navigation(radius: float = 0.40, priority: int = 1) -> void:
	agent_radius = radius
	navigation_priority = priority
	collision_layer = 2
	# Furniture/walls remain physical (layer 1). Person-to-person motion is solved
	# once, deterministically, by RestaurantWorld's reciprocal disc reservation.
	# Running Godot capsule recovery on top of it made employees stop against a
	# collider at its previous physics-frame transform and produced the visible
	# shoving/jitter that moving customers (already mask 1) did not exhibit.
	collision_mask = 1
	if _collision_shape == null:
		_collision_shape = CollisionShape3D.new()
		_collision_shape.name = "AgentCollider"
		var capsule := CapsuleShape3D.new()
		capsule.radius = agent_radius
		capsule.height = 2.90
		_collision_shape.shape = capsule
		_collision_shape.position.y = 1.45
		add_child(_collision_shape)
	else:
		(_collision_shape.shape as CapsuleShape3D).radius = agent_radius
	if world != null:
		world.register_navigation_agent(self)


func shutdown_navigation() -> void:
	if world != null:
		world.unregister_navigation_agent(self)
	navigation_active = false
	velocity = Vector3.ZERO


func _exit_tree() -> void:
	shutdown_navigation()


func add_character_model(model_path: String, offset: Vector3 = Vector3.ZERO, skin_tone: Color = Color.TRANSPARENT) -> Node3D:
	var model := ModelFactory.instantiate_model(model_path)
	# The source rigs dip a few centimetres below their origin. Keep the
	# controller on the navigation plane and lift only the rendered character.
	model.position = offset + Vector3.UP * CHARACTER_FOOT_LIFT
	add_child(model)
	if skin_tone.a <= 0.0:
		skin_tone = SKIN_TONES.pick_random()
	_apply_character_palette(model, skin_tone)
	# Characters already use a cheap blob shadow. Avoid rendering every skinned
	# mesh a second time in the directional shadow pass.
	ModelFactory.set_shadow_casting(model, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	_add_blob_shadow(model)
	var players := ModelFactory.find_animation_players(model)
	animation_players.append_array(players)
	return model


func get_avoidance_points() -> Array[Vector3]:
	var result: Array[Vector3] = [global_position]
	return result


static func skin_tone_for_key(key: String) -> Color:
	return SKIN_TONES[posmod(key.hash(), SKIN_TONES.size())]


func _apply_character_palette(model: Node3D, skin_tone: Color) -> void:
	var meshes: Array[MeshInstance3D] = []
	if model is MeshInstance3D:
		meshes.append(model)
	for node: Node in model.find_children("*", "MeshInstance3D", true, false):
		meshes.append(node as MeshInstance3D)
	for mesh_instance: MeshInstance3D in meshes:
		if mesh_instance.mesh == null:
			continue
		var hair_color := Color("352630")
		for surface: int in mesh_instance.mesh.get_surface_count():
			var source := mesh_instance.get_active_material(surface)
			if source is StandardMaterial3D and String(source.resource_name).to_lower() == "hair":
				hair_color = (source as StandardMaterial3D).albedo_color
		for surface: int in mesh_instance.mesh.get_surface_count():
			var source := mesh_instance.get_active_material(surface)
			if source == null:
				continue
			var material_name := String(source.resource_name).to_lower()
			if material_name == "skin" and source is StandardMaterial3D:
				var skin_key := "%d:%s" % [source.get_instance_id(), skin_tone.to_html()]
				var skin_material: StandardMaterial3D = _skin_material_cache.get(skin_key)
				if skin_material == null:
					skin_material = (source as StandardMaterial3D).duplicate() as StandardMaterial3D
					skin_material.albedo_color = skin_tone
					_skin_material_cache[skin_key] = skin_material
				mesh_instance.set_surface_override_material(surface, skin_material)
			elif material_name == "face":
				var bounds := mesh_instance.mesh.get_aabb()
				var brow_height := bounds.position.y + bounds.size.y * 0.808
				var face_key := "%s:%.4f" % [hair_color.to_html(), brow_height]
				var face_material: ShaderMaterial = _face_material_cache.get(face_key)
				if face_material == null:
					face_material = ShaderMaterial.new()
					face_material.shader = _character_face_shader()
					face_material.set_shader_parameter("feature_color", Color("15141a"))
					face_material.set_shader_parameter("brow_color", hair_color.darkened(0.12))
					face_material.set_shader_parameter("brow_height", brow_height)
					_face_material_cache[face_key] = face_material
				mesh_instance.set_surface_override_material(surface, face_material)


static func _character_face_shader() -> Shader:
	if _face_shader != null:
		return _face_shader
	_face_shader = Shader.new()
	_face_shader.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
uniform vec4 feature_color : source_color = vec4(0.08, 0.07, 0.09, 1.0);
uniform vec4 brow_color : source_color = vec4(0.16, 0.10, 0.11, 1.0);
uniform float brow_height = 2.67;
varying float model_height;
void vertex() {
	model_height = VERTEX.y;
}
void fragment() {
	float eyebrow = smoothstep(brow_height - 0.012, brow_height + 0.012, model_height);
	ALBEDO = mix(feature_color.rgb, brow_color.rgb, eyebrow);
	ROUGHNESS = 0.62;
}
"""
	return _face_shader


func _add_blob_shadow(model: Node3D) -> void:
	var shadow := MeshInstance3D.new()
	shadow.name = "BlobShadow"
	var mesh := CylinderMesh.new()
	mesh.top_radius = agent_radius * 0.95
	mesh.bottom_radius = agent_radius * 0.95
	mesh.height = 0.012
	mesh.radial_segments = 20
	shadow.mesh = mesh
	shadow.position.y = 0.018
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.04, 0.12, 0.13, 0.2)
	shadow.material_override = material
	model.add_child(shadow)


func validate_animations() -> void:
	_configure_animation_loops()
	for required: String in ["Idle", "Walk"]:
		if not has_animation(required):
			push_error("Character %s misses required animation %s" % [name, required])
	play_animation("Idle")


func has_animation(requested: String) -> bool:
	for player: AnimationPlayer in animation_players:
		if not resolve_animation(player, requested).is_empty():
			return true
	return false


func play_animation(requested: String) -> void:
	var all_running := current_animation == requested
	if all_running:
		for player: AnimationPlayer in animation_players:
			var expected := resolve_animation(player, requested)
			if expected.is_empty():
				expected = resolve_animation(player, "Idle")
			if not player.is_playing() or player.current_animation != expected:
				all_running = false
				break
	if all_running:
		return
	current_animation = requested
	for player: AnimationPlayer in animation_players:
		var resolved := resolve_animation(player, requested)
		if resolved.is_empty():
			resolved = resolve_animation(player, "Idle")
		if not resolved.is_empty():
			player.speed_scale = 1.0 if requested == "Idle" else SimulationManager.simulation_speed
			player.play(resolved, 0.16)


func _configure_animation_loops() -> void:
	for player: AnimationPlayer in animation_players:
		for requested: String in ["Idle", "Walk", "Walk_Carry", "Run", "Run_Carry"]:
			var resolved := resolve_animation(player, requested)
			if resolved.is_empty():
				continue
			var animation := player.get_animation(resolved)
			if animation != null:
				animation.loop_mode = Animation.LOOP_LINEAR


func resolve_animation(player: AnimationPlayer, requested: String) -> StringName:
	var cache_key := "%d:%s" % [player.get_instance_id(), requested.to_lower()]
	if _animation_resolution_cache.has(cache_key):
		return StringName(_animation_resolution_cache[cache_key])
	for animation_name: StringName in player.get_animation_list():
		var simple := String(animation_name).get_slice("/", String(animation_name).get_slice_count("/") - 1)
		if simple.to_lower() == requested.to_lower() or String(animation_name).to_lower() == requested.to_lower():
			_animation_resolution_cache[cache_key] = animation_name
			return animation_name
	_animation_resolution_cache[cache_key] = &""
	return &""


func move_to(target: Vector3) -> bool:
	destination = Vector3(target.x, 0.0, target.z)
	route_ticket = _next_route_ticket
	_next_route_ticket += 1
	navigation_failed = false
	set_collision_enabled(true)
	stuck_time = 0.0
	total_stuck_time = 0.0
	repath_cooldown = 0.0
	traffic_wait_time = 0.0
	traffic_denials = 0
	_traffic_repath_clock = 0.0
	_corridor_bypass_path_index = -1
	_traffic_pullout_active = false
	if _flat_distance(global_position, destination) <= arrival_tolerance:
		navigation_active = false
		path.clear()
		path_index = 0
		velocity = Vector3.ZERO
		play_animation("Idle")
		return true
	navigation_active = true
	var accepted := _repath()
	# A controller may assign the next route in the same tick in which the
	# previous leg finished. Start locomotion immediately so that frame cannot
	# be rendered as an Idle pose sliding away from the waypoint.
	play_animation("Walk" if accepted else "Idle")
	return accepted


func _repath() -> bool:
	if world == null:
		navigation_failed = true
		return false
	path = world.find_path(global_position, destination, self)
	path_index = 0
	navigation_revision = world.navigation_revision
	_skip_reached_waypoints()
	if path_index >= path.size() and _flat_distance(global_position, destination) > arrival_tolerance:
		navigation_failed = true
		navigation_active = false
		velocity = Vector3.ZERO
		return false
	navigation_failed = false
	return true


func advance_path(delta: float, carry: bool = false) -> bool:
	if navigation_failed:
		play_animation("Idle")
		return false
	if not navigation_active:
		play_animation("Idle")
		return true
	repath_cooldown = maxf(repath_cooldown - delta, 0.0)
	if world != null and navigation_revision != world.navigation_revision and repath_cooldown <= 0.0:
		repath_cooldown = 0.18
		if not _repath():
			return false
	_skip_reached_waypoints()
	if path_index >= path.size():
		return _complete_navigation()
	var corridor_check_required := _corridor_bypass_path_index < 0 or path_index >= _corridor_bypass_path_index
	if corridor_check_required and world != null and not world.can_agent_advance_route(self, path, path_index):
		# Waiting outside a reserved one-person corridor is intentional, not a
		# navigation failure. After a short pause, however, ask the traffic-aware
		# planner for a genuine alternate route instead of queueing unnecessarily.
		velocity = velocity.move_toward(Vector3.ZERO, movement_acceleration * delta)
		stuck_time = 0.0
		traffic_wait_time += delta
		traffic_denials += 1
		_traffic_repath_clock += delta
		var installed_detour := false
		var already_holding_clear := _traffic_pullout_active and _flat_distance(global_position, _traffic_pullout_position) <= 0.38
		if traffic_wait_time >= 0.65 and not already_holding_clear:
			installed_detour = _try_install_recovery_detour()
		if not installed_detour and _traffic_repath_clock >= TRAFFIC_REPATH_INTERVAL and repath_cooldown <= 0.0:
			_traffic_repath_clock = 0.0
			repath_cooldown = 0.35
			_repath()
		play_animation("Idle")
		return false
	traffic_wait_time = 0.0
	traffic_denials = 0
	_traffic_repath_clock = 0.0
	if corridor_check_required:
		_traffic_pullout_active = false
	if _corridor_bypass_path_index >= 0 and path_index >= _corridor_bypass_path_index:
		_corridor_bypass_path_index = -1
	var target := path[path_index]
	var flat_target := Vector3(target.x, global_position.y, target.z)
	var distance_to_target := global_position.distance_to(flat_target)
	var direction := global_position.direction_to(flat_target)
	var desired_velocity := direction * minf(movement_speed, distance_to_target / maxf(delta, 0.001))
	if world != null:
		desired_velocity = world.compute_agent_velocity(self, desired_velocity)
	velocity = velocity.move_toward(desired_velocity, movement_acceleration * delta)
	velocity.y = 0.0
	var before := global_position
	var distance_before := _flat_distance(before, flat_target)
	var frame_motion := velocity * delta
	if frame_motion.length() > distance_to_target and desired_velocity.dot(velocity) > 0.0:
		frame_motion = direction * distance_to_target
	_move_with_collisions(frame_motion)
	global_position.y = 0.0
	var progress := _flat_distance(before, global_position)
	var route_progress := distance_before - _flat_distance(global_position, flat_target)
	var minimum_visible_motion := minf(movement_speed * delta * 0.08, 0.016)
	if route_progress < minf(movement_speed * delta * 0.06, 0.02) and progress < minimum_visible_motion:
		stuck_time += delta
		total_stuck_time += delta
	elif route_progress < minf(movement_speed * delta * 0.06, 0.02):
		# A reciprocal sidestep/back-off is useful traffic resolution, not a hard
		# navigation stall. Keep a small debt so a true orbit eventually triggers a
		# new route, but never time out an agent that is visibly clearing space.
		stuck_time = maxf(stuck_time - delta * 2.0, 0.0)
		total_stuck_time = maxf(total_stuck_time + delta * 0.12, 0.0)
	else:
		stuck_time = maxf(stuck_time - delta * 3.0, 0.0)
		# Successful forward travel must clear old congestion debt quickly. The
		# previous slow decay could fail a perfectly healthy long route after a
		# handful of unrelated, short waits.
		total_stuck_time = maxf(total_stuck_time - delta * 4.0, 0.0)
	if stuck_time >= 0.7 and repath_cooldown <= 0.0:
		stuck_time = 0.0
		repath_cooldown = 0.35
		_repath()
	if total_stuck_time >= RECOVERY_PROBE_TIME:
		_try_install_recovery_detour()
	if total_stuck_time >= HARD_NAVIGATION_TIMEOUT:
		navigation_failed = true
		navigation_active = false
		velocity = Vector3.ZERO
		if world != null:
			world.finish_agent_navigation(self)
		play_animation("Idle")
		return false
	if direction.length_squared() > 0.001:
		var desired_rotation := atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, desired_rotation, 1.0 - exp(-delta * 11.0))
	if progress <= 0.012:
		play_animation("Idle")
	else:
		play_animation("Walk_Carry" if carry and has_animation("Walk_Carry") else "Walk")
		_update_walk_playback(progress / maxf(delta, 0.001))
	_skip_reached_waypoints()
	if path_index >= path.size():
		return _complete_navigation()
	return false


func _move_with_collisions(motion: Vector3) -> void:
	var step_count := maxi(ceili(motion.length() / 0.24), 1)
	var base_step := motion / float(step_count)
	for _index: int in step_count:
		# Each sub-step starts from the requested route vector. A successful
		# diagonal dodge is local to that contact; carrying the rotated vector into
		# every remaining sub-step made characters drift sideways after passing.
		var step := base_step
		if step.length_squared() <= 0.000001:
			break
		if world != null and not world.can_agent_step(self, global_position, global_position + step):
			var detour_found := false
			# Dynamic avoidance has already selected a reciprocal velocity. Do not
			# replace it with a second, contradictory contact dodge. Alternate angles
			# are only a fallback for a static grid edge discovered during the step.
			if not world.can_agent_move(global_position, global_position + step, agent_radius):
				for angle: float in [PI * 0.25, -PI * 0.25, PI * 0.5, -PI * 0.5]:
					var detour := step.rotated(Vector3.UP, angle)
					if world.can_agent_step(self, global_position, global_position + detour) and not test_move(global_transform, detour):
						step = detour
						detour_found = true
						break
			if not detour_found:
				velocity = velocity.move_toward(Vector3.ZERO, movement_acceleration * 0.08)
				break
		var collision := move_and_collide(step)
		if collision != null:
			if collision.get_collider() is AnimatedAgent:
				velocity = velocity.move_toward(Vector3.ZERO, movement_acceleration * 0.08)
				break
			var slide := collision.get_remainder().slide(collision.get_normal())
			if slide.length_squared() > 0.00001 and (world == null or world.can_agent_step(self, global_position, global_position + slide)):
				move_and_collide(slide)


func _try_install_recovery_detour() -> bool:
	if world == null or not navigation_active or repath_cooldown > 0.0 or _traffic_pullout_active:
		return false
	var recovery: Dictionary = world.find_agent_recovery_detour(self, destination)
	var recovery_path: PackedVector3Array = recovery.get("path", PackedVector3Array())
	if recovery_path.is_empty():
		return false
	path = recovery_path
	path_index = 0
	navigation_revision = world.navigation_revision
	_corridor_bypass_path_index = int(recovery.get("release_index", -1))
	_traffic_pullout_position = Vector3(recovery.get("pullout", global_position))
	_traffic_pullout_active = true
	_skip_reached_waypoints()
	stuck_time = 0.0
	total_stuck_time = 0.0
	traffic_wait_time = 0.0
	traffic_denials = 0
	_traffic_repath_clock = 0.0
	repath_cooldown = 0.55
	recovery_count += 1
	return path_index < path.size()


func _skip_reached_waypoints() -> void:
	while path_index < path.size():
		if _flat_distance(global_position, path[path_index]) <= arrival_tolerance:
			path_index += 1
			continue
		# In open rooms a grid-centre waypoint is only a guide, not a mandatory
		# occupancy slot. Skipping a nearby guide when the following segment is
		# clear prevents agents from orbiting a colleague standing on that centre.
		if world != null and world.can_agent_skip_open_waypoint(self, path, path_index):
			path_index += 1
			continue
		break


func _complete_navigation() -> bool:
	navigation_active = false
	navigation_failed = false
	velocity = Vector3.ZERO
	_corridor_bypass_path_index = -1
	_traffic_pullout_active = false
	traffic_wait_time = 0.0
	traffic_denials = 0
	var exact_destination := Vector3(destination.x, 0.0, destination.z)
	if world == null or world.can_agent_step(self, global_position, exact_destination):
		global_position = exact_destination
	if world != null:
		world.finish_agent_navigation(self)
	play_animation("Idle")
	return true


func set_collision_enabled(enabled: bool) -> void:
	if _collision_shape != null:
		_collision_shape.disabled = not enabled
	if not enabled:
		velocity = Vector3.ZERO
		navigation_active = false
		path.clear()
		path_index = 0


func set_traffic_collision_enabled(enabled: bool) -> void:
	# Used after a guest has crossed the exit threshold: the body stops
	# obstructing other agents, but its existing walk-off route and animation
	# continue until it reaches the despawn marker.
	if _collision_shape != null:
		_collision_shape.disabled = not enabled


func is_collision_enabled() -> bool:
	return _collision_shape == null or not _collision_shape.disabled


func _update_walk_playback(actual_speed: float) -> void:
	var speed_ratio := clampf(actual_speed / maxf(movement_speed, 0.01), 0.35, 1.35)
	for player: AnimationPlayer in animation_players:
		player.speed_scale = SimulationManager.simulation_speed * speed_ratio


func face_position(target: Vector3) -> void:
	var direction := global_position.direction_to(Vector3(target.x, global_position.y, target.z))
	if direction.length_squared() > 0.001:
		rotation.y = atan2(direction.x, direction.z)


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
