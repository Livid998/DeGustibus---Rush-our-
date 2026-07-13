class_name KitchenStation
extends StaticBody3D

signal processing_changed(station: KitchenStation, state: String)

var station_id := ""
var display_name := ""
var disorder := 0.0
var game: Node
var base_color := Color.WHITE
var body_mesh: MeshInstance3D
var model_root: Node3D
var highlight_ring: MeshInstance3D
var label: Label3D
var clutter: Array[MeshInstance3D] = []
var highlighted := false
var processing_state := "idle"
var processing_input := ""
var processing_result := ""
var processing_elapsed := 0.0
var processing_duration := 0.0
var ready_elapsed := 0.0
var burn_window := 8.0
var food_visual: Node3D
var status_label: Label3D
var particles: GPUParticles3D
var particle_material: StandardMaterial3D
var visual_height := 1.2

func setup(id: String, title: String, color: Color, size: Vector3, owner_game: Node) -> void:
	station_id = id
	display_name = title
	base_color = color
	game = owner_game
	visual_height = size.y
	add_to_group("interactable")
	body_mesh = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	body_mesh.mesh = mesh
	body_mesh.position.y = size.y * 0.5
	body_mesh.material_override = _material(color)
	add_child(body_mesh)
	highlight_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = maxf(size.x, size.z) * 0.48
	ring_mesh.outer_radius = maxf(size.x, size.z) * 0.56
	highlight_ring.mesh = ring_mesh
	highlight_ring.position.y = 0.055
	highlight_ring.material_override = _material(color.lightened(0.32), true)
	highlight_ring.visible = false
	add_child(highlight_ring)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.position.y = size.y * 0.5
	add_child(collision)
	label = Label3D.new()
	label.text = title.to_upper()
	label.font_size = 44
	label.pixel_size = 0.0035
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
	_build_processing_feedback()

func set_visual_model(path: String, scale_factor: Variant = 1.0, rotation_y := 0.0, offset := Vector3.ZERO) -> void:
	if is_instance_valid(model_root):
		model_root.queue_free()
	var model_scale: Vector3 = scale_factor if scale_factor is Vector3 else Vector3.ONE * float(scale_factor)
	model_root = AssetLibrary.add_model(self, path, offset, model_scale, Vector3(0, rotation_y, 0))
	if model_root:
		body_mesh.visible = false

func _process(delta: float) -> void:
	if processing_state == "idle":
		return
	if is_instance_valid(food_visual):
		food_visual.rotation.y += delta * (1.7 if processing_state == "cooking" else 0.35)
		food_visual.position.y = visual_height + 0.15 + sin(Time.get_ticks_msec() * 0.004) * 0.035
	if processing_state == "cooking":
		processing_elapsed += delta
		var remaining := maxf(0.0, processing_duration - processing_elapsed)
		status_label.text = "CUOCE  %.1fs" % remaining
		status_label.modulate = Color("#ffe070")
		if processing_elapsed >= processing_duration:
			processing_state = "ready"
			ready_elapsed = 0.0
			status_label.text = "PRONTO!  [E]"
			status_label.modulate = Color("#79ff9f")
			particle_material.albedo_color = Color("#fff1cfb8")
			processing_changed.emit(self, processing_state)
	elif processing_state == "ready":
		ready_elapsed += delta
		status_label.text = "PRONTO  %.0fs" % maxf(0.0, burn_window - ready_elapsed)
		if ready_elapsed >= burn_window:
			processing_state = "burnt"
			status_label.text = "BRUCIATO!"
			status_label.modulate = Color("#ff5a4f")
			particle_material.albedo_color = Color("#4b4545d0")
			if is_instance_valid(food_visual):
				AssetLibrary.set_burnt(food_visual)
			processing_changed.emit(self, processing_state)
	elif processing_state == "burnt":
		status_label.text = "BRUCIATO · RIMUOVI"

func start_processing(input_item: String, result_item: String, duration: float, burn_after := 8.0) -> bool:
	if processing_state != "idle":
		return false
	processing_input = input_item
	processing_result = result_item
	processing_duration = duration
	processing_elapsed = 0.0
	ready_elapsed = 0.0
	burn_window = burn_after
	processing_state = "cooking"
	food_visual = Node3D.new()
	food_visual.position = Vector3(0, visual_height + 0.12, 0)
	add_child(food_visual)
	var food_model := AssetLibrary.add_food(food_visual, input_item, Vector3.ZERO, 1.05)
	if food_model:
		AssetLibrary.set_model_tint(food_model, _food_color(input_item), true)
	particles.emitting = true
	status_label.visible = true
	processing_changed.emit(self, processing_state)
	return true

func collect_result() -> String:
	if processing_state != "ready":
		return ""
	var result := processing_result
	clear_processing()
	return result

func clear_processing() -> void:
	processing_state = "idle"
	processing_input = ""
	processing_result = ""
	processing_elapsed = 0.0
	ready_elapsed = 0.0
	if is_instance_valid(food_visual):
		food_visual.queue_free()
	food_visual = null
	particles.emitting = false
	particle_material.albedo_color = Color("#fff4d6a8")
	status_label.visible = false
	processing_changed.emit(self, processing_state)

func has_processing() -> bool:
	return processing_state != "idle"

func _build_processing_feedback() -> void:
	status_label = Label3D.new()
	status_label.font_size = 38
	status_label.outline_size = 10
	status_label.position = Vector3(0, visual_height + 0.82, 0)
	status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	status_label.visible = false
	add_child(status_label)
	particles = GPUParticles3D.new()
	particles.position = Vector3(0, visual_height + 0.25, 0)
	particles.amount = 18
	particles.lifetime = 1.15
	particles.randomness = 0.45
	particles.emitting = false
	var process_mat := ParticleProcessMaterial.new()
	process_mat.direction = Vector3.UP
	process_mat.spread = 24.0
	process_mat.initial_velocity_min = 0.45
	process_mat.initial_velocity_max = 1.1
	process_mat.gravity = Vector3(0, 0.28, 0)
	process_mat.scale_min = 0.25
	process_mat.scale_max = 0.65
	particles.process_material = process_mat
	var particle_mesh := SphereMesh.new()
	particle_mesh.radius = 0.055
	particle_mesh.height = 0.11
	particle_material = StandardMaterial3D.new()
	particle_material.albedo_color = Color("#fff4d6a8")
	particle_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	particle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	particle_mesh.material = particle_material
	particles.draw_pass_1 = particle_mesh
	add_child(particles)

func _food_color(item: String) -> Color:
	if item.begins_with("burger"): return Color("#b64e36")
	if item.begins_with("pasta"): return Color("#f0c349")
	if item.begins_with("special"): return Color("#e6a947")
	return Color("#e8d39b")

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
	if body_mesh.visible:
		body_mesh.material_override = _material(color, value)
	highlight_ring.visible = value
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
