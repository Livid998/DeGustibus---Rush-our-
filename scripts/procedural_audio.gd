class_name ProceduralAudio
extends Node

var sfx_player := AudioStreamPlayer.new()
var music_player := AudioStreamPlayer.new()
var settings: Dictionary
var music_level := 0

func setup(value: Dictionary) -> void:
	settings = value
	add_child(sfx_player)
	add_child(music_player)
	music_player.stream = _make_music(0)
	music_player.volume_db = linear_to_db(float(settings.music))
	music_player.play()

func apply_settings() -> void:
	if settings.is_empty():
		return
	music_player.volume_db = linear_to_db(maxf(0.001, float(settings.music)))
	sfx_player.volume_db = linear_to_db(maxf(0.001, float(settings.sfx)))

func set_pressure(value: float) -> void:
	var target := 0
	if value > 75.0:
		target = 3
	elif value > 45.0:
		target = 2
	elif value > 18.0:
		target = 1
	if target == music_level:
		return
	music_level = target
	var position := music_player.get_playback_position()
	music_player.stream = _make_music(target)
	music_player.play(position)

func cue(kind: String) -> void:
	var spec: Array = {
		"interact": [620.0, 0.08, 0.25],
		"order": [880.0, 0.16, 0.35],
		"success": [1040.0, 0.18, 0.45],
		"error": [180.0, 0.24, 0.55],
		"breakdown": [120.0, 0.55, 0.75],
		"hit": [95.0, 0.12, 0.8],
	}.get(kind, [440.0, 0.1, 0.3])
	sfx_player.stream = _make_tone(float(spec[0]), float(spec[1]), float(spec[2]))
	sfx_player.volume_db = linear_to_db(maxf(0.001, float(settings.sfx)))
	sfx_player.play()

func _make_tone(frequency: float, duration: float, amplitude: float) -> AudioStreamWAV:
	var rate := 22050
	var count := int(rate * duration)
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i in count:
		var envelope := 1.0 - float(i) / float(count)
		var sample := sin(TAU * frequency * float(i) / float(rate)) * amplitude * envelope
		bytes.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	return wav

func _make_music(level: int) -> AudioStreamWAV:
	var rate := 22050
	var duration := 4.0
	var count := int(rate * duration)
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	var bpm := 92.0 + level * 22.0
	var beat := 60.0 / bpm
	var notes := [110.0, 138.59, 164.81, 146.83]
	for i in count:
		var time := float(i) / float(rate)
		var note_index := int(time / beat) % notes.size()
		var pulse := fmod(time, beat) / beat
		var bass := sin(TAU * notes[note_index] * time) * 0.10 * (1.0 - pulse * 0.55)
		var click := 0.0
		if pulse < 0.06:
			click = sin(TAU * (520.0 + level * 90.0) * time) * 0.035 * (1.0 - pulse / 0.06)
		var sample := bass + click
		bytes.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = count
	wav.data = bytes
	return wav
