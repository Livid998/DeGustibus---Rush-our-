class_name ModelFactory
extends RefCounted

static var _cache: Dictionary = {}
const RigCarryMarkerScript := preload("res://scripts/utilities/rig_carry_marker.gd")

## Stable attachment contract shared by every humanoid rig.  Imported KayKit
## scenes do not expose identically named sockets, so gameplay code must never
## depend on a pack-specific bone name such as `Fist.R`.
const RIG_MARKER_NAMES: Array[StringName] = [
	&"Hand_L", &"Hand_R", &"Carry", &"Work", &"Seat", &"Table"
]
const _RIG_BONE_ALIASES := {
	"Hand_L": ["Fist.L", "Hand.L", "hand_l", "LeftHand", "mixamorig:LeftHand"],
	"Hand_R": ["Fist.R", "Hand.R", "hand_r", "RightHand", "mixamorig:RightHand"],
}
const _RIG_MARKER_FALLBACKS := {
	"Hand_L": Vector3(-0.42, 1.52, -0.08),
	"Hand_R": Vector3(0.42, 1.52, -0.08),
	"Carry": Vector3(0.0, 1.38, -0.42),
	"Work": Vector3(0.0, 1.18, -0.58),
	"Seat": Vector3(0.0, 0.0, 0.0),
	"Table": Vector3(0.0, 1.02, -0.58),
}


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


## Adds (or adopts) the six canonical marker nodes without modifying the
## imported resource. Hand markers bind to real bones when available; every
## other marker has a conservative local fallback so all supplied rigs expose
## the same API even if a future asset pack uses different bone names.
static func ensure_rig_markers(root: Node3D) -> Dictionary:
	var result: Dictionary = {}
	if root == null:
		return result
	var skeleton := find_skeleton(root)
	for marker_name: StringName in RIG_MARKER_NAMES:
		var key := String(marker_name)
		var marker := root.find_child(key, true, false) as Node3D
		if marker == null and key == "Carry" and result.has("Hand_L") and result.has("Hand_R"):
			var carry_marker := RigCarryMarkerScript.new()
			carry_marker.name = marker_name
			carry_marker.set_meta("rig_marker_source", "hands_midpoint")
			root.add_child(carry_marker)
			carry_marker.configure(result.Hand_L as Node3D, result.Hand_R as Node3D)
			marker = carry_marker
		if marker == null and skeleton != null and _RIG_BONE_ALIASES.has(key):
			var bone_index := _find_bone_alias(skeleton, _RIG_BONE_ALIASES[key])
			if bone_index >= 0:
				var attachment := BoneAttachment3D.new()
				attachment.name = marker_name
				attachment.bone_name = skeleton.get_bone_name(bone_index)
				attachment.set_meta("rig_marker_source", "bone:%s" % attachment.bone_name)
				skeleton.add_child(attachment)
				marker = attachment
		if marker == null:
			marker = Node3D.new()
			marker.name = marker_name
			marker.position = Vector3(_RIG_MARKER_FALLBACKS.get(key, Vector3.ZERO))
			marker.set_meta("rig_marker_source", "fallback")
			root.add_child(marker)
		marker.set_meta("rig_marker", true)
		marker.set_meta("rig_marker_name", key)
		result[key] = marker
	root.set_meta("rig_marker_contract", 1)
	return result


static func find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for candidate: Node in root.find_children("*", "Skeleton3D", true, false):
		return candidate as Skeleton3D
	return null


static func _find_bone_alias(skeleton: Skeleton3D, aliases: Array) -> int:
	for alias: Variant in aliases:
		var exact := skeleton.find_bone(String(alias))
		if exact >= 0:
			return exact
	for bone_index: int in skeleton.get_bone_count():
		var normalized := String(skeleton.get_bone_name(bone_index)).to_lower().replace("_", "").replace(".", "").replace(":", "")
		for alias: Variant in aliases:
			var candidate := String(alias).to_lower().replace("_", "").replace(".", "").replace(":", "")
			if normalized == candidate:
				return bone_index
	return -1


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


static func set_shadow_casting(root: Node, mode: GeometryInstance3D.ShadowCastingSetting) -> void:
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).cast_shadow = mode
	for child: Node in root.get_children():
		set_shadow_casting(child, mode)
