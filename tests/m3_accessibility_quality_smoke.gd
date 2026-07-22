extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var previous_writes := SaveManager.writes_enabled
	SaveManager.writes_enabled = false
	var original := GameState.serialize().duplicate(true)
	var legacy := original.duplicate(true)
	legacy.settings.graphics_quality = "balanced"
	legacy.settings.erase("music_volume")
	legacy.settings.erase("high_contrast")
	GameState.deserialize(legacy)
	_expect(String(GameState.settings.graphics_quality) == "medium", "legacy balanced graphics setting migrates to Media")
	_expect(GameState.settings.has("music_volume") and GameState.settings.has("high_contrast"), "additive accessibility/audio defaults load into old v12 saves")
	_expect(WebPlatformProfile.normalize_preset("ultra") == "high" and WebPlatformProfile.normalize_preset("invalid") == "auto", "obsolete and invalid quality aliases normalize safely")

	for preset: String in ["auto", "low", "medium", "high"]:
		WebPlatformProfile.apply_quality(preset)
		_expect(WebPlatformProfile.current_quality == preset, "%s is an authoritative quality preset" % preset)

	GameState.reset_to_defaults(false)
	var world := RestaurantWorld.new()
	add_child(world)
	var ui := RestaurantUI.new()
	add_child(ui)
	ui.setup(world)
	ui.show_screen("Impostazioni", false)
	await get_tree().process_frame
	await get_tree().process_frame
	var settings_page := ui.screen_page("Impostazioni")
	var quality := settings_page.find_child("GraphicsQuality", true, false) as OptionButton
	var quality_ids: Array[String] = []
	for index: int in quality.item_count:
		quality_ids.append(String(quality.get_item_metadata(index)))
	_expect(quality_ids == ["auto", "low", "medium", "high"], "settings exposes exactly Auto/Bassa/Media/Alta")
	for control_name: String in ["MusicEnabled", "SoundEnabled", "MusicVolume", "AmbienceVolume", "SFXVolume", "UIVolume", "HighContrast", "ReducedMotion"]:
		var control := settings_page.find_child(control_name, true, false) as Control
		_expect(control != null and control.custom_minimum_size.y >= 44.0, "%s has a 44 px touch target" % control_name)
	_expect(_all_interactive_targets_are_touch_sized(ui.root), "every visible shell/management interactive control is at least 44 px high")

	var normal_style := ui._button_style("blue") as StyleBoxFlat
	GameState.settings.high_contrast = true
	ui.apply_accessibility_settings()
	var contrast_style := ui._button_style("blue") as StyleBoxFlat
	_expect(contrast_style.get_border_width(SIDE_LEFT) > normal_style.get_border_width(SIDE_LEFT), "high contrast adds a stronger non-color-only control outline")
	_expect(ui.root.theme.get_stylebox("focus", "Button") != null, "keyboard focus has a visible common style")

	GameState.settings.reduced_motion = true
	var camera := RestaurantCamera.new()
	add_child(camera)
	await get_tree().process_frame
	camera.target = Vector3(3.0, 0.0, 2.0)
	camera.zoom = 19.0
	camera._process(0.016)
	_expect(camera.global_position.is_equal_approx(camera.target) and is_equal_approx(camera.camera.size, 19.0), "reduced motion applies camera pan/zoom immediately without interpolation")
	var previous_quadrant := camera.quadrant
	camera.rotate_right()
	_expect(camera.quadrant == posmod(previous_quadrant + 1, 4) and not camera.is_rotating(), "reduced motion camera rotation completes without a tween")

	var result := "M3 ACCESSIBILITY QUALITY: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/m3-accessibility-quality-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	var exit_code := 0 if failures.is_empty() else 1
	ui.queue_free()
	world.queue_free()
	camera.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	GameState.deserialize(original)
	WebPlatformProfile.apply_quality(String(GameState.settings.get("graphics_quality", "auto")))
	SaveManager.writes_enabled = previous_writes
	get_tree().quit(exit_code)


func _all_interactive_targets_are_touch_sized(node: Node) -> bool:
	if node is Control:
		var control := node as Control
		if control.visible and (control is BaseButton or control is LineEdit or control is SpinBox or control is HSlider or control is VSlider):
			if control.custom_minimum_size.y < 44.0:
				return false
	for child: Node in node.get_children():
		if not _all_interactive_targets_are_touch_sized(child):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
