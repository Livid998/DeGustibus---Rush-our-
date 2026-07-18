class_name AgentStatusBubble
extends Node3D

## Replaces the old always-on floating text with a short, readable visual cue.
## The legacy Label3D remains the source of truth so gameplay code can keep
## setting `text` and `visible`; only its rendering is hidden.

const CUSTOMER_ATLAS := "res://assets/ui/status_bubbles/customer_bubbles.png"
const STAFF_ATLAS := "res://assets/ui/status_bubbles/staff_bubbles.png"
const CELL_SIZE := Vector2(192.0, 192.0)
const SHOW_ZOOM := 18.0
const HIDE_ZOOM := 19.5
const DEFAULT_DURATION := 2.6

var source_label: Label3D
var world: RestaurantWorld
var audience := "customer"
var current_key := ""

var _sprite: Sprite3D
var _last_text := ""
var _request_was_visible := false
var _remaining := 0.0
var _zoom_allowed := false


func setup(label: Label3D, restaurant_world: RestaurantWorld, value_audience: String) -> void:
	source_label = label
	world = restaurant_world
	audience = value_audience
	name = "StatusBubbleVisual"
	position = source_label.position
	_build_sprite()
	# Preserve text for tests/accessibility and for the mapping below, but do not
	# draw a second label behind the supplied art.
	var hidden_modulate := source_label.modulate
	hidden_modulate.a = 0.0
	source_label.modulate = hidden_modulate
	set_process(true)


func _process(delta: float) -> void:
	update_bubble(delta)


func update_bubble(delta: float) -> void:
	if source_label == null or not is_instance_valid(source_label) or _sprite == null:
		return
	var requested := source_label.visible and not source_label.text.strip_edges().is_empty()
	var text := source_label.text.strip_edges().to_upper()
	if requested and (not _request_was_visible or text != _last_text):
		_last_text = text
		_set_icon_for_text(text)
		_remaining = _duration_for_text(text)
	_request_was_visible = requested
	if _remaining > 0.0:
		_remaining = maxf(_remaining - delta, 0.0)

	var was_zoom_allowed := _zoom_allowed
	var zoom := 999.0
	if world != null and is_instance_valid(world) and world.camera_rig != null:
		zoom = world.camera_rig.camera.size if world.camera_rig.camera != null else world.camera_rig.zoom
	if _zoom_allowed:
		if zoom >= HIDE_ZOOM:
			_zoom_allowed = false
	elif zoom <= SHOW_ZOOM:
		_zoom_allowed = true
	# When the player deliberately zooms in, briefly reveal the current useful
	# state even if its original transition happened while the map was distant.
	if _zoom_allowed and not was_zoom_allowed and requested and not current_key.is_empty():
		_remaining = maxf(_remaining, 1.8)

	var should_show := requested and _zoom_allowed and _remaining > 0.0 and _sprite.texture != null
	_sprite.visible = should_show
	if should_show:
		var fade := clampf(_remaining / 0.28, 0.0, 1.0)
		_sprite.modulate = Color(1.0, 1.0, 1.0, fade)


func is_icon_visible() -> bool:
	return _sprite != null and _sprite.visible and _zoom_allowed and _remaining > 0.0


func _build_sprite() -> void:
	if _sprite != null:
		return
	_sprite = Sprite3D.new()
	_sprite.name = "BubbleIcon"
	_sprite.position = Vector3(0.0, 0.22, 0.0)
	_sprite.pixel_size = 0.006
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.no_depth_test = true
	_sprite.shaded = false
	_sprite.double_sided = true
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_sprite.render_priority = 8
	_sprite.visible = false
	add_child(_sprite)


func _set_icon_for_text(text: String) -> void:
	var descriptor := _staff_descriptor(text) if audience == "staff" else _customer_descriptor(text)
	current_key = String(descriptor.get("key", ""))
	if current_key.is_empty():
		_sprite.texture = null
		return
	var atlas_path := STAFF_ATLAS if audience == "staff" else CUSTOMER_ATLAS
	var atlas_texture := load(atlas_path) as Texture2D
	if atlas_texture == null:
		_sprite.texture = null
		return
	var cell := Vector2i(descriptor.get("cell", Vector2i.ZERO))
	var texture := AtlasTexture.new()
	texture.atlas = atlas_texture
	texture.region = Rect2(Vector2(cell.x, cell.y) * CELL_SIZE, CELL_SIZE)
	_sprite.texture = texture


func _duration_for_text(text: String) -> float:
	if _contains_any(text, ["TROPPA", "NESSUN", "RITARDO", "CHIUSURA", "ATTESA"]):
		return 3.4
	return DEFAULT_DURATION


func _customer_descriptor(text: String) -> Dictionary:
	if text.begins_with("+"):
		return {"key":"paid", "cell":Vector2i(2, 4)}
	if _contains_any(text, ["CAMBIO ORDINE", "PIATTO ESAURITO", "NESSUNA ALTERNATIVA"]):
		return {"key":"change_order", "cell":Vector2i(3, 3)}
	if _contains_any(text, ["TROPPA", "NESSUN"]):
		return {"key":"angry", "cell":Vector2i(3, 0)}
	if _contains_any(text, ["RITARDO", "ATTESA TURNO", "ATTESA TAVOLO"]):
		return {"key":"waiting", "cell":Vector2i(1, 1)}
	if _contains_any(text, ["ATTENDO USCITA", "CHIUSURA", "USCITA"]):
		return {"key":"leaving", "cell":Vector2i(0, 5)}
	if _contains_any(text, ["CONTO", "PAGA"]):
		return {"key":"bill", "cell":Vector2i(0, 2)}
	if _contains_any(text, ["SERVITI", "PRONTO"]):
		return {"key":"served", "cell":Vector2i(1, 2)}
	if _contains_any(text, ["MENU", "COMAND"]):
		return {"key":"ordering", "cell":Vector2i(4, 1)}
	if _contains_any(text, ["FAME", "MANGIA"]):
		return {"key":"hungry", "cell":Vector2i(2, 1)}
	if _contains_any(text, ["FELICE", "OTTIMO"]):
		return {"key":"happy", "cell":Vector2i(1, 0)}
	return {"key":"conversation", "cell":Vector2i(5, 3)}


func _staff_descriptor(text: String) -> Dictionary:
	if _contains_any(text, ["COMANDA", "ORDINE"]):
		return {"key":"take_order", "cell":Vector2i(0, 0)}
	if _contains_any(text, ["PRONTO", "SERVIZIO"]):
		return {"key":"serve", "cell":Vector2i(2, 0)}
	if _contains_any(text, ["CONTO", "PAGAMENTO"]):
		return {"key":"payment", "cell":Vector2i(2, 1)}
	if _contains_any(text, ["PIATTI"]):
		return {"key":"collect_dishes", "cell":Vector2i(5, 0)}
	if _contains_any(text, ["LAVAGGIO", "LAVA"]):
		return {"key":"wash", "cell":Vector2i(0, 1)}
	if _contains_any(text, ["PULIZIA", "MANUTENZIONE"]):
		return {"key":"clean", "cell":Vector2i(1, 5)}
	if _contains_any(text, ["PIZZA"]):
		return {"key":"pizza_oven", "cell":Vector2i(5, 2)}
	if _contains_any(text, ["FORNO", "OVEN", "BAKE"]):
		return {"key":"oven", "cell":Vector2i(4, 2)}
	if _contains_any(text, ["GRILL", "PATTY", "BISTECCA"]):
		return {"key":"grill", "cell":Vector2i(2, 4)}
	if _contains_any(text, ["CUOCI", "COOK", "STOVE"]):
		return {"key":"stove", "cell":Vector2i(3, 2)}
	if _contains_any(text, ["TAGLIA", "CUT", "SLICE", "VEG"]):
		return {"key":"chop", "cell":Vector2i(0, 3)}
	if _contains_any(text, ["IMPASTO", "DOUGH"]):
		return {"key":"dough", "cell":Vector2i(2, 3)}
	if _contains_any(text, ["MIX", "MESCOLA"]):
		return {"key":"mix", "cell":Vector2i(1, 3)}
	if _contains_any(text, ["ASSEMBLE", "FINISH", "PLATE", "IMPIATTA"]):
		return {"key":"assemble", "cell":Vector2i(3, 3)}
	if _contains_any(text, ["FRIDGE", "STORAGE", "MAGAZZINO"]):
		return {"key":"storage", "cell":Vector2i(5, 4)}
	return {"key":"task", "cell":Vector2i(1, 0)}


func _contains_any(text: String, needles: Array[String]) -> bool:
	for needle: String in needles:
		if text.contains(needle):
			return true
	return false
