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
var _hand_prop_anchor: Node3D
var _left_hand_prop_anchor: Node3D
var _task_prop: Node3D
var _task_prop_is_tool := false
var _travel_stage := ""
var _task_destination := Vector3.ZERO
var _pickup_sources: Array[Node] = []
var _gesture_cycle_index := -1
var _gesture_seed := 0.0


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
	_gesture_seed = float(abs(String(employee.id).hash() % 1000)) / 1000.0
	_create_thought()
	validate_animations()


func _process(delta: float) -> void:
	_update_carried_prop_anchor()
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
			_update_work_gesture()
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
		_task_destination = target
		_travel_stage = "delivery"
		_pickup_sources.clear()
		var first_target := target
		if _active_task_kind() == "kitchen":
			var pickup := _kitchen_pickup_descriptor()
			if not pickup.is_empty():
				first_target = Vector3(pickup.position)
				_travel_stage = "kitchen_pickup"
			else:
				_consume_pickup_sources()
				_show_kitchen_carry_prop()
		elif String(active_task.get("action", "")) == "serve":
			var pickup_node := active_task.get("payload", {}).get("pickup_node") as Node
			var pickup_position: Variant = active_task.get("payload", {}).get("pickup_position")
			if pickup_node != null and is_instance_valid(pickup_node) and pickup_position is Vector3:
				first_target = Vector3(pickup_position)
				_pickup_sources.append(pickup_node)
				_travel_stage = "service_pickup"
			else:
				_show_task_prop(false)
		elif String(active_task.get("action", "")) != "collect_dishes":
			_show_task_prop(false)
		if not move_to(first_target):
			SimulationManager.cancel_employee_task(String(employee.get("id", "")))
			active_task = {}
			poll_time = 0.45
			return
		_thought.visible = true
		state = "moving"
		navigation_priority = _role_priority(true)
		idle_time = 0.0
		employee.current_task = String(active_task.get("recipe_step_id", active_task.get("action", "")))


func _kitchen_pickup_descriptor() -> Dictionary:
	# Semilavorati remain visible where they were produced. The next cook walks
	# there first; raw stock is collected from the closest fridge/storage unit.
	# Plating is the deliberately short hand-off to the pass: the nearest cook
	# claims the ready preparation and carries it straight there, without first
	# scheduling a second navigation leg that can stall the whole service line.
	if FoodVisualFactory.task_style(active_task) == "plate":
		return {}
	var first_node: Node3D
	for dependency_id: String in active_task.get("dependencies", []):
		var dependency: Dictionary = SimulationManager.tasks.get(dependency_id, {})
		var source := dependency.get("output_station_node") as Node3D
		if source == null or not is_instance_valid(source):
			continue
		if not _pickup_sources.has(source):
			_pickup_sources.append(source)
		if first_node == null:
			first_node = source
	if first_node != null:
		var pickup_position: Vector3 = Vector3(first_node.call("get_interaction_position")) if first_node.has_method("get_interaction_position") else first_node.global_position
		# Nearby hand-offs are walked explicitly; for a distant source the output
		# transfers to the cook's tray immediately so realism cannot collapse the
		# kitchen throughput on a large layout.
		if global_position.distance_to(pickup_position) <= 4.5:
			return {"position": pickup_position, "node": first_node}
		return {}
	if active_task.get("inputs", {}).is_empty():
		return {}
	var best_node: Node3D
	var best_position := Vector3.ZERO
	var best_distance := INF
	for storage_id: String in ["fridge", "storage"]:
		for runtime: Dictionary in SimulationManager.stations.get(storage_id, []):
			var node := runtime.get("node") as Node3D
			if node == null or not is_instance_valid(node):
				continue
			var position: Vector3 = Vector3(node.call("get_interaction_position")) if node.has_method("get_interaction_position") else node.global_position
			var distance := global_position.distance_to(position)
			if distance < best_distance:
				best_distance = distance
				best_node = node
				best_position = position
	if best_node != null:
		if best_distance <= 4.0:
			_pickup_sources.append(best_node)
			return {"position": best_position, "node": best_node}
	return {}


func _arrived() -> void:
	work_time = 0.0
	if _active_task_kind() == "kitchen" and _travel_stage == "kitchen_pickup":
		_consume_pickup_sources()
		_show_kitchen_carry_prop()
		_travel_stage = "kitchen_delivery"
		if move_to(_task_destination):
			state = "moving"
			return
		cancel_active_task()
		return
	if _active_task_kind() == "service" and _travel_stage == "service_pickup":
		_consume_pickup_sources()
		_show_task_prop(false)
		_travel_stage = "service_delivery"
		if move_to(_task_destination):
			state = "moving"
			return
		cancel_active_task()
		return
	match _active_task_kind():
		"kitchen":
			if not SimulationManager.begin_kitchen_task(active_task.id):
				_finish_task()
				return
			var runtime := _active_station_runtime()
			if runtime and is_instance_valid(runtime.node):
				face_position(runtime.node.global_position)
				runtime.node.show_task(active_task)
			_show_task_prop(true)
			_gesture_cycle_index = -1
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
				_show_task_prop(false)
				var secondary := Vector3(active_task.get("payload", {}).get("secondary_target", global_position))
				if move_to(secondary):
					state = "moving"
					return
	state = "working"


func _consume_pickup_sources() -> void:
	for dependency_id: String in active_task.get("dependencies", []):
		var dependency: Dictionary = SimulationManager.tasks.get(dependency_id, {})
		var source := dependency.get("output_station_node") as Node
		if source != null and is_instance_valid(source) and source.has_method("take_completed_output"):
			source.call("take_completed_output", dependency_id)
	var source_task_id := String(active_task.get("payload", {}).get("source_task_id", ""))
	for source: Node in _pickup_sources:
		if source != null and is_instance_valid(source) and source.has_method("play_access_animation"):
			source.call("play_access_animation")
		if source != null and is_instance_valid(source) and source.has_method("take_completed_output") and not source_task_id.is_empty():
			source.call("take_completed_output", source_task_id)
	_pickup_sources.clear()


func _finish_task() -> void:
	if _active_task_kind() == "kitchen" and active_task.has("station_runtime"):
		var runtime := _active_station_runtime()
		if runtime and is_instance_valid(runtime.node):
			if String(active_task.get("state", "")) == "completed" and runtime.node.has_method("complete_task_visual"):
				runtime.node.complete_task_visual(active_task)
			else:
				runtime.node.clear_task()
	_clear_task_prop()
	# Dictionaries are reference types. Replacing the local handle preserves the
	# authoritative task record owned by SimulationManager.
	active_task = {}
	_travel_stage = ""
	_pickup_sources.clear()
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
	_travel_stage = ""
	_pickup_sources.clear()
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
	return _task_prop != null and not _task_prop_is_tool


func _active_station_runtime() -> Dictionary:
	var value: Variant = active_task.get("station_runtime", {})
	return value if value is Dictionary else {}


func _create_task_prop_anchor() -> void:
	_task_prop_anchor = Node3D.new()
	_task_prop_anchor.name = "TaskPropAnchor"
	add_child(_task_prop_anchor)
	var skeleton := find_child("*", true, false) as Skeleton3D
	for candidate: Node in find_children("*", "Skeleton3D", true, false):
		skeleton = candidate as Skeleton3D
		if skeleton.find_bone("Fist.R") >= 0 and skeleton.find_bone("Fist.L") >= 0:
			break
	if skeleton != null and skeleton.find_bone("Fist.R") >= 0:
		var attachment := BoneAttachment3D.new()
		attachment.name = "RightHandTaskAnchor"
		attachment.bone_name = "Fist.R"
		skeleton.add_child(attachment)
		_hand_prop_anchor = attachment
		if skeleton.find_bone("Fist.L") >= 0:
			var left_attachment := BoneAttachment3D.new()
			left_attachment.name = "LeftHandCarryAnchor"
			left_attachment.bone_name = "Fist.L"
			skeleton.add_child(left_attachment)
			_left_hand_prop_anchor = left_attachment
	else:
		_hand_prop_anchor = _task_prop_anchor


func _show_task_prop(working_tool: bool = false) -> void:
	_clear_task_prop()
	if _task_prop_anchor == null:
		return
	var action := String(active_task.get("action", ""))
	var model_path := FoodVisualFactory.task_tool_model(active_task) if working_tool else String(active_task.get("tool_model", ""))
	if model_path.is_empty():
		model_path = String(active_task.get("carry_model", ""))
	if model_path.is_empty():
		model_path = String(active_task.get("payload", {}).get("carry_model", ""))
	if action == "serve" and not working_tool:
		var recipe_id := _serve_recipe_id()
		_task_prop = FoodVisualFactory.instantiate_recipe_dish(recipe_id, 0.72)
		_task_prop.name = "CarriedDish"
		_task_prop_anchor.add_child(_task_prop)
		_task_prop.position = Vector3(0.0, 0.045, 0.0)
		_task_prop_is_tool = false
		_update_carried_prop_anchor()
		return
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
	var scale_factor := 0.30 if working_tool else 1.0
	if action == "wash_dishes":
		scale_factor = 0.42
	elif action == "collect_dishes":
		scale_factor = 0.5
	_task_prop = ModelFactory.instantiate_model(model_path, scale_factor)
	_task_prop.name = "ActiveTaskProp"
	ModelFactory.align_visual_to_grid_origin(_task_prop)
	_task_prop_is_tool = working_tool or action in ["clean_spill", "clean_floor", "wash_dishes"]
	var anchor := _hand_prop_anchor if _task_prop_is_tool else _task_prop_anchor
	anchor.add_child(_task_prop)
	if _task_prop_is_tool:
		_task_prop.position = Vector3(-0.05, -0.03, -0.10)
		_task_prop.rotation = Vector3(-PI * 0.42, 0.0, PI * 0.08)
	elif action == "collect_dishes":
		_task_prop.position = Vector3(0.0, 0.045, 0.0)
	else:
		_task_prop.position = Vector3(0.0, 0.045, 0.0)
	if not _task_prop_is_tool:
		_update_carried_prop_anchor()
	ModelFactory.set_shadow_casting(_task_prop, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)


func _show_kitchen_carry_prop() -> void:
	_clear_task_prop()
	var parts := FoodVisualFactory.parts_for_task(active_task, "input")
	if parts.is_empty():
		return
	var carried: Array[Dictionary] = [{"model":"res://assets/equipment/plate.gltf", "scale":0.46, "role":"container", "offset":[0.0,0.0,0.0]}]
	for part: Dictionary in parts:
		var copy := part.duplicate(true)
		copy.scale = float(copy.get("scale", 0.4)) * 0.68
		var raw_offset: Variant = copy.get("offset", [0.0, 0.0, 0.0])
		var offset := Vector3.ZERO
		if raw_offset is Array and raw_offset.size() >= 3:
			offset = Vector3(float(raw_offset[0]), float(raw_offset[1]), float(raw_offset[2]))
		offset.y += 0.10
		copy.offset = [offset.x, offset.y, offset.z]
		carried.append(copy)
	_task_prop = FoodVisualFactory.instantiate_parts(carried, 1.0, 7)
	_task_prop.name = "CarriedPreparation"
	_task_prop_anchor.add_child(_task_prop)
	_task_prop.position = Vector3(0.0, 0.045, 0.0)
	_task_prop_is_tool = false
	_update_carried_prop_anchor()


func _serve_recipe_id() -> String:
	var order_id := String(active_task.get("payload", {}).get("order_id", ""))
	var order: Dictionary = SimulationManager.orders.get(order_id, {})
	return String(active_task.get("payload", {}).get("recipe_id", order.get("recipe_id", "")))


func _update_work_gesture() -> void:
	var style := FoodVisualFactory.task_style(active_task)
	var period := 1.25
	var active_window := 0.70
	match style:
		"chop", "slice", "grate":
			period = 0.82
			active_window = 0.62
		"knead", "mix", "sauce", "toss", "assemble", "plate":
			period = 1.35
			active_window = 0.82
		"cook", "fry", "sear", "simmer":
			period = 1.65
			active_window = 0.78
		"bake", "roast":
			period = 2.15
			active_window = 0.72
		"scoop":
			period = 1.20
			active_window = 0.76
	period *= lerpf(0.92, 1.10, _gesture_seed)
	var cycle_index := int(floor(work_time / maxf(period, 0.1)))
	var local_time := fmod(work_time, period)
	if cycle_index != _gesture_cycle_index:
		_gesture_cycle_index = cycle_index
		play_animation(String(active_task.get("animation", "PickUp")))
	elif local_time >= active_window and current_animation != "Idle":
		play_animation("Idle")


func _update_task_prop_motion() -> void:
	if _task_prop == null or not is_instance_valid(_task_prop):
		return
	if _task_prop_is_tool and _hand_prop_anchor != null:
		var style := FoodVisualFactory.task_style(active_task)
		var frequency := 8.0 if style in ["chop", "slice", "grate"] else 4.2
		_hand_prop_anchor.rotation.z = sin(work_time * frequency) * (0.10 if style in ["chop", "slice", "grate"] else 0.045)
	elif _task_prop.get_parent() == _task_prop_anchor:
		_update_carried_prop_anchor()


func _update_carried_prop_anchor() -> void:
	if _task_prop == null or not is_instance_valid(_task_prop) or _task_prop_is_tool:
		return
	if _task_prop_anchor == null or _hand_prop_anchor == null or _left_hand_prop_anchor == null:
		return
	# The tray is driven by the animated fists themselves, not a torso offset.
	# This keeps it inside both hands throughout Walk_Carry and turn blending.
	var hand_midpoint := (_hand_prop_anchor.global_position + _left_hand_prop_anchor.global_position) * 0.5
	_task_prop_anchor.position = to_local(hand_midpoint) + Vector3(0.0, 0.105, 0.04)
	_task_prop_anchor.rotation = Vector3.ZERO


func _clear_task_prop() -> void:
	if _task_prop != null and is_instance_valid(_task_prop):
		_task_prop.queue_free()
	_task_prop = null
	_task_prop_is_tool = false
	if _task_prop_anchor != null:
		_task_prop_anchor.position = Vector3.ZERO
		_task_prop_anchor.rotation = Vector3.ZERO
	if _hand_prop_anchor != null:
		_hand_prop_anchor.rotation = Vector3.ZERO


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
