class_name EmployeeAgent
extends AnimatedAgent

var employee: Dictionary = {}
var state := "idle"
var active_task: Dictionary = {}
var poll_time := 0.0
var work_time := 0.0
var stress := 0.0

var _thought: Label3D


func setup(value: Dictionary, value_world: RestaurantWorld) -> void:
	employee = value
	world = value_world
	name = "Employee_%s" % employee.id
	movement_speed = 2.4 * float(employee.get("speed", 1.0))
	var appearance := String(employee.get("appearance", "Worker_Male"))
	add_character_model("res://assets/characters/%s.gltf" % appearance)
	_create_thought()
	validate_animations()


func _process(delta: float) -> void:
	if GameState.restaurant_state == "closed":
		if state != "idle":
			cancel_active_task()
		play_animation("Idle")
		return
	var scaled := delta * SimulationManager.simulation_speed
	if state == "working":
		stress = minf(stress + scaled * 0.006, 0.75)
	else:
		stress = maxf(stress - scaled * 0.003, 0.0)
	employee.stress = stress
	employee.state = state
	match state:
		"idle":
			poll_time -= scaled
			if poll_time <= 0.0:
				poll_time = randf_range(0.25, 0.6)
				_claim_task()
		"moving":
			if advance_path(scaled, active_task.get("action", "") == "serve"):
				_arrived()
		"working":
			work_time += scaled
			play_animation(String(active_task.get("animation", "PickUp")))
			if active_task.has("order_id"):
				var runtime: Dictionary = active_task.get("station_runtime", {})
				if runtime and is_instance_valid(runtime.node):
					runtime.node.update_task_progress(active_task)
				if SimulationManager.advance_kitchen_task(active_task.id, scaled, employee):
					_finish_task()
			elif work_time >= 0.65:
				SimulationManager.complete_service_task(active_task.id)
				_finish_task()


func _claim_task() -> void:
	if String(employee.role) == "waiter":
		active_task = SimulationManager.claim_service_task(employee)
		if not active_task.is_empty():
			_thought.text = {"take_order":"COMANDA", "serve":"PRONTO!", "payment":"CONTO"}.get(active_task.action, "SERVIZIO")
			move_to(active_task.target)
	else:
		active_task = SimulationManager.claim_kitchen_task(employee, global_position)
		if not active_task.is_empty():
			_thought.text = String(active_task.recipe_step_id).to_upper()
			move_to(SimulationManager.get_station_position(active_task.station_runtime))
	if not active_task.is_empty():
		_thought.visible = true
		state = "moving"
		employee.current_task = String(active_task.get("recipe_step_id", active_task.get("action", "")))


func _arrived() -> void:
	work_time = 0.0
	if active_task.has("order_id"):
		if not SimulationManager.begin_kitchen_task(active_task.id):
			_finish_task()
			return
		var runtime: Dictionary = active_task.get("station_runtime", {})
		if runtime and is_instance_valid(runtime.node):
			runtime.node.show_task(active_task)
	state = "working"


func _finish_task() -> void:
	if active_task.has("station_runtime"):
		var runtime: Dictionary = active_task.get("station_runtime", {})
		if runtime and is_instance_valid(runtime.node):
			runtime.node.clear_task()
	# Dictionaries are reference types. Replacing the local handle preserves the
	# authoritative task record owned by SimulationManager.
	active_task = {}
	employee.current_task = ""
	_thought.visible = false
	state = "idle"
	poll_time = randf_range(0.1, 0.35)
	play_animation("Idle")


func cancel_active_task() -> void:
	SimulationManager.cancel_employee_task(String(employee.get("id", "")))
	active_task = {}
	state = "idle"
	if _thought:
		_thought.visible = false


func _create_thought() -> void:
	_thought = Label3D.new()
	_thought.font = GameFonts.medium()
	_thought.position = Vector3(0, 2.15, 0)
	_thought.font_size = 22
	_thought.outline_size = 8
	_thought.modulate = Color("fff0ae")
	_thought.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_thought.no_depth_test = true
	_thought.visible = false
	add_child(_thought)
