class_name AnimatedCharacter
extends Node3D

const MALE := "res://assets/third_party/quaternius/characters/Superhero_Male_FullBody.gltf"
const FEMALE := "res://assets/third_party/quaternius/characters/Superhero_Female_FullBody.gltf"
const ANIMATIONS_1 := "res://assets/third_party/quaternius/animations/UAL1_Standard.glb"
const ANIMATIONS_2 := "res://assets/third_party/quaternius/animations/UAL2_Standard.glb"

var animation_player: AnimationPlayer
var skeleton: Skeleton3D
var current_animation := ""
var action_time_left := 0.0
var locomotion_animation := "Idle"

func setup(tint := Color.WHITE, female := false, add_chef_hat := false) -> void:
	var animation_scene := load(ANIMATIONS_1) as PackedScene
	var rig := animation_scene.instantiate() as Node3D
	add_child(rig)
	skeleton = rig.find_child("Skeleton3D", true, false) as Skeleton3D
	animation_player = rig.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var mannequin := rig.find_child("Mannequin", true, false)
	if mannequin:
		mannequin.visible = false
	_install_character_mesh(FEMALE if female else MALE)
	_install_second_library()
	_add_outfit(tint, add_chef_hat)
	if add_chef_hat:
		_add_chef_hat()
	play_state("Idle")

func _install_character_mesh(path: String) -> void:
	var character_scene := load(path) as PackedScene
	var character := character_scene.instantiate() as Node3D
	var source_skeleton := character.find_child("Skeleton3D", true, false) as Skeleton3D
	for child in source_skeleton.get_children().duplicate():
		if child is MeshInstance3D:
			source_skeleton.remove_child(child)
			child.owner = null
			skeleton.add_child(child)
			child.skeleton = NodePath("..")
	character.free()

func _install_second_library() -> void:
	var packed := load(ANIMATIONS_2) as PackedScene
	if packed == null:
		return
	var instance := packed.instantiate()
	var source := instance.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if source and source.has_animation_library(""):
		animation_player.add_animation_library("ual2", source.get_animation_library(""))
	instance.free()

func _add_chef_hat() -> void:
	var hat_root := Node3D.new()
	hat_root.position = Vector3(0, 1.90, 0)
	add_child(hat_root)
	var brim := MeshInstance3D.new()
	var brim_mesh := CylinderMesh.new()
	brim_mesh.top_radius = 0.145
	brim_mesh.bottom_radius = 0.145
	brim_mesh.height = 0.07
	brim.mesh = brim_mesh
	brim.material_override = _white_material()
	hat_root.add_child(brim)
	var crown := MeshInstance3D.new()
	var crown_mesh := CylinderMesh.new()
	crown_mesh.top_radius = 0.125
	crown_mesh.bottom_radius = 0.135
	crown_mesh.height = 0.15
	crown.mesh = crown_mesh
	crown.position.y = 0.12
	crown.material_override = _white_material()
	hat_root.add_child(crown)
	for x in [-0.075, 0.0, 0.075]:
		var puff := MeshInstance3D.new()
		var puff_mesh := SphereMesh.new()
		puff_mesh.radius = 0.085
		puff_mesh.height = 0.15
		puff.mesh = puff_mesh
		puff.position = Vector3(x, 0.235, 0)
		puff.material_override = _white_material()
		hat_root.add_child(puff)

func _add_outfit(color: Color, chef: bool) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	var tunic := MeshInstance3D.new()
	var tunic_mesh := BoxMesh.new()
	tunic_mesh.size = Vector3(0.50, 0.48, 0.24)
	tunic.mesh = tunic_mesh
	tunic.position = Vector3(0, 1.31, 0)
	tunic.material_override = material
	add_child(tunic)
	if chef:
		var apron := MeshInstance3D.new()
		var apron_mesh := BoxMesh.new()
		apron_mesh.size = Vector3(0.43, 0.48, 0.035)
		apron.mesh = apron_mesh
		apron.position = Vector3(0, 1.10, 0.135)
		apron.material_override = _white_material()
		add_child(apron)

func _process(delta: float) -> void:
	if action_time_left <= 0.0:
		return
	action_time_left -= delta
	if action_time_left <= 0.0:
		play_state(locomotion_animation)

func set_locomotion(moving: bool, sprinting: bool, interacting: bool, carrying: bool) -> void:
	if interacting:
		locomotion_animation = "Fixing_Kneeling"
	elif moving and carrying:
		locomotion_animation = "ual2/Walk_Carry"
	elif moving and sprinting:
		locomotion_animation = "Sprint"
	elif moving:
		locomotion_animation = "Jog_Fwd"
	elif carrying:
		locomotion_animation = "Idle_Torch"
	else:
		locomotion_animation = "Idle"
	if action_time_left <= 0.0:
		play_state(locomotion_animation)

func play_action(animation_name: String, duration := 0.65) -> void:
	action_time_left = duration
	play_state(animation_name)

func play_state(animation_name: String) -> void:
	if animation_player == null or current_animation == animation_name or not animation_player.has_animation(animation_name):
		return
	current_animation = animation_name
	animation_player.play(animation_name, 0.16)

func _white_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#fff7e5")
	material.roughness = 0.75
	return material
