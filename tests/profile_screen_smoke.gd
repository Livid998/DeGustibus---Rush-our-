extends Node

var failures: Array[String] = []
var checks := 0
var emitted_profiles: Array[Dictionary] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	SaveManager.writes_enabled = false
	GameState.reset_to_defaults(false)

	var presets_text := FileAccess.get_file_as_string("res://data/avatar_presets.json")
	var parsed: Variant = JSON.parse_string(presets_text)
	_expect(parsed is Array, "avatar_presets.json is a valid JSON array")
	var presets: Array = parsed if parsed is Array else []
	var preset_paths: Dictionary = {}
	var appearances: Dictionary = {}
	var all_models_load := true
	var all_names_readable := true
	var fake_uniform_variants := false
	for raw: Variant in presets:
		if not raw is Dictionary:
			all_models_load = false
			continue
		var preset := raw as Dictionary
		var path := String(preset.get("model", ""))
		var appearance := String(preset.get("appearance", ""))
		preset_paths[path] = true
		appearances[appearance] = true
		all_names_readable = all_names_readable and not String(preset.get("name", "")).strip_edges().is_empty()
		all_models_load = all_models_load and ResourceLoader.exists(path) and load(path) is PackedScene
		fake_uniform_variants = fake_uniform_variants or preset.has("uniform_variant") or preset.has("uniform_variants")
	var character_models: PackedStringArray = []
	for file_name: String in DirAccess.get_files_at("res://assets/characters"):
		if file_name.get_extension().to_lower() == "gltf":
			character_models.append("res://assets/characters/%s" % file_name)
	var catalogue_is_complete := true
	for model_path: String in character_models:
		catalogue_is_complete = catalogue_is_complete and preset_paths.has(model_path)
	_expect(presets.size() == character_models.size() and presets.size() == 19, "every available character GLTF has exactly one avatar preset")
	_expect(catalogue_is_complete and appearances.size() == presets.size(), "avatar preset paths and appearance ids are complete and unique")
	_expect(all_models_load and all_names_readable, "every avatar preset resolves to a loadable PackedScene and a readable name")
	_expect(not fake_uniform_variants, "the preset catalogue does not advertise a uniform variant unsupported by real assets")

	var screen := ProfileScreen.create()
	add_child(screen)
	screen.profile_changed.connect(func(value: Dictionary): emitted_profiles.append(value.duplicate(true)))
	await get_tree().process_frame
	await get_tree().process_frame

	var initial_descendant_count := _descendant_count(screen)
	var preview := screen.find_child("AvatarModelPreview", true, false) as ModelPreview
	var fallback := screen.find_child("AvatarFallback", true, false) as TextureRect
	var uniform_row := screen.find_child("UniformVariantRow", true, false) as HBoxContainer
	var badge_label := screen.find_child("StarterBadgeLabel", true, false) as Label
	var player_edit := screen.find_child("PlayerNameEdit", true, false) as LineEdit
	var restaurant_edit := screen.find_child("RestaurantNameEdit", true, false) as LineEdit
	var preview_instance_id := preview.get_instance_id() if preview != null else 0

	_expect(screen.hierarchy_build_count() == 1 and screen.preset_count() == presets.size(), "ProfileScreen constructs one persistent hierarchy and loads every preset")
	_expect(preview != null and preview.model_root != null and preview.model_root.get_children().is_empty() and not preview.visible, "ModelPreview is present but loads no model before an explicit request")
	_expect(fallback != null and fallback.visible and fallback.texture == GameIcons.casual_system_icon("profile_avatar"), "the generated GameIcons profile avatar is the initial fallback")
	_expect(uniform_row != null and not uniform_row.visible, "uniform controls stay hidden when the selected asset has no real variant")
	_expect(badge_label != null and "Starter" in badge_label.text, "the starter badge is visible without an emoji placeholder")
	_expect(player_edit != null and player_edit.max_length == ProfileScreen.PLAYER_NAME_LIMIT and restaurant_edit != null and restaurant_edit.max_length == ProfileScreen.RESTAURANT_NAME_LIMIT, "both profile name inputs enforce sensible hard limits")

	var first_appearance := String(screen.current_profile().get("avatar_appearance", ""))
	screen.select_next_preset()
	var next_appearance := String(screen.current_profile().get("avatar_appearance", ""))
	_expect(next_appearance != first_appearance and String(GameState.restaurant_profile.get("avatar_appearance", "")) == next_appearance, "preset navigation immediately updates the profile through GameState")
	_expect(emitted_profiles.size() == 1 and String(emitted_profiles[0].get("avatar_appearance", "")) == next_appearance, "ProfileScreen emits one event-driven profile_changed signal per committed selection")

	var long_restaurant_name := "  De\tGustibus   Rush\nHour " + "X".repeat(48)
	screen.set_profile({
		"player_name":" \tLi\nvi%s " % String.chr(1),
		"restaurant_name":long_restaurant_name,
		"avatar_appearance":"missing_avatar",
		"badge_id":"unsupported_badge",
		"uniform_variant":99
	})
	var sanitized := screen.current_profile()
	var sanitized_player := String(sanitized.get("player_name", ""))
	var sanitized_restaurant := String(sanitized.get("restaurant_name", ""))
	_expect(sanitized_player == "Li vi" and sanitized_restaurant.length() <= ProfileScreen.RESTAURANT_NAME_LIMIT and sanitized_restaurant == sanitized_restaurant.strip_edges(), "profile names are stripped, normalized and truncated deterministically")
	_expect(not _has_control_character(sanitized_player) and not _has_control_character(sanitized_restaurant) and not "  " in sanitized_restaurant, "saved names contain no control characters or repeated whitespace")
	_expect(String(GameState.restaurant_profile.get("player_name", "")) == sanitized_player and GameState.restaurant_profile == sanitized, "set_profile persists immediately and exclusively through GameState.set_restaurant_profile")
	_expect(appearances.has(String(sanitized.get("avatar_appearance", ""))) and String(sanitized.get("badge_id", "")) == "starter" and int(sanitized.get("uniform_variant", -1)) == 0, "invalid avatar, badge and unsupported uniform values normalize to real options")

	var external_profile := sanitized.duplicate(true)
	external_profile.player_name = "Profilo esterno"
	external_profile.avatar_appearance = "Chef_Female"
	GameState.set_restaurant_profile(external_profile)
	_expect(screen.current_profile() == GameState.restaurant_profile and player_edit.text == "Profilo esterno", "external GameState profile changes refresh the existing screen through its signal")

	for _iteration: int in 5:
		screen.refresh()
	_expect(screen.hierarchy_build_count() == 1 and _descendant_count(screen) == initial_descendant_count and preview.get_instance_id() == preview_instance_id, "refreshing profile data never rebuilds controls or the ModelPreview")

	screen.request_avatar_preview()
	await get_tree().process_frame
	await get_tree().process_frame
	if DisplayServer.get_name() == "headless":
		_expect(not preview.visible and fallback.visible and preview.model_root.get_children().is_empty(), "headless preview requests safely retain the fallback without rendering a 3D model")
	else:
		_expect(preview.visible and not fallback.visible and not preview.model_root.get_children().is_empty(), "a visible preview request loads exactly the selected character model")
	_expect(screen.avatar_texture_or_icon() != null, "avatar_texture_or_icon always exposes a usable preview texture or generated fallback")

	var result := "PROFILE SCREEN SMOKE: %s | checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()]
	print(result)
	for failure: String in failures:
		print(failure)
	screen.queue_free()
	get_tree().quit(0 if failures.is_empty() else 1)


func _descendant_count(root: Node) -> int:
	var result := 0
	for child: Node in root.get_children():
		result += 1 + _descendant_count(child)
	return result


func _has_control_character(value: String) -> bool:
	for index: int in value.length():
		var code := value.unicode_at(index)
		if code < 32 or code == 127:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
