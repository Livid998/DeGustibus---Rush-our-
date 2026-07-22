extends Node

## Deterministic M0 release gate.  It deliberately exercises the same public
## storage/economy/progression transactions used by the live game, but omits
## rendering and NPC travel so a 30-day stock soak remains fast in CI.

class ReadinessWorldStub:
	extends Node

	func restaurant_opening_readiness() -> Dictionary:
		return {
			"ready": true,
			"blockers": [],
			"warnings": [],
			"context": {"source": "m0_integrity_soak"},
		}

	func restaurant_opening_blockers() -> Array:
		return []


const DAYS_TO_SOAK := 30
const ORDERS_PER_DAY := 4
const RESULT_PATH := "user://m0-integrity-soak-result.txt"

var checks := 0
var failures: Array[String] = []
var metrics := {
	"days": 0,
	"orders_consumed": 0,
	"invariant_checks": 0,
	"normal_reorder_batches": 0,
	"partial_accepted": 0,
	"partial_rejected": 0,
	"disposals": 0,
	"recoveries": 0,
	"ingredients_reached": 0,
	"recipes_reached": 0,
	"migration_preserved": 0,
}

var _original_state: Dictionary
var _original_world: Node
var _economy_was_processing := true
var _simulation_was_processing := true


func _ready() -> void:
	SaveManager.writes_enabled = false
	_original_state = GameState.serialize().duplicate(true)
	_original_world = SimulationManager.world
	_economy_was_processing = EconomyManager.is_processing()
	_simulation_was_processing = SimulationManager.is_processing()
	EconomyManager.set_process(false)
	SimulationManager.set_process(false)

	_test_auto_reorder_prioritizes_complete_recipe_bundle()
	_test_fresh_save_30_day_integrity()
	_test_all_progression_is_reachable()
	_test_saturated_corrupt_v11_migration()

	SimulationManager.close_immediately()
	SimulationManager.bind_world(_original_world)
	SimulationManager.reset_service_stats()
	StorageManager.reset_runtime_reservations()
	EconomyManager.clear_delivery_cart()
	GameState.deserialize(_original_state)
	EconomyManager.set_process(_economy_was_processing)
	SimulationManager.set_process(_simulation_was_processing)

	var result := "M0 INTEGRITY SOAK: %s | checks=%d failures=%d | metrics=%s\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		JSON.stringify(metrics),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(result)
		file.close()
	else:
		push_error("Cannot write M0 result to %s" % RESULT_PATH)
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_auto_reorder_prioritizes_complete_recipe_bundle() -> void:
	_reset_fresh_state()
	for recipe_id: String in GameState.menu:
		GameState.set_recipe_active(recipe_id, recipe_id == "margherita")
	for ingredient_id: String in GameState.stock:
		GameState.stock[ingredient_id].amount = 0
		GameState.stock[ingredient_id].reserved = 0
		GameState.stock[ingredient_id].auto_reorder = ingredient_id in ["tomato", "cheese", "dough"]
		if bool(GameState.stock[ingredient_id].auto_reorder):
			GameState.stock[ingredient_id].threshold = 4
			GameState.stock[ingredient_id].target = 12
	GameState.stock.potato.amount = StorageManager.capacity_for("ambient") - 2
	GameState.stock.carrot.amount = StorageManager.capacity_for("refrigerated") - 2
	StorageManager.recalculate_usage()
	var before := StorageManager.soft_lock_snapshot()
	_expect(
		(before.get("orderable_recipe_ids", []) as Array).has("margherita"),
		"the two-plus-two free-unit boundary can still order one complete margherita bundle"
	)
	EconomyManager._check_auto_reorders()
	var pending := StorageManager.pending_items("normal")
	_expect(
		int(pending.get("tomato", 0)) == 2
			and int(pending.get("cheese", 0)) == 1
			and int(pending.get("dough", 0)) == 1,
		"auto reorder reserves the exact complete recipe bundle before independent targets"
	)
	var after := StorageManager.soft_lock_snapshot()
	_expect(
		(after.get("pending_recipe_ids", []) as Array).has("margherita"),
		"the capacity-bound auto reorder leaves a completable recipe, not an incomplete ingredient pile"
	)
	_cancel_all_pending_for_test()


func _test_fresh_save_30_day_integrity() -> void:
	_reset_fresh_state()
	var initial_capacity := StorageManager.capacity_snapshot()
	var initial_usage := StorageManager.usage_snapshot()
	_expect(
		int(initial_usage.ambient) * 2 < int(initial_capacity.ambient)
			and int(initial_usage.refrigerated) * 2 < int(initial_capacity.refrigerated),
		"fresh save starts below 50 percent of both storage capacities"
	)

	for recipe_id: String in GameState.menu:
		GameState.set_recipe_active(recipe_id, recipe_id == "margherita")
	for ingredient_id: String in ["tomato", "cheese", "dough"]:
		var entry: Dictionary = GameState.stock[ingredient_id]
		entry.auto_reorder = true
		entry.threshold = 4
		entry.target = 12
	var customer := Node.new()
	customer.name = "M0SoakCustomer"
	add_child(customer)

	_assert_continuation_invariant("fresh save")
	for day: int in range(1, DAYS_TO_SOAK + 1):
		GameState.world_clock.day = day
		GameState.world_clock.minute = 720.0
		for order_index: int in ORDERS_PER_DAY:
			var served := _serve_paid_order("margherita", customer, "day_%02d_order_%02d" % [day, order_index])
			_expect(served, "day %d order %d consumes reserved ingredients and reaches paid" % [day, order_index + 1])
			if not served:
				break
		_assert_continuation_invariant("day %d after consumption" % day)

		var pending_before := _pending_item_total()
		EconomyManager._check_auto_reorders()
		var pending_after := _pending_item_total()
		if pending_after > pending_before:
			metrics.normal_reorder_batches = int(metrics.normal_reorder_batches) + 1
		_assert_continuation_invariant("day %d after auto reorder" % day)

		EconomyManager.advance_delivery_time(
			float(DataRegistry.balance_value("delivery.batch_interval_seconds", 300.0))
		)
		_assert_continuation_invariant("day %d after delivery" % day)

		if day == 7:
			_exercise_partial_delivery_and_disposal(day)
		if day == 15:
			_exercise_emergency_recovery(day)

		SimulationManager._prune_completed_work(true)
		metrics.days = day

	_expect(int(metrics.days) == DAYS_TO_SOAK, "the deterministic soak completes all 30 days")
	_expect(int(metrics.orders_consumed) == DAYS_TO_SOAK * ORDERS_PER_DAY, "all planned soak orders consume stock exactly once")
	_expect(int(metrics.normal_reorder_batches) > 0, "the 30-day soak triggers automatic reorder batches")
	_expect(int(metrics.partial_accepted) == 2 and int(metrics.partial_rejected) == 3, "the soak observes the expected partial delivery split")
	_expect(int(metrics.disposals) > 0 and int(metrics.recoveries) == 1, "the same fresh-save run exercises disposal and one-shot recovery")
	_expect(GameState.money >= 0, "the storage soak never produces negative currency")
	_expect(StorageManager.reservation_count() == 0, "the 30-day soak leaves no runtime stock reservation")
	customer.queue_free()


func _exercise_partial_delivery_and_disposal(day: int) -> void:
	EconomyManager.advance_delivery_time(
		float(DataRegistry.balance_value("delivery.batch_interval_seconds", 300.0))
	)
	EconomyManager.clear_delivery_cart()
	StorageManager.recalculate_usage()
	var free_before := StorageManager.free_capacity("ambient")
	var filler := maxi(free_before - 2, 0)
	_expect(filler > 0, "day %d has ambient room to construct the partial-delivery boundary" % day)
	if filler <= 0:
		return
	GameState.add_stock("flour", filler)
	StorageManager.recalculate_usage()
	_expect(StorageManager.free_capacity("ambient") == 2, "day %d reaches exactly two free ambient units" % day)

	_expect(EconomyManager.add_to_delivery_cart("potato", 5), "day %d adds five potatoes to the live cart" % day)
	var preview := EconomyManager.delivery_preview({}, false)
	metrics.partial_accepted = int(preview.accepted_items.get("potato", 0))
	metrics.partial_rejected = int(preview.rejected_items.get("potato", 0))
	_expect(EconomyManager.confirm_delivery_cart(false), "day %d confirms the capacity-safe part of the cart" % day)
	_expect(
		int(EconomyManager.normal_batch_snapshot().items.get("potato", {}).get("amount", 0)) == 2
			and int(EconomyManager.delivery_cart_snapshot().get("potato", 0)) == 3,
		"day %d keeps the rejected remainder editable" % day
	)
	_assert_continuation_invariant("day %d with partial batch pending" % day)

	var cancellation := EconomyManager.cancel_pending_batch("normal")
	_expect(bool(cancellation.get("success", false)) and is_equal_approx(float(cancellation.get("refund_rate", 0.0)), 0.8), "day %d cancels the partial batch at the documented refund" % day)
	EconomyManager.clear_delivery_cart()
	var disposal := EconomyManager.discard_stock("flour", filler)
	_expect(bool(disposal.get("success", false)) and int(disposal.get("amount", 0)) == filler, "day %d disposes only the injected unreserved filler" % day)
	if bool(disposal.get("success", false)):
		metrics.disposals = int(metrics.disposals) + int(disposal.get("amount", 0))
	_assert_continuation_invariant("day %d after cancellation and disposal" % day)


func _exercise_emergency_recovery(day: int) -> void:
	EconomyManager.clear_delivery_cart()
	_cancel_all_pending_for_test()
	for ingredient_id: String in GameState.stock:
		GameState.stock[ingredient_id].amount = 0
		GameState.stock[ingredient_id].reserved = 0
	GameState.stock.potato.amount = StorageManager.capacity_for("ambient")
	GameState.stock.carrot.amount = StorageManager.capacity_for("refrigerated")
	GameState.progress.emergency_recovery_used = false
	StorageManager.reset_runtime_reservations()
	StorageManager.recalculate_usage()
	StorageManager.refresh_auto_sold_out()
	var audit := StorageManager.soft_lock_snapshot()
	_expect(bool(audit.soft_locked), "day %d detects a genuinely saturated soft-lock" % day)
	_expect(bool(audit.recovery_available), "day %d exposes an atomic recovery action" % day)
	_assert_continuation_invariant("day %d saturated save" % day)
	var recovery := EconomyManager.apply_recovery_plan()
	_expect(bool(recovery.get("success", false)), "day %d applies the recovery preview atomically" % day)
	if bool(recovery.get("success", false)):
		metrics.recoveries = int(metrics.recoveries) + 1
	_expect(
		StorageManager.is_recipe_producible(String(recovery.get("recipe_id", ""))),
		"day %d recovery leaves its selected recipe immediately producible" % day
	)
	_assert_continuation_invariant("day %d after emergency recovery" % day)


func _test_all_progression_is_reachable() -> void:
	_reset_fresh_state()
	var stub := ReadinessWorldStub.new()
	add_child(stub)
	SimulationManager.bind_world(stub)
	_expect(SimulationManager.open_restaurant(), "a valid restaurant starts the first service through the public opening flow")
	SimulationManager.close_immediately()
	_expect(bool(GameState.stock.egg.unlocked), "the first-service rule unlocks egg without a debug mutation")

	for ingredient_id: String in ["milk", "pepperoni"]:
		var status := GameState.ingredient_unlock_status(ingredient_id)
		var cost := int((status.get("rule", {}) as Dictionary).get("cost", 0))
		_expect(GameState.money >= cost and GameState.purchase_ingredient_unlock(ingredient_id), "%s is bought through its Album purchase rule" % ingredient_id)

	var customer := Node.new()
	customer.name = "M0ReachabilityCustomer"
	add_child(customer)
	GameState.set_recipe_active("margherita", true)
	var dessert_definition: Dictionary = DataRegistry.build_by_id.get("dessert", {})
	var dessert_price := int(dessert_definition.get("price", 0))
	var starter_orders := 0
	# The 1,200-coin starter must earn expansion money through ordinary paid
	# service.  Keep serving until both tabletop machines are affordable; using a
	# large starting-wallet fixture here would hide a real progression dead end.
	while (starter_orders < 25 or GameState.money < dessert_price * 2) and starter_orders < 150:
		_expect(
			_serve_paid_order("margherita", customer, "reach_customer_%02d" % starter_orders),
			"customer progression order %d completes through stock and payment APIs" % (starter_orders + 1)
		)
		starter_orders += 1
	_expect(starter_orders < 150 and GameState.money >= dessert_price * 2, "normal starter service earns both tabletop ice-cream machines without cheats")
	_expect(bool(GameState.stock.veg_patty.unlocked), "25 paid customers unlock the vegetable patty rule")
	_expect(GameState.reputation >= 3.0, "normal five-star payments can reach reputation 3")
	GameState.check_progression(false)
	_expect(bool(GameState.stock.ham.unlocked) and bool(GameState.stock.ice_chocolate.unlocked), "review-driven reputation unlocks ham and chocolate ice cream")

	_expect(
		not dessert_definition.is_empty()
		and GameState.spend(dessert_price * 2, "M0 reachability tabletop machines"),
		"two tabletop ice-cream machines are bought with normal service earnings"
	)
	GameState.layout.append_array([
		{
			"uid": "m0_reachability_dessert_1",
			"item": "dessert",
			"cell": [15, 9],
			"rotation": 0,
			"support_uid": "support_dough_1",
			"attachment_slot": 1,
		},
		{
			"uid": "m0_reachability_dessert_2",
			"item": "dessert",
			"cell": [5, 9],
			"rotation": 0,
			"support_uid": "prep_1",
			"attachment_slot": 1,
		},
	])
	GameState.layout_changed.emit()
	var build_unlocks := GameState.check_progression(false)
	_expect(build_unlocks.has("ice_vanilla"), "buying a second tabletop ice-cream machine unlocks vanilla")
	_expect(bool(GameState.menu.icecream_cone.unlocked), "vanilla plus milk unlock the first dessert recipe")

	GameState.set_recipe_active("icecream_cone", true)
	for index: int in 10:
		_expect(_serve_paid_order("icecream_cone", customer, "reach_dessert_%02d" % index), "dessert progression order %d completes through stock and payment APIs" % (index + 1))
	GameState.check_progression(false)
	_expect(bool(GameState.stock.ice_strawberry.unlocked), "ten paid desserts unlock strawberry ice cream")
	CollectionManager.sync_recipe_unlocks()

	var missing_ingredients: Array[String] = []
	for ingredient: Dictionary in DataRegistry.ingredients:
		var ingredient_id := String(ingredient.id)
		if not bool(GameState.stock.get(ingredient_id, {}).get("unlocked", false)):
			missing_ingredients.append(ingredient_id)
	var missing_recipes: Array[String] = []
	for recipe: Dictionary in DataRegistry.recipes:
		var recipe_id := String(recipe.id)
		if not bool(GameState.menu.get(recipe_id, {}).get("unlocked", false)):
			missing_recipes.append(recipe_id)
	metrics.ingredients_reached = DataRegistry.ingredients.size() - missing_ingredients.size()
	metrics.recipes_reached = DataRegistry.recipes.size() - missing_recipes.size()
	_expect(missing_ingredients.is_empty(), "all ingredient unlocks are reachable without debug APIs; missing=%s" % str(missing_ingredients))
	_expect(missing_recipes.is_empty(), "all recipe unlocks are reachable without debug APIs; missing=%s" % str(missing_recipes))

	customer.queue_free()
	stub.queue_free()
	SimulationManager.bind_world(_original_world)
	SimulationManager.reset_service_stats()


func _test_saturated_corrupt_v11_migration() -> void:
	_reset_fresh_state()
	var v11 := GameState.serialize().duplicate(true)
	v11.save_version = 11
	v11.money = 1234
	v11.layout.append({"uid": "m0_v11_layout_sentinel", "item": "plant", "cell": [6, 6], "rotation": 3})
	var expected_layout_size: int = v11.layout.size()
	for recipe_id: String in v11.menu:
		v11.menu[recipe_id].active = false
	v11.menu.margherita.active = true
	v11.menu.margherita.unlocked = true
	v11.menu.margherita.price = 31
	v11.menu.pepperoni_pizza.unlocked = true
	v11.menu.pepperoni_pizza.price = 41
	v11.stock.milk.unlocked = true
	v11.stock.pepperoni.unlocked = true
	for ingredient_id: String in v11.stock:
		v11.stock[ingredient_id].amount = 0
		v11.stock[ingredient_id].reserved = 0
	v11.stock.potato.amount = StorageManager.capacity_for("ambient")
	v11.stock.potato.reserved = 999
	v11.stock.potato.storage_type = "corrupt_type"
	v11.stock.potato.storage_units = -7
	v11.stock.carrot.amount = StorageManager.capacity_for("refrigerated")
	v11.stock.tomato.amount = -40
	v11.purchased_preparations = {"dough_base": 3, "tomato_slices": 2, "burger_cooked": 1}
	v11.pending_delivery_batch = {"id": "", "items": {}, "remaining": -20.0, "paid": false}

	GameState.deserialize(v11)
	StorageManager.reset_runtime_reservations()
	StorageManager.recalculate_layout_capacity()
	var layout_preserved: bool = GameState.layout.size() == expected_layout_size and GameState.layout.any(
		func(record: Dictionary) -> bool: return String(record.get("uid", "")) == "m0_v11_layout_sentinel" and int(record.get("rotation", -1)) == 3
	)
	var menu_preserved := (
		bool(GameState.menu.margherita.active)
		and bool(GameState.menu.margherita.unlocked)
		and int(GameState.menu.margherita.price) == 31
		and bool(GameState.menu.pepperoni_pizza.unlocked)
		and int(GameState.menu.pepperoni_pizza.price) == 41
	)
	var unlocks_preserved := bool(GameState.stock.milk.unlocked) and bool(GameState.stock.pepperoni.unlocked)
	_expect(layout_preserved, "v11 migration preserves layout count, UID, cell and rotation")
	_expect(menu_preserved, "v11 migration preserves active menu, learned recipes and prices")
	_expect(unlocks_preserved, "v11 migration preserves purchased ingredient unlocks")
	metrics.migration_preserved = int(layout_preserved) + int(menu_preserved) + int(unlocks_preserved)

	var potato_metadata := DataRegistry.storage_metadata_for_ingredient("potato")
	_expect(int(GameState.stock.tomato.amount) == 0, "v11 migration sanitizes a corrupt negative amount")
	_expect(int(GameState.stock.potato.amount) == StorageManager.capacity_for("ambient"), "v11 migration preserves saturated physical stock")
	_expect(int(GameState.stock.potato.reserved) == 0, "v11 migration clears non-persistent corrupt reservations")
	_expect(
		String(GameState.stock.potato.storage_type) == String(potato_metadata.storage_type)
			and int(GameState.stock.potato.storage_units) == int(potato_metadata.storage_units),
		"v11 migration restores authoritative storage metadata"
	)
	_expect(GameState.purchased_preparations == {"dough_base": 3}, "v11 migration removes unusable preparation inventory")
	_expect(GameState.money == 1249, "v11 migration fully refunds removed legacy preparations")
	_expect(float(GameState.pending_delivery_batch.remaining) >= 0.0, "v11 migration sanitizes a corrupt delivery countdown")

	var audit := StorageManager.soft_lock_snapshot()
	_expect(bool(audit.soft_locked) and bool(audit.recovery_available), "the saturated migrated save exposes recovery instead of remaining stuck")
	var recovery := EconomyManager.apply_recovery_plan()
	_expect(bool(recovery.get("success", false)), "the saturated v11 fixture is repairable after migration")
	_expect(StorageManager.is_recipe_producible(String(recovery.get("recipe_id", ""))), "v11 repair guarantees a producible recipe")
	var serialized := GameState.serialize()
	_expect(int(serialized.save_version) == 12, "the repaired legacy fixture serializes as schema v12")
	_expect(
		serialized.layout == GameState.layout and bool(serialized.menu.margherita.active) and bool(serialized.stock.milk.unlocked),
		"layout, menu and unlock preservation survives the migrated v12 round-trip payload"
	)


func _serve_paid_order(recipe_id: String, customer: Node, label: String) -> bool:
	if not _ensure_recipe_stock(recipe_id):
		_fail("%s cannot acquire the ingredients required by %s" % [label, recipe_id])
		return false
	GameState.set_recipe_unlocked(recipe_id, true)
	GameState.set_recipe_active(recipe_id, true)
	GameState.set_recipe_manual_paused(recipe_id, false)
	var order := SimulationManager.create_order(recipe_id, "m0_gate_table", customer)
	if order.is_empty():
		_fail("%s cannot create an order for %s" % [label, recipe_id])
		return false
	var order_id := String(order.id)
	var requirements := DataRegistry.recipe_raw_requirements(recipe_id)
	if not StorageManager.consume_reserved(order_id, requirements):
		SimulationManager.cancel_order(order_id, "m0_consume_failed")
		_fail("%s cannot consume its atomic reservation for %s" % [label, recipe_id])
		return false
	SimulationManager.complete_order_payment(order_id, 1.0)
	var paid := String(SimulationManager.orders.get(order_id, {}).get("state", "")) == "paid"
	if paid:
		metrics.orders_consumed = int(metrics.orders_consumed) + 1
	else:
		_fail("%s did not reach paid after stock consumption" % label)
	return paid


func _ensure_recipe_stock(recipe_id: String) -> bool:
	var requirements := DataRegistry.recipe_raw_requirements(recipe_id)
	var missing: Dictionary = {}
	for ingredient_id: String in requirements:
		var needed := int(requirements[ingredient_id]) - StorageManager.available_amount(ingredient_id)
		if needed > 0:
			missing[ingredient_id] = needed
	if missing.is_empty():
		return true
	EconomyManager.clear_delivery_cart()
	for ingredient_id: String in missing:
		if not bool(GameState.stock.get(ingredient_id, {}).get("unlocked", false)):
			return false
		if not EconomyManager.add_to_delivery_cart(ingredient_id, int(missing[ingredient_id])):
			return false
	var preview := EconomyManager.delivery_preview({}, true)
	if not bool(preview.fully_accepted) or not bool(preview.affordable):
		EconomyManager.clear_delivery_cart()
		return false
	if not EconomyManager.confirm_delivery_cart(true):
		return false
	EconomyManager.advance_delivery_time(float(DataRegistry.balance_value("delivery.urgent_delivery_seconds", 30.0)))
	for ingredient_id: String in requirements:
		if StorageManager.available_amount(ingredient_id) < int(requirements[ingredient_id]):
			return false
	return true


func _assert_continuation_invariant(label: String) -> void:
	var audit := StorageManager.soft_lock_snapshot()
	var holds := (
		not (audit.get("producible_recipe_ids", []) as Array).is_empty()
		or not (audit.get("pending_recipe_ids", []) as Array).is_empty()
		or not (audit.get("orderable_recipe_ids", []) as Array).is_empty()
		or bool(audit.get("recovery_available", false))
	)
	metrics.invariant_checks = int(metrics.invariant_checks) + 1
	_expect(
		holds,
		"%s satisfies producible OR completable pending OR orderable OR recovery; audit=%s" % [label, JSON.stringify(audit)]
	)


func _pending_item_total() -> int:
	var total := 0
	for batch_kind: String in ["normal", "urgent"]:
		for amount: Variant in StorageManager.pending_items(batch_kind).values():
			total += int(amount)
	return total


func _cancel_all_pending_for_test() -> void:
	for batch_kind: String in ["normal", "urgent"]:
		if not StorageManager.pending_items(batch_kind).is_empty():
			EconomyManager.cancel_pending_batch(batch_kind, true)


func _reset_fresh_state() -> void:
	SimulationManager.close_immediately()
	SimulationManager.reset_service_stats()
	GameState.reset_to_defaults(false)
	GameState.set_restaurant_state("closed")
	GameState.set_pending_delivery_batch({
		"id": "",
		"items": {},
		"remaining": float(DataRegistry.balance_value("delivery.batch_interval_seconds", 300.0)),
		"paid": false,
		"paid_cost": 0,
		"urgent": {
			"id": "",
			"items": {},
			"remaining": float(DataRegistry.balance_value("delivery.urgent_delivery_seconds", 30.0)),
			"paid": false,
			"paid_cost": 0,
		},
	})
	EconomyManager.clear_delivery_cart()
	StorageManager.reset_runtime_reservations()
	StorageManager.recalculate_layout_capacity()
	StorageManager.refresh_auto_sold_out()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)


func _fail(message: String) -> void:
	failures.append("FAIL: %s" % message)
