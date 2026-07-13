class_name StaffAgent
extends Node3D

var staff_id := ""
var data: Dictionary
var state: Dictionary
var waypoints: Array[Vector3] = []
var target_index := 0
var pause := 0.0
var body: MeshInstance3D
var stress_ring: MeshInstance3D

func setup(id: String, staff_data: Dictionary, staff_state: Dictionary, points: Array) -> void:
	staff_id = id
	data = staff_data
	state = staff_state
	waypoints.clear()
	for point in points:
		waypoints.append(point as Vector3)
	body = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.38
	capsule.height = 1.25
	body.mesh = capsule
	body.position.y = 0.85
	body.material_override = _material(data.color)
	add_child(body)
	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.33
	sphere.height = 0.66
	head.mesh = sphere
	head.position.y = 1.75
	head.material_override = _material(Color("#f2b38f"))
	add_child(head)
	var accessory := MeshInstance3D.new()
	var hat := CylinderMesh.new()
	hat.top_radius = 0.35
	hat.bottom_radius = 0.42
	hat.height = 0.20
	accessory.mesh = hat
	accessory.position.y = 2.08
	accessory.material_override = _material(data.color.lightened(0.18))
	add_child(accessory)
	var label := Label3D.new()
	label.text = "%s · %s" % [data.name, data.role]
	label.font_size = 38
	label.outline_size = 9
	label.position.y = 2.48
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	stress_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.40
	torus.outer_radius = 0.47
	stress_ring.mesh = torus
	stress_ring.position.y = 0.08
	stress_ring.material_override = _material(Color("#ff5d55"), true)
	stress_ring.visible = false
	add_child(stress_ring)

func _process(delta: float) -> void:
	if waypoints.is_empty():
		return
	stress_ring.visible = float(state.stress) >= 58.0
	stress_ring.rotation.y += delta * 2.0
	if pause > 0.0:
		pause -= delta
		return
	var target := waypoints[target_index]
	var flat := Vector3(target.x, global_position.y, target.z)
	var distance := global_position.distance_to(flat)
	if distance < 0.22:
		target_index = (target_index + 1) % waypoints.size()
		pause = 0.8 + float(state.stress) * 0.012
		return
	var speed := float(data.speed) * 0.022 * clampf(1.15 - float(state.stress) * 0.007, 0.45, 1.0)
	global_position = global_position.move_toward(flat, speed * delta)
	look_at(flat, Vector3.UP, true)

func _material(color: Color, emission := false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.78
	if emission:
		mat.emission_enabled = true
		mat.emission = color
	return mat
