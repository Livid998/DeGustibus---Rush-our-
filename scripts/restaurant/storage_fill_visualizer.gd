class_name StorageFillVisualizer
extends Node3D

## Event-driven, aggregate world representation of physical stock. Ambient
## inventory uses at most four lightweight crates; refrigerated inventory uses
## a deliberately different cold-status badge on every cold-storage provider.

signal visuals_changed(snapshot: Dictionary)

const AMBIENT_CRATE_MODEL := "res://assets/equipment/crate.gltf"
const MAX_AMBIENT_CRATES := 4
const FLOOR_CRATE_SCALE := 0.42
const FLOOR_CRATE_CLEARANCE := 0.07
const FLOOR_CRATE_LAYER_HEIGHT := 0.37
const WALL_SEGMENT_SPACING := 0.34

var world: RestaurantWorld
var refresh_count := 0


func setup(value_world: RestaurantWorld) -> void:
	world = value_world
	name = "StorageFillVisuals"
	_connect_runtime_signals()
	refresh()


func snapshot() -> Dictionary:
	var usage := StorageManager.usage_snapshot()
	var capacity := StorageManager.capacity_snapshot()
	var overflow := StorageManager.overflow_snapshot()
	var ambient_providers := _providers("ambient")
	var refrigerated_providers := _providers("refrigerated")
	var ambient_display_provider := _ambient_display_provider(ambient_providers)
	var ambient_used := maxi(int(usage.get("ambient", 0)), 0)
	var ambient_capacity := maxi(int(capacity.get("ambient", 0)), 0)
	var refrigerated_used := maxi(int(usage.get("refrigerated", 0)), 0)
	var refrigerated_capacity := maxi(int(capacity.get("refrigerated", 0)), 0)
	var ambient_ratio := (
		clampf(float(ambient_used) / float(ambient_capacity), 0.0, 1.0)
		if ambient_capacity > 0 else 0.0
	)
	var refrigerated_ratio := (
		clampf(float(refrigerated_used) / float(refrigerated_capacity), 0.0, 1.0)
		if refrigerated_capacity > 0 else 0.0
	)
	return {
		"ambient": {
			"used": ambient_used,
			"capacity": ambient_capacity,
			"ratio": ambient_ratio,
			"crate_count": (
				clampi(ceili(ambient_ratio * MAX_AMBIENT_CRATES), 0, MAX_AMBIENT_CRATES)
				if ambient_used > 0 else 0
			),
			"provider_count": ambient_providers.size(),
			"display_provider_uid": (
				ambient_display_provider.uid if ambient_display_provider != null else ""
			),
			"display_mode": _ambient_display_mode(ambient_display_provider),
			"overflow": bool(overflow.get("ambient", false)),
		},
		"refrigerated": {
			"used": refrigerated_used,
			"capacity": refrigerated_capacity,
			"ratio": refrigerated_ratio,
			"indicator_count": refrigerated_providers.size(),
			"provider_count": refrigerated_providers.size(),
			"overflow": bool(overflow.get("refrigerated", false)),
		},
		"refresh_count": refresh_count,
	}


func refresh() -> void:
	if world == null or not is_instance_valid(world):
		return
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	var ambient_providers := _providers("ambient")
	var refrigerated_providers := _providers("refrigerated")
	var current := snapshot()
	var crate_count := int((current.get("ambient", {}) as Dictionary).get("crate_count", 0))
	if crate_count > 0 and not ambient_providers.is_empty():
		var primary := _ambient_display_provider(ambient_providers)
		var display_mode := _ambient_display_mode(primary)
		var offsets := _ambient_display_offsets(primary, crate_count, display_mode)
		for crate_index: int in offsets.size():
			var crate := _create_ambient_crate(crate_index, display_mode == "wall_compact")
			crate.set_meta("storage_provider_uid", primary.uid)
			crate.set_meta("storage_display_mode", display_mode)
			add_child(crate)
			crate.global_position = primary.to_global(offsets[crate_index])
			crate.global_rotation.y = primary.global_rotation.y
		var ambient: Dictionary = current.get("ambient", {})
		var fill_label := _create_ambient_fill_label(
			float(ambient.get("ratio", 0.0)),
			bool(ambient.get("overflow", false))
		)
		fill_label.set_meta("storage_provider_uid", primary.uid)
		fill_label.set_meta("storage_display_mode", display_mode)
		add_child(fill_label)
		fill_label.global_position = primary.to_global(
			_ambient_label_offset(primary, display_mode)
		)
	var cold: Dictionary = current.get("refrigerated", {})
	for provider: PlacedObject in refrigerated_providers:
		var indicator := _create_cold_indicator(
			float(cold.get("ratio", 0.0)),
			bool(cold.get("overflow", false))
		)
		add_child(indicator)
		indicator.global_position = provider.to_global(Vector3(0.0, 2.55, 0.0))
	refresh_count += 1
	visuals_changed.emit(snapshot())


func _connect_runtime_signals() -> void:
	var totals_callback := Callable(self, "_on_totals_changed")
	for runtime_signal: Signal in [
		StorageManager.usage_changed,
		StorageManager.capacity_changed,
		StorageManager.overflow_changed,
	]:
		if not runtime_signal.is_connected(totals_callback):
			runtime_signal.connect(totals_callback)
	var layout_callback := Callable(self, "_on_layout_changed")
	if not GameState.layout_changed.is_connected(layout_callback):
		GameState.layout_changed.connect(layout_callback)


func _on_totals_changed(_value: Dictionary) -> void:
	refresh()


func _on_layout_changed() -> void:
	# A fixture move can keep capacity unchanged, but its attached fill display
	# still needs to follow the new transform.
	refresh()


func _providers(storage_type: String) -> Array[PlacedObject]:
	var result: Array[PlacedObject] = []
	var ordered_uids: Array[String] = []
	for uid_value: Variant in world.placed_objects.keys():
		ordered_uids.append(String(uid_value))
	ordered_uids.sort()
	for uid: String in ordered_uids:
		var object := world.placed_objects.get(uid) as PlacedObject
		if object == null or not is_instance_valid(object):
			continue
		var contribution: Variant = object.definition.get("storage_capacity", {})
		if contribution is Dictionary and int((contribution as Dictionary).get(storage_type, 0)) > 0:
			result.append(object)
	return result


func _ambient_display_provider(providers: Array[PlacedObject]) -> PlacedObject:
	# Floor pantry crates are the clearest physical anchor and must win over a
	# wall shelf whose local space is easily hidden by walls or appliances.
	for provider: PlacedObject in providers:
		if provider.item_id == "storage_crate":
			return provider
	for provider: PlacedObject in providers:
		if String(provider.definition.get("placement", "cell")) != "wall_mount":
			return provider
	return providers[0] if not providers.is_empty() else null


func _ambient_display_mode(provider: PlacedObject) -> String:
	if provider == null:
		return "none"
	return (
		"wall_compact"
		if String(provider.definition.get("placement", "cell")) == "wall_mount"
		else "floor_stack"
	)


func _ambient_display_offsets(
	provider: PlacedObject,
	count: int,
	display_mode: String
) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var provider_top := _provider_visual_height(provider)
	if display_mode == "wall_compact":
		for index: int in count:
			result.append(Vector3(
				(float(index) - float(count - 1) * 0.5) * WALL_SEGMENT_SPACING,
				provider_top + 0.16,
				0.34
			))
		return result
	var stack_offsets: Array[Vector3] = []
	match count:
		1:
			stack_offsets = [Vector3(0.0, 0.0, 0.12)]
		2:
			stack_offsets = [
				Vector3(-0.36, 0.0, 0.12),
				Vector3(0.36, 0.0, 0.12),
			]
		3:
			stack_offsets = [
				Vector3(-0.36, 0.0, 0.12),
				Vector3(0.36, 0.0, 0.12),
				Vector3(0.0, FLOOR_CRATE_LAYER_HEIGHT, 0.12),
			]
		_:
			stack_offsets = [
				Vector3(-0.36, 0.0, 0.12),
				Vector3(0.36, 0.0, 0.12),
				Vector3(-0.28, FLOOR_CRATE_LAYER_HEIGHT, 0.12),
				Vector3(0.28, FLOOR_CRATE_LAYER_HEIGHT, 0.12),
			]
	for offset: Vector3 in stack_offsets:
		result.append(Vector3(
			offset.x,
			provider_top + FLOOR_CRATE_CLEARANCE + offset.y,
			offset.z
		))
	return result


func _ambient_label_offset(provider: PlacedObject, display_mode: String) -> Vector3:
	var provider_top := _provider_visual_height(provider)
	if display_mode == "wall_compact":
		return Vector3(0.0, provider_top + 0.56, 0.36)
	return Vector3(0.0, provider_top + 1.0, 0.0)


func _provider_visual_height(provider: PlacedObject) -> float:
	if provider == null or provider.visual_model == null:
		return 1.0
	var bounds := ModelFactory.calculate_visual_bounds(provider.visual_model, true)
	return maxf(bounds.end.y, 0.1)


func _create_ambient_crate(index: int, compact: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "AmbientStockCrate_%02d" % index
	if compact:
		var segment := MeshInstance3D.new()
		var segment_mesh := BoxMesh.new()
		segment_mesh.size = Vector3(0.28, 0.24, 0.2)
		var segment_material := StandardMaterial3D.new()
		segment_material.albedo_color = Color("e8a04d")
		segment_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		segment_mesh.material = segment_material
		segment.mesh = segment_mesh
		segment.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(segment)
	elif ResourceLoader.exists(AMBIENT_CRATE_MODEL):
		var visual := ModelFactory.instantiate_model(AMBIENT_CRATE_MODEL, FLOOR_CRATE_SCALE)
		ModelFactory.align_visual_to_grid_origin(visual)
		root.add_child(visual)
	else:
		var fallback := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.62, 0.42, 0.52)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("bd7d45")
		mesh.material = material
		fallback.mesh = mesh
		fallback.position.y = mesh.size.y * 0.5
		root.add_child(fallback)
	ModelFactory.set_shadow_casting(root, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	return root


func _create_ambient_fill_label(ratio: float, overflow: bool) -> Label3D:
	var label := Label3D.new()
	label.name = "AmbientFillLabel"
	label.text = "SCORTE %d%%" % clampi(roundi(ratio * 100.0), 0, 100)
	label.font_size = 30
	label.outline_size = 7
	label.modulate = Color("ff847b") if overflow else Color("ffd07a")
	label.outline_modulate = Color("49331c")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	return label


func _create_cold_indicator(ratio: float, overflow: bool) -> Node3D:
	var root := Node3D.new()
	root.name = "RefrigeratedStockIndicator"
	var badge := MeshInstance3D.new()
	var badge_mesh := BoxMesh.new()
	badge_mesh.size = Vector3(0.78, 0.14, 0.12)
	var badge_material := StandardMaterial3D.new()
	badge_material.albedo_color = Color("ff6b6b") if overflow else Color("57d4e8")
	badge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	badge_mesh.material = badge_material
	badge.mesh = badge_mesh
	badge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(badge)
	var label := Label3D.new()
	label.name = "ColdFillLabel"
	label.text = "FREDDO %d%%" % clampi(roundi(ratio * 100.0), 0, 100)
	label.position = Vector3(0.0, 0.28, 0.0)
	label.font_size = 30
	label.outline_size = 7
	label.modulate = Color("ff8d86") if overflow else Color("a8f4ff")
	label.outline_modulate = Color("173f4b")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	root.add_child(label)
	return root
