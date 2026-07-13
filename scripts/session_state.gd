class_name SessionState
extends Node

signal changed

enum Phase { MENU, PREP_SELECT, PREP, BRIEFING, SERVICE, BREAKDOWN, SUMMARY, DEBRIEF }

var phase: Phase = Phase.MENU
var prep_profile := "standard"
var prep_time_left := 45.0
var service_time_left := 420.0
var service_elapsed := 0.0
var directives: Array[String] = []
var selected_recipe := "burger"
var selected_order_id := 0
var carried_item := ""
var carried_since := 0.0
var anger := 0.0
var max_anger := 0.0
var reputation := 50.0
var money := 0
var labor_cost := 60
var waste_cost := 0
var dishes_succeeded := 0
var dishes_failed := 0
var customers_happy := 0
var customers_fled := 0
var wrong_hits := 0
var problematic_ejected := 0
var catering_contract := {}
var special_real := 5
var special_estimated := 4
var special_communicated := -1
var special_promised := 0
var mise_en_place := 0
var incidents: Array[Dictionary] = []
var staff_state := {}
var settings := {
	"music": 0.55,
	"sfx": 0.75,
	"camera_sensitivity": 0.20,
	"camera_distance": 6.2,
	"camera_fov": 68.0,
	"subtitles": true,
}
var persistent := {
	"best_score": 0,
	"reputation": 50.0,
	"catering_won": false,
	"staff_learning": {"cassiera": 0, "waiter": 0, "assistant": 0},
}

func _ready() -> void:
	load_save()

func reset_run() -> void:
	prep_time_left = 45.0
	service_time_left = 420.0
	service_elapsed = 0.0
	directives.clear()
	selected_recipe = "burger"
	selected_order_id = 0
	carried_item = ""
	carried_since = 0.0
	anger = 0.0
	max_anger = 0.0
	reputation = float(persistent.reputation)
	money = 0
	waste_cost = 0
	dishes_succeeded = 0
	dishes_failed = 0
	customers_happy = 0
	customers_fled = 0
	wrong_hits = 0
	problematic_ejected = 0
	catering_contract = {}
	special_real = 5
	special_estimated = 4
	special_communicated = -1
	special_promised = 0
	mise_en_place = 0
	incidents.clear()
	staff_state.clear()
	for key in GameData.STAFF:
		staff_state[key] = {
			"stress": 0.0,
			"mood": float(GameData.STAFF[key].mood),
			"trust": 60.0,
			"learning": int(persistent.staff_learning.get(key, 0)),
		}

func configure_prep(profile: String) -> void:
	prep_profile = profile
	var data: Dictionary = GameData.PREP_PROFILES[profile]
	labor_cost = int(data.cost)
	mise_en_place = int(data.mise)
	special_real = 5 + int(data.mise)
	for key in staff_state:
		staff_state[key].stress = float(data.stress)
	changed.emit()

func set_phase(value: Phase) -> void:
	phase = value
	changed.emit()

func add_anger(amount: float, reason := "") -> void:
	anger = clampf(anger + amount, 0.0, 100.0)
	max_anger = maxf(max_anger, anger)
	if not reason.is_empty() and amount >= 3.0:
		incidents.append({"actor": "chef", "text": reason, "severity": amount})
	changed.emit()

func add_staff_stress(key: String, amount: float) -> void:
	if staff_state.has(key):
		staff_state[key].stress = clampf(float(staff_state[key].stress) + amount, 0.0, 100.0)
	changed.emit()

func score() -> int:
	return money + dishes_succeeded * 40 + customers_happy * 25 - labor_cost - waste_cost - wrong_hits * 120 + int(reputation * 5.0)

func save_progress() -> void:
	var current_score := score()
	persistent.best_score = maxi(int(persistent.best_score), current_score)
	persistent.reputation = reputation
	persistent.catering_won = bool(persistent.catering_won) or not catering_contract.is_empty()
	for key in staff_state:
		persistent.staff_learning[key] = int(staff_state[key].learning)
	var cfg := ConfigFile.new()
	for key in persistent:
		cfg.set_value("progress", key, persistent[key])
	for key in settings:
		cfg.set_value("settings", key, settings[key])
	cfg.save("user://rush_hour_save.cfg")

func load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://rush_hour_save.cfg") != OK:
		return
	for key in persistent:
		persistent[key] = cfg.get_value("progress", key, persistent[key])
	for key in settings:
		settings[key] = cfg.get_value("settings", key, settings[key])
