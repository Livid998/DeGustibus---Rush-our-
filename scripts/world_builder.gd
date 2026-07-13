class_name WorldBuilder
extends Node3D

var game: Node
var stations := {}
var table_positions := {
	1: Vector3(4.0, 0, -5.4), 2: Vector3(8.0, 0, -5.4), 3: Vector3(12.0, 0, -5.4),
	4: Vector3(4.0, 0, -1.2), 5: Vector3(8.0, 0, -1.2), 6: Vector3(12.0, 0, -1.2),
}
var customer_colors := [Color("#e37b65"), Color("#67a9cf"), Color("#d29b54"), Color("#8fc17a"), Color("#aa7bc1"), Color("#e86e96")]

func setup(owner_game: Node) -> void:
	game = owner_game
	_build_environment()
	_build_shell()
	_build_kitchen()
	_build_dining_room()
	_build_signage()

func _build_environment() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#3b1e1b")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#ffd9a6")
	env.ambient_light_energy = 0.62
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = env
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58, -38, 0)
	sun.light_color = Color("#ffe0af")
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)
	for position in [Vector3(-5, 5.5, -2), Vector3(7, 5.5, -2), Vector3(11, 5.5, -6)]:
		var light := OmniLight3D.new()
		light.position = position
		light.light_color = Color("#ffbd72")
		light.light_energy = 6.0
		light.omni_range = 9.0
		light.shadow_enabled = false
		add_child(light)

func _build_shell() -> void:
	_add_static_box("Floor", Vector3(3.5, -0.14, -2.5), Vector3(27.0, 0.25, 14.0), Color("#dfb778"))
	for x in range(-9, 17, 2):
		for z in range(-8, 5, 2):
			if (x + z) % 4 == 0:
				_add_visual_box(Vector3(x, 0.01, z), Vector3(1.92, 0.03, 1.92), Color("#edcf9a"))
	_add_static_box("BackWall", Vector3(3.5, 2.3, -9.1), Vector3(27.0, 4.6, 0.3), Color("#b94d3f"))
	_add_static_box("LeftWall", Vector3(-10.1, 2.3, -2.5), Vector3(0.3, 4.6, 14.0), Color("#a63f36"))
	_add_static_box("RightWall", Vector3(17.1, 2.3, -2.5), Vector3(0.3, 4.6, 14.0), Color("#a63f36"))
	_add_static_box("FrontWallA", Vector3(-4.5, 2.3, 4.4), Vector3(11.0, 4.6, 0.3), Color("#a63f36"))
	_add_static_box("FrontWallB", Vector3(12.5, 2.3, 4.4), Vector3(9.0, 4.6, 0.3), Color("#a63f36"))
	_add_static_box("KitchenDividerA", Vector3(-5.7, 1.4, -0.6), Vector3(8.3, 2.8, 0.22), Color("#f0c98e"))
	_add_static_box("KitchenDividerB", Vector3(0.6, 1.4, -0.6), Vector3(1.9, 2.8, 0.22), Color("#f0c98e"))
	# Door gap between x=-1.5 and x=-0.35 keeps kitchen and sala physically connected.

func _build_kitchen() -> void:
	_add_station("fridge", "Frigo", Vector3(-8.4, 0, -7.4), Vector3(1.5, 2.35, 1.25), Color("#7ab6b5"))
	_add_station("grill", "Piastra", Vector3(-5.9, 0, -7.7), Vector3(1.7, 1.05, 1.25), Color("#55535b"))
	_add_station("stove", "Fornelli", Vector3(-3.5, 0, -7.7), Vector3(1.7, 1.05, 1.25), Color("#61656f"))
	_add_station("fryer", "Friggitrice", Vector3(-1.2, 0, -7.7), Vector3(1.45, 1.1, 1.25), Color("#9d7a43"))
	_add_station("assembly", "Assemblaggio", Vector3(-7.1, 0, -3.9), Vector3(2.4, 1.05, 1.25), Color("#d7754f"))
	_add_station("pass", "Pass", Vector3(-2.5, 0, -1.1), Vector3(2.2, 1.05, 0.75), Color("#e4a63f"))
	_add_station("sink", "Lavaggio", Vector3(-3.2, 0, -3.9), Vector3(1.8, 1.05, 1.25), Color("#5da2b4"))
	_add_station("trash", "Rifiuti", Vector3(-8.7, 0, -2.3), Vector3(1.0, 1.25, 1.0), Color("#63705f"))
	# Shelves and small props prevent an empty greybox look.
	for x in [-8.2, -6.3, -4.4, -2.5, -0.6]:
		_add_visual_box(Vector3(x, 2.65, -8.75), Vector3(1.5, 0.14, 0.45), Color("#7e4035"))
		for i in 3:
			_add_visual_box(Vector3(x - 0.35 + i * 0.35, 2.86, -8.72), Vector3(0.22, 0.32 + i * 0.08, 0.22), [Color("#f1bd58"), Color("#75a97d"), Color("#d96855")][i])

func _build_dining_room() -> void:
	for table_id in table_positions:
		var pos: Vector3 = table_positions[table_id]
		_add_visual_box(pos + Vector3(0, 0.72, 0), Vector3(2.25, 0.16, 1.35), Color("#6f342d"))
		_add_static_box("TableCollision%d" % table_id, pos + Vector3(0, 0.43, 0), Vector3(1.1, 0.75, 0.65), Color(0, 0, 0, 0), false)
		for chair_offset in [Vector3(0, 0.44, -1.0), Vector3(0, 0.44, 1.0)]:
			_add_visual_box(pos + chair_offset, Vector3(0.75, 0.85, 0.55), Color("#cc7650"))
		var marker := Label3D.new()
		marker.text = "TAVOLO %d" % table_id
		marker.font_size = 32
		marker.outline_size = 7
		marker.position = pos + Vector3(0, 1.45, 0)
		marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		add_child(marker)
	_add_station("cash", "Cassa", Vector3(14.4, 0, 2.4), Vector3(2.2, 1.15, 1.1), Color("#9d5faf"))
	_add_visual_box(Vector3(8.5, 0.35, 3.8), Vector3(5.0, 0.7, 0.55), Color("#d57b55"))
	for x in [6.7, 8.0, 9.3, 10.6]:
		_add_visual_box(Vector3(x, 0.8, 3.8), Vector3(0.52, 0.9, 0.52), Color("#f0b65b"))

func _build_signage() -> void:
	var logo := Label3D.new()
	logo.text = "DE GUSTIBUS\nRUSH HOUR"
	logo.font_size = 88
	logo.outline_size = 14
	logo.modulate = Color("#fff0bf")
	logo.position = Vector3(6.2, 3.45, -8.72)
	add_child(logo)
	var kitchen_sign := Label3D.new()
	kitchen_sign.text = "CUCINA  ←     →  SALA"
	kitchen_sign.font_size = 48
	kitchen_sign.outline_size = 9
	kitchen_sign.position = Vector3(-1.0, 2.45, -0.45)
	kitchen_sign.rotation_degrees = Vector3(0, 180, 0)
	add_child(kitchen_sign)

func _add_station(id: String, title: String, position: Vector3, size: Vector3, color: Color) -> void:
	var station := KitchenStation.new()
	station.position = position
	station.setup(id, title, color, size, game)
	add_child(station)
	stations[id] = station

func _add_static_box(node_name: String, position: Vector3, size: Vector3, color: Color, visible := true) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = position
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	if visible:
		var mesh_instance := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = size
		mesh_instance.mesh = mesh
		mesh_instance.material_override = _material(color)
		body.add_child(mesh_instance)
	add_child(body)
	return body

func _add_visual_box(position: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.position = position
	instance.material_override = _material(color)
	add_child(instance)
	return instance

func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.82
	return mat

