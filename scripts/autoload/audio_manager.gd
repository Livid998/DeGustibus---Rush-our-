extends Node

signal mix_changed(snapshot: Dictionary)

const BUS_MUSIC := "Music"
const BUS_AMBIENCE := "Ambience"
const BUS_SFX := "SFX"
const BUS_UI := "UI"
const MIX_RATE := 11025
const ONE_SHOT_POOL_SIZE := 8

# The game can replace any generated fallback with a licensed file later without
# changing call sites. Until then these definitions provide distinct, deterministic
# feedback instead of the former three placeholder beeps.
const EFFECTS := {
	"tap": {"bus": BUS_UI, "wave": "sine", "hz": 540.0, "end_hz": 620.0, "seconds": 0.055, "gain": 0.11, "cooldown": 0.035},
	"confirm": {"bus": BUS_UI, "wave": "triangle", "hz": 520.0, "end_hz": 790.0, "seconds": 0.11, "gain": 0.12, "cooldown": 0.08},
	"cancel": {"bus": BUS_UI, "wave": "triangle", "hz": 420.0, "end_hz": 260.0, "seconds": 0.10, "gain": 0.10, "cooldown": 0.08},
	"page": {"bus": BUS_UI, "wave": "noise", "hz": 900.0, "end_hz": 520.0, "seconds": 0.07, "gain": 0.055, "cooldown": 0.06},
	"purchase": {"bus": BUS_UI, "wave": "sine", "hz": 620.0, "end_hz": 980.0, "seconds": 0.16, "gain": 0.12, "cooldown": 0.14},
	"warning": {"bus": BUS_UI, "wave": "square", "hz": 250.0, "end_hz": 210.0, "seconds": 0.13, "gain": 0.065, "cooldown": 0.35},
	"notification": {"bus": BUS_UI, "wave": "sine", "hz": 720.0, "end_hz": 880.0, "seconds": 0.09, "gain": 0.10, "cooldown": 0.20},
	"income": {"bus": BUS_SFX, "wave": "sine", "hz": 760.0, "end_hz": 1160.0, "seconds": 0.18, "gain": 0.13, "cooldown": 0.12},
	"coin": {"bus": BUS_SFX, "wave": "triangle", "hz": 980.0, "end_hz": 1460.0, "seconds": 0.10, "gain": 0.09, "cooldown": 0.08},
	"order_ticket": {"bus": BUS_SFX, "wave": "noise", "hz": 740.0, "end_hz": 360.0, "seconds": 0.13, "gain": 0.07, "cooldown": 0.16},
	"ingredient_pickup": {"bus": BUS_SFX, "wave": "triangle", "hz": 330.0, "end_hz": 470.0, "seconds": 0.08, "gain": 0.075, "cooldown": 0.10},
	"chop": {"bus": BUS_SFX, "wave": "noise", "hz": 1150.0, "end_hz": 170.0, "seconds": 0.055, "gain": 0.11, "cooldown": 0.09},
	"mix": {"bus": BUS_SFX, "wave": "noise", "hz": 420.0, "end_hz": 260.0, "seconds": 0.16, "gain": 0.055, "cooldown": 0.20},
	"knead": {"bus": BUS_SFX, "wave": "noise", "hz": 210.0, "end_hz": 130.0, "seconds": 0.12, "gain": 0.07, "cooldown": 0.20},
	"burner_ignite": {"bus": BUS_SFX, "wave": "noise", "hz": 980.0, "end_hz": 180.0, "seconds": 0.19, "gain": 0.085, "cooldown": 0.35},
	"sizzle": {"bus": BUS_SFX, "wave": "noise", "hz": 1700.0, "end_hz": 680.0, "seconds": 0.32, "gain": 0.045, "cooldown": 0.42},
	"oven_open": {"bus": BUS_SFX, "wave": "noise", "hz": 180.0, "end_hz": 340.0, "seconds": 0.21, "gain": 0.075, "cooldown": 0.25},
	"oven_close": {"bus": BUS_SFX, "wave": "noise", "hz": 260.0, "end_hz": 95.0, "seconds": 0.14, "gain": 0.105, "cooldown": 0.25},
	"fridge_open": {"bus": BUS_SFX, "wave": "triangle", "hz": 170.0, "end_hz": 260.0, "seconds": 0.20, "gain": 0.065, "cooldown": 0.25},
	"fridge_close": {"bus": BUS_SFX, "wave": "noise", "hz": 240.0, "end_hz": 110.0, "seconds": 0.12, "gain": 0.09, "cooldown": 0.25},
	"plate_pickup": {"bus": BUS_SFX, "wave": "sine", "hz": 1140.0, "end_hz": 920.0, "seconds": 0.07, "gain": 0.06, "cooldown": 0.10},
	"plate_place": {"bus": BUS_SFX, "wave": "sine", "hz": 860.0, "end_hz": 520.0, "seconds": 0.09, "gain": 0.07, "cooldown": 0.12},
	"dish_serve": {"bus": BUS_SFX, "wave": "triangle", "hz": 480.0, "end_hz": 720.0, "seconds": 0.12, "gain": 0.08, "cooldown": 0.16},
	"eat_bite": {"bus": BUS_SFX, "wave": "noise", "hz": 310.0, "end_hz": 190.0, "seconds": 0.08, "gain": 0.035, "cooldown": 0.55},
	"glass": {"bus": BUS_SFX, "wave": "sine", "hz": 1320.0, "end_hz": 980.0, "seconds": 0.14, "gain": 0.05, "cooldown": 0.30},
	"dishes": {"bus": BUS_SFX, "wave": "noise", "hz": 1450.0, "end_hz": 360.0, "seconds": 0.19, "gain": 0.065, "cooldown": 0.28},
	"scrub": {"bus": BUS_SFX, "wave": "noise", "hz": 680.0, "end_hz": 420.0, "seconds": 0.22, "gain": 0.045, "cooldown": 0.28},
	"sweep": {"bus": BUS_SFX, "wave": "noise", "hz": 520.0, "end_hz": 250.0, "seconds": 0.25, "gain": 0.04, "cooldown": 0.32},
	"door": {"bus": BUS_SFX, "wave": "triangle", "hz": 220.0, "end_hz": 310.0, "seconds": 0.16, "gain": 0.055, "cooldown": 0.22},
	"footstep": {"bus": BUS_SFX, "wave": "noise", "hz": 170.0, "end_hz": 90.0, "seconds": 0.045, "gain": 0.025, "cooldown": 0.16},
}

const MUSIC_TRACKS := ["closed_cozy", "service_rush"]
const AMBIENCE_TRACKS := ["dining_room", "street"]

var enabled := true
var _effect_cache: Dictionary = {}
var _loop_cache: Dictionary = {}
var _cooldowns: Dictionary = {}
var _one_shots: Array[AudioStreamPlayer] = []
var _pool_cursor := 0
var _music_player: AudioStreamPlayer
var _ambience_player: AudioStreamPlayer
var _current_music := ""
var _current_ambience := ""


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		enabled = false
		return
	_ensure_audio_buses()
	_create_players()
	_apply_saved_mix()
	if not GameState.restaurant_state_changed.is_connected(_on_restaurant_state_changed):
		GameState.restaurant_state_changed.connect(_on_restaurant_state_changed)
	_on_restaurant_state_changed(GameState.restaurant_state)
	set_ambience("dining_room")


func _process(delta: float) -> void:
	if _cooldowns.is_empty():
		return
	for event_id: String in _cooldowns.keys():
		var remaining := float(_cooldowns[event_id]) - delta
		if remaining <= 0.0:
			_cooldowns.erase(event_id)
		else:
			_cooldowns[event_id] = remaining


func _exit_tree() -> void:
	if GameState != null and GameState.restaurant_state_changed.is_connected(_on_restaurant_state_changed):
		GameState.restaurant_state_changed.disconnect(_on_restaurant_state_changed)
	for player: AudioStreamPlayer in _one_shots:
		_dispose_player(player)
	_one_shots.clear()
	_dispose_player(_music_player)
	_dispose_player(_ambience_player)
	_music_player = null
	_ambience_player = null
	_effect_cache.clear()
	_loop_cache.clear()
	_cooldowns.clear()


func play_feedback(kind: String = "tap") -> void:
	# Compatibility facade for existing UI/gameplay calls.
	play_event(kind if EFFECTS.has(kind) else "tap")


func play_ui(event_id: String = "tap") -> void:
	play_event(event_id if String(EFFECTS.get(event_id, {}).get("bus", "")) == BUS_UI else "tap")


func play_sfx(event_id: String, pitch_scale: float = 1.0) -> void:
	play_event(event_id, pitch_scale)


func play_event(event_id: String, pitch_scale: float = 1.0) -> void:
	if not enabled or _one_shots.is_empty() or not EFFECTS.has(event_id):
		return
	var definition: Dictionary = EFFECTS[event_id]
	var bus_name := String(definition.get("bus", BUS_SFX))
	if not _bus_setting_enabled(bus_name) or _cooldowns.has(event_id):
		return
	if not _effect_cache.has(event_id):
		_effect_cache[event_id] = _create_effect(definition, event_id.hash())
	var player := _next_one_shot()
	player.bus = bus_name
	player.pitch_scale = clampf(pitch_scale, 0.75, 1.30)
	player.stream = _effect_cache[event_id]
	player.play()
	_cooldowns[event_id] = maxf(float(definition.get("cooldown", 0.05)), 0.0)


func play_music(track_id: String, restart: bool = false) -> void:
	if track_id not in MUSIC_TRACKS or _music_player == null:
		return
	if _current_music == track_id and _music_player.playing and not restart:
		return
	_current_music = track_id
	if not _loop_cache.has(track_id):
		_loop_cache[track_id] = _create_music_loop(track_id)
	_music_player.stream = _loop_cache[track_id]
	if _bus_setting_enabled(BUS_MUSIC):
		_music_player.play()
	mix_changed.emit(mix_snapshot())


func set_ambience(context_id: String) -> void:
	if context_id not in AMBIENCE_TRACKS or _ambience_player == null:
		return
	if _current_ambience == context_id and _ambience_player.playing:
		return
	_current_ambience = context_id
	if not _loop_cache.has(context_id):
		_loop_cache[context_id] = _create_ambience_loop(context_id)
	_ambience_player.stream = _loop_cache[context_id]
	if _bus_setting_enabled(BUS_AMBIENCE):
		_ambience_player.play()
	mix_changed.emit(mix_snapshot())


func apply_settings() -> void:
	_apply_saved_mix()
	if _music_player != null:
		if _bus_setting_enabled(BUS_MUSIC) and not _current_music.is_empty():
			if not _music_player.playing:
				_music_player.play()
		else:
			_music_player.stop()
	if _ambience_player != null:
		if _bus_setting_enabled(BUS_AMBIENCE) and not _current_ambience.is_empty():
			if not _ambience_player.playing:
				_ambience_player.play()
		else:
			_ambience_player.stop()
	mix_changed.emit(mix_snapshot())


func set_bus_volume(bus_name: String, linear_value: float) -> void:
	var normalized := clampf(linear_value, 0.0, 1.0)
	var settings_key := _bus_settings_key(bus_name)
	if settings_key.is_empty():
		return
	GameState.settings[settings_key] = normalized
	GameState.mark_save_dirty()
	var index := AudioServer.get_bus_index(bus_name)
	if index >= 0:
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(normalized, 0.0001)))
		AudioServer.set_bus_mute(index, normalized <= 0.001 or not _bus_setting_enabled(bus_name))
	mix_changed.emit(mix_snapshot())


func registered_effect_ids() -> Array[String]:
	var result: Array[String] = []
	for event_id: String in EFFECTS:
		result.append(event_id)
	result.sort()
	return result


func mix_snapshot() -> Dictionary:
	return {
		"music": _current_music,
		"ambience": _current_ambience,
		"effects": EFFECTS.size(),
		"buses": [BUS_MUSIC, BUS_AMBIENCE, BUS_SFX, BUS_UI],
		"cooldowns": _cooldowns.size(),
	}


func _on_restaurant_state_changed(state: String) -> void:
	play_music("service_rush" if state in ["open", "closing"] else "closed_cozy")


func _ensure_audio_buses() -> void:
	for bus_name: String in [BUS_MUSIC, BUS_AMBIENCE, BUS_SFX, BUS_UI]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus(AudioServer.bus_count)
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)


func _create_players() -> void:
	_music_player = _new_player(BUS_MUSIC, -13.0)
	_ambience_player = _new_player(BUS_AMBIENCE, -17.0)
	for _index: int in ONE_SHOT_POOL_SIZE:
		_one_shots.append(_new_player(BUS_SFX, -10.0))


func _new_player(bus_name: String, volume_db: float) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.bus = bus_name
	player.volume_db = volume_db
	add_child(player)
	return player


func _dispose_player(player: AudioStreamPlayer) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.stop()
	player.stream = null
	if player.get_parent() == self:
		remove_child(player)
	player.free()


func _next_one_shot() -> AudioStreamPlayer:
	var player := _one_shots[_pool_cursor % _one_shots.size()]
	_pool_cursor = (_pool_cursor + 1) % _one_shots.size()
	return player


func _apply_saved_mix() -> void:
	for bus_name: String in [BUS_MUSIC, BUS_AMBIENCE, BUS_SFX, BUS_UI]:
		var index := AudioServer.get_bus_index(bus_name)
		if index < 0:
			continue
		var value := float(GameState.settings.get(_bus_settings_key(bus_name), 0.72 if bus_name == BUS_MUSIC else 0.82))
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(clampf(value, 0.0, 1.0), 0.0001)))
		AudioServer.set_bus_mute(index, value <= 0.001 or not _bus_setting_enabled(bus_name))


func _bus_setting_enabled(bus_name: String) -> bool:
	if bus_name == BUS_MUSIC:
		return bool(GameState.settings.get("music", true))
	return bool(GameState.settings.get("sound", true))


func _bus_settings_key(bus_name: String) -> String:
	return {
		BUS_MUSIC: "music_volume",
		BUS_AMBIENCE: "ambience_volume",
		BUS_SFX: "sfx_volume",
		BUS_UI: "ui_volume",
	}.get(bus_name, "")


func _create_effect(definition: Dictionary, seed_value: int) -> AudioStreamWAV:
	var seconds := float(definition.get("seconds", 0.1))
	var frame_count := maxi(int(MIX_RATE * seconds), 8)
	var data := PackedByteArray()
	data.resize(frame_count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for frame: int in frame_count:
		var progress := float(frame) / float(maxi(frame_count - 1, 1))
		var frequency := lerpf(float(definition.get("hz", 440.0)), float(definition.get("end_hz", definition.get("hz", 440.0))), progress)
		var phase := TAU * frequency * float(frame) / float(MIX_RATE)
		var waveform := _wave_sample(String(definition.get("wave", "sine")), phase, rng)
		var attack := minf(progress / 0.08, 1.0)
		var envelope := attack * pow(1.0 - progress, 1.7)
		var sample := waveform * float(definition.get("gain", 0.08)) * envelope
		data.encode_s16(frame * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	return _wav(data, false)


func _create_music_loop(track_id: String) -> AudioStreamWAV:
	var seconds := 12.0
	var frame_count := int(MIX_RATE * seconds)
	var data := PackedByteArray()
	data.resize(frame_count * 2)
	var notes: Array[float] = [261.63, 329.63, 392.0, 329.63, 293.66, 349.23, 440.0, 349.23]
	if track_id == "service_rush":
		notes = [329.63, 392.0, 493.88, 392.0, 349.23, 440.0, 523.25, 440.0]
	var beat_seconds := 0.75 if track_id == "closed_cozy" else 0.5
	for frame: int in frame_count:
		var time := float(frame) / float(MIX_RATE)
		var beat := int(time / beat_seconds) % notes.size()
		var local := fmod(time, beat_seconds) / beat_seconds
		var root: float = notes[beat]
		var melody := sin(TAU * root * time) * pow(1.0 - local, 2.2)
		var harmony := sin(TAU * root * 0.5 * time) * (0.35 + 0.25 * sin(TAU * time / seconds))
		var pulse := sin(TAU * (74.0 if track_id == "service_rush" else 62.0) * time) * pow(1.0 - local, 6.0)
		var sample := (melody * 0.055 + harmony * 0.04 + pulse * 0.018) * _loop_fade(time, seconds)
		data.encode_s16(frame * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	return _wav(data, true)


func _create_ambience_loop(context_id: String) -> AudioStreamWAV:
	var seconds := 8.0
	var frame_count := int(MIX_RATE * seconds)
	var data := PackedByteArray()
	data.resize(frame_count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 88421 if context_id == "dining_room" else 41277
	var smoothed := 0.0
	for frame: int in frame_count:
		var time := float(frame) / float(MIX_RATE)
		var noise := rng.randf_range(-1.0, 1.0)
		smoothed = lerpf(smoothed, noise, 0.012 if context_id == "dining_room" else 0.006)
		var tone := sin(TAU * (118.0 if context_id == "dining_room" else 54.0) * time) * 0.006
		var distant := sin(TAU * 0.17 * time) * smoothed
		var gain := 0.025 if context_id == "dining_room" else 0.032
		var sample := (distant * gain + tone) * _loop_fade(time, seconds)
		data.encode_s16(frame * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	return _wav(data, true)


func _loop_fade(time: float, seconds: float) -> float:
	# Matching short fades make generated loops click-free at their seam.
	var edge := 0.20
	return minf(minf(time / edge, (seconds - time) / edge), 1.0)


func _wave_sample(kind: String, phase: float, rng: RandomNumberGenerator) -> float:
	match kind:
		"triangle":
			return asin(sin(phase)) * (2.0 / PI)
		"square":
			return 1.0 if sin(phase) >= 0.0 else -1.0
		"noise":
			return rng.randf_range(-1.0, 1.0)
		_:
			return sin(phase)


func _wav(data: PackedByteArray, looped: bool) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	if looped:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = data.size() / 2
	return stream
