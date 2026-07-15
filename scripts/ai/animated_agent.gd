class_name AnimatedAgent
extends Node3D

var world: RestaurantWorld
var movement_speed := 2.5
var path: PackedVector3Array = PackedVector3Array()
var path_index := 0
var animation_players: Array[AnimationPlayer] = []
var current_animation := ""


func add_character_model(model_path: String, offset: Vector3 = Vector3.ZERO) -> Node3D:
	var model := ModelFactory.instantiate_model(model_path)
	model.position = offset
	add_child(model)
	_add_blob_shadow(model)
	var players := ModelFactory.find_animation_players(model)
	animation_players.append_array(players)
	return model


func _add_blob_shadow(model: Node3D) -> void:
	var shadow := MeshInstance3D.new()
	shadow.name = "BlobShadow"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.3
	mesh.bottom_radius = 0.3
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
	if current_animation == requested:
		return
	current_animation = requested
	for player: AnimationPlayer in animation_players:
		var resolved := resolve_animation(player, requested)
		if resolved.is_empty():
			resolved = resolve_animation(player, "Idle")
		if not resolved.is_empty():
			player.play(resolved, 0.16)


func resolve_animation(player: AnimationPlayer, requested: String) -> StringName:
	for animation_name: StringName in player.get_animation_list():
		var simple := String(animation_name).get_slice("/", String(animation_name).get_slice_count("/") - 1)
		if simple.to_lower() == requested.to_lower() or String(animation_name).to_lower() == requested.to_lower():
			return animation_name
	return &""


func move_to(target: Vector3) -> void:
	path = world.find_path(global_position, target)
	path_index = 0
	if path.is_empty():
		path = PackedVector3Array([target])


func advance_path(delta: float, carry: bool = false) -> bool:
	if path_index >= path.size():
		play_animation("Idle")
		return true
	var target := path[path_index]
	var flat_target := Vector3(target.x, global_position.y, target.z)
	var distance := global_position.distance_to(flat_target)
	if distance < 0.12:
		path_index += 1
		return path_index >= path.size()
	var direction := global_position.direction_to(flat_target)
	global_position += direction * minf(movement_speed * delta, distance)
	if direction.length_squared() > 0.001:
		var desired := atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, desired, minf(delta * 10.0, 1.0))
	play_animation("Walk_Carry" if carry and has_animation("Walk_Carry") else "Walk")
	return false
