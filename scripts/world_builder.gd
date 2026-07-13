class_name WorldBuilder
extends Node3D

var game: Node
var stations := {}
var table_positions := {
	1: Vector3(4.0, 0, -5.4), 2: Vector3(8.0, 0, -5.4), 3: Vector3(12.0, 0, -5.4),
	4: Vector3(4.0, 0, -1.2), 5: Vector3(8.0, 0, -1.2), 6: Vector3(12.0, 0, -1.2),
}
var customer_colors := [Color("#e37b65"), Color("#67a9cf"), Color("#d29b54"), Color("#8fc17a"), Color("#aa7bc1"), Color("#e86e96")]
var mise_visuals: Array[Node3D] = []
var mise_label: Label3D

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
	env.background_color = Color("#171b24")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#ffd9a6")
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = env
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58, -38, 0)
	sun.light_color = Color("#ffe0af")
	sun.light_energy = 0.82
	sun.shadow_enabled = true
	add_child(sun)
	for position in [Vector3(-5, 5.5, -2), Vector3(7, 5.5, -2), Vector3(11, 5.5, -6)]:
		var light := OmniLight3D.new()
		light.position = position
		light.light_color = Color("#ffbd72")
		light.light_energy = 1.65
		light.omni_range = 9.0
		light.shadow_enabled = false
		add_child(light)

func _build_shell() -> void:
	_add_static_box("Floor", Vector3(3.5, -0.14, -2.5), Vector3(27.0, 0.25, 14.0), Color("#a97942"))
	for x in range(-9, 17, 2):
		for z in range(-8, 5, 2):
			if (x + z) % 4 == 0:
				_add_visual_box(Vector3(x, 0.01, z), Vector3(1.92, 0.03, 1.92), Color("#c29a61"))
	_add_static_box("BackWall", Vector3(3.5, 2.3, -9.1), Vector3(27.0, 4.6, 0.3), Color("#55362f"))
	_add_visual_box(Vector3(3.5, 1.05, -8.92), Vector3(26.7, 1.8, 0.08), Color("#34474b"))
	_add_static_box("LeftWall", Vector3(-10.1, 2.3, -2.5), Vector3(0.3, 4.6, 14.0), Color("#704438"))
	_add_static_box("RightWall", Vector3(17.1, 2.3, -2.5), Vector3(0.3, 4.6, 14.0), Color("#704438"))
	_add_static_box("FrontWallA", Vector3(-4.5, 2.3, 4.4), Vector3(11.0, 4.6, 0.3), Color("#704438"))
	_add_static_box("FrontWallB", Vector3(12.5, 2.3, 4.4), Vector3(9.0, 4.6, 0.3), Color("#704438"))
	_add_static_box("KitchenDividerA", Vector3(-5.7, 1.4, -0.6), Vector3(8.3, 2.8, 0.22), Color("#f0c98e"))
	_add_static_box("KitchenDividerB", Vector3(0.6, 1.4, -0.6), Vector3(1.9, 2.8, 0.22), Color("#f0c98e"))
	# Door gap between x=-1.5 and x=-0.35 keeps kitchen and sala physically connected.

func _build_kitchen() -> void:
	_add_station("fridge", "Frigo", Vector3(-8.4, 0, -7.4), Vector3(1.5, 2.35, 1.25), Color("#7ab6b5"), "Fridge.glb", 0.92)
	_add_station("grill", "Piastra", Vector3(-5.9, 0, -7.7), Vector3(1.7, 1.05, 1.25), Color("#55535b"), "Stove with multi burner.glb", 0.88)
	_add_station("stove", "Fornelli", Vector3(-3.5, 0, -7.7), Vector3(1.7, 1.05, 1.25), Color("#61656f"), "Oven.glb", 0.88)
	_add_station("fryer", "Friggitrice", Vector3(-1.2, 0, -7.7), Vector3(1.45, 1.1, 1.25), Color("#9d7a43"), "Stove Single.glb", 0.88)
	_add_station("assembly", "Assemblaggio", Vector3(-7.1, 0, -3.9), Vector3(2.4, 1.05, 1.25), Color("#d7754f"), "Kitchen Table.glb", Vector3(1.05, 1.05, 0.62))
	_add_station("pass", "Pass", Vector3(-2.5, 0, -1.1), Vector3(2.2, 1.05, 0.75), Color("#e4a63f"), "Kitchen Table-BAT1fix4uD.glb", Vector3(1.0, 0.96, 0.36))
	_add_station("sink", "Lavaggio", Vector3(-3.2, 0, -3.9), Vector3(1.8, 1.05, 1.25), Color("#5da2b4"), "Table with sink.glb", Vector3(0.90, 0.96, 0.62))
	_add_station("trash", "Rifiuti", Vector3(-8.7, 0, -2.3), Vector3(1.0, 1.25, 1.0), Color("#63705f"))
	# Readable silhouettes and real props make each work area recognizable at a glance.
	AssetLibrary.add_restaurant(self, "Extractorhood.glb", Vector3(-5.9, 3.55, -8.72), 0.82)
	AssetLibrary.add_restaurant(self, "Extractorhood.glb", Vector3(-3.4, 3.55, -8.72), 0.82)
	AssetLibrary.add_restaurant(self, "Shelf Papertowel.glb", Vector3(-7.0, 2.2, -8.65), 1.0)
	AssetLibrary.add_restaurant(self, "Crate of Tomatoes.glb", Vector3(-8.1, 0.04, -5.5), 0.82, 15.0)
	AssetLibrary.add_restaurant(self, "Crate of Potatoes.glb", Vector3(-7.2, 0.04, -5.5), 0.82, -12.0)
	AssetLibrary.add_restaurant(self, "Dishrack.glb", Vector3(-3.7, 1.05, -3.9), 0.90)
	AssetLibrary.add_restaurant(self, "Pan A.glb", Vector3(-5.9, 1.08, -7.7), 0.90, 20.0)
	AssetLibrary.add_restaurant(self, "Pot.glb", Vector3(-3.5, 1.05, -7.7), 0.92)
	mise_label = Label3D.new()
	mise_label.text = "BASI PRONTE  0"
	mise_label.font_size = 32
	mise_label.outline_size = 8
	mise_label.position = Vector3(-7.1, 1.62, -3.9)
	mise_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mise_label.modulate = Color("#8dffac")
	add_child(mise_label)

func set_mise_count(count: int) -> void:
	for visual in mise_visuals:
		if is_instance_valid(visual):
			remove_child(visual)
			visual.queue_free()
	mise_visuals.clear()
	for i in count:
		var tray := AssetLibrary.add_model(self, AssetLibrary.FOOD + "cutting-board.glb", Vector3(-7.82 + i * 0.46, 1.12 + (i % 2) * 0.10, -3.9), Vector3.ONE * 0.72, Vector3(0, i * 12.0, 0))
		mise_visuals.append(tray)
	if is_instance_valid(mise_label):
		mise_label.text = "BASI PRONTE  %d" % count
		mise_label.visible = count > 0

func _build_dining_room() -> void:
	for table_id in table_positions:
		var pos: Vector3 = table_positions[table_id]
		AssetLibrary.add_model(self, AssetLibrary.FURNITURE + "table_medium_long.gltf", pos, Vector3(0.72, 0.72, 0.72), Vector3(0, 90, 0))
		_add_static_box("TableCollision%d" % table_id, pos + Vector3(0, 0.43, 0), Vector3(1.1, 0.75, 0.65), Color(0, 0, 0, 0), false)
		AssetLibrary.add_model(self, AssetLibrary.FURNITURE + "chair_A_wood.gltf", pos + Vector3(0, 0, -1.05), Vector3.ONE * 0.82, Vector3(0, 0, 0))
		AssetLibrary.add_model(self, AssetLibrary.FURNITURE + "chair_A_wood.gltf", pos + Vector3(0, 0, 1.05), Vector3.ONE * 0.82, Vector3(0, 180, 0))
		var marker := Label3D.new()
		marker.text = "TAVOLO %d" % table_id
		marker.font_size = 32
		marker.pixel_size = 0.0035
		marker.outline_size = 7
		marker.position = pos + Vector3(0, 1.45, 0)
		marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		add_child(marker)
	_add_station("cash", "Cassa", Vector3(14.4, 0, 2.4), Vector3(2.2, 1.15, 1.1), Color("#9d5faf"), "Kitchen Cabinet.glb", 1.05, 180.0)
	AssetLibrary.add_model(self, AssetLibrary.FURNITURE + "cabinet_medium_decorated.gltf", Vector3(15.8, 0, -6.7), Vector3.ONE * 0.85, Vector3(0, -90, 0))
	AssetLibrary.add_model(self, AssetLibrary.FURNITURE + "cactus_medium_A.gltf", Vector3(15.7, 0, 3.7), Vector3.ONE * 0.9)
	AssetLibrary.add_model(self, AssetLibrary.FURNITURE + "lamp_standing.gltf", Vector3(1.8, 0, -7.8), Vector3.ONE * 0.92)
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

func _add_station(id: String, title: String, position: Vector3, size: Vector3, color: Color, model_file := "", model_scale: Variant = 1.0, model_rotation := 0.0) -> void:
	var station := KitchenStation.new()
	station.position = position
	station.setup(id, title, color, size, game)
	add_child(station)
	if not model_file.is_empty():
		station.set_visual_model(AssetLibrary.RESTAURANT + model_file, model_scale, model_rotation)
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
