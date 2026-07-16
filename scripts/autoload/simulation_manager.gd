extends Node

signal task_board_changed
signal order_created(order: Dictionary)
signal order_updated(order: Dictionary)
signal dish_ready(order: Dictionary)
signal service_task_created(task: Dictionary)
signal maintenance_task_created(task: Dictionary)
signal customer_count_changed(count: int)
signal statistics_changed

var simulation_speed: float = 1.0
var world: Node = null
var tasks: Dictionary = {}
var orders: Dictionary = {}
var service_tasks: Dictionary = {}
var maintenance_tasks: Dictionary = {}
var stations: Dictionary = {}
var customers: Array[Node] = []
var stats: Dictionary = {}
var _task_serial := 0
var _order_serial := 0
var _service_serial := 0
var _maintenance_serial := 0
var _simulation_tick_accumulator := 0.0
var _maintenance_clock := 0.0

const SIMULATION_TICK := 0.1
const COMPLETED_WORK_RETENTION := 6.0


func _ready() -> void:
	reset_service_stats()


func _process(delta: float) -> void:
	var scaled := delta * simulation_speed
	if GameState.restaurant_state == "open" or GameState.restaurant_state == "closing":
		GameState.service_seconds += scaled
		_simulation_tick_accumulator += scaled
		# Task dependency scans and station metrics do not need renderer frequency.
		# A fixed tick removes frame-rate-dependent work and prevents large catch-up
		# spikes after a browser tab resumes from the background.
		var processed := 0
		while _simulation_tick_accumulator >= SIMULATION_TICK and processed < 5:
			_update_waiting_tasks(SIMULATION_TICK)
			_update_metrics(SIMULATION_TICK)
			_simulation_tick_accumulator -= SIMULATION_TICK
			_maintenance_clock += SIMULATION_TICK
			processed += 1
		if processed == 5:
			_simulation_tick_accumulator = minf(_simulation_tick_accumulator, SIMULATION_TICK)
		if _maintenance_clock >= 2.0:
			_maintenance_clock = 0.0
			_prune_completed_work()
	if GameState.restaurant_state == "closing" and customers.is_empty():
		stats.labor_cost += EconomyManager.pay_shift_wages()
		GameState.set_restaurant_state("closed")
		SaveManager.save_game()


func bind_world(value: Node) -> void:
	world = value


func set_speed(value: float) -> void:
	simulation_speed = clampf(value, 1.0, 4.0)


func open_restaurant() -> void:
	if GameState.restaurant_state != "closed":
		return
	reset_service_stats()
	GameState.service_seconds = 0.0
	GameState.progress.services_started = int(GameState.progress.get("services_started", 0)) + 1
	GameState.check_progression()
	GameState.set_restaurant_state("open")


func request_close() -> void:
	if GameState.restaurant_state == "open":
		GameState.set_restaurant_state("closing")


func close_immediately() -> void:
	for customer: Node in customers.duplicate():
		if is_instance_valid(customer):
			customer.queue_free()
	customers.clear()
	for task_id: String in service_tasks:
		service_tasks[task_id].state = "cancelled"
	for task_id: String in maintenance_tasks:
		_cancel_maintenance_record(maintenance_tasks[task_id], false)
	GameState.set_restaurant_state("closed")
	customer_count_changed.emit(0)
	_prune_completed_work(true)


func register_station(station_id: String, node: Node, capacity: int) -> void:
	if not stations.has(station_id):
		stations[station_id] = []
	var interaction_positions: Array[Vector3] = []
	if node.has_method("get_interaction_positions"):
		interaction_positions = node.get_interaction_positions()
	elif node.has_method("get_interaction_position"):
		interaction_positions.append(node.get_interaction_position())
	else:
		interaction_positions.append(node.global_position)
	# `capacity` is batch/storage throughput, not a number of cooks that may
	# overlap on the same physical appliance. Every placed workstation has one
	# exclusive operator; buying a second instance creates another work place.
	var worker_capacity := 1
	interaction_positions = _expanded_interaction_positions(interaction_positions, worker_capacity, node)
	var physical_capacity := maxi(capacity, 1)
	stations[station_id].append({
		"node": node,
		"capacity": physical_capacity,
		"configured_capacity": capacity,
		"worker_capacity": worker_capacity,
		"interaction_positions": interaction_positions,
		"reservations": {},
		"busy": 0,
		"busy_time": 0.0,
		"total_time": 0.0,
		"completed": 0,
		"blocked": 0,
		"wait_total": 0.0
	})


func _expanded_interaction_positions(base_positions: Array[Vector3], capacity: int, node: Node) -> Array[Vector3]:
	if base_positions.is_empty():
		base_positions.append(node.global_position)
	var result: Array[Vector3] = []
	var lateral := Vector3.RIGHT
	if node is Node3D:
		lateral = (node as Node3D).global_transform.basis.x.normalized()
	for slot: int in maxi(capacity, 1):
		var base_index := slot % base_positions.size()
		var base := base_positions[base_index]
		var occurrences := ceili(float(capacity - base_index) / float(base_positions.size()))
		var occurrence := slot / base_positions.size()
		var offset := 0.0
		if occurrences > 1:
			offset = -0.46 if occurrence == 0 else 0.46
		result.append(base + lateral * offset)
	return result


func unregister_world_stations() -> void:
	stations.clear()


func register_customer(customer: Node) -> void:
	if not customers.has(customer):
		customers.append(customer)
		customer_count_changed.emit(customers.size())


func unregister_customer(customer: Node, lost: bool = false) -> void:
	customers.erase(customer)
	if lost:
		stats.customers_lost += 1
	customer_count_changed.emit(customers.size())


func create_order(recipe_id: String, table_id: String, customer: Node) -> Dictionary:
	var recipe: Dictionary = DataRegistry.recipes_by_id.get(recipe_id, {})
	if recipe.is_empty():
		return {}
	_order_serial += 1
	var order_id := "O%03d" % _order_serial
	var order := {
		"id": order_id,
		"table_id": table_id,
		"recipe_id": recipe_id,
		"recipe_name": recipe.name,
		"customer": customer,
		"created_at": GameState.service_seconds,
		"priority": 1,
		"suspended": false,
		"state": "cooking",
		"ready": false,
		"task_ids": [],
		"missing": []
	}
	orders[order_id] = order
	var step_task_ids: Dictionary = {}
	for step: Dictionary in recipe.steps:
		_task_serial += 1
		var task_id := "%s_%s_%03d" % [order_id, step.id, _task_serial]
		step_task_ids[String(step.id)] = task_id
		var task := {
			"id": task_id,
			"order_id": order_id,
			"recipe_step_id": String(step.id),
			"priority": 1,
			"dependencies": [],
			"inputs": step.get("inputs", {}).duplicate(true),
			"output": String(step.get("output", "")),
			"station": String(step.station),
			"state": "waiting_dependencies",
			"employee_id": "",
			"remaining": float(step.get("time", 1.0)),
			"duration": float(step.get("time", 1.0)),
			"animation": String(step.get("animation", "PickUp")),
			"model": String(step.get("model", "")),
			"visual": step.get("visual", {}).duplicate(true),
			"quantity": int(step.get("quantity", 1)),
			"created_at": GameState.service_seconds,
			"station_runtime": null,
			"stock_consumed": false,
			"prebuilt": false
		}
		for dependency: String in step.get("dependencies", []):
			task.dependencies.append(step_task_ids.get(dependency, "%s_%s" % [order_id, dependency]))
		var output_id := String(step.get("output", ""))
		if bool(step.get("preppable", false)) and int(GameState.purchased_preparations.get(output_id, 0)) > 0:
			GameState.purchased_preparations[output_id] = int(GameState.purchased_preparations[output_id]) - 1
			task.state = "completed"
			task.prebuilt = true
			task.remaining = 0.0
		tasks[task_id] = task
		order.task_ids.append(task_id)
	_update_waiting_tasks(0.0)
	order_created.emit(order)
	task_board_changed.emit()
	return order


func _update_waiting_tasks(delta: float) -> void:
	var changed := false
	for task_id: String in tasks:
		var task: Dictionary = tasks.get(task_id, {})
		if float(task.get("handoff_grace", 0.0)) > 0.0:
			task.handoff_grace = maxf(float(task.handoff_grace) - delta, 0.0)
		if task.is_empty() or not task.has("state"):
			continue
		if bool(orders.get(String(task.get("order_id", "")), {}).get("suspended", false)):
			continue
		if String(task.get("state", "cancelled")) in ["completed", "cancelled", "failed", "reserved", "in_progress"]:
			continue
		if String(task.get("state", "")) == "queued":
			continue
		var dependencies_ready := true
		for dependency_id: String in task.get("dependencies", []):
			if not tasks.has(dependency_id) or String(tasks.get(dependency_id, {}).get("state", "missing")) != "completed":
				dependencies_ready = false
				break
		if not dependencies_ready:
			task.state = "waiting_dependencies"
			continue
		if not _stock_available(task.get("inputs", {})):
			task.state = "waiting_stock"
			for ingredient_id: String in task.get("inputs", {}):
				if not stats.ingredients_out.has(ingredient_id):
					stats.ingredients_out.append(ingredient_id)
		else:
			task.state = "queued"
			changed = true
		if task.state in ["waiting_dependencies", "waiting_stock", "queued"]:
			task["wait_age"] = float(task.get("wait_age", 0.0)) + delta
	if changed:
		task_board_changed.emit()
	_refresh_order_missing_components()


func claim_kitchen_task(employee: Dictionary, from_position: Variant = null) -> Dictionary:
	# Kitchen work is exclusive to cooks. Handymen have their own maintenance
	# board, so a quiet dining room can never make them steal a recipe step.
	if String(employee.get("role", "")) != "cook":
		return {}
	var best: Dictionary = {}
	var best_score := -INF
	var best_runtime: Dictionary = {}
	var best_slot := -1
	var best_position := Vector3.ZERO
	var preferred_station := _effective_preferred_station(employee)
	for task_id: String in tasks:
		var task: Dictionary = tasks.get(task_id, {})
		if task.is_empty() or String(task.get("state", "")) != "queued":
			continue
		var handoff_employee := String(task.get("handoff_employee_id", ""))
		if not handoff_employee.is_empty() and handoff_employee != String(employee.get("id", "")) and float(task.get("handoff_grace", 0.0)) > 0.0:
			continue
		if bool(orders.get(String(task.get("order_id", "")), {}).get("suspended", false)):
			continue
		for runtime: Dictionary in stations.get(String(task.station), []):
			var slot := _free_station_slot(runtime)
			if slot < 0:
				continue
			var positions: Array = runtime.get("interaction_positions", [])
			var interaction_position := Vector3(positions[slot])
			if world != null and world.has_method("is_work_position_available") and not world.is_work_position_available(interaction_position, String(employee.get("id", ""))):
				continue
			if from_position is Vector3 and world != null and world.has_method("find_path") and world.find_path(Vector3(from_position), interaction_position).is_empty():
				continue
			var skill := float(employee.get("skills", {}).get(task.station, 0.55))
			var worker_capacity := maxf(float(runtime.get("worker_capacity", runtime.get("capacity", 1))), 1.0)
			var occupancy := float(runtime.get("busy", 0)) / worker_capacity
			var score := float(task.priority) * 100.0 + float(task.get("wait_age", 0.0)) * 2.2 + skill * 28.0
			# Prefer a physically empty instance over crowding the first compatible
			# workstation. Skills guide the brigade but never forbid useful fallback work.
			score += 24.0 if int(runtime.get("busy", 0)) == 0 else -occupancy * 72.0
			if preferred_station == String(task.station):
				score += 30.0
			if from_position is Vector3:
				score -= Vector3(from_position).distance_to(interaction_position) * 1.5
			if score > best_score:
				best_score = score
				best = task
				best_runtime = runtime
				best_slot = slot
				best_position = interaction_position
	if best.is_empty():
		return {}
	best.state = "reserved"
	best.employee_id = String(employee.id)
	best.station_runtime = best_runtime
	best.interaction_slot = best_slot
	best.interaction_position = best_position
	best.station_runtime.reservations[best_slot] = String(employee.id)
	best.station_runtime.busy = best.station_runtime.reservations.size()
	task_board_changed.emit()
	return best


func _effective_preferred_station(employee: Dictionary) -> String:
	var explicit := String(employee.get("preferred_station", ""))
	if not explicit.is_empty():
		return explicit
	var best_station := ""
	var best_skill := -INF
	for station_id: String in employee.get("skills", {}):
		var skill := float(employee.skills[station_id])
		if skill > best_skill:
			best_skill = skill
			best_station = station_id
	return best_station


func begin_kitchen_task(task_id: String) -> bool:
	if not tasks.has(task_id):
		return false
	var task: Dictionary = tasks[task_id]
	if task.state != "reserved":
		return false
	if not _station_reservation_is_owned(task):
		task.state = "queued"
		task.employee_id = ""
		_release_station(task)
		task.station_runtime = null
		task_board_changed.emit()
		return false
	if not bool(task.get("stock_consumed", false)) and not GameState.consume_stock(task.inputs):
		task.state = "waiting_stock"
		_release_station(task)
		task.employee_id = ""
		task.station_runtime.blocked += 1 if task.station_runtime else 0
		task.station_runtime = null
		task_board_changed.emit()
		return false
	task.stock_consumed = true
	task.state = "in_progress"
	return true


func advance_kitchen_task(task_id: String, delta: float, employee: Dictionary) -> bool:
	if not tasks.has(task_id):
		return true
	var task: Dictionary = tasks[task_id]
	if task.state != "in_progress":
		return true
	var skill := float(employee.get("skills", {}).get(task.station, 0.65))
	var speed := float(employee.get("speed", 1.0)) * lerpf(0.8, 1.2, skill)
	task.remaining -= delta * speed
	if task.remaining > 0.0:
		return false
	_complete_kitchen_task(task)
	return true


func _complete_kitchen_task(task: Dictionary) -> void:
	task.state = "completed"
	var employee_id := String(task.get("employee_id", ""))
	if not employee_id.is_empty():
		stats.employee_tasks[employee_id] = int(stats.employee_tasks.get(employee_id, 0)) + 1
	if task.station_runtime:
		var output_node := task.station_runtime.get("node") as Node3D
		if output_node != null and is_instance_valid(output_node):
			task.output_station_node = output_node
			task.output_position = output_node.global_position
		task.station_runtime.completed += 1
		task.station_runtime.wait_total += float(task.get("wait_age", 0.0))
	_release_station(task)
	# Give the cook who just produced the last missing component a brief first
	# refusal on its successor. This keeps the object in the same hands for the
	# assembly/pass hand-off instead of letting a distant cook materialise it.
	if not employee_id.is_empty():
		for successor_id: String in tasks:
			var successor: Dictionary = tasks.get(successor_id, {})
			if successor.is_empty() or not successor.get("dependencies", []).has(String(task.get("id", ""))):
				continue
			var dependencies_ready := true
			for dependency_id: String in successor.get("dependencies", []):
				if String(tasks.get(dependency_id, {}).get("state", "")) != "completed":
					dependencies_ready = false
					break
			if dependencies_ready:
				successor.handoff_employee_id = employee_id
				successor.handoff_grace = 0.75
	var order: Dictionary = orders.get(task.order_id, {})
	var all_done := not order.is_empty()
	for task_id: String in order.get("task_ids", []):
		if not tasks.has(task_id) or String(tasks.get(task_id, {}).get("state", "missing")) != "completed":
			all_done = false
			break
	if all_done:
		order.ready = true
		order.state = "at_pass"
		dish_ready.emit(order)
		if is_instance_valid(order.customer):
			var recipe: Dictionary = DataRegistry.recipes_by_id.get(String(order.get("recipe_id", "")), {})
			request_service(order.customer, "serve", order.customer.get_service_position(), {
				"order_id": order.id,
				"recipe_id": String(order.get("recipe_id", "")),
				"carry_model": String(recipe.get("dish_model", "")),
				"pickup_node": task.get("output_station_node"),
				"pickup_position": task.get("output_position", Vector3.ZERO),
				"source_task_id": String(task.get("id", ""))
			})
	order_updated.emit(order)
	_update_waiting_tasks(0.0)
	task_board_changed.emit()


func cancel_employee_task(employee_id: String) -> void:
	for task_id: String in tasks:
		var task: Dictionary = tasks.get(task_id, {})
		if task.is_empty():
			continue
		if String(task.get("employee_id", "")) == employee_id and String(task.get("state", "")) in ["reserved", "in_progress"]:
			var order: Dictionary = orders.get(String(task.get("order_id", "")), {})
			task.state = "queued" if not order.is_empty() and String(order.get("state", "")) not in ["cancelled", "paid"] else "cancelled"
			_release_station(task)
			task.employee_id = ""
			task.station_runtime = null
	for task_id: String in service_tasks:
		var service_task: Dictionary = service_tasks.get(task_id, {})
		if String(service_task.get("employee_id", "")) == employee_id and String(service_task.get("state", "")) in ["reserved", "in_progress"]:
			service_task.state = "queued" if service_task_is_actionable(service_task) else "cancelled"
			service_task.employee_id = ""
			if service_task.state == "cancelled":
				service_task.finished_at = GameState.service_seconds
	for task_id: String in maintenance_tasks:
		var maintenance_task: Dictionary = maintenance_tasks.get(task_id, {})
		if String(maintenance_task.get("employee_id", "")) != employee_id or String(maintenance_task.get("state", "")) not in ["reserved", "in_progress"]:
			continue
		_release_station(maintenance_task)
		maintenance_task.station_runtime = null
		maintenance_task.employee_id = ""
		if maintenance_task_is_actionable(maintenance_task):
			maintenance_task.state = "queued"
			var owner := maintenance_task.get("owner") as Node
			if owner != null and is_instance_valid(owner) and owner.has_method("maintenance_interrupted"):
				owner.call("maintenance_interrupted", String(maintenance_task.get("action", "")), maintenance_task.get("payload", {}))
		else:
			maintenance_task.state = "cancelled"
			maintenance_task.finished_at = GameState.service_seconds
	task_board_changed.emit()


func request_service(customer: Node, action: String, target: Vector3, payload: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(customer):
		return {}
	if customer.has_method("accepts_service_action") and not customer.accepts_service_action(action, payload):
		return {}
	for existing: Dictionary in service_tasks.values():
		if existing.get("customer") == customer and String(existing.get("action", "")) == action and existing.get("payload", {}) == payload and String(existing.get("state", "")) not in ["completed", "cancelled"]:
			return existing
	_service_serial += 1
	var task := {
		"id": "S%04d" % _service_serial,
		"customer": customer,
		"action": action,
		"target": target,
		"payload": payload,
		# Exposed at task level so an EmployeeAgent can instantiate the carried
		# dish without coupling its visuals to a particular customer class.
		"carry_model": String(payload.get("carry_model", "")),
		"state": "queued",
		"employee_id": "",
		# World-owned service jobs (for example one dirty-table batch) may expose
		# their own key while customer jobs retain the historical per-party lock.
		"reservation_key": String(payload.get("reservation_key", str(customer.get_instance_id()))),
		"created_at": GameState.service_seconds,
		"priority": 2 if action == "serve" else 1
	}
	service_tasks[task.id] = task
	service_task_created.emit(task)
	return task


func claim_service_task(employee: Dictionary, from_position: Variant = null) -> Dictionary:
	if String(employee.get("role", "")) != "waiter":
		return {}
	var best: Dictionary = {}
	var score := -INF
	for task_id: String in service_tasks:
		var task: Dictionary = service_tasks.get(task_id, {})
		if task.is_empty() or String(task.get("state", "")) != "queued":
			continue
		if not service_task_is_actionable(task):
			task.state = "cancelled"
			task.finished_at = GameState.service_seconds
			continue
		if _service_key_is_reserved(String(task.get("reservation_key", ""))):
			continue
		if from_position is Vector3 and world != null and world.has_method("find_path") and world.find_path(Vector3(from_position), Vector3(task.target)).is_empty():
			continue
		var candidate := float(task.priority) * 100.0 + GameState.service_seconds - float(task.created_at)
		if from_position is Vector3:
			candidate -= Vector3(from_position).distance_to(Vector3(task.target))
		if candidate > score:
			score = candidate
			best = task
	if best.is_empty():
		return {}
	best.state = "reserved"
	best.employee_id = String(employee.id)
	return best


func begin_service_task(task_id: String) -> bool:
	if not service_tasks.has(task_id):
		return false
	var task: Dictionary = service_tasks[task_id]
	if String(task.get("state", "")) != "reserved" or not service_task_is_actionable(task):
		if String(task.get("state", "")) == "reserved":
			task.state = "cancelled"
			task.employee_id = ""
			task.finished_at = GameState.service_seconds
		return false
	task.state = "in_progress"
	return true


func complete_service_task(task_id: String) -> void:
	if not service_tasks.has(task_id):
		return
	var task: Dictionary = service_tasks[task_id]
	if String(task.get("state", "")) not in ["reserved", "in_progress"]:
		return
	if not service_task_is_actionable(task):
		task.state = "cancelled"
		task.employee_id = ""
		task.finished_at = GameState.service_seconds
		task_board_changed.emit()
		return
	task.state = "completed"
	task.finished_at = GameState.service_seconds
	var employee_id := String(task.get("employee_id", ""))
	if not employee_id.is_empty():
		stats.employee_tasks[employee_id] = int(stats.employee_tasks.get(employee_id, 0)) + 1
	if is_instance_valid(task.customer) and task.customer.has_method("service_completed"):
		task.customer.service_completed(task.action, task.payload)
	task_board_changed.emit()


func service_task_is_actionable(task: Dictionary) -> bool:
	if task.is_empty() or String(task.get("state", "")) in ["completed", "cancelled"]:
		return false
	var customer := task.get("customer") as Node
	if customer == null or not is_instance_valid(customer) or customer.is_queued_for_deletion():
		return false
	if customer.has_method("accepts_service_action"):
		return customer.accepts_service_action(String(task.get("action", "")), task.get("payload", {}))
	return true


func request_maintenance_task(owner: Node, action: String, target: Vector3, payload: Dictionary = {}, priority: int = 1, duration: float = 1.5, tool_model: String = "") -> Dictionary:
	if owner == null or not is_instance_valid(owner) or owner.is_queued_for_deletion():
		return {}
	if owner.has_method("accepts_maintenance_action") and not bool(owner.call("accepts_maintenance_action", action, payload)):
		return {}
	var reservation_key := String(payload.get("reservation_key", ""))
	if reservation_key.is_empty():
		reservation_key = "maintenance:%d:%s" % [owner.get_instance_id(), action]
	for existing: Dictionary in maintenance_tasks.values():
		if String(existing.get("reservation_key", "")) == reservation_key and String(existing.get("state", "")) not in ["completed", "cancelled"]:
			return existing
	_maintenance_serial += 1
	var task_payload := payload.duplicate(true)
	var station_id := String(task_payload.get("station_id", task_payload.get("station", "")))
	var task := {
		"id": "M%04d" % _maintenance_serial,
		"task_kind": "maintenance",
		"owner": owner,
		"action": action,
		"target": Vector3(target.x, 0.0, target.z),
		"payload": task_payload,
		"station": station_id,
		"station_runtime": null,
		"state": "queued",
		"employee_id": "",
		"reservation_key": reservation_key,
		"created_at": GameState.service_seconds,
		"priority": priority,
		"duration": maxf(duration, 0.05),
		"animation": String(task_payload.get("animation", "PickUp")),
		"tool_model": tool_model if not tool_model.is_empty() else String(task_payload.get("tool_model", "")),
		"carry_model": String(task_payload.get("carry_model", ""))
	}
	maintenance_tasks[task.id] = task
	maintenance_task_created.emit(task)
	task_board_changed.emit()
	return task


func request_maintenance(owner: Node, action: String, target: Vector3, payload: Dictionary = {}, priority: int = 1, duration: float = 1.5, tool_model: String = "") -> Dictionary:
	return request_maintenance_task(owner, action, target, payload, priority, duration, tool_model)


func claim_maintenance_task(employee: Dictionary, from_position: Variant = null) -> Dictionary:
	if String(employee.get("role", "")) != "handyman":
		return {}
	var best: Dictionary = {}
	var best_score := -INF
	var best_runtime: Dictionary = {}
	var best_slot := -1
	var best_position := Vector3.ZERO
	for task_id: String in maintenance_tasks:
		var task: Dictionary = maintenance_tasks.get(task_id, {})
		if task.is_empty() or String(task.get("state", "")) != "queued":
			continue
		if not maintenance_task_is_actionable(task):
			_cancel_maintenance_record(task, false)
			continue
		if _maintenance_key_is_reserved(String(task.get("reservation_key", ""))):
			continue
		var station_id := String(task.get("station", ""))
		if station_id.is_empty():
			var target := Vector3(task.get("target", Vector3.ZERO))
			if from_position is Vector3 and world != null and world.has_method("find_path") and world.find_path(Vector3(from_position), target).is_empty():
				continue
			var candidate := float(task.get("priority", 1)) * 100.0 + GameState.service_seconds - float(task.get("created_at", 0.0))
			if from_position is Vector3:
				candidate -= Vector3(from_position).distance_to(target)
			if candidate > best_score:
				best_score = candidate
				best = task
				best_runtime = {}
				best_slot = -1
				best_position = target
			continue
		for runtime: Dictionary in stations.get(station_id, []):
			var slot := _free_station_slot(runtime)
			if slot < 0:
				continue
			var positions: Array = runtime.get("interaction_positions", [])
			if slot >= positions.size():
				continue
			var interaction_position := Vector3(positions[slot])
			if world != null and world.has_method("is_work_position_available") and not world.is_work_position_available(interaction_position, String(employee.get("id", ""))):
				continue
			if from_position is Vector3 and world != null and world.has_method("find_path") and world.find_path(Vector3(from_position), interaction_position).is_empty():
				continue
			var candidate := float(task.get("priority", 1)) * 100.0 + GameState.service_seconds - float(task.get("created_at", 0.0))
			if from_position is Vector3:
				candidate -= Vector3(from_position).distance_to(interaction_position)
			if candidate > best_score:
				best_score = candidate
				best = task
				best_runtime = runtime
				best_slot = slot
				best_position = interaction_position
	if best.is_empty():
		return {}
	best.state = "reserved"
	best.employee_id = String(employee.get("id", ""))
	best.target = best_position
	if not best_runtime.is_empty():
		best.station_runtime = best_runtime
		best.interaction_slot = best_slot
		best.interaction_position = best_position
		best.station_runtime.reservations[best_slot] = String(employee.get("id", ""))
		best.station_runtime.busy = best.station_runtime.reservations.size()
	task_board_changed.emit()
	return best


func begin_maintenance_task(task_id: String) -> bool:
	if not maintenance_tasks.has(task_id):
		return false
	var task: Dictionary = maintenance_tasks[task_id]
	if String(task.get("state", "")) != "reserved" or not maintenance_task_is_actionable(task) or not maintenance_task_reservation_is_valid(task_id, String(task.get("employee_id", ""))):
		if String(task.get("state", "")) == "reserved":
			_cancel_maintenance_record(task, false)
		return false
	task.state = "in_progress"
	var owner := task.get("owner") as Node
	if owner != null and is_instance_valid(owner) and owner.has_method("maintenance_started"):
		owner.call("maintenance_started", String(task.get("action", "")), task.get("payload", {}), String(task.get("employee_id", "")))
	task_board_changed.emit()
	return true


func complete_maintenance_task(task_id: String) -> bool:
	if not maintenance_tasks.has(task_id):
		return false
	var task: Dictionary = maintenance_tasks[task_id]
	if String(task.get("state", "")) not in ["reserved", "in_progress"]:
		return false
	if not maintenance_task_is_actionable(task):
		_cancel_maintenance_record(task, false)
		return false
	var employee_id := String(task.get("employee_id", ""))
	_release_station(task)
	task.station_runtime = null
	task.state = "completed"
	task.finished_at = GameState.service_seconds
	if not employee_id.is_empty():
		stats.employee_tasks[employee_id] = int(stats.employee_tasks.get(employee_id, 0)) + 1
	var owner := task.get("owner") as Node
	if owner != null and is_instance_valid(owner) and owner.has_method("maintenance_completed"):
		owner.call("maintenance_completed", String(task.get("action", "")), task.get("payload", {}))
	task_board_changed.emit()
	return true


func maintenance_task_is_actionable(task: Dictionary) -> bool:
	if task.is_empty() or String(task.get("state", "")) in ["completed", "cancelled"]:
		return false
	var owner := task.get("owner") as Node
	if owner == null or not is_instance_valid(owner) or owner.is_queued_for_deletion():
		return false
	if owner.has_method("accepts_maintenance_action"):
		return bool(owner.call("accepts_maintenance_action", String(task.get("action", "")), task.get("payload", {})))
	return true


func maintenance_task_reservation_is_valid(task_id: String, employee_id: String) -> bool:
	if not maintenance_tasks.has(task_id) or employee_id.is_empty():
		return false
	var task: Dictionary = maintenance_tasks[task_id]
	if String(task.get("employee_id", "")) != employee_id:
		return false
	if String(task.get("station", "")).is_empty():
		return String(task.get("state", "")) in ["reserved", "in_progress"]
	return _station_reservation_is_owned(task)


func cancel_maintenance_task(task_id: String) -> void:
	if maintenance_tasks.has(task_id):
		_cancel_maintenance_record(maintenance_tasks[task_id], true)


func cancel_maintenance_for_owner(owner: Node) -> void:
	for task: Dictionary in maintenance_tasks.values():
		if task.get("owner") == owner and String(task.get("state", "")) not in ["completed", "cancelled"]:
			_cancel_maintenance_record(task, true)


func _cancel_maintenance_record(task: Dictionary, notify_owner: bool) -> void:
	if task.is_empty() or String(task.get("state", "")) in ["completed", "cancelled"]:
		return
	_release_station(task)
	task.station_runtime = null
	task.employee_id = ""
	task.state = "cancelled"
	task.finished_at = GameState.service_seconds
	var owner := task.get("owner") as Node
	if notify_owner and owner != null and is_instance_valid(owner) and owner.has_method("maintenance_cancelled"):
		owner.call("maintenance_cancelled", String(task.get("action", "")), task.get("payload", {}))
	task_board_changed.emit()


func _maintenance_key_is_reserved(key: String) -> bool:
	if key.is_empty():
		return false
	for task: Dictionary in maintenance_tasks.values():
		if String(task.get("reservation_key", "")) == key and String(task.get("state", "")) in ["reserved", "in_progress"]:
			return true
	return false


func _service_key_is_reserved(key: String) -> bool:
	for task: Dictionary in service_tasks.values():
		if String(task.get("reservation_key", "")) == key and String(task.get("state", "")) in ["reserved", "in_progress"]:
			return true
	return false


func cancel_customer_work(customer: Node) -> void:
	for service_task: Dictionary in service_tasks.values():
		if service_task.get("customer") == customer and String(service_task.get("state", "")) not in ["completed", "cancelled"]:
			service_task.state = "cancelled"
			service_task.employee_id = ""
			service_task.finished_at = GameState.service_seconds
	for order: Dictionary in orders.values():
		if order.get("customer") != customer or String(order.get("state", "")) in ["paid", "cancelled"]:
			continue
		order.state = "cancelled"
		order.finished_at = GameState.service_seconds
		for task_id: String in order.get("task_ids", []):
			var task: Dictionary = tasks.get(task_id, {})
			if task.is_empty() or String(task.get("state", "")) in ["completed", "cancelled"]:
				continue
			_release_station(task)
			task.station_runtime = null
			task.employee_id = ""
			task.state = "cancelled"
	task_board_changed.emit()


func raise_order_priority(order_id: String) -> void:
	if not orders.has(order_id):
		return
	orders[order_id].priority = mini(int(orders[order_id].priority) + 1, 3)
	for task_id: String in orders[order_id].task_ids:
		tasks[task_id].priority = orders[order_id].priority
	task_board_changed.emit()


func toggle_order_suspended(order_id: String) -> void:
	if not orders.has(order_id) or String(orders[order_id].state) == "paid":
		return
	orders[order_id].suspended = not bool(orders[order_id].get("suspended", false))
	order_updated.emit(orders[order_id])
	task_board_changed.emit()


func complete_order_payment(order_id: String, satisfaction: float) -> void:
	if not orders.has(order_id):
		return
	var order: Dictionary = orders[order_id]
	if order.state == "paid":
		return
	order.state = "paid"
	order.finished_at = GameState.service_seconds
	var price := int(GameState.menu.get(order.recipe_id, {}).get("price", DataRegistry.recipes_by_id[order.recipe_id].price))
	var tip := int(round(max(satisfaction - 0.7, 0.0) * price * 0.3))
	GameState.earn(price + tip, "%s servito" % order.recipe_name)
	stats.revenue += price + tip
	stats.ingredient_cost += DataRegistry.estimate_recipe_cost(DataRegistry.recipes_by_id[order.recipe_id])
	stats.customers_served += 1
	stats.satisfaction_sum += satisfaction
	stats.recipe_sales[order.recipe_id] = int(stats.recipe_sales.get(order.recipe_id, 0)) + 1
	stats.service_time_total += GameState.service_seconds - float(order.created_at)
	GameState.record_completed_order(String(order.recipe_id), satisfaction)
	statistics_changed.emit()


func get_station_position(runtime: Dictionary) -> Vector3:
	if runtime.is_empty() or not is_instance_valid(runtime.node):
		return Vector3.ZERO
	if runtime.node.has_method("get_interaction_position"):
		return runtime.node.get_interaction_position()
	return runtime.node.global_position


func _find_free_station(station_id: String) -> Dictionary:
	for runtime: Dictionary in stations.get(station_id, []):
		if is_instance_valid(runtime.node) and int(runtime.busy) < int(runtime.capacity):
			return runtime
	return {}


func _free_station_slot(runtime: Dictionary) -> int:
	if runtime.is_empty() or not is_instance_valid(runtime.get("node")):
		return -1
	var reservations: Dictionary = runtime.get("reservations", {})
	var positions: Array = runtime.get("interaction_positions", [])
	for slot: int in mini(int(runtime.get("capacity", 1)), positions.size()):
		if not reservations.has(slot):
			return slot
	return -1


func _release_station(task: Dictionary) -> void:
	if task.station_runtime:
		var slot := int(task.get("interaction_slot", -1))
		var owner_id := String(task.get("employee_id", ""))
		if slot >= 0 and String(task.station_runtime.reservations.get(slot, "")) == owner_id:
			task.station_runtime.reservations.erase(slot)
		task.station_runtime.busy = task.station_runtime.reservations.size()
		task.erase("interaction_slot")
		task.erase("interaction_position")


func kitchen_task_reservation_is_valid(task_id: String, employee_id: String) -> bool:
	if not tasks.has(task_id):
		return false
	var task: Dictionary = tasks[task_id]
	return String(task.get("employee_id", "")) == employee_id and _station_reservation_is_owned(task)


func _station_reservation_is_owned(task: Dictionary) -> bool:
	var runtime: Variant = task.get("station_runtime", null)
	if not (runtime is Dictionary) or (runtime as Dictionary).is_empty():
		return false
	var slot := int(task.get("interaction_slot", -1))
	var employee_id := String(task.get("employee_id", ""))
	if slot < 0 or employee_id.is_empty():
		return false
	return String((runtime as Dictionary).get("reservations", {}).get(slot, "")) == employee_id


func _stock_available(requirements: Dictionary) -> bool:
	for ingredient_id: String in requirements:
		if int(GameState.stock.get(ingredient_id, {}).get("amount", 0)) < int(requirements[ingredient_id]):
			return false
	return true


func _refresh_order_missing_components() -> void:
	for order_id: String in orders:
		var order: Dictionary = orders[order_id]
		var missing: Array[String] = []
		for task_id: String in order.get("task_ids", []):
			var task: Dictionary = tasks.get(task_id, {})
			if String(task.get("state", "")) != "waiting_stock":
				continue
			for ingredient_id: String in task.get("inputs", {}):
				if int(GameState.stock.get(ingredient_id, {}).get("amount", 0)) < int(task.inputs[ingredient_id]):
					var ingredient_name := String(DataRegistry.ingredients_by_id.get(ingredient_id, {"name": ingredient_id}).name)
					if not missing.has(ingredient_name):
						missing.append(ingredient_name)
		order.missing = missing


func _update_metrics(delta: float) -> void:
	for station_id: String in stations:
		for runtime: Dictionary in stations[station_id]:
			runtime.total_time += delta
			if runtime.busy > 0:
				runtime.busy_time += delta * minf(float(runtime.busy) / maxf(float(runtime.capacity), 1.0), 1.0)


func station_metrics() -> Array:
	var result: Array = []
	for definition: Dictionary in DataRegistry.stations:
		var busy_time := 0.0
		var total_time := 0.0
		var busy := 0
		var capacity := 0
		var completed := 0
		var blocked := 0
		var wait_total := 0.0
		for runtime: Dictionary in stations.get(definition.id, []):
			busy_time += float(runtime.busy_time)
			total_time += float(runtime.total_time)
			busy += int(runtime.busy)
			capacity += int(runtime.capacity)
			completed += int(runtime.completed)
			blocked += int(runtime.blocked)
			wait_total += float(runtime.wait_total)
		var queue := 0
		for task_id: String in tasks:
			if tasks[task_id].station == definition.id and tasks[task_id].state in ["queued", "waiting_stock"]:
				queue += 1
		var utilization := 0.0 if total_time <= 0.0 else busy_time / total_time * 100.0
		result.append({
			"id": definition.id,
			"name": definition.name,
			"utilization": utilization,
			"predicted": predicted_station_load(definition.id),
			"queue": queue,
			"busy": busy,
			"capacity": capacity,
			"completed": completed,
			"blocked": blocked,
			"average_wait": wait_total / maxf(completed, 1.0),
			"idle": maxf(100.0 - utilization, 0.0)
		})
	return result


func predicted_station_load(station_id: String) -> float:
	var load := 0.0
	var capacity := 0
	for runtime: Dictionary in stations.get(station_id, []):
		capacity += int(runtime.capacity)
	capacity = maxi(capacity, 1)
	for recipe: Dictionary in DataRegistry.active_recipes(GameState.menu):
		for step: Dictionary in recipe.steps:
			if step.station == station_id:
				load += float(step.time) * float(recipe.get("popularity", 1.0)) * 18.0
	return load / capacity


func reset_service_stats() -> void:
	# Release runtime slots before dropping task records. This matters when a
	# service is restarted without rebuilding the restaurant scene.
	for maintenance_task: Dictionary in maintenance_tasks.values():
		_release_station(maintenance_task)
	stats = {
		"revenue": 0,
		"ingredient_cost": 0.0,
		"labor_cost": 0,
		"customers_served": 0,
		"customers_lost": 0,
		"satisfaction_sum": 0.0,
		"recipe_sales": {},
		"employee_tasks": {},
		"service_time_total": 0.0,
		"waste": 0,
		"ingredients_out": []
	}
	tasks.clear()
	orders.clear()
	service_tasks.clear()
	maintenance_tasks.clear()
	_simulation_tick_accumulator = 0.0
	_maintenance_clock = 0.0
	statistics_changed.emit()


func _prune_completed_work(force: bool = false) -> void:
	var now := GameState.service_seconds
	for service_id: String in service_tasks.keys():
		var service_task: Dictionary = service_tasks.get(service_id, {})
		if String(service_task.get("state", "")) not in ["completed", "cancelled"]:
			continue
		var finished_at := float(service_task.get("finished_at", service_task.get("created_at", now)))
		if force or now - finished_at >= COMPLETED_WORK_RETENTION:
			service_tasks.erase(service_id)
	for maintenance_id: String in maintenance_tasks.keys():
		var maintenance_task: Dictionary = maintenance_tasks.get(maintenance_id, {})
		if String(maintenance_task.get("state", "")) not in ["completed", "cancelled"] and not maintenance_task_is_actionable(maintenance_task):
			_cancel_maintenance_record(maintenance_task, false)
		if String(maintenance_task.get("state", "")) not in ["completed", "cancelled"]:
			continue
		var finished_at := float(maintenance_task.get("finished_at", maintenance_task.get("created_at", now)))
		if force or now - finished_at >= COMPLETED_WORK_RETENTION:
			maintenance_tasks.erase(maintenance_id)
	for order_id: String in orders.keys():
		var order: Dictionary = orders.get(order_id, {})
		if String(order.get("state", "")) not in ["paid", "cancelled"]:
			continue
		var finished_at := float(order.get("finished_at", order.get("created_at", now)))
		if not force and now - finished_at < COMPLETED_WORK_RETENTION:
			continue
		for task_id: String in order.get("task_ids", []):
			tasks.erase(task_id)
		orders.erase(order_id)


func summary() -> Dictionary:
	var served := int(stats.customers_served)
	var top_recipe := "—"
	var low_recipe := "—"
	var top_count := -1
	var low_count := 999999
	for recipe_id: String in stats.recipe_sales:
		var count := int(stats.recipe_sales[recipe_id])
		if count > top_count:
			top_count = count
			top_recipe = DataRegistry.recipes_by_id[recipe_id].name
		if count < low_count:
			low_count = count
			low_recipe = DataRegistry.recipes_by_id[recipe_id].name
	return {
		"revenue": int(stats.revenue),
		"ingredient_cost": int(round(float(stats.ingredient_cost))),
		"labor_cost": int(stats.labor_cost),
		"profit": int(stats.revenue - float(stats.ingredient_cost) - int(stats.labor_cost)),
		"customers_served": served,
		"customers_lost": int(stats.customers_lost),
		"satisfaction": 0.0 if served == 0 else float(stats.satisfaction_sum) / served,
		"top_recipe": top_recipe,
		"low_recipe": low_recipe,
		"waste": int(stats.waste)
		,"average_time": 0.0 if served == 0 else float(stats.service_time_total) / served
		,"employee_tasks": stats.employee_tasks.duplicate(true)
		,"ingredients_out": stats.ingredients_out.duplicate()
	}
