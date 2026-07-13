extends Node3D

var session: SessionState
var order_manager: OrderManager
var world: WorldBuilder
var player: PlayerController
var ui: UIManager
var audio: ProceduralAudio
var rng := RandomNumberGenerator.new()
var customers_by_order := {}
var pending_interruptions: Array[Dictionary] = []
var interruption_index := 0
var interruption_times := [42.0, 92.0, 148.0, 205.0]
var interaction := {}
var system_timer := 0.0
var hud_timer := 0.0
var paused := false
var guidance_beacon: Node3D
var guidance_label: Label3D
var guidance_station_id := ""
var guidance_ring: MeshInstance3D
var staff_agents := {}
var onboarding_open := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	rng.seed = 18102026
	_setup_input()
	session = SessionState.new()
	add_child(session)
	session.reset_run()
	order_manager = OrderManager.new()
	add_child(order_manager)
	order_manager.setup(session)
	world = WorldBuilder.new()
	add_child(world)
	world.setup(self)
	_build_guidance_beacon()
	player = PlayerController.new()
	player.position = Vector3(-5.2, 0.05, -5.6)
	add_child(player)
	player.setup(self)
	player.set_mouse_sensitivity(float(session.settings.camera_sensitivity))
	player.set_camera_distance(float(session.settings.camera_distance))
	player.set_camera_fov(float(session.settings.camera_fov))
	_spawn_staff()
	audio = ProceduralAudio.new()
	add_child(audio)
	audio.setup(session.settings)
	ui = UIManager.new()
	add_child(ui)
	ui.setup(session)
	ui.process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_signals()
	ui.update_orders([])
	if "--smoke-test" in OS.get_cmdline_user_args() or OS.get_environment("DEGUSTIBUS_SMOKE") == "1":
		_run_smoke_test()
	elif not OS.get_environment("DEGUSTIBUS_CAPTURE").is_empty():
		_capture_preview.call_deferred()

func _connect_signals() -> void:
	ui.start_pressed.connect(_on_start_pressed)
	ui.prep_selected.connect(_on_prep_selected)
	ui.prep_finished.connect(_open_briefing)
	ui.briefing_confirmed.connect(_on_briefing_confirmed)
	ui.interruption_choice.connect(_resolve_interruption)
	ui.summary_continue.connect(_open_debrief)
	ui.debrief_choice.connect(_resolve_debrief)
	ui.restart_pressed.connect(_restart_run)
	ui.resume_pressed.connect(func(): _set_paused(false))
	ui.settings_changed.connect(_apply_settings)
	ui.tutorial_closed.connect(_on_tutorial_closed)
	player.focus_changed.connect(_on_focus_changed)
	player.interaction_cancelled.connect(_cancel_interaction)
	player.slapstick_requested.connect(_perform_slapstick)
	order_manager.orders_changed.connect(_refresh_orders_ui)
	order_manager.order_created.connect(_on_order_created)
	order_manager.order_failed.connect(_on_order_failed)
	for station in world.stations.values():
		station.processing_changed.connect(_on_station_processing_changed)

func _setup_input() -> void:
	for action in ["move_forward", "move_back", "move_left", "move_right", "sprint", "interact", "cancel", "slapstick", "pause"]:
		if not InputMap.has_action(action):
			InputMap.add_action(action)

func _process(delta: float) -> void:
	if paused:
		return
	if onboarding_open:
		return
	if session.phase == SessionState.Phase.PREP:
		session.prep_time_left = maxf(0.0, session.prep_time_left - delta)
		if session.prep_time_left <= 0.0:
			_open_briefing()
	elif session.phase == SessionState.Phase.SERVICE or session.phase == SessionState.Phase.BREAKDOWN:
		session.service_time_left = maxf(0.0, session.service_time_left - delta)
		session.service_elapsed += delta
		order_manager.tick(delta)
		_tick_interruptions(delta)
		_tick_customers()
		_tick_systems(delta)
		if session.anger >= 100.0 and session.phase != SessionState.Phase.BREAKDOWN:
			_start_breakdown()
		if session.service_time_left <= 0.0:
			_finish_service()
	if not interaction.is_empty():
		_tick_interaction(delta)
	hud_timer -= delta
	if hud_timer <= 0.0:
		hud_timer = 0.15
		if ui.hud.visible:
			ui.update_hud()
			_update_guidance()
			audio.set_pressure(maxf(session.anger, _average_staff_stress()))
	if is_instance_valid(guidance_beacon) and guidance_beacon.visible:
		guidance_beacon.rotation.y += delta * 1.8

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE and session.phase in [SessionState.Phase.PREP, SessionState.Phase.SERVICE, SessionState.Phase.BREAKDOWN]:
			_set_paused(not paused)
			get_viewport().set_input_as_handled()
		elif paused:
			return
		elif event.physical_keycode == KEY_1:
			_select_recipe("burger")
		elif event.physical_keycode == KEY_2:
			_select_recipe("pasta")
		elif event.physical_keycode == KEY_3:
			_select_recipe("special")
		elif event.physical_keycode == KEY_TAB and session.phase == SessionState.Phase.SERVICE:
			_cycle_selected_order()
		elif event.physical_keycode == KEY_ENTER and session.phase == SessionState.Phase.PREP:
			_open_briefing()

func _on_start_pressed() -> void:
	session.reset_run()
	_clear_dynamic_world()
	session.set_phase(SessionState.Phase.PREP_SELECT)
	ui.show_prep_selection()

func _on_prep_selected(profile: String) -> void:
	session.configure_prep(profile)
	world.set_mise_count(session.mise_en_place)
	session.set_phase(SessionState.Phase.PREP)
	player.global_position = Vector3(-5.2, 0.05, -5.6)
	player.set_active(false)
	ui.show_prep_hud()
	onboarding_open = true
	ui.show_tutorial()
	for station in world.stations.values():
		station.add_disorder(float(GameData.PREP_PROFILES[profile].disorder) * (0.45 if station.station_id == "sink" else 1.0))

func _open_briefing() -> void:
	if session.phase != SessionState.Phase.PREP:
		return
	_cancel_interaction()
	ui.hide_tutorial()
	onboarding_open = false
	session.set_phase(SessionState.Phase.BRIEFING)
	player.set_active(false)
	ui.show_briefing()

func _on_briefing_confirmed(directives: Array[String]) -> void:
	session.directives = directives
	session.special_communicated = session.special_estimated if "special_estimate" in directives else -1
	session.set_phase(SessionState.Phase.SERVICE)
	player.set_active(true)
	ui.show_service()
	order_manager.reset()
	order_manager.create_order("pasta")
	order_manager.create_order("burger")
	_select_first_available_order()
	audio.cue("order")

func _on_tutorial_closed() -> void:
	onboarding_open = false
	if session.phase in [SessionState.Phase.PREP, SessionState.Phase.SERVICE]:
		player.set_active(true)

func _select_recipe(recipe: String) -> void:
	if session.phase != SessionState.Phase.PREP and session.phase != SessionState.Phase.SERVICE:
		return
	session.selected_recipe = recipe
	ui.update_hud()
	audio.cue("interact")

func _select_order(order_id: int) -> void:
	for order in order_manager.active_orders():
		if int(order.id) == order_id:
			session.selected_order_id = order_id
			session.selected_recipe = str(order.recipe)
			_refresh_orders_ui()
			_update_guidance()
			ui.toast("Comanda attiva: Tavolo %d · %s" % [order.table, GameData.recipe_name(order.recipe)], 1.8)
			return

func _select_first_available_order() -> void:
	var active := order_manager.active_orders()
	if active.is_empty():
		session.selected_order_id = 0
		return
	_select_order(int(active[0].id))

func _cycle_selected_order() -> void:
	var active := order_manager.active_orders()
	if active.is_empty(): return
	var index := 0
	for i in active.size():
		if int(active[i].id) == session.selected_order_id:
			index = (i + 1) % active.size()
			break
	_select_order(int(active[index].id))

func _refresh_orders_ui() -> void:
	ui.update_orders(order_manager.active_orders(), session.selected_order_id)

func _selected_order() -> Dictionary:
	for order in order_manager.active_orders():
		if int(order.id) == session.selected_order_id:
			return order
	return {}

func get_station_action(station: KitchenStation) -> Dictionary:
	if station.processing_state == "burnt":
		return {"code": "clear_burnt", "label": "Rimuovi cibo bruciato da %s" % station.display_name, "duration": 2.6}
	if station.processing_state == "cooking":
		var remaining := maxf(0.0, station.processing_duration - station.processing_elapsed)
		return {"code": "blocked", "label": "%s cuoce davvero · torna fra %.1fs" % [station.display_name, remaining], "duration": 0.0}
	if station.processing_state == "ready":
		if not session.carried_item.is_empty():
			return {"code": "blocked", "label": "Il cibo è pronto, ma hai le mani occupate", "duration": 0.0}
		return {"code": "collect_cooked", "label": "Raccogli da %s · brucia fra %.0fs" % [station.display_name, maxf(0.0, station.burn_window - station.ready_elapsed)], "duration": 0.65}
	if station.disorder >= 78.0 and station.station_id not in ["trash", "cash"]:
		return {"code": "reset", "label": "RESET POSTAZIONE · disordine %d%%" % int(station.disorder), "duration": 5.2}
	if session.phase == SessionState.Phase.PREP:
		match station.station_id:
			"fridge": return {"code": "prep_mise", "label": "Prepara una base (%d/4)" % session.mise_en_place, "duration": 2.2}
			"sink": return {"code": "reset", "label": "Riordina e lava", "duration": 3.8}
			_: return {"code": "inspect", "label": "Controlla %s" % station.display_name, "duration": 1.2}
	if session.phase != SessionState.Phase.SERVICE:
		return {"code": "blocked", "label": "Non ora", "duration": 0.0}
	var item := session.carried_item
	match station.station_id:
		"fridge":
			if not item.is_empty(): return {"code": "blocked", "label": "Hai già le mani occupate", "duration": 0.0}
			if session.selected_recipe == "special" and session.special_real <= 0:
				return {"code": "blocked", "label": "SPECIALE TERMINATO", "duration": 0.0}
			return {"code": "take_%s" % session.selected_recipe, "label": "Prendi ingredienti · %s" % GameData.recipe_name(session.selected_recipe), "duration": 1.3}
		"grill":
			if item == "burger_raw": return {"code": "start_burger", "label": "Posa la carne sulla piastra", "duration": 0.7}
		"fryer":
			if item == "burger_patty": return {"code": "start_fries", "label": "Immergi il cestello delle patatine", "duration": 0.8}
			if item == "special_raw": return {"code": "start_special", "label": "Immergi il pollo nella friggitrice", "duration": 0.8}
		"stove":
			if item == "pasta_raw": return {"code": "start_pasta", "label": "Versa la pasta nella pentola", "duration": 0.75}
		"assembly":
			if item == "burger_components": return {"code": "plate_burger", "label": "Assembla burger e contorno", "duration": 2.8}
			if item == "pasta_cooked": return {"code": "plate_pasta", "label": "Termina e impiatta", "duration": 2.0}
			if item == "special_crispy": return {"code": "plate_special", "label": "Impiatta lo speciale", "duration": 2.6}
		"pass":
			if item.ends_with("_ready"):
				if staff_agents.has("waiter") and staff_agents.waiter.delivery_active:
					return {"code": "blocked", "label": "Pass occupato: Nico sta servendo un altro tavolo", "duration": 0.0}
				return {"code": "deliver", "label": "Appoggia il piatto al pass per Nico", "duration": 1.2}
		"sink": return {"code": "reset", "label": "Riordina e lava", "duration": 4.4}
		"trash":
			if not item.is_empty(): return {"code": "discard", "label": "Butta %s" % item, "duration": 0.8}
	var destination := world.stations.get(guidance_station_id) as KitchenStation
	var direction_hint := "segui il segnale arancione"
	if destination: direction_hint = "vai a %s" % destination.display_name.to_upper()
	return {"code": "blocked", "label": "Qui non serve · %s" % direction_hint, "duration": 0.0}

func request_station_interaction(station: KitchenStation, _interactor: PlayerController) -> void:
	if not interaction.is_empty():
		return
	var action := get_station_action(station)
	if action.code == "blocked":
		ui.toast(action.label, 1.8)
		audio.cue("error")
		return
	var efficiency := station.efficiency()
	var duration := float(action.duration) / efficiency
	if session.anger >= 35.0 and session.anger < 75.0:
		duration *= 0.88
	if session.mise_en_place > 0 and str(action.code).begins_with("take_"):
		duration *= 0.55
	interaction = {"station": station, "action": action, "elapsed": 0.0, "duration": duration}
	player.interacting = true
	ui.set_interaction(action.label, 0.0, true)
	audio.cue("interact")

func _tick_interaction(delta: float) -> void:
	if interaction.is_empty(): return
	interaction.elapsed += delta
	var progress: float = clampf(float(interaction.elapsed) / maxf(0.01, float(interaction.duration)), 0.0, 1.0)
	ui.set_interaction(interaction.action.label, progress, true)
	if progress >= 1.0:
		var completed := interaction.duplicate()
		interaction.clear()
		player.interacting = false
		ui.set_interaction("", 0.0, false)
		_complete_station_action(completed.station, completed.action.code)

func _cancel_interaction() -> void:
	if interaction.is_empty(): return
	interaction.clear()
	player.interacting = false
	ui.set_interaction("", 0.0, false)
	ui.toast("Interazione annullata", 1.4)

func _complete_station_action(station: KitchenStation, code: String) -> void:
	match code:
		"prep_mise":
			session.mise_en_place = mini(4, session.mise_en_place + 1)
			world.set_mise_count(session.mise_en_place)
			station.add_disorder(5.0)
			ui.toast("Base pronta. Il servizio inizierà un po' più fluido.")
		"inspect":
			station.add_disorder(-6.0)
			ui.toast("%s controllata: efficienza %d%%" % [station.display_name, int(station.efficiency() * 100.0)])
		"reset":
			station.reset_disorder()
			for key in session.staff_state: session.add_staff_stress(key, -2.0)
			ui.toast("Postazione ripristinata. Il debito operativo cala.")
		"take_burger": _set_carried("burger_raw"); _consume_mise(); station.add_disorder(4.0)
		"take_pasta": _set_carried("pasta_raw"); _consume_mise(); station.add_disorder(3.0)
		"take_special":
			session.special_real -= 1
			_set_carried("special_raw")
			_consume_mise()
			station.add_disorder(4.0)
		"start_burger": _start_station_cooking(station, "burger_raw", "burger_patty", 7.0, 8.0)
		"start_fries": _start_station_cooking(station, "burger_patty", "burger_components", 5.8, 7.0)
		"start_special": _start_station_cooking(station, "special_raw", "special_crispy", 8.2, 7.0)
		"start_pasta": _start_station_cooking(station, "pasta_raw", "pasta_cooked", 6.5, 5.5)
		"collect_cooked":
			var cooked := station.collect_result()
			if not cooked.is_empty():
				_set_carried(cooked)
				ui.toast("Raccolto al momento giusto: %s" % ui._friendly_item(cooked), 2.0)
		"clear_burnt":
			station.clear_processing()
			station.add_disorder(18.0)
			session.waste_cost += 8
			session.dishes_failed += 1
			session.add_anger(8.0, "%s ha bruciato una preparazione lasciata incustodita" % station.display_name)
			ui.toast("Preparazione bruciata rimossa · -€8 · postazione sporca")
		"cook_burger": _set_carried("burger_patty"); station.add_disorder(8.0)
		"fry_fries": _set_carried("burger_components"); station.add_disorder(12.0)
		"fry_special": _set_carried("special_crispy"); station.add_disorder(14.0)
		"cook_pasta": _set_carried("pasta_cooked"); station.add_disorder(9.0)
		"plate_burger": _set_carried("burger_ready"); station.add_disorder(7.0)
		"plate_pasta": _set_carried("pasta_ready"); station.add_disorder(6.0)
		"plate_special": _set_carried("special_ready"); station.add_disorder(7.0)
		"deliver": _deliver_plate(station)
		"discard":
			session.carried_item = ""
			player.set_carried_visual("")
			session.waste_cost += 5
			ui.toast("Spreco registrato: -€5")
	if session.phase == SessionState.Phase.SERVICE and session.anger >= 76.0 and rng.randf() < 0.12 and not session.carried_item.is_empty():
		session.carried_item = ""
		player.set_carried_visual("")
		session.waste_cost += 8
		session.dishes_failed += 1
		session.add_anger(5.0, "Con la rabbia alta lo chef ha fatto cadere una preparazione")
		ui.toast("CRASH! Movimento brusco: preparazione a terra.")
		audio.cue("error")
	else:
		audio.cue("success")
	ui.update_hud()

func _set_carried(item: String) -> void:
	session.carried_item = item
	session.carried_since = session.service_elapsed
	player.set_carried_visual(item)

func _start_station_cooking(station: KitchenStation, expected: String, result: String, duration: float, burn_after: float) -> void:
	if session.carried_item != expected:
		return
	if station.start_processing(expected, result, duration, burn_after):
		session.carried_item = ""
		player.set_carried_visual("")
		station.add_disorder(5.0)
		ui.toast("%s è in cottura. Puoi occuparti di altro e tornare quando diventa verde." % station.display_name, 3.2)

func _consume_mise() -> void:
	if session.mise_en_place > 0:
		session.mise_en_place -= 1
		world.set_mise_count(session.mise_en_place)

func _deliver_plate(station: KitchenStation) -> void:
	var recipe := session.carried_item.trim_suffix("_ready")
	var held := session.service_elapsed - session.carried_since
	var quality := clampf(100.0 - held * (2.8 if recipe == "pasta" else 1.7) - station.disorder * 0.16, 35.0, 100.0)
	var order := order_manager.complete_recipe(recipe, quality)
	if order.is_empty():
		session.waste_cost += 6
		session.dishes_failed += 1
		ui.toast("Nessuna comanda corrispondente: piatto sprecato.")
		audio.cue("error")
	else:
		var price := int(GameData.RECIPES[recipe].price)
		if order.invalid: price -= 3
		if order.invalid:
			session.add_anger(4.0, "È arrivata al pass una richiesta assurda accettata dalla sala")
		if OS.get_environment("DEGUSTIBUS_SMOKE") == "1" or "--smoke-test" in OS.get_cmdline_user_args():
			_finish_table_delivery(order, quality, price)
		else:
			ui.toast("Piatto sul pass: Nico lo porta fisicamente al Tavolo %d." % order.table, 2.8)
			var table_target: Vector3 = world.table_positions[int(order.table)] + Vector3(0, 0, 0.72)
			staff_agents.waiter.start_delivery(table_target, _finish_table_delivery.bind(order, quality, price))
	session.carried_item = ""
	player.set_carried_visual("")
	if not order.is_empty() and int(order.id) == session.selected_order_id:
		_select_first_available_order()

func _finish_table_delivery(order: Dictionary, quality: float, price: int) -> void:
	session.money += price
	session.dishes_succeeded += 1
	session.customers_happy += 1
	session.reputation = clampf(session.reputation + quality * 0.012, 0.0, 100.0)
	ui.toast("Nico serve il Tavolo %d · qualità %d%% · +€%d" % [order.table, int(quality), price])
	_remove_customer_for_order(int(order.id), true)
	audio.cue("success")

func _on_focus_changed(target: Node) -> void:
	if target and target.has_method("get_prompt"):
		ui.set_prompt(target.get_prompt())
	else:
		ui.set_prompt("")

func _on_order_created(order: Dictionary) -> void:
	audio.cue("order")
	ui.toast("Nuova comanda · Tavolo %d · %s" % [order.table, GameData.recipe_name(order.recipe)])
	var customer := CustomerAgent.new()
	var color: Color = world.customer_colors[(int(order.id) - 1) % world.customer_colors.size()]
	customer.position = world.table_positions[int(order.table)] + Vector3(0, 0.0, 1.04)
	world.add_child(customer)
	customer.setup(self, int(order.id), int(order.table), color, bool(order.invalid))
	customers_by_order[order.id] = customer
	if session.selected_order_id == 0:
		_select_order(int(order.id))

func _on_order_failed(order: Dictionary) -> void:
	session.customers_fled += 1
	session.dishes_failed += 1
	session.reputation = maxf(0.0, session.reputation - 2.8)
	session.add_anger(6.0, order.failure_reason)
	ui.toast(order.failure_reason)
	audio.cue("error")
	_remove_customer_for_order(order.id, false)
	if int(order.id) == session.selected_order_id:
		_select_first_available_order()

func _on_station_processing_changed(station: KitchenStation, state: String) -> void:
	if state == "ready":
		ui.toast("%s: preparazione PRONTA. Il segnale è verde, raccoglila prima che bruci." % station.display_name, 3.4)
		audio.cue("success")
	elif state == "burnt":
		session.add_anger(5.0, "Una preparazione è bruciata su %s" % station.display_name)
		station.add_disorder(10.0)
		ui.toast("FUMO! La preparazione su %s è bruciata fisicamente." % station.display_name, 4.0)
		audio.cue("error")
	_update_guidance()

func _remove_customer_for_order(order_id: int, happy: bool) -> void:
	if not customers_by_order.has(order_id): return
	var customer: CustomerAgent = customers_by_order[order_id]
	customers_by_order.erase(order_id)
	if is_instance_valid(customer):
		var tween := customer.create_tween()
		tween.tween_property(customer, "global_position", Vector3(7.0, 0.0, 6.5), 1.5)
		tween.tween_callback(customer.queue_free)

func _tick_customers() -> void:
	for order in order_manager.active_orders():
		if customers_by_order.has(order.id) and is_instance_valid(customers_by_order[order.id]):
			customers_by_order[order.id].set_patience(order.patience, order.max_patience)

func _tick_systems(delta: float) -> void:
	system_timer -= delta
	if system_timer > 0.0: return
	system_timer = 4.0
	var active_count := order_manager.active_orders().size()
	var total_disorder := 0.0
	for station in world.stations.values(): total_disorder += station.disorder
	var avg_disorder: float = total_disorder / maxf(1.0, float(world.stations.size()))
	for key in session.staff_state:
		var pressure := active_count * 0.75 + avg_disorder * 0.022
		if session.phase == SessionState.Phase.BREAKDOWN: pressure += 3.5
		session.add_staff_stress(key, pressure - float(GameData.STAFF[key].stress_resistance) * 0.018)
	# Pippo's low Order steadily creates visible operational debt.
	var station_keys := ["grill", "stove", "fryer", "assembly", "sink"]
	var messy: KitchenStation = world.stations[station_keys[rng.randi_range(0, station_keys.size() - 1)]]
	var assistant_order := float(GameData.STAFF.assistant.order)
	messy.add_disorder(5.8 * (1.15 - assistant_order / 100.0))
	if messy.disorder >= 72.0:
		session.add_anger(2.5, "%s ha lasciato %s in disordine" % [GameData.STAFF.assistant.name, messy.display_name])
	if int(session.service_elapsed) % 24 < 5:
		_staff_error_check()
	var pressure_anger := active_count * 0.35 + maxf(0.0, avg_disorder - 35.0) * 0.045 + maxf(0.0, _average_staff_stress() - 62.0) * 0.055
	session.add_anger(pressure_anger)

func _staff_error_check() -> void:
	for key in ["waiter", "cassiera", "assistant"]:
		var stress := float(session.staff_state[key].stress)
		var competence := float(GameData.STAFF[key].competence)
		var chance := clampf((stress - competence * 0.45) / 170.0, 0.0, 0.28)
		if rng.randf() < chance:
			var message: String = {
				"waiter": "Il tavolo sei vuole sapere quanto manca.",
				"cassiera": "Avevi detto che erano rimaste dieci porzioni.",
				"assistant": "Chef, la friggitrice è di nuovo da riordinare.",
			}[key]
			session.incidents.append({"actor": key, "text": message, "severity": 5.0, "fault": true})
			session.add_anger(5.0, message)
			session.add_staff_stress(key, 4.0)
			ui.toast(message)
			audio.cue("error")
			break

func _average_staff_stress() -> float:
	if session.staff_state.is_empty(): return 0.0
	var total := 0.0
	for key in session.staff_state: total += float(session.staff_state[key].stress)
	return total / float(session.staff_state.size())

func _tick_interruptions(delta: float) -> void:
	if interruption_index < interruption_times.size() and session.service_elapsed >= interruption_times[interruption_index]:
		_spawn_interruption(GameData.INTERRUPTIONS[interruption_index])
		interruption_index += 1
	for pending in pending_interruptions:
		if pending.resolved: continue
		pending.age += delta
		if pending.age >= 30.0 and not pending.escalated:
			pending.escalated = true
			pending.agent.problematic = true
			pending.agent.label.text = "! DISTURBATORE"
			pending.agent.label.modulate = Color("#ff5d55")
			session.add_staff_stress("cassiera", 12.0)
			session.add_anger(9.0, "%s sta bloccando la cassa" % pending.event.title)
			ui.toast("La cassa è bloccata: %s" % pending.event.title)

func _spawn_interruption(event: Dictionary) -> void:
	var agent := CustomerAgent.new()
	agent.position = Vector3(12.7 - pending_interruptions.size() * 0.65, 0.0, 3.1 - pending_interruptions.size() * 0.4)
	world.add_child(agent)
	agent.setup(self, 100 + interruption_index, 0, world.customer_colors[(interruption_index + 2) % world.customer_colors.size()], event.id in ["progressive", "unwelcome"], event)
	pending_interruptions.append({"agent": agent, "event": event, "age": 0.0, "escalated": false, "resolved": false})
	ui.toast(event.line, 5.0)
	audio.cue("order")

func open_interruption(agent: CustomerAgent) -> void:
	if session.phase != SessionState.Phase.SERVICE: return
	ui.show_interruption(agent, agent.interruption)
	player.set_active(false)

func _resolve_interruption(index: int, agent: Node) -> void:
	if not is_instance_valid(agent): return
	var event: Dictionary = agent.interruption
	match event.id:
		"catering":
			if index == 0:
				session.catering_contract = {"guests": 20, "margin": 210, "risk": "medio", "prep_hours": 5, "extras": 2}
				session.add_staff_stress("cassiera", 6.0)
				ui.toast("Marta chiude il contratto, ma con due extra e margine ridotto.")
			elif index == 1:
				session.catering_contract = {"guests": 20, "margin": 320, "risk": "alto", "prep_hours": 7, "extras": 3}
				for order in order_manager.active_orders(): order.patience = maxf(0.0, order.patience - 14.0)
				session.add_anger(4.0, "Lo chef ha lasciato scoperta la cucina per il catering")
				ui.toast("Contratto migliore. In cucina, però, nessuno ha coperto il pass.")
			else:
				session.reputation -= 1.0
		"progressive":
			if index == 0: session.reputation += 0.5
			elif index == 1: session.add_staff_stress("cassiera", 8.0)
			else: session.reputation -= 1.5
		"change":
			if index == 0: session.add_staff_stress("cassiera", 3.0)
			elif index == 1: session.money += 2
			else: session.reputation -= 0.6
		"unwelcome":
			if index == 0: session.reputation += 1.5
			elif index == 1: session.money -= 3; session.reputation += 2.0
			else: session.reputation -= 3.0; session.add_staff_stress("waiter", 9.0)
	for pending in pending_interruptions:
		if pending.agent == agent: pending.resolved = true
	ui.hide_interruption()
	player.set_active(true)
	agent.remove_from_group("interactable")
	var tween := agent.create_tween()
	tween.tween_property(agent, "global_position", Vector3(15.5, 0.0, 5.5), 1.4)
	tween.tween_callback(agent.queue_free)

func _start_breakdown() -> void:
	_cancel_interaction()
	session.set_phase(SessionState.Phase.BREAKDOWN)
	ui.phase_label.text = "PUNTO DI ROTTURA"
	ui.toast("PUNTO DI ROTTURA! Espelli 3 disturbatori in rosso. Non colpire clienti tranquilli o personale.", 7.0)
	audio.cue("breakdown")
	var problematic_count := 0
	for customer in get_tree().get_nodes_in_group("customers"):
		if is_instance_valid(customer) and customer.problematic:
			problematic_count += 1
	while problematic_count < 3:
		var agent := CustomerAgent.new()
		agent.position = Vector3(4.2 + problematic_count * 3.5, 0.0, 2.1)
		world.add_child(agent)
		agent.setup(self, 200 + problematic_count, 0, world.customer_colors[problematic_count], true)
		agent.label.text = "! CLIENTE AGGRESSIVO"
		problematic_count += 1

func _perform_slapstick() -> void:
	if session.phase != SessionState.Phase.BREAKDOWN or not player.active:
		return
	var target: CustomerAgent = null
	var best := 3.2
	for customer in get_tree().get_nodes_in_group("customers"):
		if not is_instance_valid(customer) or not customer.active: continue
		var distance := player.global_position.distance_to(customer.global_position)
		if distance < best:
			best = distance
			target = customer
	if target == null:
		ui.toast("Nessun bersaglio a portata di mestolo.", 1.4)
		return
	var direction := target.global_position - player.global_position
	target.slapstick_hit(direction)
	audio.cue("hit")
	if target.problematic:
		session.problematic_ejected += 1
		session.reputation -= 1.0
		ui.toast("FUORI! Disturbatore espulso (%d/3)." % session.problematic_ejected)
	else:
		session.wrong_hits += 1
		session.reputation -= 9.0
		session.money -= 25
		session.add_anger(6.0, "Lo chef ha colpito un cliente tranquillo")
		ui.toast("BERSAGLIO ERRATO! -€25 e reputazione in caduta.")
	if session.problematic_ejected >= 3:
		session.anger = 34.0
		session.set_phase(SessionState.Phase.SERVICE)
		ui.phase_label.text = "RITORNO AL SERVIZIO"
		for order in order_manager.active_orders(): order.patience = maxf(0.0, order.patience - 8.0)
		for station in world.stations.values(): station.add_disorder(5.0)
		ui.toast("La sala si calma. La cucina no: piatti e postazioni sono peggiorati.", 6.0)

func _finish_service() -> void:
	if session.phase == SessionState.Phase.SUMMARY: return
	_cancel_interaction()
	for order in order_manager.active_orders():
		order_manager.fail_order(order, "Servizio chiuso prima della consegna")
	session.set_phase(SessionState.Phase.SUMMARY)
	player.set_active(false)
	session.save_progress()
	ui.show_summary()

func _open_debrief() -> void:
	session.set_phase(SessionState.Phase.DEBRIEF)
	ui.show_debrief()

func _resolve_debrief(style: String) -> void:
	var actor := "assistant"
	if not session.incidents.is_empty() and GameData.STAFF.has(str(session.incidents[-1].get("actor", "assistant"))):
		actor = str(session.incidents[-1].actor)
	var state: Dictionary = session.staff_state[actor]
	var learning_stat := float(GameData.STAFF[actor].learning)
	var morale_delta := 0.0
	var learn_delta := 0
	var trust_delta := 0.0
	match style:
		"Correttivo": morale_delta = -2; learn_delta = int(2 + learning_stat / 35.0); trust_delta = 3
		"Aggressivo": morale_delta = -14; learn_delta = 1; trust_delta = -10; session.add_staff_stress(actor, 10)
		"Comprensivo": morale_delta = 5; learn_delta = 2; trust_delta = 6
		"Sarcastico": morale_delta = -7; learn_delta = 0; trust_delta = -5
		"Nessun richiamo": morale_delta = 1; learn_delta = 0; trust_delta = 0
		"Riconoscimento positivo": morale_delta = 9; learn_delta = 1; trust_delta = 8
	state.mood = clampf(float(state.mood) + morale_delta, 0.0, 100.0)
	state.learning = int(state.learning) + learn_delta
	state.trust = clampf(float(state.trust) + trust_delta, 0.0, 100.0)
	var repeat_risk := clampi(72 - int(state.learning) * 3 - int(state.trust * 0.18), 5, 90)
	ui.show_debrief_result("%s · morale %+d · apprendimento +%d · fiducia %+d · rischio recidiva %d%%" % [GameData.STAFF[actor].name, int(morale_delta), learn_delta, int(trust_delta), repeat_risk])
	session.save_progress()

func _restart_run() -> void:
	session.set_phase(SessionState.Phase.MENU)
	_clear_dynamic_world()
	ui.show_main_menu()

func _clear_dynamic_world() -> void:
	for customer in get_tree().get_nodes_in_group("customers"):
		if is_instance_valid(customer): customer.queue_free()
	customers_by_order.clear()
	pending_interruptions.clear()
	interruption_index = 0
	interaction.clear()
	order_manager.reset()
	session.selected_order_id = 0
	session.carried_item = ""
	world.set_mise_count(0)
	if is_instance_valid(player): player.set_carried_visual("")
	for station in world.stations.values():
		station.clear_processing()
		station.disorder = 0.0
		station.add_disorder(0.0)

func _spawn_staff() -> void:
	var routes := {
		"cassiera": [Vector3(14.1, 0, 1.2), Vector3(14.1, 0, 2.5), Vector3(12.8, 0, 2.5)],
		"waiter": [Vector3(1.3, 0, -0.1), Vector3(5.0, 0, -3.1), Vector3(11.0, 0, -3.1), Vector3(14.0, 0, 0.2)],
		"assistant": [Vector3(-7.4, 0, -5.4), Vector3(-4.0, 0, -5.4), Vector3(-2.0, 0, -3.0), Vector3(-6.2, 0, -2.6)],
	}
	for key in ["cassiera", "waiter", "assistant"]:
		var agent := StaffAgent.new()
		agent.position = routes[key][0]
		world.add_child(agent)
		agent.setup(key, GameData.STAFF[key], session.staff_state[key], routes[key])
		staff_agents[key] = agent

func _set_paused(value: bool) -> void:
	paused = value
	get_tree().paused = value
	ui.set_paused(value)
	player.set_active(not value)

func _apply_settings() -> void:
	audio.apply_settings()
	player.set_mouse_sensitivity(float(session.settings.camera_sensitivity))
	player.set_camera_distance(float(session.settings.camera_distance))
	player.set_camera_fov(float(session.settings.camera_fov))
	session.save_progress()

func _build_guidance_beacon() -> void:
	guidance_beacon = Node3D.new()
	world.add_child(guidance_beacon)
	guidance_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.52
	ring_mesh.outer_radius = 0.66
	guidance_ring.mesh = ring_mesh
	guidance_ring.rotation.x = PI * 0.5
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color("#ffad35")
	ring_mat.emission_enabled = true
	ring_mat.emission = Color("#ff8c24")
	ring_mat.emission_energy_multiplier = 2.2
	guidance_ring.material_override = ring_mat
	guidance_beacon.add_child(guidance_ring)
	var arrow := MeshInstance3D.new()
	var arrow_mesh := CylinderMesh.new()
	arrow_mesh.top_radius = 0.0
	arrow_mesh.bottom_radius = 0.23
	arrow_mesh.height = 0.52
	arrow.mesh = arrow_mesh
	arrow.position.y = -0.46
	arrow.material_override = ring_mat
	guidance_beacon.add_child(arrow)
	guidance_label = Label3D.new()
	guidance_label.font_size = 37
	guidance_label.outline_size = 10
	guidance_label.position.y = 0.48
	guidance_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	guidance_label.modulate = Color("#ffd26b")
	guidance_beacon.add_child(guidance_label)
	guidance_beacon.visible = false

func _update_guidance() -> void:
	if not is_instance_valid(ui) or not is_instance_valid(guidance_beacon): return
	if session.phase == SessionState.Phase.PREP:
		_set_guidance_target("fridge", "PREPARAZIONE · MISE EN PLACE", "FRIGO  →  prepara basi fisiche", "Segui il segnale arancione e premi E. Invio apre il briefing.")
		return
	if session.phase != SessionState.Phase.SERVICE:
		guidance_beacon.visible = false
		return
	var order := _selected_order()
	if order.is_empty():
		_set_guidance_target("sink", "CUCINA IN PAUSA", "Riordina mentre aspetti una comanda", "Il debito operativo rallenta davvero le interazioni.")
		return
	var recipe := str(order.recipe)
	var item := session.carried_item
	if not item.is_empty():
		recipe = item.get_slice("_", 0)
	var station_id := "fridge"
	match item:
		"burger_raw": station_id = "grill"
		"burger_patty": station_id = "fryer"
		"burger_components", "pasta_cooked", "special_crispy": station_id = "assembly"
		"pasta_raw": station_id = "stove"
		"special_raw": station_id = "fryer"
		"burger_ready", "pasta_ready", "special_ready": station_id = "pass"
	if item.is_empty():
		for candidate in ["grill", "stove", "fryer"]:
			var station: KitchenStation = world.stations[candidate]
			if station.has_processing() and (station.processing_input.begins_with(recipe) or station.processing_result.begins_with(recipe)):
				station_id = candidate
				break
	var target: KitchenStation = world.stations[station_id]
	var action_text := target.display_name.to_upper()
	var hint := "Raggiungi il segnale e premi E per continuare la preparazione."
	if target.processing_state == "cooking":
		var remaining := maxf(0.0, target.processing_duration - target.processing_elapsed)
		action_text = "%s STA CUOCENDO · %.1fs" % [target.display_name.to_upper(), remaining]
		hint = "La cottura continua senza tenere premuto. TAB passa a un'altra comanda."
	elif target.processing_state == "ready":
		action_text = "%s È PRONTO · %.0fs AL BRUCIATO" % [target.display_name.to_upper(), maxf(0.0, target.burn_window - target.ready_elapsed)]
		hint = "Raccoglilo ora con E: il cibo è visibile sulla postazione."
	elif target.processing_state == "burnt":
		action_text = "%s È BRUCIATO" % target.display_name.to_upper()
		hint = "Rimuovilo fisicamente prima di poter riutilizzare la postazione."
	var steps: Array = GameData.RECIPES[recipe].steps
	var chain := "  ›  ".join(steps)
	_set_guidance_target(station_id, "T%d · %s · %s" % [order.table, GameData.RECIPES[recipe].short, action_text], chain, hint)

func _set_guidance_target(station_id: String, title: String, steps: String, hint: String) -> void:
	if not world.stations.has(station_id):
		guidance_beacon.visible = false
		return
	var station: KitchenStation = world.stations[station_id]
	guidance_station_id = station_id
	guidance_beacon.visible = true
	guidance_beacon.global_position = station.global_position + Vector3(0, station.visual_height + 1.45 + sin(Time.get_ticks_msec() * 0.004) * 0.12, 0)
	guidance_label.text = "PROSSIMO · %s" % station.display_name.to_upper()
	var ready := station.processing_state == "ready"
	guidance_label.modulate = Color("#7dff9d") if ready else Color("#ffd26b")
	var mat := guidance_ring.material_override as StandardMaterial3D
	mat.albedo_color = Color("#58df7b") if ready else Color("#ffad35")
	mat.emission = Color("#43e778") if ready else Color("#ff8c24")
	ui.set_objective(title, steps, hint)

func _run_smoke_test() -> void:
	# Deterministic end-to-end verification used by scripts/test_project.ps1.
	_on_start_pressed()
	_on_prep_selected("standard")
	_complete_station_action(world.stations.fridge, "prep_mise")
	_open_briefing()
	_on_briefing_confirmed(["promote_pasta", "special_estimate", "forbid_sauce"])
	for recipe in ["burger", "pasta", "special"]:
		order_manager.create_order(recipe)
		match recipe:
			"burger":
				_complete_station_action(world.stations.fridge, "take_burger")
				_complete_station_action(world.stations.grill, "cook_burger")
				_complete_station_action(world.stations.fryer, "fry_fries")
				_complete_station_action(world.stations.assembly, "plate_burger")
			"pasta":
				_complete_station_action(world.stations.fridge, "take_pasta")
				_complete_station_action(world.stations.stove, "cook_pasta")
				_complete_station_action(world.stations.assembly, "plate_pasta")
			"special":
				_complete_station_action(world.stations.fridge, "take_special")
				_complete_station_action(world.stations.fryer, "fry_special")
				_complete_station_action(world.stations.assembly, "plate_special")
		_complete_station_action(world.stations.pass, "deliver")
	for event in GameData.INTERRUPTIONS:
		_spawn_interruption(event)
		var agent: CustomerAgent = pending_interruptions[-1].agent
		_resolve_interruption(1 if event.id == "catering" else 0, agent)
	var async_station: KitchenStation = world.stations.grill
	async_station.clear_processing()
	assert(async_station.start_processing("burger_raw", "burger_patty", 0.1, 0.1), "Cooking station must accept a physical item")
	async_station._process(0.11)
	assert(async_station.processing_state == "ready", "Cooking must become ready asynchronously")
	async_station._process(0.11)
	assert(async_station.processing_state == "burnt", "Unattended food must physically burn")
	async_station.clear_processing()
	var waiter_check := [false]
	staff_agents.waiter.start_delivery(staff_agents.waiter.global_position + Vector3(0.1, 0, 0), func(): waiter_check[0] = true)
	staff_agents.waiter._process(0.1)
	assert(waiter_check[0], "Waiter must physically complete a table delivery")
	assert(session.dishes_succeeded >= 3, "All three recipe paths must deliver")
	assert(not session.catering_contract.is_empty(), "Catering choice must create a future contract")
	assert(pending_interruptions.size() == 4, "All interruption archetypes must spawn")
	_finish_service()
	_open_debrief()
	_resolve_debrief("Correttivo")
	var result := "SMOKE PASS | recipes=3 cooking=async+burn waiter=physical interruptions=4 catering=yes summary=yes debrief=yes score=%d" % session.score()
	var report := FileAccess.open("res://.smoke-test-result", FileAccess.WRITE)
	if report:
		report.store_string(result)
	print(result)
	get_tree().quit(0)

func _capture_preview() -> void:
	var capture_mode := OS.get_environment("DEGUSTIBUS_CAPTURE")
	var output_name := "main_menu.png"
	if capture_mode == "tutorial":
		_on_start_pressed()
		_on_prep_selected("standard")
		output_name = "tutorial.png"
	elif capture_mode in ["service", "cooking"]:
		_on_start_pressed()
		_on_prep_selected("standard")
		_open_briefing()
		_on_briefing_confirmed(["promote_pasta", "special_estimate", "update_tables"])
		if capture_mode == "cooking":
			world.stations.grill.start_processing("burger_raw", "burger_patty", 7.0, 8.0)
			player.global_position = Vector3(-5.7, 0.05, -5.1)
			output_name = "cooking.png"
		else:
			output_name = "service.png"
	for _i in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png("res://artifacts/%s" % output_name)
	get_tree().quit(0)
