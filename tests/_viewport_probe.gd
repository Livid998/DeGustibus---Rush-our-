extends Node


func _ready() -> void:
	await get_tree().process_frame
	print(
		"WINDOW=", get_window().size,
		" VISIBLE=", get_viewport_rect().size,
		" DISPLAY=", DisplayServer.window_get_size()
	)
	get_tree().quit()
