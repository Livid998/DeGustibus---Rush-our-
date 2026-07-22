extends Node

var checks := 0
var failures: Array[String] = []
var _original_state: Dictionary
var _economy_was_processing := true


func _ready() -> void:
	SaveManager.writes_enabled = false
	_original_state = GameState.serialize().duplicate(true)
	_economy_was_processing = EconomyManager.is_processing()
	EconomyManager.set_process(false)

	_test_capacity_and_overflow()
	_test_aggregate_batches()
	_test_partial_delivery_disposal_and_cancellation()
	_test_auto_reorder_capacity_clamp()
	_test_storage_removal_guard_and_recovery()
	_test_reservation_race_and_release()
	_test_auto_sold_out_recovery()
	_test_change_order()

	SimulationManager.reset_service_stats()
	StorageManager.reset_runtime_reservations()
	GameState.deserialize(_original_state)
	EconomyManager.clear_delivery_cart()
	EconomyManager.set_process(_economy_was_processing)
	var result := "STORAGE DELIVERY RESERVATION: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("user://storage-delivery-reservation-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_capacity_and_overflow() -> void:
	_reset_test_state()
	_expect(StorageManager.capacity_for("ambient") == 200, "lo scaffale iniziale fornisce 200 unità ambiente")
	_expect(StorageManager.capacity_for("refrigerated") == 240, "il frigorifero iniziale fornisce 240 unità refrigerate")
	_expect(not StorageManager.is_overflowing("ambient") and not StorageManager.is_overflowing("refrigerated"), "lo stock iniziale rientra nelle due capacità")

	GameState.layout.append({"uid":"test_crate", "item":"storage_crate", "cell":[1, 1], "rotation":0})
	StorageManager.recalculate_layout_capacity()
	_expect(StorageManager.capacity_for("ambient") == 280, "la cassa aggiunge la capacità ambiente configurata dal catalogo")
	GameState.layout.pop_back()
	StorageManager.recalculate_layout_capacity()

	var preserved := StorageManager.capacity_for("ambient") + 1
	GameState.stock.tomato.amount = preserved
	StorageManager.recalculate_usage()
	var money_before := GameState.money
	_expect(StorageManager.is_overflowing("ambient") and int(GameState.stock.tomato.amount) == preserved, "l'overflow conserva integralmente lo stock già posseduto")
	_expect(not EconomyManager.order_stock("potato", 1, false), "l'overflow blocca nuovi acquisti dello stesso tipo")
	_expect(GameState.money == money_before and EconomyManager.normal_batch_snapshot().items.is_empty(), "un acquisto bloccato non addebita denaro e non muta il batch")


func _test_aggregate_batches() -> void:
	_reset_test_state()
	_set_all_stock(0)
	var money_before := GameState.money
	_expect(EconomyManager.add_to_delivery_cart("tomato", 10) and EconomyManager.add_to_delivery_cart("cheese", 5), "il carrello aggrega ingredienti diversi")
	var preview := EconomyManager.delivery_preview({}, false)
	_expect(bool(preview.capacity_valid) and int(preview.forecast.ambient) == 10 and int(preview.forecast.refrigerated) == 5, "la previsione include unità e tipo di conservazione all'arrivo")
	_expect(EconomyManager.confirm_delivery_cart(false), "il carrello normale viene confermato")
	var paid_once := money_before - GameState.money
	_expect(paid_once == int(preview.cost) and paid_once > 0, "il pagamento avviene una sola volta alla conferma")

	EconomyManager.add_to_delivery_cart("tomato", 3)
	_expect(EconomyManager.confirm_delivery_cart(false), "un secondo riordino confluisce nel batch aperto")
	var normal := EconomyManager.normal_batch_snapshot()
	_expect(normal.items.size() == 2 and int(normal.items.tomato.amount) == 13, "il merge non crea righe duplicate per lo stesso ingrediente")
	EconomyManager.advance_delivery_time(149.0, 2.0)
	_expect(int(GameState.stock.tomato.amount) == 0 and is_equal_approx(float(EconomyManager.normal_batch_snapshot().remaining), 2.0), "la velocità 2x accelera il countdown senza consegna anticipata")
	EconomyManager.advance_delivery_time(1.0, 2.0)
	_expect(int(GameState.stock.tomato.amount) == 13 and int(GameState.stock.cheese.amount) == 5, "il batch consegna tutti gli articoli insieme a 300 secondi")
	_expect(EconomyManager.normal_batch_snapshot().items.is_empty() and is_equal_approx(float(EconomyManager.normal_batch_snapshot().remaining), 300.0), "dopo l'arrivo il countdown globale riparte")

	var urgent_money_before := GameState.money
	EconomyManager.add_to_delivery_cart("potato", 4)
	var urgent_preview := EconomyManager.delivery_preview({}, true)
	_expect(EconomyManager.confirm_delivery_cart(true), "il batch urgente viene confermato separatamente")
	_expect(urgent_money_before - GameState.money == int(urgent_preview.cost) and int(urgent_preview.cost) > int(ceil(4.0 * float(DataRegistry.ingredients_by_id.potato.cost))), "l'urgenza applica un sovrapprezzo coerente")
	_expect(EconomyManager.normal_batch_snapshot().items.is_empty() and int(EconomyManager.urgent_batch_snapshot().items.potato.amount) == 4, "l'urgenza non contamina il batch normale")
	EconomyManager.advance_delivery_time(29.0)
	_expect(int(GameState.stock.potato.amount) == 0 and is_equal_approx(float(EconomyManager.urgent_batch_snapshot().remaining), 1.0), "la consegna urgente attende 30 secondi")

	var persisted := GameState.serialize().duplicate(true)
	GameState.deserialize(persisted)
	_expect(int(EconomyManager.urgent_batch_snapshot().items.potato.amount) == 4, "il batch urgente sopravvive al round-trip del salvataggio")
	EconomyManager.advance_delivery_time(1.0)
	_expect(int(GameState.stock.potato.amount) == 4 and EconomyManager.urgent_batch_snapshot().items.is_empty(), "l'urgenza arriva interamente e si chiude")


func _test_partial_delivery_disposal_and_cancellation() -> void:
	_reset_test_state()
	_set_all_stock(0)
	GameState.stock.tomato.amount = StorageManager.capacity_for("ambient") - 2
	StorageManager.recalculate_usage()
	_expect(StorageManager.max_orderable_amount("potato") == 2, "la quantita massima ordinabile usa stock e consegne pendenti")
	EconomyManager.add_to_delivery_cart("potato", 5)
	var preview := EconomyManager.delivery_preview({}, false)
	_expect(int(preview.accepted_items.potato) == 2 and int(preview.rejected_items.potato) == 3, "il planner divide il carrello nella parte accettata e rifiutata")
	var money_before := GameState.money
	_expect(EconomyManager.confirm_delivery_cart(false), "un carrello parzialmente compatibile viene confermato")
	var paid := money_before - GameState.money
	_expect(int(EconomyManager.normal_batch_snapshot().items.potato.amount) == 2 and int(EconomyManager.delivery_cart_snapshot().potato) == 3, "solo la parte accettata entra nel batch e il residuo resta modificabile")
	_expect(paid == int(ceil(float(DataRegistry.ingredients_by_id.potato.cost) * 2.0)), "la conferma addebita esclusivamente gli articoli accettati")

	var cancellation := EconomyManager.cancel_pending_batch("normal")
	_expect(bool(cancellation.success) and int(cancellation.refund) == int(floor(float(paid) * 0.8)), "l'annullamento standard rimborsa esattamente l'80 percento")
	_expect(EconomyManager.normal_batch_snapshot().items.is_empty(), "il batch annullato non rimane nella previsione di capacita")

	GameState.stock.tomato.amount = 10
	GameState.stock.tomato.reserved = 3
	GameState.stock.tomato.average_cost = 5.0
	StorageManager.recalculate_usage()
	var discard_money_before := GameState.money
	var disposal := EconomyManager.discard_stock("tomato", 99)
	_expect(bool(disposal.success) and int(disposal.amount) == 7 and int(GameState.stock.tomato.amount) == 3, "lo smaltimento non puo consumare le unita riservate")
	_expect(GameState.money - discard_money_before == 7, "lo smaltimento restituisce il 20 percento del costo medio")


func _test_auto_reorder_capacity_clamp() -> void:
	_reset_test_state()
	_set_all_stock(0)
	GameState.stock.tomato.amount = StorageManager.capacity_for("ambient") - 1
	GameState.stock.potato.amount = 0
	GameState.stock.potato.threshold = 0
	GameState.stock.potato.target = 10
	GameState.stock.potato.auto_reorder = true
	StorageManager.recalculate_usage()
	EconomyManager._check_auto_reorders()
	_expect(int(EconomyManager.normal_batch_snapshot().items.potato.amount) == 1, "il riordino automatico viene limitato allo spazio realmente disponibile")
	var money_after_first := GameState.money
	EconomyManager._check_auto_reorders()
	_expect(GameState.money == money_after_first and int(EconomyManager.normal_batch_snapshot().items.potato.amount) == 1, "un riordino saturo non ripete addebiti o batch")


func _test_storage_removal_guard_and_recovery() -> void:
	_reset_test_state()
	var fridge_guard := StorageManager.can_remove_storage_item("fridge_1")
	var pantry_guard := StorageManager.can_remove_storage_item("storage_1")
	_expect(not bool(fridge_guard.valid) and fridge_guard.blocked_types.has("refrigerated"), "la guardia impedisce di rimuovere il frigorifero sotto stock o consegne")
	_expect(not bool(pantry_guard.valid) and pantry_guard.blocked_types.has("ambient"), "la guardia impedisce di rimuovere l'ultimo deposito ambiente")

	_set_all_stock(0)
	GameState.stock.potato.amount = StorageManager.capacity_for("ambient")
	GameState.progress.emergency_recovery_used = false
	StorageManager.recalculate_usage()
	var audit := StorageManager.soft_lock_snapshot()
	_expect(bool(audit.soft_locked) and bool(audit.recovery_available), "l'audit rileva un save pieno senza alcuna ricetta producibile o ordinabile")
	var plan: Dictionary = audit.recovery_plan
	_expect(not String(plan.recipe_id).is_empty() and not plan.grant_items.is_empty() and not plan.discard_items.is_empty(), "il recupero propone una ricetta e lo smaltimento minimo necessario")
	var recovered := EconomyManager.apply_recovery_plan()
	_expect(bool(recovered.success) and StorageManager.is_recipe_producible(String(recovered.recipe_id)), "il recupero atomico garantisce una porzione producibile")
	_expect(bool(GameState.progress.emergency_recovery_used) and not bool(EconomyManager.apply_recovery_plan().success), "il grant di emergenza e disponibile una sola volta per salvataggio")


func _test_reservation_race_and_release() -> void:
	_reset_test_state()
	_set_all_stock(0)
	GameState.stock.tomato.amount = 2
	GameState.stock.cheese.amount = 1
	GameState.stock.dough.amount = 1
	StorageManager.recalculate_usage()
	var requirements := DataRegistry.recipe_raw_requirements("margherita")
	_expect(int(requirements.tomato) == 2 and int(requirements.cheese) == 1 and int(requirements.dough) == 1, "i requisiti aggregano tutti gli input grezzi della ricetta")
	_expect(StorageManager.reserve_for_order("race_a", requirements), "la prima prenotazione atomica riesce")
	_expect(not StorageManager.reserve_for_order("race_b", requirements), "una prenotazione concorrente non usa unità già riservate")
	_expect(int(GameState.stock.tomato.reserved) == 2 and StorageManager.available_amount("tomato") == 0, "stock.reserved alimenta la disponibilità reale")

	_expect(StorageManager.consume_reserved("race_a", {"tomato": 1}), "il consumo graduale usa il ledger dell'ordine")
	_expect(int(GameState.stock.tomato.amount) == 1 and int(GameState.stock.tomato.reserved) == 1, "consumo e riserva diminuiscono esattamente una volta")
	var released := StorageManager.release_order("race_a")
	_expect(int(released.consumed.tomato) == 1 and int(GameState.stock.tomato.amount) == 1 and int(GameState.stock.tomato.reserved) == 0, "la cancellazione rilascia solo il non consumato")
	_expect(StorageManager.reservation_count() == 0, "il ledger viene chiuso senza prenotazioni fantasma")


func _test_auto_sold_out_recovery() -> void:
	_reset_test_state()
	_set_all_stock(0)
	GameState.stock.tomato.amount = 2
	GameState.stock.cheese.amount = 1
	GameState.stock.dough.amount = 1
	GameState.set_recipe_unlocked("margherita", true)
	GameState.set_recipe_active("margherita", true)
	GameState.set_recipe_manual_paused("margherita", false)
	StorageManager.refresh_auto_sold_out()
	_expect(not bool(GameState.menu.margherita.auto_sold_out), "una porzione libera mantiene la ricetta disponibile")
	StorageManager.reserve_recipe_for_order("sold_out_probe", "margherita")
	_expect(bool(GameState.menu.margherita.auto_sold_out), "la prenotazione dell'ultima porzione attiva l'esaurimento automatico")
	StorageManager.release_order("sold_out_probe")
	_expect(not bool(GameState.menu.margherita.auto_sold_out), "il rilascio riattiva automaticamente la ricetta")

	_set_all_stock(0)
	StorageManager.refresh_auto_sold_out()
	_expect(bool(GameState.menu.margherita.auto_sold_out), "senza stock libero la ricetta risulta automaticamente esaurita")
	EconomyManager.add_to_delivery_cart("tomato", 2)
	EconomyManager.add_to_delivery_cart("cheese", 1)
	EconomyManager.add_to_delivery_cart("dough", 1)
	_expect(EconomyManager.confirm_delivery_cart(true), "una consegna urgente può ripristinare gli ingredienti mancanti")
	EconomyManager.advance_delivery_time(30.0)
	_expect(not bool(GameState.menu.margherita.auto_sold_out), "l'arrivo della consegna riattiva la ricetta senza intervento manuale")


func _test_change_order() -> void:
	_reset_test_state()
	_set_all_stock(0)
	GameState.stock.tomato.amount = 2
	GameState.stock.cheese.amount = 1
	GameState.stock.dough.amount = 1
	GameState.stock.bun.amount = 1
	GameState.stock.patty.amount = 1
	GameState.stock.lettuce.amount = 1
	GameState.set_recipe_unlocked("margherita", true)
	GameState.set_recipe_active("margherita", true)
	GameState.set_recipe_unlocked("classic_burger", true)
	GameState.set_recipe_active("classic_burger", true)
	StorageManager.refresh_auto_sold_out()
	var order := SimulationManager.create_order("margherita", "test_table", null)
	_expect(not order.is_empty() and StorageManager.reservation_count() == 1, "SimulationManager prenota prima di accettare l'ordine")
	_expect(SimulationManager.mark_order_unproducible(String(order.id), "test_failure"), "un guasto raro porta l'ordine nello stato change_order")
	var alternatives := SimulationManager.order_change_alternatives(String(order.id), 50)
	_expect(alternatives.any(func(recipe: Dictionary): return String(recipe.id) == "classic_burger"), "il cambio propone solo un'alternativa attiva, sbloccata, producibile e nel budget")
	var changed := SimulationManager.complete_order_change(String(order.id), "classic_burger", 5.0)
	_expect(not changed.is_empty() and String(changed.recipe_id) == "classic_burger" and String(changed.state) == "cooking", "la nuova scelta sostituisce atomicamente ricetta e prenotazione")
	_expect(changed.review_tags.has("sold_out_after_order") and float(changed.satisfaction_penalty) > 0.03, "il cambio registra tag recensione e penalità crescente")
	var new_reservation := StorageManager.reservation_for_order(String(order.id))
	_expect(new_reservation.original == DataRegistry.recipe_raw_requirements("classic_burger"), "il ledger contiene soltanto i requisiti della nuova ricetta")
	SimulationManager.cancel_order(String(order.id), "test_complete")
	_expect(StorageManager.reservation_count() == 0, "l'uscita/cancellazione dopo il cambio rilascia il residuo")


func _reset_test_state() -> void:
	SimulationManager.reset_service_stats()
	GameState.reset_to_defaults(false)
	GameState.money = 10000
	GameState.set_pending_delivery_batch({
		"id": "",
		"items": {},
		"remaining": float(DataRegistry.balance_value("delivery.batch_interval_seconds", 300.0)),
		"paid": false,
		"urgent": {
			"id": "",
			"items": {},
			"remaining": float(DataRegistry.balance_value("delivery.urgent_delivery_seconds", 30.0)),
			"paid": false
		}
	})
	GameState.deliveries.clear()
	EconomyManager.clear_delivery_cart()
	for ingredient_id: String in GameState.stock:
		GameState.stock[ingredient_id].auto_reorder = false
	StorageManager.reset_runtime_reservations()
	StorageManager.recalculate_layout_capacity()
	StorageManager.refresh_auto_sold_out()


func _set_all_stock(amount: int) -> void:
	for ingredient_id: String in GameState.stock:
		GameState.stock[ingredient_id].amount = maxi(amount, 0)
		GameState.stock[ingredient_id].reserved = 0
	StorageManager.reset_runtime_reservations()
	StorageManager.recalculate_usage()
	StorageManager.refresh_auto_sold_out()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
