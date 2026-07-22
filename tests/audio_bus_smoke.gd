extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	var ids := AudioManager.registered_effect_ids()
	_expect(ids.size() >= 24, "audio registry exposes at least 24 production event ids")
	for required: String in [
		"tap", "confirm", "warning", "income", "order_ticket", "chop", "mix",
		"burner_ignite", "sizzle", "oven_open", "fridge_open", "plate_pickup",
		"dish_serve", "eat_bite", "dishes", "scrub", "sweep", "door",
	]:
		_expect(ids.has(required), "audio registry contains %s" % required)
	var snapshot := AudioManager.mix_snapshot()
	_expect(snapshot.get("buses", []) == ["Music", "Ambience", "SFX", "UI"], "audio mixer exposes the four canonical buses")
	_expect(int(snapshot.get("effects", 0)) == ids.size(), "audio mixer reports the complete registry")
	_expect(AudioManager.MUSIC_TRACKS == ["closed_cozy", "service_rush"], "two distinct music contexts are registered")
	_expect(AudioManager.AMBIENCE_TRACKS == ["dining_room", "street"], "room and street ambience contexts are registered")
	for event_id: String in ids:
		var definition: Dictionary = AudioManager.EFFECTS[event_id]
		_expect(float(definition.get("cooldown", 0.0)) > 0.0, "%s has an explicit cooldown" % event_id)
		_expect(String(definition.get("bus", "")) in ["SFX", "UI"], "%s routes to a canonical effect bus" % event_id)

	_expect(EmployeeAgent.maintenance_audio_event("wash_dishes") == "dishes", "dish washing starts with the dishes cue")
	_expect(EmployeeAgent.maintenance_audio_event("clean_spill") == "scrub", "spill cleaning starts with the scrub cue")
	_expect(EmployeeAgent.maintenance_audio_event("clean_kitchen") == "scrub", "kitchen cleaning starts with the scrub cue")
	_expect(EmployeeAgent.maintenance_audio_event("clean_floor") == "sweep", "floor cleaning starts with the sweep cue")
	_expect(EmployeeAgent.maintenance_audio_event("remove_pest").is_empty(), "unsupported maintenance actions do not borrow a misleading cue")

	var result := "AUDIO BUS SMOKE: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/audio-bus-smoke-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
