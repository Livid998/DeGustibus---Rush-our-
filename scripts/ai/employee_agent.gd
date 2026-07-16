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
var _task_prop_anchor: Node3D
var _task_prop: Node3D


func setup(value: Dictionary, value_world: RestaurantWorld) -> void:
	employee = value
	world = value_world
	name = "Employee_%s" % employee.id
	movement_speed = 2.4 * float(employee.get("speed", 1.0))
	var appearance := String(employee.get("appearance", "Worker_Male"))
	add_character_model("res://assets/characters/%s.gltf" % appearance, Vector3.ZERO, skin_tone_for_key(String(employee.id)))
	configure_navigation(0.40, _role_priority(false))
	home_position = world.staff_standby_position(self, String(employee.get("role", "cook")))
	_create_task_prop_anchor()
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
			elif advance_path(scaled, _task_uses_carry_animation()):
				_arrived()
		"working":
			if not _active_task_is_actionable():
				cancel_active_task()
				return
			work_time += scaled
			play_animation(String(active_task.get("animation", "PickUp")))
			_update_task_prop_motion()
			match _active_task_kind():
				"kitchen":
					var runtime := _active_station_runtime()
					if runtime and is_instance_valid(runtime.node):
						runtime.node.update_task_progress(active_task)
					if SimulationManager.advance_kitchen_task(active_task.id, scaled, employee):
						_finish_task()
				"maintenance":
					var duration := float(active_task.get("duration", 1.5)) / maxf(float(employee.get("speed", 1.0)), 0.1)
					if work_time >= duration:
						SimulationManager.complete_maintenance_task(String(active_task.get("id", "")))
						_finish_task()
				_:
					if work_time >= 0.65:
						SimulationManager.complete_service_task(active_task.id)
						_finish_task()


func _claim_task() -> void:
	match String(employee.get("role", "cook")):
		"waiter":
			active_task = SimulationManager.claim_service_task(employee, global_position)
			if not active_task.is_empty():
				_thought.text = {"take_order":"COMANDA", "serve":"PRONTO!", "payment":"CONTO", "collect_dishes":"PIATTI"}.get(active_task.action, "SERVIZIO")
		"handyman":
			active_task = SimulationManager.claim_maintenance_task(employee, global_position)
			if not active_task.is_empty():
				_thought.text = {"wash_dishes":"LAVAGGIO", "clean_spill":"PULIZIA", "clean_floor":"PULIZIA"}.get(active_task.action, "MANUTENZIONE")
		_:
			active_task = SimulationManager.claim_kitchen_task(employee, global_position)
			if not active_task.is_empty():
				_thought.text = String(active_task.recipe_step_id).to_upper()
	if not active_task.is_empty():
		var target_value: Variant = active_task.get("target", null)
		if not target_value is Vector3:
			target_value = active_task.get("interaction_position", null)
		if not target_value is Vector3:
			var runtime_value: Variant = active_task.get("station_runtime", {})
			target_value = SimulationManager.get_station_position(runtime_value if runtime_value is Dictionary else {})
		var target := Vector3(target_value)
		if not move_to(target):
			SimulationManager.cancel_employee_task(String(employee.get("id", "")))
			active_task = {}
			poll_time = 0.45
			return
		if String(active_task.get("action", "")) != "collect_dishes":
			_show_task_prop()
		_thought.visible = true
		state = "moving"
		navigation_priority = _role_priority(true)
		idle_time = 0.0
		employee.current_task = String(active_task.get("recipe_step_id", active_task.get("action", "")))


func _arrived() -> void:
	work_time = 0.0
	match _active_task_kind():
		"kitchen":
			if not SimulationManager.begin_kitchen_task(active_task.id):
				_finish_task()
				return
			var runtime := _active_station_runtime()
			if runtime and is_instance_valid(runtime.node):
				face_position(runtime.node.global_position)
				runtime.node.show_task(active_task)
		"maintenance":
			if not SimulationManager.begin_maintenance_task(String(active_task.get("id", ""))):
				_finish_task()
				return
			var runtime := _active_station_runtime()
			if runtime and is_instance_valid(runtime.get("node")):
				face_position((runtime.node as Node3D).global_position)
			else:
				var owner := active_task.get("owner") as Node3D
				if owner != null and is_instance_valid(owner):
					face_position(owner.global_position)
		_:
			var task_state := String(active_task.get("state", ""))
			if task_state == "reserved":
				if not SimulationManager.begin_service_task(String(active_task.get("id", ""))):
					_finish_task()
					return
			elif task_state != "in_progress":
				_finish_task()
				return
			var customer := active_task.get("customer") as Node3D
			if customer != null and is_instance_valid(customer):
				face_position(customer.global_position)
			if String(active_task.get("action", "")) == "collect_dishes" and String(active_task.get("travel_stage", "")) != "delivery":
				if customer != null and customer.has_method("service_task_stage"):
					customer.call("service_task_stage", "collect_dishes", active_task.get("payload", {}), "pickup")
				active_task.travel_stage = "delivery"
				active_task.carry_model = String(active_task.get("payload", {}).get("carry_model", "res://assets/equipment/plate_dirty.gltf"))
				_show_task_prop()
				var secondary := Vector3(active_task.get("payload", {}).get("secondary_target", global_position))
				if move_to(secondary):
					state = "moving"
					return
	state = "working"


func _finish_task() -> void:
	if _active_task_kind() == "kitchen" and active_task.has("station_runtime"):
		var runtime := _active_station_runtime()
		if runtime and is_instance_valid(runtime.node):
			runtime.node.clear_task()
	_clear_task_prop()
	# Dictionaries are reference types. Replacing the local handle preserves the
	# authoritative task record owned by SimulationManager.
	active_task = {}
	employee.current_task = ""
	_thought.visible = false
	poll_time = randf_range(0.1, 0.25)
	_begin_return_to_standby()


func cancel_active_task() -> void:
	if _active_task_kind() == "kitchen" and active_task.has("station_runtime"):
		var runtime := _active_station_runtime()
		if runtime and is_instance_valid(runtime.get("node")):
			runtime.node.clear_task()
	SimulationManager.cancel_employee_task(String(employee.get("id", "")))
	_clear_task_prop()
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
	match _active_task_kind():
		"kitchen":
			if not SimulationManager.tasks.has(task_id):
				return false
			return String(SimulationManager.tasks[task_id].get("state", "")) in ["reserved", "in_progress"] and SimulationManager.kitchen_task_reservation_is_valid(task_id, String(employee.get("id", "")))
		"maintenance":
			if not SimulationManager.maintenance_tasks.has(task_id):
				return false
			return String(SimulationManager.maintenance_tasks[task_id].get("state", "")) in ["reserved", "in_progress"] and SimulationManager.maintenance_task_is_actionable(SimulationManager.maintenance_tasks[task_id]) and SimulationManager.maintenance_task_reservation_is_valid(task_id, String(employee.get("id", "")))
		_:
			if not SimulationManager.service_tasks.has(task_id):
				return false
			return String(SimulationManager.service_tasks[task_id].get("state", "")) in ["reserved", "in_progress"] and SimulationManager.service_task_is_actionable(SimulationManager.service_tasks[task_id])


func _active_task_kind() -> String:
	if String(active_task.get("task_kind", "")) == "maintenance":
		return "maintenance"
	return "kitchen" if active_task.has("order_id") else "service"


func _task_uses_carry_animation() -> bool:
	if active_task.is_empty():
		return false
	return String(active_task.get("action", "")) in ["serve", "collect_dishes"] or not String(active_task.get("carry_model", "")).is_empty() or (_active_task_kind() == "maintenance" and _task_prop != null)


func _active_station_runtime() -> Dictionary:
	var value: Variant = active_task.get("station_runtime", {})
	return value if value is Dictionary else {}


func _create_task_prop_anchor() -> void:
	_task_prop_anchor = Node3D.new()
	_task_prop_anchor.name = "TaskPropAnchor"
	add_child(_task_prop_anchor)


func _show_task_prop() -> void:
	_clear_task_prop()
	if _task_prop_anchor == null:
		return
	var action := String(active_task.get("action", ""))
	var model_path := String(active_task.get("tool_model", ""))
	if model_path.is_empty():
		model_path = String(active_task.get("carry_model", ""))
	if model_path.is_empty():
		model_path = String(active_task.get("payload", {}).get("carry_model", ""))
	if model_path.is_empty() and action == "serve":
		model_path = _serve_dish_model()
	if model_path.is_empty():
		match action:
			"clean_spill", "clean_floor":
				model_path = "res://assets/cleaning/Tool_Mop.glb"
			"wash_dishes":
				model_path = "res://assets/cleaning/Cleaning_Sponge.glb"
			"collect_dishes":
				model_path = "res://assets/equipment/plate.gltf"
	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return
	var scale_factor := 1.0
	if action == "wash_dishes":
		scale_factor = 0.55
	elif action == "collect_dishes":
		scale_factor = 0.5
	elif action == "serve":
		scale_factor = 0.46
	_task_prop = ModelFactory.instantiate_model(model_path, scale_factor)
	_task_prop.name = "ActiveTaskProp"
	ModelFactory.align_visual_to_grid_origin(_task_prop)
	_task_prop_anchor.add_child(_task_prop)
	if action == "wash_dishes":
		_task_prop.position = Vector3(0.18, 0.95, -0.18)
	elif action == "collect_dishes":
		_task_prop.position = Vector3(0.0, 1.02, -0.35)
	elif action == "serve":
		# Kept level in front of both hands: the food now visibly travels with the
		# waiter and is replaced by the customer's table dish on delivery.
		_task_prop.position = Vector3(0.0, 1.02, -0.34)
	else:
		_task_prop.position = Vector3(0.34, 0.02, -0.08)
	ModelFactory.set_shadow_casting(_task_prop, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)


func _serve_dish_model() -> String:
	var order_id := String(active_task.get("payload", {}).get("order_id", ""))
	var order: Dictionary = SimulationManager.orders.get(order_id, {})
	var recipe: Dictionary = DataRegistry.recipes_by_id.get(String(order.get("recipe_id", "")), {})
	return String(recipe.get("dish_model", ""))


func _update_task_prop_motion() -> void:
	if _task_prop == null or not is_instance_valid(_task_prop):
		return
	var action := String(active_task.get("action", ""))
	if action in ["clean_spill", "clean_floor"]:
		_task_prop.rotation.z = sin(work_time * 5.4) * 0.18
		_task_prop.position.x = 0.34 + sin(work_time * 4.1) * 0.12
	elif action == "wash_dishes":
		_task_prop.position.x = 0.18 + sin(work_time * 7.0) * 0.09
		_task_prop.position.z = -0.18 + cos(work_time * 5.5) * 0.05


func _clear_task_prop() -> void:
	if _task_prop != null and is_instance_valid(_task_prop):
		_task_prop.queue_free()
	_task_prop = null
	if _task_prop_anchor != null:
		_task_prop_anchor.rotation = Vector3.ZERO


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
