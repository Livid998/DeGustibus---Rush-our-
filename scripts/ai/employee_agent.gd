class_name EmployeeAgent
extends AnimatedAgent

var employee: Dictionary = {}
var state := "idle"
var active_task: Dictionary = {}
var poll_time := 0.0
var work_time := 0.0
var stress := 0.0
var home_position := Vector3.ZERO
var idle_time := 0.0

var _thought: Label3D


func setup(value: Dictionary, value_world: RestaurantWorld) -> void:
	employee = value
	world = value_world
	name = "Employee_%s" % employee.id
	movement_speed = 2.4 * float(employee.get("speed", 1.0))
	var appearance := String(employee.get("appearance", "Worker_Male"))
	add_character_model("res://assets/characters/%s.gltf" % appearance, Vector3.ZERO, skin_tone_for_key(String(employee.id)))
	configure_navigation(0.40, _role_priority(false))
	home_position = world.staff_standby_position(self, String(employee.get("role", "cook")))
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
			navigation_priority = _role_priority(false)
			idle_time += scaled
			poll_time -= scaled
			if poll_time <= 0.0:
				poll_time = randf_range(0.25, 0.6)
				_claim_task()
			if state == "idle" and idle_time >= 0.35:
				_begin_return_to_standby()
		"returning_idle":
			poll_time -= scaled
			if poll_time <= 0.0:
				poll_time = randf_range(0.2, 0.45)
				_claim_task()
			if state == "moving":
				pass
			elif navigation_failed:
				_begin_return_to_standby(true)
			elif advance_path(scaled):
				state = "idle"
				navigation_priority = _role_priority(false)
				idle_time = 0.0
				poll_time = randf_range(0.08, 0.22)
		"moving":
			if not _active_task_is_actionable():
				cancel_active_task()
			elif navigation_failed:
				cancel_active_task()
			elif advance_path(scaled, active_task.get("action", "") == "serve"):
				_arrived()
		"working":
			if not _active_task_is_actionable():
				cancel_active_task()
				return
			work_time += scaled
			play_animation(String(active_task.get("animation", "PickUp")))
			if active_task.has("order_id"):
				var runtime := _active_station_runtime()
				if runtime and is_instance_valid(runtime.node):
					runtime.node.update_task_progress(active_task)
				if SimulationManager.advance_kitchen_task(active_task.id, scaled, employee):
					_finish_task()
			elif work_time >= 0.65:
				SimulationManager.complete_service_task(active_task.id)
				_finish_task()


func _claim_task() -> void:
	if String(employee.role) == "waiter":
		active_task = SimulationManager.claim_service_task(employee, global_position)
		if not active_task.is_empty():
			_thought.text = {"take_order":"COMANDA", "serve":"PRONTO!", "payment":"CONTO"}.get(active_task.action, "SERVIZIO")
	else:
		active_task = SimulationManager.claim_kitchen_task(employee, global_position)
		if not active_task.is_empty():
			_thought.text = String(active_task.recipe_step_id).to_upper()
	if not active_task.is_empty():
		var target := Vector3(active_task.get("target", active_task.get("interaction_position", SimulationManager.get_station_position(active_task.get("station_runtime", {})))))
		if not move_to(target):
			SimulationManager.cancel_employee_task(String(employee.get("id", "")))
			active_task = {}
			poll_time = 0.45
			return
		_thought.visible = true
		state = "moving"
		navigation_priority = _role_priority(true)
		idle_time = 0.0
		employee.current_task = String(active_task.get("recipe_step_id", active_task.get("action", "")))


func _arrived() -> void:
	work_time = 0.0
	if active_task.has("order_id"):
		if not SimulationManager.begin_kitchen_task(active_task.id):
			_finish_task()
			return
		var runtime := _active_station_runtime()
		if runtime and is_instance_valid(runtime.node):
			face_position(runtime.node.global_position)
			runtime.node.show_task(active_task)
	else:
		if not SimulationManager.begin_service_task(String(active_task.get("id", ""))):
			_finish_task()
			return
		var customer := active_task.get("customer") as Node3D
		if customer != null and is_instance_valid(customer):
			face_position(customer.global_position)
	state = "working"


func _finish_task() -> void:
	if active_task.has("station_runtime"):
		var runtime := _active_station_runtime()
		if runtime and is_instance_valid(runtime.node):
			runtime.node.clear_task()
	# Dictionaries are reference types. Replacing the local handle preserves the
	# authoritative task record owned by SimulationManager.
	active_task = {}
	employee.current_task = ""
	_thought.visible = false
	poll_time = randf_range(0.1, 0.25)
	_begin_return_to_standby()


func cancel_active_task() -> void:
	if active_task.has("station_runtime"):
		var runtime := _active_station_runtime()
		if runtime and is_instance_valid(runtime.get("node")):
			runtime.node.clear_task()
	SimulationManager.cancel_employee_task(String(employee.get("id", "")))
	active_task = {}
	employee.current_task = ""
	state = "idle"
	navigation_priority = _role_priority(false)
	idle_time = 0.0
	velocity = Vector3.ZERO
	navigation_active = false
	navigation_failed = false
	stuck_time = 0.0
	total_stuck_time = 0.0
	path.clear()
	path_index = 0
	play_animation("Idle")
	if _thought:
		_thought.visible = false
	if GameState.restaurant_state != "closed":
		_begin_return_to_standby()


func _begin_return_to_standby(force_refresh: bool = false) -> void:
	home_position = world.staff_standby_position(self, String(employee.get("role", "cook")), force_refresh)
	idle_time = 0.0
	navigation_priority = 5
	if _flat_distance(global_position, home_position) > 0.28 and move_to(home_position):
		state = "returning_idle"
		play_animation("Walk")
	else:
		state = "idle"
		navigation_priority = _role_priority(false)
		play_animation("Idle")


func _role_priority(active: bool) -> int:
	if not active:
		return 6
	match String(employee.get("role", "cook")):
		"waiter":
			return 2
		"cook":
			return 3
		_:
			return 4


func _active_task_is_actionable() -> bool:
	if active_task.is_empty():
		return false
	var task_id := String(active_task.get("id", ""))
	if active_task.has("order_id"):
		if not SimulationManager.tasks.has(task_id):
			return false
		return String(SimulationManager.tasks[task_id].get("state", "")) in ["reserved", "in_progress"]
	if not SimulationManager.service_tasks.has(task_id):
		return false
	return String(SimulationManager.service_tasks[task_id].get("state", "")) in ["reserved", "in_progress"] and SimulationManager.service_task_is_actionable(SimulationManager.service_tasks[task_id])


func _active_station_runtime() -> Dictionary:
	var value: Variant = active_task.get("station_runtime", {})
	return value if value is Dictionary else {}


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
