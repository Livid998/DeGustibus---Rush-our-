extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	SaveManager.writes_enabled = false
	var original_state := GameState.serialize().duplicate(true)
	var original_orders := SimulationManager.orders.duplicate(true)
	var original_stats := SimulationManager.stats.duplicate(true)
	GameState.reset_to_defaults(false)
	GameState.money = 1000
	GameState.set_reputation_value(3.0)
	GameState.reviews.clear()
	GameState.review_reward_progress = 0
	SimulationManager.orders.clear()
	SimulationManager.reset_service_stats()

	var customer := Node.new()
	customer.name = "RuntimeReviewCustomer"
	add_child(customer)
	var experience := SimulationManager.begin_group_experience("runtime_paid_group", {
		"customer_type": "famiglia",
		"stage": "paying",
	})
	SimulationManager.record_group_wait(experience, "order", 4.0)
	SimulationManager.record_group_wait(experience, "food", 7.0)
	SimulationManager.record_group_wait(experience, "bill", 3.0)
	SimulationManager.record_group_food_quality(experience, 96.0)
	SimulationManager.record_group_service(experience, 92.0)
	_add_order("runtime_a", "margherita", 24, customer, experience)
	_add_order("runtime_b", "classic_burger", 22, customer, experience)

	var money_before := GameState.money
	var reputation_before := GameState.reputation
	var completion := SimulationManager.complete_group_payment(
		customer,
		experience,
		["runtime_a", "runtime_b"]
	)
	var review: Dictionary = completion.get("review", {})
	var expected_income := 46 + int(review.get("tip", 0))
	_expect(bool(completion.get("accepted", false)), "il pagamento gruppo produce una recensione accettata")
	_expect(GameState.reviews.size() == 1, "due ordini dello stesso gruppo producono una sola recensione")
	_expect(String(SimulationManager.orders.runtime_a.state) == "paid" and String(SimulationManager.orders.runtime_b.state) == "paid", "tutti gli ordini del gruppo diventano pagati insieme")
	_expect(GameState.money == money_before + expected_income, "il conto accredita una volta il totale e una sola mancia aggregata")
	_expect(int(SimulationManager.stats.revenue) == expected_income, "le statistiche ricavo coincidono col pagamento aggregato")
	_expect(int(SimulationManager.stats.customers_served) == 2, "i contatori ricetta restano per singolo coperto")
	_expect(GameState.reputation > reputation_before, "una recensione positiva aumenta lentamente la reputazione")

	var repeat_money := GameState.money
	var repeat := SimulationManager.complete_group_payment(
		customer,
		experience,
		["runtime_a", "runtime_b"]
	)
	_expect(not bool(repeat.get("accepted", false)) and String(repeat.get("reason", "")) == "already_paid", "un pagamento ripetuto viene rifiutato in modo idempotente")
	_expect(GameState.money == repeat_money and GameState.reviews.size() == 1, "il retry non duplica denaro, mancia o recensione")

	var negative := SimulationManager.begin_group_experience("runtime_abandoned_group", {
		"customer_type": "studente",
		"stage": "ordered",
	})
	SimulationManager.record_group_wait(negative, "food", 180.0)
	var reputation_after_positive := GameState.reputation
	var abandoned := SimulationManager.complete_group_abandonment(negative, "abandoned")
	_expect(bool(abandoned.get("accepted", false)) and GameState.reviews.size() == 2, "un gruppo che abbandona dopo l'ordine lascia una recensione negativa")
	_expect(GameState.reputation < reputation_after_positive, "la reputazione puo anche diminuire tramite recensioni")

	customer.queue_free()
	SimulationManager.orders = original_orders
	SimulationManager.stats = original_stats
	GameState.deserialize(original_state)
	var result := "REVIEW RUNTIME: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	get_tree().quit(0 if failures.is_empty() else 1)


func _add_order(
	order_id: String,
	recipe_id: String,
	price: int,
	customer: Node,
	experience: Dictionary
) -> void:
	var recipe: Dictionary = DataRegistry.recipes_by_id[recipe_id]
	SimulationManager.add_group_recipe(experience, recipe_id)
	SimulationManager.orders[order_id] = {
		"id": order_id,
		"recipe_id": recipe_id,
		"recipe_name": String(recipe.name),
		"price": price,
		"customer": customer,
		"state": "at_pass",
		"created_at": 0.0,
		"reservation": {},
	}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
