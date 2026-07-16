class_name RestaurantCamera
extends Node3D

var camera: Camera3D
var target := Vector3.ZERO
var zoom := 24.0

var _mouse_pan_button := false
var _primary_down := false
var _primary_dragged := false
var _primary_origin := Vector2.ZERO
var _tap_ready := false
var _tap_position := Vector2.ZERO
var _touches: Dictionary = {}
var _last_pinch := 0.0
var _last_touch_center := Vector2.ZERO
var _touch_hold_time := 0.0
var _long_press_ready := false
var _long_press_triggered := false
var _long_press_position := Vector2.ZERO

const DRAG_THRESHOLD := 7.0


func _ready() -> void:
	zoom = clampf(float(GameState.settings.get("camera_zoom", 24.0)), 13.0, 34.0)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = zoom
	camera.position = Vector3(18, 22, 18)
	add_child(camera)
	camera.look_at(Vector3.ZERO)


func _process(delta: float) -> void:
	global_position = global_position.lerp(target, minf(delta * 8.0, 1.0))
	camera.size = lerpf(camera.size, zoom, minf(delta * 10.0, 1.0))
	if _touches.size() == 1 and not _primary_dragged and not _long_press_triggered:
		_touch_hold_time += delta
		if _touch_hold_time >= 0.55:
			_long_press_triggered = true
			_long_press_ready = true
			_long_press_position = Vector2(_touches.values()[0])


func handle_input(event: InputEvent, allow_primary_pan: bool = true) -> bool:
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			_mouse_pan_button = event.pressed
			return true
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			zoom_at(event.position, -1.5)
			return true
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			zoom_at(event.position, 1.5)
			return true
		if event.button_index == MOUSE_BUTTON_LEFT and allow_primary_pan:
			if event.pressed:
				_primary_down = true
				_primary_dragged = false
				_primary_origin = event.position
			else:
				if _primary_down and not _primary_dragged:
					_tap_ready = true
					_tap_position = event.position
				_primary_down = false
			return true
	if event is InputEventMouseMotion:
		if _mouse_pan_button:
			pan_by(event.relative)
			return true
		if allow_primary_pan and _primary_down:
			if event.position.distance_to(_primary_origin) >= DRAG_THRESHOLD:
				_primary_dragged = true
			if _primary_dragged:
				pan_by(event.relative)
			return true
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() == 1:
				_primary_origin = event.position
				_primary_dragged = false
				_touch_hold_time = 0.0
				_long_press_triggered = false
		else:
			var was_single := _touches.size() == 1
			_touches.erase(event.index)
			if allow_primary_pan and was_single and not _primary_dragged and not _long_press_triggered:
				_tap_ready = true
				_tap_position = event.position
			_touch_hold_time = 0.0
			if _touches.size() < 2:
				_last_pinch = 0.0
				_last_touch_center = Vector2.ZERO
		return allow_primary_pan or _touches.size() >= 1
	if event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			_touch_hold_time = 0.0
			var values: Array = _touches.values()
			var first := Vector2(values[0])
			var second := Vector2(values[1])
			var distance := first.distance_to(second)
			var center := (first + second) * 0.5
			if _last_pinch > 0.0:
				zoom = clampf(zoom - (distance - _last_pinch) * 0.025, 13.0, 34.0)
			if _last_touch_center != Vector2.ZERO:
				pan_by(center - _last_touch_center)
			_last_pinch = distance
			_last_touch_center = center
			_primary_dragged = true
			return true
		if allow_primary_pan:
			if event.position.distance_to(_primary_origin) >= DRAG_THRESHOLD:
				_primary_dragged = true
				_touch_hold_time = 0.0
			if _primary_dragged:
				pan_by(event.relative)
			return true
	return false


func consume_tap() -> Variant:
	if not _tap_ready:
		return null
	_tap_ready = false
	return _tap_position


func consume_long_press() -> Variant:
	if not _long_press_ready:
		return null
	_long_press_ready = false
	return _long_press_position


func zoom_at(_screen_position: Vector2, amount: float) -> void:
	zoom = clampf(zoom + amount, 13.0, 34.0)


func pan_by(delta: Vector2) -> void:
	var right := Vector3(camera.global_transform.basis.x.x, 0, camera.global_transform.basis.x.z).normalized()
	var forward := Vector3(camera.global_transform.basis.y.x, 0, camera.global_transform.basis.y.z).normalized()
	target += (-right * delta.x + forward * delta.y) * zoom * 0.0022
	# The buildable lot extends well beyond the original dining room.
	target.x = clampf(target.x, -24.0, 36.0)
	target.z = clampf(target.z, -20.0, 20.0)
