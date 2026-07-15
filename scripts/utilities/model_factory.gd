class_name ModelFactory
extends RefCounted

static var _cache: Dictionary = {}


static func instantiate_model(path: String, scale_factor: float = 1.0) -> Node3D:
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("Missing model: %s" % path)
		return Node3D.new()
	var packed: PackedScene = _cache.get(path)
	if packed == null:
		packed = load(path) as PackedScene
		_cache[path] = packed
	if packed == null:
		push_error("Model is not a PackedScene: %s" % path)
		return Node3D.new()
	var instance := packed.instantiate() as Node3D
	instance.scale = Vector3.ONE * scale_factor
	return instance


static func instantiate_build_visual(definition: Dictionary, ground_to_zero: bool = true) -> Node3D:
	var visual := Node3D.new()
	visual.name = "BuildVisual"
	var base := instantiate_model(String(definition.get("model", "")))
	base.name = "BaseModel"
	var raw_scale: Array = definition.get("model_scale", [1.0, 1.0, 1.0])
	base.scale = Vector3(float(raw_scale[0]), float(raw_scale[1]), float(raw_scale[2]))
	align_visual_to_grid_origin(base, ground_to_zero)
	visual.add_child(base)
	var embedded_path := String(definition.get("embedded_model", ""))
	if not embedded_path.is_empty():
		var embedded := instantiate_model(embedded_path)
		embedded.name = "EmbeddedModel"
		var embedded_scale: Array = definition.get("embedded_scale", [1.0, 1.0, 1.0])
		embedded.scale = Vector3(float(embedded_scale[0]), float(embedded_scale[1]), float(embedded_scale[2]))
		align_visual_to_grid_origin(embedded, ground_to_zero)
		var embedded_offset: Array = definition.get("embedded_offset", [0.0, 0.0, 0.0])
		embedded.position += Vector3(float(embedded_offset[0]), float(embedded_offset[1]), float(embedded_offset[2]))
		visual.add_child(embedded)
	return visual


static func find_animation_players(root: Node) -> Array[AnimationPlayer]:
	var result: Array[AnimationPlayer] = []
	if root is AnimationPlayer:
		result.append(root)
	for child: Node in root.get_children():
		result.append_array(find_animation_players(child))
	return result


static func calculate_visual_bounds(root: Node3D, include_root_transform: bool = false) -> AABB:
	var points: Array[Vector3] = []
	_collect_visual_bounds(root, Transform3D.IDENTITY, points, include_root_transform)
	if points.is_empty():
		return AABB()
	var bounds := AABB(points[0], Vector3.ZERO)
	for index: int in range(1, points.size()):
		bounds = bounds.expand(points[index])
	return bounds


static func align_visual_to_grid_origin(root: Node3D, ground_to_zero: bool = true) -> AABB:
	var bounds := calculate_visual_bounds(root, true)
	if bounds.size.is_zero_approx():
		return bounds
	var center := bounds.get_center()
	var offset := Vector3(-center.x, -bounds.position.y if ground_to_zero else 0.0, -center.z)
	root.position += offset
	return AABB(bounds.position + offset, bounds.size)


static func _collect_visual_bounds(node: Node, parent_transform: Transform3D, points: Array[Vector3], include_transform: bool = true) -> void:
	var current_transform := parent_transform
	if node is Node3D and include_transform:
		current_transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		var bounds := (node as MeshInstance3D).mesh.get_aabb()
		for x: float in [bounds.position.x, bounds.end.x]:
			for y: float in [bounds.position.y, bounds.end.y]:
				for z: float in [bounds.position.z, bounds.end.z]:
					points.append(current_transform * Vector3(x, y, z))
	for child: Node in node.get_children():
		_collect_visual_bounds(child, current_transform, points, true)


static func set_preview_tint(root: Node, color: Color) -> void:
	for child: Node in root.get_children():
		if child is GeometryInstance3D:
			var overlay := StandardMaterial3D.new()
			overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
			overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			overlay.albedo_color = color
			child.material_overlay = overlay
		set_preview_tint(child, color)
