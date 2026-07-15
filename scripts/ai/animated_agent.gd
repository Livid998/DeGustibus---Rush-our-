class_name AnimatedAgent
extends CharacterBody3D

const SKIN_TONES: Array[Color] = [
	Color("e3b0ad"),
	Color("cf9698"),
	Color("b97d85"),
	Color("a26775"),
	Color("875164"),
	Color("663d50")
]

static var _face_shader: Shader

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
var agent_radius := 0.34
var arrival_tolerance := 0.16
var animation_players: Array[AnimationPlayer] = []
var current_animation := ""
var stuck_time := 0.0
var total_stuck_time := 0.0
var repath_cooldown := 0.0
var _collision_shape: CollisionShape3D


func configure_navigation(radius: float = 0.34, priority: int = 1) -> void:
	agent_radius = radius
	navigation_priority = priority
	collision_layer = 2
	collision_mask = 3
	if _collision_shape == null:
		_collision_shape = CollisionShape3D.new()
		_collision_shape.name = "AgentCollider"
		var capsule := CapsuleShape3D.new()
		capsule.radius = agent_radius
		capsule.height = 1.62
		_collision_shape.shape = capsule
		_collision_shape.position.y = 0.81
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
	model.position = offset
	add_child(model)
	if skin_tone.a <= 0.0:
		skin_tone = SKIN_TONES.pick_random()
	_apply_character_palette(model, skin_tone)
	_add_blob_shadow(model)
	var players := ModelFactory.find_animation_players(model)
	animation_players.append_array(players)
	return model


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
				var skin_material := (source as StandardMaterial3D).duplicate() as StandardMaterial3D
				skin_material.albedo_color = skin_tone
				mesh_instance.set_surface_override_material(surface, skin_material)
			elif material_name == "face":
				var face_material := ShaderMaterial.new()
				face_material.shader = _character_face_shader()
				face_material.set_shader_parameter("feature_color", Color("15141a"))
				face_material.set_shader_parameter("brow_color", hair_color.darkened(0.12))
				var bounds := mesh_instance.mesh.get_aabb()
				face_material.set_shader_parameter("brow_height", bounds.position.y + bounds.size.y * 0.808)
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
	for animation_name: StringName in player.get_animation_list():
		var simple := String(animation_name).get_slice("/", String(animation_name).get_slice_count("/") - 1)
		if simple.to_lower() == requested.to_lower() or String(animation_name).to_lower() == requested.to_lower():
			return animation_name
	return &""


func move_to(target: Vector3) -> bool:
	destination = Vector3(target.x, 0.0, target.z)
	navigation_failed = false
	set_collision_enabled(true)
	stuck_time = 0.0
	total_stuck_time = 0.0
	repath_cooldown = 0.0
	if _flat_distance(global_position, destination) <= arrival_tolerance:
		navigation_active = false
		path.clear()
		path_index = 0
		velocity = Vector3.ZERO
		play_animation("Idle")
		return true
	navigation_active = true
	return _repath()


func _repath() -> bool:
	if world == null:
		navigation_failed = true
		return false
	path = world.find_path(global_position, destination)
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
		_complete_navigation()
		return true
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
	if route_progress < minf(movement_speed * delta * 0.06, 0.02):
		stuck_time += delta
		total_stuck_time += delta
	else:
		stuck_time = maxf(stuck_time - delta * 1.8, 0.0)
		total_stuck_time = maxf(total_stuck_time - delta * 0.35, 0.0)
	if stuck_time >= 0.7 and repath_cooldown <= 0.0:
		stuck_time = 0.0
		repath_cooldown = 0.35
		_repath()
	if total_stuck_time >= 5.0:
		navigation_failed = true
		navigation_active = false
		velocity = Vector3.ZERO
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
		_complete_navigation()
		return true
	return false


func _move_with_collisions(motion: Vector3) -> void:
	var remaining := motion
	var step_count := maxi(ceili(remaining.length() / 0.24), 1)
	var step := remaining / float(step_count)
	for _index: int in step_count:
		if step.length_squared() <= 0.000001:
			break
		if world != null and not world.can_agent_step(self, global_position, global_position + step):
			var side := Vector3(-step.z, 0.0, step.x) * 0.72
			if world.can_agent_step(self, global_position, global_position + side):
				step = side
			else:
				velocity = velocity.move_toward(Vector3.ZERO, movement_acceleration * 0.08)
				break
		var collision := move_and_collide(step)
		if collision != null:
			var slide := collision.get_remainder().slide(collision.get_normal())
			if slide.length_squared() > 0.00001 and (world == null or world.can_agent_step(self, global_position, global_position + slide)):
				move_and_collide(slide)


func _skip_reached_waypoints() -> void:
	while path_index < path.size() and _flat_distance(global_position, path[path_index]) <= arrival_tolerance:
		path_index += 1


func _complete_navigation() -> void:
	navigation_active = false
	navigation_failed = false
	velocity = Vector3.ZERO
	var exact_destination := Vector3(destination.x, 0.0, destination.z)
	if world == null or world.can_agent_step(self, global_position, exact_destination):
		global_position = exact_destination
	play_animation("Idle")


func set_collision_enabled(enabled: bool) -> void:
	if _collision_shape != null:
		_collision_shape.disabled = not enabled
	if not enabled:
		velocity = Vector3.ZERO
		navigation_active = false
		path.clear()
		path_index = 0


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
