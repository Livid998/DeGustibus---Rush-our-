class_name AssetLibrary
extends RefCounted

const RESTAURANT := "res://assets/third_party/restaurant_bits/models/"
const FOOD := "res://assets/third_party/kenney_food/"
const FURNITURE := "res://assets/third_party/kaykit_furniture/"

static func add_model(parent: Node, path: String, position := Vector3.ZERO, model_scale := Vector3.ONE, rotation_degrees := Vector3.ZERO) -> Node3D:
	var packed := load(path) as PackedScene
	if packed == null:
		push_warning("Unable to load 3D asset: %s" % path)
		return null
	var model := packed.instantiate() as Node3D
	if model == null:
		return null
	parent.add_child(model)
	model.position = position
	model.scale = model_scale
	model.rotation_degrees = rotation_degrees
	return model

static func add_restaurant(parent: Node, file_name: String, position := Vector3.ZERO, scale_factor := 1.0, rotation_y := 0.0) -> Node3D:
	return add_model(parent, RESTAURANT + file_name, position, Vector3.ONE * scale_factor, Vector3(0, rotation_y, 0))

static func add_food(parent: Node, item: String, position := Vector3.ZERO, scale_factor := 1.0) -> Node3D:
	var file_name := food_file(item)
	if file_name.is_empty():
		return null
	return add_model(parent, FOOD + file_name, position, Vector3.ONE * scale_factor)

static func food_file(item: String) -> String:
	match item:
		"burger_raw": return "meat-raw.glb"
		"burger_patty": return "meat-cooked.glb"
		"burger_components", "burger_ready": return "burger-cheese.glb"
		"pasta_raw": return "bowl.glb"
		"pasta_cooked", "pasta_ready": return "bowl-soup.glb"
		"special_raw": return "meat-raw.glb"
		"special_crispy", "special_ready": return "corn-dog.glb"
		"fries": return "fries.glb"
		_: return "plate-dinner.glb"

static func set_model_tint(root: Node, color: Color, emission := false) -> void:
	var meshes: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.push_front(root)
	for node in meshes:
		var mesh := node as MeshInstance3D
		for surface in mesh.mesh.get_surface_count():
			var source: Material = mesh.get_active_material(surface)
			if source is BaseMaterial3D:
				var material := source.duplicate() as BaseMaterial3D
				material.albedo_color *= color
				if emission:
					material.emission_enabled = true
					material.emission = color
					material.emission_energy_multiplier = 0.35
				mesh.set_surface_override_material(surface, material)

static func set_burnt(root: Node) -> void:
	set_model_tint(root, Color("#29201c"), false)
