extends Node

var world: RestaurantWorld
var ui: RestaurantUI


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	SaveManager.load_game()
	WebPlatformProfile.apply_quality(String(GameState.settings.get("graphics_quality", "auto")))
	AudioManager.apply_settings()
	world = RestaurantWorld.new()
	add_child(world)
	ui = RestaurantUI.new()
	add_child(ui)
	ui.setup(world)
	GameState.employees_changed.connect(world.spawn_staff)
	get_window().min_size = Vector2i(320, 320) if OS.has_feature("web") else Vector2i(800, 540)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		SaveManager.save_game()
		get_tree().quit()
