extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	SaveManager.writes_enabled = false
	var original_state := GameState.serialize().duplicate(true)
	GameState.reset_to_defaults(false)

	_test_explicit_costs()
	_test_atomic_unlock()
	_test_ingredient_unlock_rules_and_purchase()
	_test_recipe_progression_authority()
	_test_progression_reachability()
	_test_market_preparation_whitelist_and_migration()
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


func _test_ingredient_unlock_rules_and_purchase() -> void:
	GameState.reset_to_defaults(false)
	_expect(DataRegistry.gameplay_balance_valid, "le regole di progressione superano la validazione dati")
	var all_structured := true
	for ingredient: Dictionary in DataRegistry.ingredients:
		if bool(ingredient.get("unlocked", false)):
			continue
		var rule := DataRegistry.ingredient_unlock_rule(ingredient)
		all_structured = all_structured and DataRegistry.INGREDIENT_UNLOCK_RULE_TYPES.has(String(rule.get("type", "")))
	_expect(all_structured, "ogni ingrediente non iniziale ha una regola di sblocco strutturata")

	for ingredient_id: String in ["milk", "pepperoni"]:
		var definition: Dictionary = DataRegistry.ingredients_by_id[ingredient_id]
		var rule := DataRegistry.ingredient_unlock_rule(definition)
		var cost := int(rule.get("cost", 0))
		_expect(String(rule.get("type", "")) == "album_purchase" and cost == (250 if ingredient_id == "milk" else 350), "%s ha il corretto acquisto Album" % ingredient_id)
		GameState.stock[ingredient_id].unlocked = false
		GameState.money = cost - 1
		var state_before := GameState.serialize().duplicate(true)
		_expect(not GameState.purchase_ingredient_unlock(ingredient_id), "%s non viene sbloccato senza fondi" % ingredient_id)
		_expect(GameState.money == int(state_before.money) and GameState.stock[ingredient_id] == state_before.stock[ingredient_id], "l'acquisto fallito di %s e atomico" % ingredient_id)
		GameState.money = cost
		_expect(GameState.purchase_ingredient_unlock(ingredient_id), "%s e acquistabile dall'Album live" % ingredient_id)
		_expect(GameState.money == 0 and bool(GameState.stock[ingredient_id].unlocked) and bool(GameState.album_discovered[ingredient_id]), "l'acquisto di %s addebita una volta e persiste lo sblocco" % ingredient_id)
		_expect(not GameState.purchase_ingredient_unlock(ingredient_id) and GameState.money == 0, "%s non puo essere acquistato due volte" % ingredient_id)


func _test_recipe_progression_authority() -> void:
	GameState.reset_to_defaults(false)
	GameState.menu.pepperoni_pizza.unlocked = false
	GameState.stock.pepperoni.unlocked = false
	_expect(CollectionManager.sync_recipe_unlocks().is_empty(), "una ricetta resta bloccata finche manca il suo ingrediente fisico")
	GameState.stock.pepperoni.unlocked = true
	var granted := CollectionManager.sync_recipe_unlocks()
	_expect(granted.has("pepperoni_pizza") and bool(GameState.menu.pepperoni_pizza.unlocked), "CollectionManager applica i requisiti ricetta dichiarati nei dati")
	GameState.stock.pepperoni.unlocked = false
	CollectionManager.sync_recipe_unlocks()
	_expect(bool(GameState.menu.pepperoni_pizza.unlocked), "la sincronizzazione non revoca ricette gia sbloccate nei salvataggi")

	GameState.stock.veg_patty.unlocked = false
	GameState.progress.customers_served = 24
	_expect(not GameState.check_progression(false).has("veg_patty"), "il progresso strutturato non anticipa la soglia")
	GameState.progress.customers_served = 25
	_expect(GameState.check_progression(false).has("veg_patty"), "il progresso strutturato sblocca alla soglia dichiarata")


func _test_progression_reachability() -> void:
	GameState.reset_to_defaults(false)
	GameState.money = 250
	_expect(GameState.purchase_ingredient_unlock("milk"), "il ramo dessert puo iniziare acquistando il latte")
	# The focused M2 starter kitchen intentionally has no dessert equipment.
	# Build both tabletop machines here so this progression fixture still reaches
	# the authoritative `build_count: 2` rule without relying on an old layout.
	GameState.layout.append({"uid":"reachability_dessert_1", "item":"dessert", "cell":[14, 11], "rotation":2})
	GameState.layout.append({"uid":"reachability_dessert_2", "item":"dessert", "cell":[15, 11], "rotation":2})
	var first_unlocks := GameState.check_progression(false)
	_expect(first_unlocks.has("ice_vanilla") and bool(GameState.menu.icecream_cone.unlocked), "la seconda gelatiera rende raggiungibile il primo dessert senza dipendenze circolari")
	GameState.reputation = 3.0
	GameState.progress.desserts_served = 10
	var later_unlocks := GameState.check_progression(false)
	_expect(later_unlocks.has("ice_chocolate") and later_unlocks.has("ice_strawberry"), "reputazione e dessert completano gli ingredienti avanzati")
	_expect(bool(GameState.menu.mixed_sundae.unlocked), "la coppa mista diventa raggiungibile tramite sole regole pubbliche")


func _test_market_preparation_whitelist_and_migration() -> void:
	var expected: Array[String] = ["bun_split", "cheese_grated", "dough_base", "potato_cut", "tomato_sauce"]
	_expect(DataRegistry.market_preparation_ids() == expected, "il mercato espone soltanto i cinque semilavorati consumabili")
	var all_consumed := true
	for preparation_id: String in DataRegistry.market_preparation_ids():
		all_consumed = all_consumed and not DataRegistry.preparation_consumers(preparation_id).is_empty()
	_expect(all_consumed, "ogni semilavorato vendibile sostituisce almeno una fase preppable")
	_expect(not DataRegistry.is_market_preparation("tomato_slices") and not DataRegistry.is_market_preparation("burger_cooked"), "i semilavorati non consumati sono rifiutati")

	var sanitized := DataRegistry.sanitize_purchased_preparations({"dough_base": 3, "tomato_slices": 2, "burger_cooked": 1}, true)
	_expect(sanitized.kept == {"dough_base": 3}, "la migrazione conserva le preparazioni utilizzabili")
	_expect(sanitized.removed == {"tomato_slices": 2, "burger_cooked": 1}, "la migrazione identifica tutte le preparazioni legacy")
	_expect(int(sanitized.refund) == 15, "la migrazione calcola il rimborso pieno ai prezzi di acquisto")

	var legacy := GameState.serialize().duplicate(true)
	legacy.save_version = 11
	legacy.money = 100
	legacy.purchased_preparations = {"dough_base": 3, "tomato_slices": 2, "burger_cooked": 1}
	GameState.deserialize(legacy)
	_expect(GameState.purchased_preparations == {"dough_base": 3} and GameState.money == 115, "il caricamento v11 rimborsa e rimuove i semilavorati inutilizzabili")
	_expect(int(GameState.serialize().save_version) == 12, "il salvataggio migrato viene serializzato come v12")


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

	CollectionManager.set_reward_seed(19, 3)
	var saved := GameState.serialize().duplicate(true)
	CollectionManager.set_reward_seed(19, 0)
	GameState.deserialize(saved)
	_expect(
		CollectionManager.reward_pity_progress() == 3,
		"il progresso pity sopravvive al round-trip del salvataggio"
	)


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
