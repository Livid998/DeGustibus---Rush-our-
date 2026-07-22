class_name ModelPreview
extends SubViewportContainer

var viewport_3d: SubViewport
var model_root: Node3D
var camera: Camera3D
var auto_rotate := true
var _render_clock := 0.0
var _render_interval := 1.0 / 24.0


func _ready() -> void:
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(180, 135)
	stretch = true
	viewport_3d = SubViewport.new()
	var low_memory := WebPlatformProfile.low_memory_mode()
	viewport_3d.size = Vector2i(220, 165) if low_memory else Vector2i(300, 225) if auto_rotate else Vector2i(180, 120)
	viewport_3d.transparent_bg = auto_rotate
	viewport_3d.msaa_3d = Viewport.MSAA_DISABLED
	viewport_3d.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport_3d.render_target_update_mode = SubViewport.UPDATE_ONCE
	_render_interval = 1.0 / (12.0 if low_memory else 24.0)
	add_child(viewport_3d)
	model_root = Node3D.new()
	viewport_3d.add_child(model_root)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.4
	camera.position = Vector3(3.4, 2.5, 3.4)
	viewport_3d.add_child(camera)
	camera.look_at(Vector3(0, 0.75, 0))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -35, 0)
	light.light_energy = 1.35 if auto_rotate else 0.95
	viewport_3d.add_child(light)
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0) if auto_rotate else Color("edf5f2")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.85 if auto_rotate else 0.62
	environment_node.environment = environment
	viewport_3d.add_child(environment_node)


func _process(delta: float) -> void:
	if model_root == null or not auto_rotate or not is_visible_in_tree():
		return
	_render_clock += delta
	if _render_clock < _render_interval:
		return
	model_root.rotation.y += _render_clock * 0.55
	_render_clock = 0.0
	viewport_3d.render_target_update_mode = SubViewport.UPDATE_ONCE


func set_model(path: String) -> void:
	if model_root == null:
		if not is_inside_tree():
			return
		await ready
	if not is_inside_tree() or model_root == null:
		return
	for child: Node in model_root.get_children():
		child.queue_free()
	if not path.is_empty():
		var model := ModelFactory.instantiate_model(path)
		model_root.add_child(model)
		var tree := get_tree()
		if tree == null:
			return
		await tree.process_frame
		if not is_inside_tree() or model_root == null or camera == null:
			return
		_fit_camera_to_model()
		if not auto_rotate:
			viewport_3d.render_target_update_mode = SubViewport.UPDATE_ONCE


func set_build_definition(definition: Dictionary) -> void:
	if model_root == null:
		if not is_inside_tree():
			return
		await ready
	if not is_inside_tree() or model_root == null:
		return
	for child: Node in model_root.get_children():
		child.queue_free()
	if definition.is_empty():
		return
	var item_id := String(definition.get("id", ""))
	var model := ModelFactory.instantiate_build_visual(definition, not item_id.begins_with("floor_"))
	ModelFactory.align_visual_to_grid_origin(model, not item_id.begins_with("floor_"))
	model_root.add_child(model)
	var tree := get_tree()
	if tree == null:
		return
	await tree.process_frame
	if not is_inside_tree() or model_root == null or camera == null:
		return
	_fit_camera_to_model()
	if not auto_rotate:
		viewport_3d.render_target_update_mode = SubViewport.UPDATE_ONCE


func _fit_camera_to_model() -> void:
	var bounds := AABB()
	var has_bounds := false
	for node: Node in model_root.find_children("*", "GeometryInstance3D", true, false):
		var geometry := node as GeometryInstance3D
		var local_bounds := geometry.get_aabb()
		for corner_index: int in 8:
			var corner := local_bounds.get_endpoint(corner_index)
			var preview_point := model_root.to_local(geometry.to_global(corner))
			if not has_bounds:
				bounds = AABB(preview_point, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(preview_point)
	if not has_bounds:
		return
	var center := bounds.get_center()
	var extent := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	camera.size = clampf(extent * 1.55, 0.55, 8.0)
	var direction := Vector3(1.0, 0.72, 1.0).normalized()
	camera.position = center + direction * maxf(extent * 2.5, 2.0)
	camera.look_at(center)
