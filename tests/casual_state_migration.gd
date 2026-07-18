extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	var previous_writes_enabled := SaveManager.writes_enabled
	SaveManager.writes_enabled = false
	var original_state := GameState.serialize().duplicate(true)
	_test_balance_registry()
	_test_v9_migration()
	_test_current_schema_round_trip()
	GameState.deserialize(original_state)
	SaveManager.writes_enabled = previous_writes_enabled
	var result := "CASUAL STATE MIGRATION: %s | checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()]
	print(result)
	for failure: String in failures:
		print(failure)
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_balance_registry() -> void:
	_expect(DataRegistry.gameplay_balance_valid, "gameplay_balance passes schema validation")
	_expect(int(DataRegistry.balance_value("day_cycle.real_seconds_at_1x", 0)) == 720, "day duration is data-driven")
	_expect(int(DataRegistry.balance_value("delivery.batch_interval_seconds", 0)) == 300, "delivery batch interval is data-driven")
	_expect(int(DataRegistry.balance_value("delivery.urgent_delivery_seconds", 0)) == 30, "urgent delivery interval is data-driven")
	_expect(int(DataRegistry.balance_value("reviews.history_limit", 0)) == 100, "review history limit is data-driven")
	_expect(DataRegistry.recipe_raw_requirements("margherita") == {"dough": 1, "tomato": 2, "cheese": 1}, "recipe helper aggregates raw inputs across every step")


func _test_v9_migration() -> void:
	GameState.reset_to_defaults(false)
	var v9 := GameState.serialize().duplicate(true)
	v9.save_version = 9
	for key: String in [
		"album_inventory", "album_discovered", "reviews", "review_reward_progress",
		"reputation_weight", "world_clock", "restaurant_profile",
		"cleanliness_state", "pest_state", "staff_preferences"
	]:
		v9.erase(key)
	for ingredient_id: String in v9.stock:
		v9.stock[ingredient_id].erase("reserved")
		v9.stock[ingredient_id].erase("storage_type")
		v9.stock[ingredient_id].erase("storage_units")
	for recipe_id: String in v9.menu:
		v9.menu[recipe_id].erase("manual_paused")
		v9.menu[recipe_id].erase("auto_sold_out")
	v9.money = 4321
	v9.reputation = 2.75
	v9.stock.tomato.amount = 77
	v9.stock.tomato.unlocked = true
	v9.stock.potato.amount = 64
	v9.menu.margherita = {"active": false, "unlocked": true, "price": 37, "sold_out": true}
	v9.employees[0].id = "legacy_employee"
	v9.settings.graphics_quality = "high"
	v9.layout.append({"uid": "legacy_custom_object", "item": "plant", "cell": [6, 6], "rotation": 2})
	# Not part of official v9 serialization, but preserve it if a pre-release
	# save already carried the future batch payload.
	v9.pending_delivery_batch = {
		"id": "legacy_batch",
		"items": {"tomato": {"amount": 5, "unit_cost": 2.0}},
		"remaining": 123.0,
		"paid": true
	}

	GameState.deserialize(v9)
	var starter := DataRegistry.album_starter_inventory()
	_expect(GameState.money == 4321 and is_equal_approx(GameState.reputation, 2.75), "v9 migration preserves money and reputation")
	_expect(int(GameState.stock.tomato.amount) == 77 and int(GameState.stock.potato.amount) == 64, "v9 migration preserves physical stock exactly")
	_expect(int(GameState.stock.tomato.reserved) == 0, "v9 migration initializes runtime reservation to zero")
	var tomato_storage := DataRegistry.storage_metadata_for_ingredient("tomato")
	_expect(
		String(GameState.stock.tomato.storage_type) == String(tomato_storage.storage_type)
		and int(GameState.stock.tomato.storage_units) == int(tomato_storage.storage_units),
		"v9 migration adds authoritative storage metadata"
	)
	_expect(not bool(GameState.menu.margherita.active) and bool(GameState.menu.margherita.unlocked) and int(GameState.menu.margherita.price) == 37, "v9 migration preserves menu active, unlocked and price")
	_expect(bool(GameState.menu.margherita.manual_paused) and not bool(GameState.menu.margherita.auto_sold_out) and bool(GameState.menu.margherita.sold_out), "legacy sold_out becomes manual pause only")
	_expect(String(GameState.employees[0].id) == "legacy_employee" and String(GameState.settings.graphics_quality) == "high", "v9 migration preserves staff and settings")
	_expect(GameState.layout.any(func(record: Dictionary): return String(record.get("uid", "")) == "legacy_custom_object"), "v9 migration preserves layout UIDs")
	_expect(int(GameState.album_inventory.tomato) == int(starter.get("tomato", 0)) and int(GameState.album_inventory.potato) == int(starter.get("potato", 0)), "album migration uses only configured starter quantities")
	_expect(int(GameState.album_inventory.tomato) != int(GameState.stock.tomato.amount), "album quantities are never copied from physical stock")
	_expect(bool(GameState.album_discovered.tomato), "legacy unlocked ingredients remain discovered")
	_expect(String(GameState.pending_delivery_batch.id) == "legacy_batch" and int(GameState.pending_delivery_batch.items.tomato.amount) == 5 and is_equal_approx(float(GameState.pending_delivery_batch.remaining), 123.0), "an existing pending batch survives v9 migration")


func _test_current_schema_round_trip() -> void:
	GameState.album_inventory.tomato = 9
	GameState.album_discovered.ice_vanilla = true
	GameState.reviews = [{"id": "review_roundtrip", "stars": 5}]
	GameState.review_reward_progress = 4
	GameState.reputation_weight = 12.5
	GameState.world_clock = {"day": 7, "minute": 1215.5}
	GameState.restaurant_profile = {
		"player_name": "Ada",
		"restaurant_name": "Bistrot Test",
		"avatar_appearance": "Chef_Female",
		"badge_id": "starter",
		"uniform_variant": 2
	}
	GameState.pending_delivery_batch = {
		"id": "batch_roundtrip",
		"items": {"cheese": {"amount": 12, "unit_cost": 3.25}},
		"remaining": 184.0,
		"paid": true
	}
	GameState.cleanliness_state = {"score": 72.0, "dirty_tables": 2}
	GameState.pest_state = {"warning": true, "active": ["insects"], "last_spawn_day": 6}
	GameState.staff_preferences = {"legacy_employee": "kitchen"}
	GameState.stock.tomato.reserved = 99

	var serialized: Dictionary = JSON.parse_string(JSON.stringify(GameState.serialize()))
	_expect(int(serialized.save_version) == GameState.SAVE_VERSION, "new saves use the current schema version")
	_expect(int(serialized.stock.tomato.reserved) == 0, "runtime reservations are not persisted")
	GameState.reset_to_defaults(false)
	GameState.deserialize(serialized)
	_expect(int(GameState.album_inventory.tomato) == 9 and bool(GameState.album_discovered.ice_vanilla), "album state survives a current-schema round-trip")
	_expect(GameState.reviews.size() == 1 and String(GameState.reviews[0].id) == "review_roundtrip" and GameState.review_reward_progress == 4, "reviews and reward progress survive a current-schema round-trip")
	_expect(
		is_equal_approx(GameState.reputation_weight, 12.5)
			and int(GameState.world_clock.day) == 7
			and is_equal_approx(float(GameState.world_clock.minute), 1215.5),
		"reputation weight and world clock survive a current-schema round-trip (weight=%.3f, day=%d, minute=%.3f)"
			% [GameState.reputation_weight, int(GameState.world_clock.day), float(GameState.world_clock.minute)]
	)
	_expect(String(GameState.restaurant_profile.player_name) == "Ada" and String(GameState.restaurant_profile.restaurant_name) == "Bistrot Test", "restaurant profile survives a current-schema round-trip")
	_expect(String(GameState.pending_delivery_batch.id) == "batch_roundtrip" and int(GameState.pending_delivery_batch.items.cheese.amount) == 12, "pending delivery batch survives a current-schema round-trip")
	_expect(is_equal_approx(float(GameState.cleanliness_state.score), 72.0) and bool(GameState.pest_state.warning), "cleanliness and pest state survive a current-schema round-trip")
	_expect(String(GameState.staff_preferences.legacy_employee) == "kitchen", "staff preferences survive a current-schema round-trip")
	_expect(int(GameState.stock.tomato.reserved) == 0, "runtime reservations are forcibly reset when loading the current schema")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
