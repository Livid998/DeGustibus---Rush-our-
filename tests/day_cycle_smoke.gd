extends Node

const DAY_CYCLE_SCRIPT := preload("res://scripts/autoload/day_cycle_manager.gd")

var checks := 0
var failures: Array[String] = []
var warning_events: Array[String] = []
var started_events: Array[String] = []
var ended_events: Array[String] = []
var completed_days: Array[int] = []
var completed_clock_days: Array[int] = []
var period_events: Array[String] = []
var manager: DayCycleClockManager


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	SaveManager.writes_enabled = false
	var original_state := GameState.serialize().duplicate(true)
	GameState.reset_to_defaults(false)
	GameState.set_restaurant_state("closed")

	manager = DAY_CYCLE_SCRIPT.new() as DayCycleClockManager
	add_child(manager)
	manager.set_process(false)
	manager.connect("rush_warning", _on_rush_warning)
	manager.connect("rush_started", _on_rush_started)
	manager.connect("rush_ended", _on_rush_ended)
	manager.connect("day_completed", _on_day_completed)
	manager.connect("period_changed", _on_period_changed)

	_test_rollover_and_periods()
	_test_rush_signal_boundaries()
	_test_pause_and_speed()
	_test_force_rush_debug()
	_test_traffic_formula_and_cap()
	_test_lighting_profile()
	_test_daily_payroll_and_reward()

	manager.set_paused(false, false)
	GameState.deserialize(original_state)
	manager.queue_free()
	var result := "DAY CYCLE: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/day-cycle-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_rollover_and_periods() -> void:
	_clear_events()
	manager.reset_event_history()
	manager.set_clock(3, 1439.0)
	manager.advance_seconds(_seconds_for_game_minutes(2.0), 1.0, "open")
	_expect(manager.day == 4 and is_equal_approx(manager.minute, 1.0), "il rollover porta giorno 3 23:59 a giorno 4 00:01 in modo deterministico")
	_expect(completed_days == [3], "day_completed viene emesso una sola volta per il giorno appena concluso")
	_expect(completed_clock_days == [4], "day_completed osserva gia il nuovo giorno persistito, pronto per il payroll")
	_expect(int(GameState.world_clock.day) == 4 and is_equal_approx(float(GameState.world_clock.minute), 1.0), "il clock persistente segue il rollover")

	manager.set_clock(4, 600.0)
	_expect(manager.current_period_id == "morning", "le 10:00 appartengono alla mattina")
	manager.set_clock(4, 750.0)
	_expect(manager.current_period_id == "lunch" and manager.rush_active, "il periodo pranzo attiva il rush configurato")
	manager.set_clock(4, 900.0)
	_expect(manager.current_period_id == "afternoon" and not manager.rush_active, "fra i rush il periodo e pomeriggio")
	manager.set_clock(4, 1200.0)
	_expect(manager.current_period_id == "dinner" and manager.rush_active, "il periodo cena attiva il secondo rush")
	manager.set_clock(4, 1320.0)
	_expect(manager.current_period_id == "night" and not manager.rush_active, "dopo cena il periodo passa a notte")


func _test_rush_signal_boundaries() -> void:
	_clear_events()
	manager.reset_event_history()
	var windows := manager.configured_rush_windows()
	var lunch: Dictionary = windows[0]
	var warning_game_minutes := float(DataRegistry.balance_value("day_cycle.rush_warning_seconds", 0.0))
	warning_game_minutes *= 1440.0 / float(DataRegistry.balance_value("day_cycle.real_seconds_at_1x", 1.0))
	var warning_boundary := float(lunch.start) - warning_game_minutes
	manager.set_clock(5, warning_boundary - 1.0)
	manager.advance_seconds(_seconds_for_game_minutes(2.0), 1.0, "open")
	manager.advance_seconds(_seconds_for_game_minutes(float(lunch.start) - manager.minute + 1.0), 1.0, "open")
	manager.advance_seconds(_seconds_for_game_minutes(float(lunch.end) - manager.minute + 1.0), 1.0, "open")
	manager.advance_seconds(_seconds_for_game_minutes(10.0), 1.0, "open")
	_expect(warning_events == [String(lunch.id)], "il preavviso rush viene emesso esattamente una volta")
	_expect(started_events == [String(lunch.id)], "rush_started viene emesso esattamente una volta")
	_expect(ended_events == [String(lunch.id)], "rush_ended viene emesso esattamente una volta")
	_expect(period_events.count(String(lunch.id)) == 1, "period_changed segnala una sola entrata nel periodo rush")


func _test_pause_and_speed() -> void:
	manager.set_clock(7, 600.0)
	manager.set_paused(true, false)
	manager.advance_seconds(20.0, 4.0, "open")
	_expect(is_equal_approx(manager.minute, 600.0), "la pausa 0x non avanza il clock")
	manager.set_paused(false, false)

	manager.set_clock(7, 600.0)
	manager.advance_seconds(10.0, 1.0, "open")
	var one_x_delta := manager.minute - 600.0
	manager.set_clock(7, 600.0)
	manager.advance_seconds(10.0, 2.0, "open")
	var two_x_delta := manager.minute - 600.0
	_expect(is_equal_approx(two_x_delta, one_x_delta * 2.0), "la velocita 2x raddoppia esattamente l'avanzamento")

	manager.set_clock(7, 600.0)
	manager.advance_seconds(10.0, 4.0, "closed")
	_expect(is_equal_approx(manager.minute, 600.0), "il clock continuo resta fermo a ristorante chiuso")
	manager.advance_seconds(10.0, 1.0, "closing")
	_expect(manager.minute > 600.0, "il clock continua durante la chiusura operativa")


func _test_force_rush_debug() -> void:
	_clear_events()
	manager.set_clock(8, 900.0)
	manager.force_rush_debug(true)
	manager.force_rush_debug(true)
	_expect(manager.rush_active and manager.active_rush_id == "debug", "force rush debug attiva uno stato rush esplicito")
	manager.force_rush_debug(false)
	manager.force_rush_debug(false)
	_expect(started_events == ["debug"] and ended_events == ["debug"], "force rush debug emette start/end una sola volta")


func _test_traffic_formula_and_cap() -> void:
	var normal_low_rep := manager.effective_spawn_interval(1.0, true, 900.0)
	var normal_high_rep := manager.effective_spawn_interval(5.0, true, 900.0)
	var lunch_high_rep := manager.effective_spawn_interval(5.0, true, 750.0)
	var night_high_rep := manager.effective_spawn_interval(5.0, true, 1320.0)
	var sold_out_interval := manager.effective_spawn_interval(5.0, false, 900.0)
	_expect(normal_high_rep < normal_low_rep, "la reputazione alta aumenta l'afflusso")
	_expect(lunch_high_rep < normal_high_rep, "il moltiplicatore rush riduce l'intervallo di spawn")
	_expect(night_high_rep > normal_high_rep, "il moltiplicatore notturno rallenta l'afflusso")
	_expect(sold_out_interval > normal_high_rep, "nessuna ricetta producibile rallenta senza azzerare l'afflusso")
	_expect(minf(minf(normal_low_rep, lunch_high_rep), minf(night_high_rep, sold_out_interval)) > 0.0, "ogni intervallo di spawn resta strettamente positivo")

	var queue_buffer := int(DataRegistry.balance_value("traffic.queue_buffer_groups", 0))
	var absolute_cap := int(DataRegistry.balance_value("traffic.absolute_group_cap", 1))
	_expect(manager.group_cap(4) == mini(4 + queue_buffer, absolute_cap), "il cap usa posti piu coda e il limite assoluto")
	_expect(manager.group_cap(100) == absolute_cap, "il cap non supera mai il limite assoluto configurato")
	_expect(manager.group_cap(4) > 0 and is_finite(normal_low_rep), "clienti restano possibili anche fuori dal rush")


func _test_lighting_profile() -> void:
	var midnight := manager.lighting_profile_for_minute(0.0)
	var midday := manager.lighting_profile_for_minute(720.0)
	var morning := manager.lighting_profile_for_minute(540.0)
	_expect(float(midday.daylight) > float(midnight.daylight), "il profilo luce distingue giorno e notte")
	_expect(float(midday.sun_energy) > float(midnight.sun_energy), "il sole e piu intenso a mezzogiorno")
	_expect(float(midnight.lamp_energy) > float(midday.lamp_energy), "i lampioni sono attivi soprattutto di notte")
	_expect(float(morning.daylight) > float(midnight.daylight) and float(morning.daylight) < float(midday.daylight), "la transizione mattutina e graduale")
	_expect(midday.background_color is Color and midnight.ambient_color is Color, "il profilo espone colori compatibili con mobile e GL")


func _test_daily_payroll_and_reward() -> void:
	GameState.employees = [
		{"id": "payroll_a", "salary": 70},
		{"id": "payroll_b", "salary": 50},
	]
	GameState.money = 80
	GameState.progress.erase("last_payroll_day")
	GameState.progress.erase("last_album_reward_day")
	GameState.progress.erase("wage_debt")
	var album_before := 0
	for amount: Variant in GameState.album_inventory.values():
		album_before += int(amount)
	manager.reset_event_history()
	manager.set_clock(20, 1439.0)
	manager.advance_seconds(_seconds_for_game_minutes(2.0), 1.0, "open")
	var album_after := 0
	for amount: Variant in GameState.album_inventory.values():
		album_after += int(amount)
	_expect(int(GameState.progress.get("last_payroll_day", 0)) == 20, "il payroll viene registrato per il giorno concluso")
	_expect(GameState.money == 0 and int(GameState.progress.get("wage_debt", 0)) == 40, "fondi insufficienti producono debito salariale recuperabile senza denaro negativo")
	_expect(int(GameState.progress.get("last_album_reward_day", 0)) == 20 and album_after == album_before + 1, "il completamento giorno assegna una sola ricompensa album")
	var duplicate: Dictionary = EconomyManager.process_daily_payroll(20)
	_expect(not bool(duplicate.processed) and int(GameState.progress.wage_debt) == 40, "lo stesso giorno non puo addebitare due volte gli stipendi")
	GameState.money = 200
	manager.reset_event_history()
	manager.set_clock(21, 1439.0)
	manager.advance_seconds(_seconds_for_game_minutes(2.0), 1.0, "open")
	_expect(GameState.money == 40 and int(GameState.progress.get("wage_debt", -1)) == 0, "il giorno successivo paga stipendio e debito precedente, poi azzera il debito")


func _seconds_for_game_minutes(game_minutes: float) -> float:
	return game_minutes * float(DataRegistry.balance_value("day_cycle.real_seconds_at_1x", 1.0)) / 1440.0


func _clear_events() -> void:
	warning_events.clear()
	started_events.clear()
	ended_events.clear()
	completed_days.clear()
	completed_clock_days.clear()
	period_events.clear()


func _on_rush_warning(rush_id: String, _seconds_remaining: float) -> void:
	warning_events.append(rush_id)


func _on_rush_started(rush_id: String) -> void:
	started_events.append(rush_id)


func _on_rush_ended(rush_id: String) -> void:
	ended_events.append(rush_id)


func _on_day_completed(completed_day: int) -> void:
	completed_days.append(completed_day)
	completed_clock_days.append(int(GameState.world_clock.day))


func _on_period_changed(period_id: String) -> void:
	period_events.append(period_id)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
