extends Node

signal evaluated(snapshot: Dictionary)

const LOW_STOCK_SERVINGS := 4


func evaluate(world: Node) -> Dictionary:
	var blockers: Array[Dictionary] = []
	var warnings: Array[Dictionary] = []
	if world == null or not is_instance_valid(world):
		blockers.append(_issue(
			"world_unavailable",
			"La mappa del ristorante non e disponibile.",
			"Ristorante",
			"Torna alla mappa"
		))
		return _finish(blockers, warnings)

	var active_recipes := DataRegistry.active_recipes(GameState.menu)
	var producible_recipes: Array[Dictionary] = []
	if active_recipes.is_empty():
		blockers.append(_issue(
			"menu_empty",
			"Attiva almeno una ricetta nel menu.",
			"Menu",
			"Apri il menu"
		))
	else:
		for recipe: Dictionary in active_recipes:
			if _recipe_has_stock(recipe):
				producible_recipes.append(recipe)
		if producible_recipes.is_empty():
			blockers.append(_issue(
				"menu_not_producible",
				"Nessuna ricetta attiva ha ingredienti sufficienti per una porzione.",
				"Magazzino",
				"Controlla le scorte"
			))

	var seating: Dictionary = (
		world.call("opening_seating_snapshot")
		if world.has_method("opening_seating_snapshot")
		else {}
	)
	if int(seating.get("reachable_tables", 0)) <= 0 or int(seating.get("reachable_seats", 0)) <= 0:
		blockers.append(_issue(
			"seating_unreachable",
			"Serve almeno un tavolo raggiungibile con una sedia agganciata correttamente.",
			"builder",
			"Sistema sala e sedute",
			String((seating.get("unreachable_table_uids", []) as Array).front()) if not (seating.get("unreachable_table_uids", []) as Array).is_empty() else ""
		))

	var access: Dictionary = (
		world.call("opening_access_snapshot")
		if world.has_method("opening_access_snapshot")
		else {}
	)
	if not bool(access.get("entrance_present", false)):
		blockers.append(_issue(
			"entrance_missing",
			"Manca una porta sul punto di ingresso del ristorante.",
			"builder",
			"Aggiungi la porta"
		))
	elif not bool(access.get("entrance_reachable", false)) or not bool(access.get("exit_reachable", false)):
		blockers.append(_issue(
			"entrance_blocked",
			"Ingresso o uscita non sono collegati alla sala.",
			"builder",
			"Libera il percorso"
		))

	var roles := _employee_role_counts()
	if int(roles.get("cook", 0)) <= 0:
		blockers.append(_issue("cook_missing", "Assumi almeno un cuoco.", "Personale", "Apri il personale"))
	if int(roles.get("waiter", 0)) <= 0:
		blockers.append(_issue("waiter_missing", "Assumi almeno un cameriere.", "Personale", "Apri il personale"))
	if int(roles.get("handyman", 0)) <= 0:
		warnings.append(_issue(
			"handyman_missing",
			"Nessun tuttofare: pulizia e lavaggio possono rallentare il servizio.",
			"Personale",
			"Apri il personale"
		))

	var required_stations: Array[String] = []
	for recipe: Dictionary in active_recipes:
		for station_id: String in DataRegistry.required_station_ids(recipe):
			if not required_stations.has(station_id):
				required_stations.append(station_id)
	required_stations.sort()
	var station_snapshot: Dictionary = (
		world.call("opening_station_snapshot", required_stations)
		if world.has_method("opening_station_snapshot")
		else {}
	)
	var unventilated: Array = world.call("unventilated_heat_stations") if world.has_method("unventilated_heat_stations") else []
	var unventilated_station_ids: Dictionary = {}
	for station: Variant in unventilated:
		if station != null and is_instance_valid(station):
			unventilated_station_ids[String(station.get("station_id"))] = true
	for station_id: String in station_snapshot.get("missing", []):
		blockers.append(_station_issue("station_missing", station_id, "manca dal ristorante"))
	for station_id: String in station_snapshot.get("inoperative", []):
		if not unventilated_station_ids.has(station_id):
			blockers.append(_station_issue("station_inoperative", station_id, "non e operativa"))
	for station_id: String in station_snapshot.get("unreachable", []):
		blockers.append(_station_issue("station_unreachable", station_id, "non e raggiungibile"))

	for station: Variant in unventilated:
		if station == null or not is_instance_valid(station):
			continue
		var station_id := String(station.get("station_id"))
		var definition: Dictionary = station.get("definition")
		blockers.append(_issue(
			"ventilation_missing",
			"%s: manca una cappa aspirante." % String(definition.get("name", station_id)),
			"builder",
			"Aggiungi una cappa",
			String(station.get("uid"))
		))

	var maximum_servings := 0
	for recipe: Dictionary in producible_recipes:
		maximum_servings = maxi(maximum_servings, _recipe_available_servings(recipe))
	if not producible_recipes.is_empty() and maximum_servings < LOW_STOCK_SERVINGS:
		warnings.append(_issue(
			"low_stock",
			"Le scorte coprono solo %d coperti: valuta un riordino." % maximum_servings,
			"Magazzino",
			"Apri il magazzino"
		))

	return _finish(blockers, warnings, {
		"active_recipe_ids": active_recipes.map(func(recipe: Dictionary): return String(recipe.get("id", ""))),
		"producible_recipe_ids": producible_recipes.map(func(recipe: Dictionary): return String(recipe.get("id", ""))),
		"seating": seating,
		"access": access,
		"roles": roles,
		"stations": station_snapshot,
		"maximum_servings": maximum_servings,
	})


func _finish(blockers: Array[Dictionary], warnings: Array[Dictionary], context: Dictionary = {}) -> Dictionary:
	var result := {
		"ready": blockers.is_empty(),
		"blockers": blockers,
		"warnings": warnings,
		"context": context,
	}
	evaluated.emit(result.duplicate(true))
	return result


func _issue(id: String, message: String, action: String, label: String, entity_uid: String = "") -> Dictionary:
	var result := {
		"id": id,
		"message": message,
		"cta": {"action": action, "label": label},
	}
	if not entity_uid.is_empty():
		result.entity_uid = entity_uid
	return result


func _station_issue(prefix: String, station_id: String, suffix: String) -> Dictionary:
	var definition: Dictionary = DataRegistry.stations_by_id.get(station_id, {})
	return _issue(
		"%s:%s" % [prefix, station_id],
		"%s %s." % [String(definition.get("name", station_id.capitalize())), suffix],
		"builder",
		"Sistema la postazione"
	)


func _employee_role_counts() -> Dictionary:
	var result := {"cook": 0, "waiter": 0, "handyman": 0}
	for employee: Dictionary in GameState.employees:
		var role := String(employee.get("role", ""))
		if result.has(role):
			result[role] = int(result[role]) + 1
	return result


func _recipe_has_stock(recipe: Dictionary) -> bool:
	return _recipe_available_servings(recipe) > 0


func _recipe_available_servings(recipe: Dictionary) -> int:
	var requirements := DataRegistry.recipe_raw_requirements(recipe)
	if requirements.is_empty():
		return 999
	var servings := 999999
	for ingredient_id: String in requirements:
		var required := maxi(int(requirements[ingredient_id]), 1)
		var available := StorageManager.available_amount(ingredient_id)
		servings = mini(servings, floori(float(available) / float(required)))
	return maxi(servings, 0)
