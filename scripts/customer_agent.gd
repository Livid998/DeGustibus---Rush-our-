class_name CustomerAgent
extends CharacterBody3D

var game: Node
var customer_id := 0
var table_id := 0
var problematic := false
var interruption := {}
var patience := 100.0
var active := true
var body_color := Color.WHITE
var label: Label3D
var body: MeshInstance3D

func setup(owner_game: Node, id: int, table: int, color: Color, is_problematic := false, event := {}) -> void:
	game = owner_game
	customer_id = id
	table_id = table
	problematic = is_problematic
	interruption = event
	body_color = color
	add_to_group("customers")
	if not interruption.is_empty():
		add_to_group("interactable")
	_build_visual()

func _build_visual() -> void:
	body = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.36
	capsule.height = 1.18
	body.mesh = capsule
	body.position.y = 0.79
	body.material_override = _material(body_color)
	add_child(body)
	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.31
	sphere.height = 0.62
	head.mesh = sphere
	head.position.y = 1.67
	head.material_override = _material(Color("#eeb18b"))
	add_child(head)
	var hair := MeshInstance3D.new()
	var hair_mesh := SphereMesh.new()
	hair_mesh.radius = 0.32
	hair_mesh.height = 0.35
	hair.mesh = hair_mesh
	hair.position.y = 1.88
	hair.material_override = _material(body_color.darkened(0.45))
	add_child(hair)
	label = Label3D.new()
	label.font_size = 34
	label.outline_size = 9
	label.position.y = 2.35
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.text = "! %s" % interruption.get("title", "PROBLEMATICO") if problematic else "TAVOLO %d" % table_id
	label.modulate = Color("#ff725e") if problematic else Color("#fff4da")
	add_child(label)
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.36
	shape.height = 1.55
	collision.shape = shape
	collision.position.y = 0.78
	add_child(collision)

func get_prompt() -> String:
	if not interruption.is_empty():
		return "Gestisci: %s" % interruption.title
	return "Cliente al tavolo %d" % table_id

func begin_interaction(_player: Node) -> void:
	if not interruption.is_empty() and game and game.has_method("open_interruption"):
		game.open_interruption(self)

func set_patience(value: float, maximum: float) -> void:
	patience = value
	if not problematic:
		label.text = "T%d  %d%%" % [table_id, int(100.0 * value / maxf(1.0, maximum))]
		label.modulate = Color("#ff725e") if value / maximum < 0.35 else Color("#fff4da")

func slapstick_hit(direction: Vector3) -> void:
	if not active:
		return
	active = false
	var target := global_position + direction.normalized() * 7.0 + Vector3.UP * 2.5
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "global_position", target, 0.75)
	tween.tween_property(self, "rotation", Vector3(TAU, TAU * 1.4, TAU * 0.7), 0.75)
	tween.chain().tween_callback(queue_free)

func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.75
	return mat

