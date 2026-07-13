class_name StaffAgent
extends Node3D

var staff_id := ""
var data: Dictionary
var state: Dictionary
var waypoints: Array[Vector3] = []
var target_index := 0
var pause := 0.0
var body: AnimatedCharacter
var stress_ring: MeshInstance3D
var anim_time := 0.0
var delivery_active := false
var delivery_target := Vector3.ZERO
var delivery_callback: Callable
var delivery_plate: Node3D

func setup(id: String, staff_data: Dictionary, staff_state: Dictionary, points: Array) -> void:
	staff_id = id
	data = staff_data
	state = staff_state
	waypoints.clear()
	for point in points:
		waypoints.append(point as Vector3)
	body = AnimatedCharacter.new()
	add_child(body)
	body.setup(data.color.lightened(0.22), staff_id == "cassiera", staff_id == "assistant")
	var label := Label3D.new()
	label.text = "%s · %s" % [data.name, data.role]
	label.font_size = 38
	label.pixel_size = 0.0035
	label.outline_size = 9
	label.position.y = 2.20
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
	delivery_plate = Node3D.new()
	delivery_plate.position = Vector3(0, 1.18, -0.55)
	delivery_plate.visible = false
	add_child(delivery_plate)
	AssetLibrary.add_model(delivery_plate, AssetLibrary.FOOD + "plate-dinner.glb", Vector3.ZERO, Vector3.ONE * 1.2)
	AssetLibrary.add_food(delivery_plate, "burger_ready", Vector3(0, 0.08, 0), 0.75)

func _process(delta: float) -> void:
	if waypoints.is_empty():
		return
	stress_ring.visible = float(state.stress) >= 58.0
	stress_ring.rotation.y += delta * 2.0
	anim_time += delta
	if delivery_active:
		_process_delivery(delta)
		return
	if pause > 0.0:
		pause -= delta
		body.set_locomotion(false, false, false, delivery_active)
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
	body.set_locomotion(true, false, false, false)
	look_at(flat, Vector3.UP, true)

func start_delivery(target: Vector3, callback: Callable) -> void:
	delivery_active = true
	delivery_target = target
	delivery_callback = callback
	delivery_plate.visible = true
	pause = 0.0

func _process_delivery(delta: float) -> void:
	var target := Vector3(delivery_target.x, global_position.y, delivery_target.z)
	var distance := global_position.distance_to(target)
	if distance < 0.28:
		delivery_active = false
		delivery_plate.visible = false
		if delivery_callback.is_valid():
			delivery_callback.call()
		return
	var speed := float(data.speed) * 0.028 * clampf(1.1 - float(state.stress) * 0.006, 0.52, 1.0)
	global_position = global_position.move_toward(target, speed * delta)
	body.set_locomotion(true, false, false, true)
	look_at(target, Vector3.UP, true)

func _material(color: Color, emission := false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.78
	if emission:
		mat.emission_enabled = true
		mat.emission = color
	return mat
