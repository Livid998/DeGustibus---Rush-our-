extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	SaveManager.writes_enabled = false
	var original_state := GameState.serialize().duplicate(true)
	GameState.reset_to_defaults(false)

	_test_explicit_costs()
	_test_atomic_unlock()
	_test_seeded_rewards_and_pity()

	GameState.deserialize(original_state)
	var result := "ALBUM UNLOCK: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/album-unlock-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_explicit_costs() -> void:
	var all_explicit := true
	var all_valid := true
	for recipe: Dictionary in DataRegistry.recipes:
		var cost: Dictionary = recipe.get("unlock_cost", {})
		all_explicit = all_explicit and not cost.is_empty()
		for ingredient_id: String in cost:
			all_valid = all_valid and DataRegistry.ingredients_by_id.has(ingredient_id) and int(cost[ingredient_id]) > 0
	_expect(all_explicit, "ogni ricetta dichiara un costo album esplicito")
	_expect(all_valid, "ogni costo ricetta usa ingredienti validi e quantità positive")


func _test_atomic_unlock() -> void:
	var recipe_id := "pepperoni_pizza"
	var recipe: Dictionary = DataRegistry.recipes_by_id[recipe_id]
	var cost: Dictionary = recipe.unlock_cost
	GameState.set_recipe_unlocked(recipe_id, false)
	for ingredient_id: String in cost:
		GameState.set_album_ingredient_amount(ingredient_id, int(cost[ingredient_id]))
	var missing_id := String(cost.keys()[0])
	GameState.set_album_ingredient_amount(missing_id, int(cost[missing_id]) - 1)
	var album_before_failure := GameState.album_inventory.duplicate(true)
	var stock_before_failure := GameState.stock.duplicate(true)
	_expect(not CollectionManager.unlock_recipe(recipe_id), "lo sblocco fallisce se manca anche un solo ingrediente")
	_expect(GameState.album_inventory == album_before_failure, "uno sblocco fallito non muta nessuna quantità album")
	_expect(GameState.stock == stock_before_failure, "uno sblocco fallito non tocca lo stock fisico")

	for ingredient_id: String in cost:
		GameState.set_album_ingredient_amount(ingredient_id, int(cost[ingredient_id]))
	var exact_before: Dictionary = {}
	for ingredient_id: String in cost:
		exact_before[ingredient_id] = int(GameState.album_inventory[ingredient_id])
	var stock_before_success := GameState.stock.duplicate(true)
	_expect(CollectionManager.unlock_recipe(recipe_id), "il costo completo impara la ricetta")
	var exact_subtraction := true
	for ingredient_id: String in cost:
		exact_subtraction = exact_subtraction and int(GameState.album_inventory[ingredient_id]) == int(exact_before[ingredient_id]) - int(cost[ingredient_id])
	_expect(exact_subtraction, "lo sblocco sottrae esattamente il costo album configurato")
	_expect(bool(GameState.menu[recipe_id].unlocked), "la ricetta resta marcata come imparata")
	_expect(GameState.stock == stock_before_success, "imparare una ricetta non consuma mai stock fisico")

	for ingredient_id: String in cost:
		GameState.add_album_ingredient(ingredient_id, 2)
	var album_before_double := GameState.album_inventory.duplicate(true)
	_expect(not CollectionManager.unlock_recipe(recipe_id), "una ricetta già imparata non può essere pagata due volte")
	_expect(GameState.album_inventory == album_before_double, "il doppio sblocco non addebita ingredienti album")

	var tomato_stock_before := int(GameState.stock.tomato.amount)
	GameState.set_album_ingredient_amount("tomato", 7)
	_expect(int(GameState.album_inventory.tomato) == 7 and int(GameState.stock.tomato.amount) == tomato_stock_before, "album e stock sono inventari indipendenti")
	_expect(CollectionManager.debug_add("tomato", 2) and CollectionManager.debug_remove("tomato", 1) and int(GameState.album_inventory.tomato) == 8, "i comandi debug aggiungono e rimuovono soltanto dall'album")


func _test_seeded_rewards_and_pity() -> void:
	_reset_reward_state()
	CollectionManager.set_reward_seed(20260717)
	var first := CollectionManager.grant_weighted_reward("seed_test")
	_reset_reward_state()
	CollectionManager.set_reward_seed(20260717)
	var second := CollectionManager.grant_weighted_reward("seed_test")
	_expect(not first.is_empty() and first == second, "lo stesso seed produce lo stesso premio pesato")

	_reset_reward_state()
	var useful_before := CollectionManager.needed_album_ingredients()
	var pity_interval := maxi(int(DataRegistry.balance_value("album.pity_interval", 4)), 1)
	CollectionManager.set_reward_seed(77, pity_interval - 1)
	var pity_reward := CollectionManager.grant_weighted_reward("pity_test")
	_expect(bool(pity_reward.get("pity_forced", false)), "la soglia pity forza un premio utile")
	_expect(useful_before.has(String(pity_reward.get("ingredient_id", ""))), "il premio pity è necessario a una ricetta scoperta ma bloccata")


func _reset_reward_state() -> void:
	for ingredient: Dictionary in DataRegistry.ingredients:
		GameState.set_album_ingredient_amount(String(ingredient.id), 0)
		GameState.set_album_discovered(String(ingredient.id), false)
	for recipe: Dictionary in DataRegistry.recipes:
		GameState.set_recipe_unlocked(String(recipe.id), bool(recipe.get("unlocked", false)))


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
