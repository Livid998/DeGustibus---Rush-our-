extends Node

var checks := 0
var failures := 0


func _ready() -> void:
	SaveManager.writes_enabled = false
	await get_tree().process_frame
	_check_factory_bounds()
	var main_scene: PackedScene = load("res://scenes/main/main.tscn")
	var main := main_scene.instantiate()
	add_child(main)
	GameState.tutorial.skipped = true
	for _frame: int in 30:
		await get_tree().process_frame
	_check_waiter_carry(main.world)
	_check_world_dirty_adoption(main.world)
	print("DISH_VISUALS: %d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)


func _check_factory_bounds() -> void:
	for kind: String in ["plate", "bowl"]:
		var expected := FoodVisualFactory.canonical_container_size(kind)
		_expect(expected.x >= 0.65 and expected.z >= 0.65, "%s has a readable table-service footprint (%.3fx%.3f)" % [kind, expected.x, expected.z])
		_expect(expected.x <= 0.72 and expected.z <= 0.72, "%s remains credible on one place setting (%.3fx%.3f)" % [kind, expected.x, expected.z])
		_expect(FoodVisualFactory.canonical_content_scale(kind) >= 1.25, "%s food layout grows with the readable container" % kind)
		for dirty: bool in [false, true]:
			var container := FoodVisualFactory.instantiate_canonical_container(kind, dirty)
			var size := ModelFactory.calculate_visual_bounds(container, true).size
			_expect(_same_footprint(size, expected), "%s %s uses canonical rendered bounds" % ["dirty" if dirty else "clean", kind])
			container.free()
	for recipe: Dictionary in DataRegistry.recipes:
		var recipe_id := String(recipe.id)
		var kind := FoodVisualFactory.consumption_container(recipe_id)
		var serving := FoodVisualFactory.instantiate_canonical_serving(recipe_id)
		var container := serving.get_node_or_null("StableContainer") as Node3D
		var size := ModelFactory.calculate_visual_bounds(container, true).size if container != null else Vector3.ZERO
		var serving_size := ModelFactory.calculate_visual_bounds(serving, true).size
		_expect(container != null and _same_footprint(size, FoodVisualFactory.canonical_container_size(kind)), "%s full serving has exactly one canonical %s" % [recipe_id, kind])
		var is_pizza := recipe_id in ["margherita", "mushroom_pizza", "pepperoni_pizza"]
		if is_pizza:
			var food_content := serving.get_node_or_null("FoodContent") as Node3D
			var food_size := ModelFactory.calculate_visual_bounds(food_content, true).size if food_content != null else Vector3.ZERO
			var coverage := maxf(food_size.x, food_size.z) / maxf(maxf(size.x, size.z), 0.0001)
			var authored_scale := float(DataRegistry.food_visuals_by_id.get(recipe_id, {}).get("canonical_scale_multiplier", 1.0))
			# Pizza slice meshes contain generous non-crust bounds, so an AABB
			# around 115% is intentional: the visible crust, verified by the
			# capture, reaches the plate rim without visibly crossing it.
			_expect(authored_scale >= 1.05, "%s uses the perceptual pizza scale rather than the padded mesh default" % recipe_id)
			_expect(coverage >= 1.10 and coverage <= 1.20, "%s padded mesh footprint produces a visually thin plate rim (%.1f%%)" % [recipe_id, coverage * 100.0])
		else:
			_expect(serving_size.x <= size.x + 0.025 and serving_size.z <= size.z + 0.025, "%s assembled food stays inside the dirty-container footprint (%.3fx%.3f)" % [recipe_id, serving_size.x, serving_size.z])
		for stage: int in [1, 2]:
			var stage_parts := FoodVisualFactory.consumption_parts(recipe_id, stage)
			if stage_parts.is_empty():
				continue
			var stage_food := FoodVisualFactory.instantiate_parts(stage_parts)
			var stage_size := ModelFactory.calculate_visual_bounds(stage_food, true).size
			if is_pizza:
				var stage_coverage := maxf(stage_size.x, stage_size.z) / maxf(maxf(size.x, size.z), 0.0001)
				_expect(stage_coverage >= 1.10 and stage_coverage <= 1.20, "%s stage %d keeps the perceptual pizza diameter (%.1f%% padded footprint)" % [recipe_id, stage, stage_coverage * 100.0])
			else:
				_expect(stage_size.x <= size.x + 0.025 and stage_size.z <= size.z + 0.025, "%s stage %d food stays inside the same canonical %s" % [recipe_id, stage, kind])
			stage_food.free()
		serving.free()


func _check_waiter_carry(world: RestaurantWorld) -> void:
	var waiter: EmployeeAgent
	for value: Variant in world.staff_agents.values():
		var employee := value as EmployeeAgent
		if employee != null and String(employee.employee.get("role", "")) == "waiter":
			waiter = employee
			break
	if waiter == null:
		_expect(false, "waiter fixture exists")
		return
	waiter.set_process(false)
	waiter.active_task = {"action":"serve", "payload":{"recipe_id":"margherita"}}
	waiter._show_task_prop(false)
	waiter._update_carried_prop_anchor()
	var carried_container := waiter._task_prop.get_node_or_null("StableContainer") as Node3D
	var carried_food := waiter._task_prop.get_node_or_null("FoodContent") as Node3D
	var midpoint := (waiter._hand_prop_anchor.global_position + waiter._left_hand_prop_anchor.global_position) * 0.5
	var center_distance := Vector2(carried_container.global_position.x, carried_container.global_position.z).distance_to(Vector2(midpoint.x, midpoint.z)) if carried_container != null else INF
	_expect(carried_container != null and _same_footprint(ModelFactory.calculate_visual_bounds(carried_container, true).size, FoodVisualFactory.canonical_container_size("plate")), "served dish keeps canonical dirty-plate footprint while carried")
	var carried_plate_size := ModelFactory.calculate_visual_bounds(carried_container, true).size if carried_container != null else Vector3.ZERO
	var carried_food_size := ModelFactory.calculate_visual_bounds(carried_food, true).size if carried_food != null else Vector3.ZERO
	var carried_coverage := maxf(carried_food_size.x, carried_food_size.z) / maxf(maxf(carried_plate_size.x, carried_plate_size.z), 0.0001)
	_expect(carried_food != null and carried_coverage >= 1.10 and carried_coverage <= 1.20, "carried pizza keeps its perceptual table-service diameter (%.1f%% padded footprint)" % (carried_coverage * 100.0))
	_expect(center_distance <= 0.10, "served dish is driven by the midpoint between both animated hands")
	waiter.active_task = {"action":"collect_dishes", "payload":{"container_kinds":["plate", "bowl"]}}
	waiter._show_task_prop(false)
	var stack_kinds: Array[String] = []
	for child: Node in waiter._task_prop.get_children():
		if child is Node3D:
			var kind := String(child.get_meta("canonical_container_kind", ""))
			stack_kinds.append(kind)
			_expect(_same_footprint(ModelFactory.calculate_visual_bounds(child, true).size, FoodVisualFactory.canonical_container_size(kind)), "carried dirty %s keeps canonical footprint" % kind)
	_expect(stack_kinds == ["plate", "bowl"], "dirty carry preserves plate/bowl kinds")
	waiter._clear_task_prop()


func _check_world_dirty_adoption(world: RestaurantWorld) -> void:
	var table_uid := String(world.placed_objects.keys()[0]) if not world.placed_objects.is_empty() else ""
	var sources: Array[Node3D] = []
	for index: int in 2:
		var source := Node3D.new()
		source.set_meta("consumption_container", "plate" if index == 0 else "bowl")
		world.cleanup_root.add_child(source)
		source.global_position = Vector3(3.0 + index, 1.0, 3.0)
		sources.append(source)
	world.adopt_dirty_table(self, table_uid, sources)
	var record: Dictionary = world.table_dirty_records.get(table_uid, {})
	_expect(record.get("container_kinds", []) == ["plate", "bowl"], "table adoption preserves dirty container kinds")
	for node: Node3D in record.get("nodes", []):
		var kind := String(node.get_meta("canonical_container_kind", ""))
		_expect(_same_footprint(ModelFactory.calculate_visual_bounds(node, true).size, FoodVisualFactory.canonical_container_size(kind)), "table-adopted dirty %s keeps canonical footprint" % kind)


func _same_footprint(actual: Vector3, expected: Vector3) -> bool:
	return absf(actual.x - expected.x) <= 0.001 and absf(actual.z - expected.z) <= 0.001


func _expect(condition: bool, description: String) -> void:
	checks += 1
	if condition:
		print("PASS | ", description)
	else:
		failures += 1
		push_error("FAIL | %s" % description)
