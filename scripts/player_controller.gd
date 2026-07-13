class_name PlayerController
extends CharacterBody3D

signal focus_changed(target: Node)
signal interaction_cancelled
signal slapstick_requested

var game: Node
var speed := 5.2
var sprint_multiplier := 1.45
var gravity := 18.0
var active := false
var camera_pivot: Node3D
var camera: Camera3D
var focused: Node
var interacting := false
var mouse_sensitivity := 0.20
var visual: Node3D

func setup(owner_game: Node) -> void:
	game = owner_game
	_build_body()
	_build_camera()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _build_body() -> void:
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.42
	shape.height = 1.65
	collision.shape = shape
	collision.position.y = 0.83
	add_child(collision)
	visual = Node3D.new()
	add_child(visual)
	var torso := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.43
	capsule.height = 1.35
	torso.mesh = capsule
	torso.position.y = 0.88
	torso.material_override = _material(Color("#d84f3f"))
	visual.add_child(torso)
	var apron := MeshInstance3D.new()
	var apron_mesh := BoxMesh.new()
	apron_mesh.size = Vector3(0.72, 0.78, 0.10)
	apron.mesh = apron_mesh
	apron.position = Vector3(0, 0.92, -0.39)
	apron.material_override = _material(Color("#fff0d5"))
	visual.add_child(apron)
	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.36
	sphere.height = 0.72
	head.mesh = sphere
	head.position.y = 1.88
	head.material_override = _material(Color("#efb28f"))
	visual.add_child(head)
	var hat := MeshInstance3D.new()
	var hat_mesh := CylinderMesh.new()
	hat_mesh.top_radius = 0.36
	hat_mesh.bottom_radius = 0.43
	hat_mesh.height = 0.48
	hat.mesh = hat_mesh
	hat.position.y = 2.27
	hat.material_override = _material(Color("#fff9e9"))
	visual.add_child(hat)

func _build_camera() -> void:
	camera_pivot = Node3D.new()
	camera_pivot.position = Vector3(0, 1.55, 0)
	add_child(camera_pivot)
	var spring := SpringArm3D.new()
	spring.spring_length = 6.8
	spring.margin = 0.25
	spring.collision_mask = 1
	camera_pivot.add_child(spring)
	camera = Camera3D.new()
	camera.fov = 68.0
	camera.position.y = 0.35
	spring.add_child(camera)

func set_active(value: bool) -> void:
	active = value
	if active:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func set_mouse_sensitivity(value: float) -> void:
	mouse_sensitivity = value

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_pivot.rotation.y -= event.relative.x * mouse_sensitivity * 0.01
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x - event.relative.y * mouse_sensitivity * 0.01, -0.75, 0.58)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		slapstick_requested.emit()
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_E:
			if interacting:
				interaction_cancelled.emit()
			elif focused and focused.has_method("begin_interaction"):
				focused.begin_interaction(self)
		elif event.physical_keycode == KEY_Q and interacting:
			interaction_cancelled.emit()
		elif event.physical_keycode == KEY_SPACE:
			slapstick_requested.emit()

func _physics_process(delta: float) -> void:
	if not active:
		velocity = Vector3.ZERO
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = -0.4
	var input := Vector2.ZERO
	if not interacting:
		input.x = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		input.y = float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
		if Input.is_physical_key_pressed(KEY_RIGHT): input.x += 1.0
		if Input.is_physical_key_pressed(KEY_LEFT): input.x -= 1.0
		if Input.is_physical_key_pressed(KEY_DOWN): input.y += 1.0
		if Input.is_physical_key_pressed(KEY_UP): input.y -= 1.0
	input = input.normalized()
	var basis := Basis(Vector3.UP, camera_pivot.global_rotation.y)
	var direction := (basis * Vector3(input.x, 0, input.y)).normalized()
	var actual_speed := speed * (sprint_multiplier if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	velocity.x = move_toward(velocity.x, direction.x * actual_speed, delta * 18.0)
	velocity.z = move_toward(velocity.z, direction.z * actual_speed, delta * 18.0)
	if direction.length_squared() > 0.02:
		visual.rotation.y = lerp_angle(visual.rotation.y, atan2(direction.x, direction.z) + PI, delta * 12.0)
	move_and_slide()
	_update_focus()

func _update_focus() -> void:
	var candidate: Node = null
	var best := 3.0
	for node in get_tree().get_nodes_in_group("interactable"):
		if not is_instance_valid(node) or not node is Node3D:
			continue
		var distance := global_position.distance_to((node as Node3D).global_position)
		if distance < best:
			best = distance
			candidate = node
	if candidate != focused:
		if focused and focused.has_method("set_highlighted"):
			focused.set_highlighted(false)
		focused = candidate
		if focused and focused.has_method("set_highlighted"):
			focused.set_highlighted(true)
		focus_changed.emit(focused)

func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.78
	return mat

