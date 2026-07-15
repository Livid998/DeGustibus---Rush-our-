extends Node

var enabled := true
var player: AudioStreamPlayer
var generator: AudioStreamGenerator


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		enabled = false
		return
	generator = AudioStreamGenerator.new()
	generator.mix_rate = 22050.0
	generator.buffer_length = 0.25
	player = AudioStreamPlayer.new()
	player.stream = generator
	player.volume_db = -18.0
	add_child(player)
	player.play()


func _exit_tree() -> void:
	if player:
		player.stop()
		player.stream = null
		if player.get_parent() == self:
			remove_child(player)
		player.free()
	player = null
	generator = null


func play_feedback(kind: String = "tap") -> void:
	if not enabled or not GameState.settings.get("sound", true) or player == null:
		return
	if not player.playing:
		player.play()
	var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		return
	var frequency: float = float({"tap": 520.0, "income": 760.0, "warning": 230.0}.get(kind, 520.0))
	var frame_count := int(generator.mix_rate * 0.055)
	for frame: int in frame_count:
		var envelope := 1.0 - float(frame) / frame_count
		var sample := sin(TAU * frequency * float(frame) / generator.mix_rate) * 0.09 * envelope
		if playback.get_frames_available() > 0:
			playback.push_frame(Vector2(sample, sample))
