extends Node

var enabled := true
var player: AudioStreamPlayer
var tone_cache: Dictionary = {}

const MIX_RATE := 22050
const TONE_SECONDS := 0.055


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		enabled = false
		return
	# Cached one-shot samples avoid keeping an empty streaming audio generator
	# active for the whole browser session.
	player = AudioStreamPlayer.new()
	player.volume_db = -18.0
	add_child(player)


func _exit_tree() -> void:
	if player:
		player.stop()
		player.stream = null
		if player.get_parent() == self:
			remove_child(player)
		player.free()
	player = null
	tone_cache.clear()


func play_feedback(kind: String = "tap") -> void:
	if not enabled or not GameState.settings.get("sound", true) or player == null:
		return
	if not tone_cache.has(kind):
		var frequency: float = float({"tap": 520.0, "income": 760.0, "warning": 230.0}.get(kind, 520.0))
		tone_cache[kind] = _create_tone(frequency)
	player.stream = tone_cache[kind]
	player.play()


func _create_tone(frequency: float) -> AudioStreamWAV:
	var frame_count := int(MIX_RATE * TONE_SECONDS)
	var data := PackedByteArray()
	data.resize(frame_count * 2)
	for frame: int in frame_count:
		var envelope := 1.0 - float(frame) / float(frame_count)
		var sample := sin(TAU * frequency * float(frame) / float(MIX_RATE)) * 0.09 * envelope
		data.encode_s16(frame * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	var tone := AudioStreamWAV.new()
	tone.format = AudioStreamWAV.FORMAT_16_BITS
	tone.mix_rate = MIX_RATE
	tone.stereo = false
	tone.data = data
	return tone
