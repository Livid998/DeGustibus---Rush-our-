class_name KitchenStation
extends StaticBody3D

var station_id := ""
var display_name := ""
var disorder := 0.0
var game: Node
var base_color := Color.WHITE
var body_mesh: MeshInstance3D
var label: Label3D
var clutter: Array[MeshInstance3D] = []
var highlighted := false

func setup(id: String, title: String, color: Color, size: Vector3, owner_game: Node) -> void:
	station_id = id
	display_name = title
	base_color = color
	game = owner_game
	add_to_group("interactable")
	body_mesh = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	body_mesh.mesh = mesh
	body_mesh.position.y = size.y * 0.5
	body_mesh.material_override = _material(color)
	add_child(body_mesh)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.position.y = size.y * 0.5
	add_child(collision)
	label = Label3D.new()
	label.text = title.to_upper()
	label.font_size = 44
	label.outline_size = 10
	label.modulate = Color("#fff3d6")
	label.position = Vector3(0.0, size.y + 0.42, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	for i in 3:
		var prop := MeshInstance3D.new()
		var prop_mesh := BoxMesh.new()
		prop_mesh.size = Vector3(0.24 + i * 0.07, 0.12 + i * 0.04, 0.32)
		prop.mesh = prop_mesh
		prop.material_override = _material([Color("#d8c28f"), Color("#a8c8bc"), Color("#cf6d4f")][i])
		prop.position = Vector3(-0.45 + i * 0.42, size.y + 0.08 + i * 0.04, 0.05 * (i - 1))
		prop.rotation.y = i * 0.38
		prop.visible = false
		add_child(prop)
		clutter.append(prop)

func begin_interaction(player: Node) -> void:
	if game and game.has_method("request_station_interaction"):
		game.request_station_interaction(self, player)

func get_prompt() -> String:
	if game and game.has_method("get_station_action"):
		return game.get_station_action(self).get("label", "Usa %s" % display_name)
	return "Usa %s" % display_name

func set_highlighted(value: bool) -> void:
	if highlighted == value:
		return
	highlighted = value
	var color := base_color.lightened(0.28) if value else base_color
	body_mesh.material_override = _material(color, value)
	label.modulate = Color.WHITE if value else Color("#fff3d6")

func add_disorder(amount: float) -> void:
	disorder = clampf(disorder + amount, 0.0, 100.0)
	for i in clutter.size():
		clutter[i].visible = disorder >= 22.0 + i * 22.0
	if disorder >= 75.0:
		label.modulate = Color("#ff685f")
	elif not highlighted:
		label.modulate = Color("#fff3d6")

func reset_disorder() -> void:
	disorder = maxf(0.0, disorder - 72.0)
	for i in clutter.size():
		clutter[i].visible = disorder >= 22.0 + i * 22.0

func efficiency() -> float:
	return clampf(1.0 - disorder * 0.0065, 0.40, 1.0)

func _material(color: Color, glow := false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.72
	if glow:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 0.5
	return mat

