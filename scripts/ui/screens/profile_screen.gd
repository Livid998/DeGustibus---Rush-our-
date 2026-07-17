class_name ProfileScreen
extends VBoxContainer

signal profile_changed(value: Dictionary)

const PRESETS_PATH := "res://data/avatar_presets.json"
const PLAYER_NAME_LIMIT := 24
const RESTAURANT_NAME_LIMIT := 32

var _presets: Array[Dictionary] = []
var _profile: Dictionary = {}
var _preset_index := 0
var _hierarchy_build_count := 0
var _built := false
var _refreshing := false
var _preview_requested := false
var _preview_model_path := ""

var _player_name_edit: LineEdit
var _restaurant_name_edit: LineEdit
var _preset_name_label: Label
var _badge_label: Label
var _uniform_row: HBoxContainer
var _uniform_selector: OptionButton
var _fallback_avatar: TextureRect
var _model_preview: ModelPreview
var _preview_button: Button


static func create() -> ProfileScreen:
	var screen := ProfileScreen.new()
	screen.name = "ProfileScreen"
	return screen


func _ready() -> void:
	_ensure_presets_loaded()
	_ensure_hierarchy()
	var callback := Callable(self, "_on_game_state_profile_changed")
	if not GameState.restaurant_profile_changed.is_connected(callback):
		GameState.restaurant_profile_changed.connect(callback)
	_apply_profile(GameState.restaurant_profile, false)


func _exit_tree() -> void:
	var callback := Callable(self, "_on_game_state_profile_changed")
	if GameState.restaurant_profile_changed.is_connected(callback):
		GameState.restaurant_profile_changed.disconnect(callback)


func refresh() -> void:
	_ensure_presets_loaded()
	_ensure_hierarchy()
	_apply_profile(GameState.restaurant_profile, false)


func set_profile(value: Dictionary) -> void:
	_commit_profile(value, true)


func current_profile() -> Dictionary:
	if _profile.is_empty():
		_ensure_presets_loaded()
		_profile = _normalize_profile(GameState.restaurant_profile, false)
	return _profile.duplicate(true)


func avatar_texture_or_icon() -> Texture2D:
	if _preview_requested and not _is_headless() and _model_preview != null and _model_preview.viewport_3d != null:
		var preview_texture := _model_preview.viewport_3d.get_texture()
		if preview_texture != null:
			return preview_texture
	return GameIcons.casual_system_icon("profile_avatar")


func request_avatar_preview() -> void:
	_preview_requested = true
	if _preview_button != null:
		_preview_button.disabled = true
	if _is_headless() or _model_preview == null or not is_inside_tree():
		if _fallback_avatar != null:
			_fallback_avatar.visible = true
		if _model_preview != null:
			_model_preview.visible = false
		return
	var model_path := _current_model_path()
	_fallback_avatar.visible = false
	_model_preview.visible = true
	if model_path == _preview_model_path and _model_preview.model_root != null and not _model_preview.model_root.get_children().is_empty():
		return
	_preview_model_path = model_path
	_model_preview.set_model(model_path)


func select_previous_preset() -> void:
	if _presets.is_empty():
		return
	_select_preset_index(posmod(_preset_index - 1, _presets.size()))


func select_next_preset() -> void:
	if _presets.is_empty():
		return
	_select_preset_index(posmod(_preset_index + 1, _presets.size()))


func hierarchy_build_count() -> int:
	return _hierarchy_build_count


func preset_count() -> int:
	_ensure_presets_loaded()
	return _presets.size()


func _ensure_presets_loaded() -> void:
	if not _presets.is_empty():
		return
	var text := FileAccess.get_file_as_string(PRESETS_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Array:
		push_error("Avatar presets must be a JSON array: %s" % PRESETS_PATH)
		return
	for raw: Variant in parsed:
		if not raw is Dictionary:
			continue
		var preset := (raw as Dictionary).duplicate(true)
		var model_path := String(preset.get("model", ""))
		var appearance := String(preset.get("appearance", ""))
		if appearance.is_empty() or model_path.is_empty() or not ResourceLoader.exists(model_path):
			continue
		_presets.append(preset)


func _ensure_hierarchy() -> void:
	if _built:
		return
	_built = true
	_hierarchy_build_count += 1
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 12)

	var title := Label.new()
	title.name = "ProfileTitle"
	title.text = "PROFILO"
	title.add_theme_font_override("font", GameFonts.bold())
	title.add_theme_font_size_override("font_size", 26)
	add_child(title)

	var subtitle := Label.new()
	subtitle.name = "ProfileSubtitle"
	subtitle.text = "Personalizza il tuo profilo e l'identità del ristorante."
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(subtitle)

	var body := HBoxContainer.new()
	body.name = "ProfileBody"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	add_child(body)

	var avatar_column := VBoxContainer.new()
	avatar_column.name = "AvatarColumn"
	avatar_column.custom_minimum_size = Vector2(260, 0)
	avatar_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	avatar_column.add_theme_constant_override("separation", 8)
	body.add_child(avatar_column)

	var preview_frame := PanelContainer.new()
	preview_frame.name = "AvatarPreviewFrame"
	preview_frame.custom_minimum_size = Vector2(250, 210)
	avatar_column.add_child(preview_frame)

	var preview_stack := CenterContainer.new()
	preview_stack.name = "AvatarPreviewStack"
	preview_frame.add_child(preview_stack)

	_fallback_avatar = TextureRect.new()
	_fallback_avatar.name = "AvatarFallback"
	_fallback_avatar.custom_minimum_size = Vector2(152, 152)
	_fallback_avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fallback_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fallback_avatar.texture = GameIcons.casual_system_icon("profile_avatar")
	preview_stack.add_child(_fallback_avatar)

	_model_preview = ModelPreview.new()
	_model_preview.name = "AvatarModelPreview"
	_model_preview.auto_rotate = false
	_model_preview.custom_minimum_size = Vector2(250, 200)
	_model_preview.visible = false
	preview_stack.add_child(_model_preview)

	_preview_button = Button.new()
	_preview_button.name = "AvatarPreviewButton"
	_preview_button.text = "Mostra anteprima 3D"
	_preview_button.add_theme_font_override("font", GameFonts.semi_bold())
	_preview_button.pressed.connect(request_avatar_preview)
	avatar_column.add_child(_preview_button)

	var preset_controls := HBoxContainer.new()
	preset_controls.name = "AvatarPresetControls"
	preset_controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	avatar_column.add_child(preset_controls)

	var previous_button := Button.new()
	previous_button.name = "PreviousAvatar"
	previous_button.text = "Precedente"
	previous_button.icon = GameIcons.previous_icon()
	previous_button.expand_icon = true
	previous_button.custom_minimum_size = Vector2(104, 42)
	previous_button.pressed.connect(select_previous_preset)
	preset_controls.add_child(previous_button)

	_preset_name_label = Label.new()
	_preset_name_label.name = "AvatarPresetName"
	_preset_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preset_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preset_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_name_label.add_theme_font_override("font", GameFonts.semi_bold())
	preset_controls.add_child(_preset_name_label)

	var next_button := Button.new()
	next_button.name = "NextAvatar"
	next_button.text = "Successivo"
	next_button.icon = GameIcons.next_icon()
	next_button.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	next_button.expand_icon = true
	next_button.custom_minimum_size = Vector2(104, 42)
	next_button.pressed.connect(select_next_preset)
	preset_controls.add_child(next_button)

	_uniform_row = HBoxContainer.new()
	_uniform_row.name = "UniformVariantRow"
	_uniform_row.visible = false
	avatar_column.add_child(_uniform_row)
	var uniform_label := Label.new()
	uniform_label.text = "Variante uniforme"
	_uniform_row.add_child(uniform_label)
	_uniform_selector = OptionButton.new()
	_uniform_selector.name = "UniformVariantSelector"
	_uniform_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_uniform_selector.item_selected.connect(_on_uniform_selected)
	_uniform_row.add_child(_uniform_selector)

	var form := VBoxContainer.new()
	form.name = "ProfileForm"
	form.custom_minimum_size = Vector2(310, 0)
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_theme_constant_override("separation", 10)
	body.add_child(form)

	form.add_child(_field_label("Nome giocatore"))
	_player_name_edit = LineEdit.new()
	_player_name_edit.name = "PlayerNameEdit"
	_player_name_edit.placeholder_text = "Il tuo nome"
	_player_name_edit.max_length = PLAYER_NAME_LIMIT
	_player_name_edit.text_changed.connect(_on_player_name_changed)
	_player_name_edit.focus_exited.connect(_finalize_player_name)
	form.add_child(_player_name_edit)

	form.add_child(_field_label("Nome ristorante"))
	_restaurant_name_edit = LineEdit.new()
	_restaurant_name_edit.name = "RestaurantNameEdit"
	_restaurant_name_edit.placeholder_text = "DeGustibus"
	_restaurant_name_edit.max_length = RESTAURANT_NAME_LIMIT
	_restaurant_name_edit.text_changed.connect(_on_restaurant_name_changed)
	_restaurant_name_edit.focus_exited.connect(_finalize_restaurant_name)
	form.add_child(_restaurant_name_edit)

	var badge_panel := PanelContainer.new()
	badge_panel.name = "StarterBadge"
	badge_panel.custom_minimum_size = Vector2(0, 68)
	form.add_child(badge_panel)
	var badge_row := HBoxContainer.new()
	badge_row.alignment = BoxContainer.ALIGNMENT_CENTER
	badge_row.add_theme_constant_override("separation", 10)
	badge_panel.add_child(badge_row)
	var badge_icon := TextureRect.new()
	badge_icon.name = "StarterBadgeIcon"
	badge_icon.custom_minimum_size = Vector2(44, 44)
	badge_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	badge_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	badge_icon.texture = GameIcons.level_icon()
	badge_row.add_child(badge_icon)
	_badge_label = Label.new()
	_badge_label.name = "StarterBadgeLabel"
	_badge_label.add_theme_font_override("font", GameFonts.semi_bold())
	badge_row.add_child(_badge_label)


func _field_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", GameFonts.semi_bold())
	return label


func _on_game_state_profile_changed(value: Dictionary) -> void:
	_apply_profile(value, false)
	profile_changed.emit(_profile.duplicate(true))


func _apply_profile(value: Dictionary, trim_names: bool) -> void:
	_profile = _normalize_profile(value, trim_names)
	_preset_index = _preset_index_for_appearance(String(_profile.get("avatar_appearance", "")))
	if _preset_index < 0:
		_preset_index = 0
	_refreshing = true
	if _player_name_edit != null and _player_name_edit.text != String(_profile.get("player_name", "")):
		_player_name_edit.text = String(_profile.get("player_name", ""))
		_player_name_edit.caret_column = _player_name_edit.text.length()
	if _restaurant_name_edit != null and _restaurant_name_edit.text != String(_profile.get("restaurant_name", "")):
		_restaurant_name_edit.text = String(_profile.get("restaurant_name", ""))
		_restaurant_name_edit.caret_column = _restaurant_name_edit.text.length()
	if _preset_name_label != null:
		_preset_name_label.text = String(_current_preset().get("name", "Profilo"))
	if _badge_label != null:
		_badge_label.text = "Badge iniziale: %s" % _readable_badge_name(String(_profile.get("badge_id", "starter")))
	_refresh_uniform_selector()
	_refreshing = false
	if _preview_requested:
		request_avatar_preview()


func _commit_profile(value: Dictionary, trim_names: bool) -> void:
	_ensure_presets_loaded()
	var merged := current_profile()
	merged.merge(value, true)
	var normalized := _normalize_profile(merged, trim_names)
	if GameState.restaurant_profile == normalized:
		_apply_profile(normalized, false)
		return
	GameState.set_restaurant_profile(normalized)


func _normalize_profile(value: Dictionary, trim_names: bool) -> Dictionary:
	var result := {
		"player_name": "",
		"restaurant_name": "DeGustibus",
		"avatar_appearance": "Chef_Female",
		"badge_id": "starter",
		"uniform_variant": 0
	}
	if not GameState.restaurant_profile.is_empty():
		result.merge(GameState.restaurant_profile, true)
	result.merge(value, true)
	result.player_name = _sanitize_name(String(result.get("player_name", "")), PLAYER_NAME_LIMIT, trim_names)
	result.restaurant_name = _sanitize_name(String(result.get("restaurant_name", "")), RESTAURANT_NAME_LIMIT, trim_names)
	var appearance := String(result.get("avatar_appearance", ""))
	var index := _preset_index_for_appearance(appearance)
	if index < 0 and not _presets.is_empty():
		index = 0
		result.avatar_appearance = String(_presets[0].appearance)
	var badge_id := String(result.get("badge_id", "starter")).strip_edges().to_lower()
	result.badge_id = badge_id if badge_id == "starter" else "starter"
	var variants := _uniform_variants_for_index(index)
	if variants.is_empty():
		result.uniform_variant = 0
	else:
		var requested := int(result.get("uniform_variant", 0))
		var allowed: Array[int] = []
		for variant: Dictionary in variants:
			allowed.append(int(variant.get("id", allowed.size())))
		result.uniform_variant = requested if requested in allowed else allowed[0]
	return result


func _sanitize_name(value: String, limit: int, trim_edges: bool) -> String:
	var cleaned := ""
	for index: int in value.length():
		var code := value.unicode_at(index)
		if code < 32 or code == 127:
			if code in [9, 10, 13] and not cleaned.is_empty() and not cleaned.ends_with(" "):
				cleaned += " "
			continue
		var character := String.chr(code)
		if character == " ":
			if not cleaned.is_empty() and not cleaned.ends_with(" "):
				cleaned += character
		else:
			cleaned += character
		if cleaned.length() >= limit:
			break
	if trim_edges:
		cleaned = cleaned.strip_edges()
	return cleaned.left(limit)


func _select_preset_index(index: int) -> void:
	if _presets.is_empty():
		return
	var clamped := posmod(index, _presets.size())
	var value := current_profile()
	value.avatar_appearance = String(_presets[clamped].appearance)
	var variants := _uniform_variants_for_index(clamped)
	value.uniform_variant = int(variants[0].get("id", 0)) if not variants.is_empty() else 0
	_commit_profile(value, true)


func _preset_index_for_appearance(appearance: String) -> int:
	for index: int in _presets.size():
		if String(_presets[index].get("appearance", "")) == appearance:
			return index
	return -1


func _current_preset() -> Dictionary:
	if _presets.is_empty():
		return {}
	return _presets[clampi(_preset_index, 0, _presets.size() - 1)]


func _uniform_variants_for_index(index: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if index < 0 or index >= _presets.size():
		return result
	var raw: Variant = _presets[index].get("uniform_variants", [])
	if raw is Array:
		for value: Variant in raw:
			if value is Dictionary:
				result.append((value as Dictionary).duplicate(true))
	return result


func _refresh_uniform_selector() -> void:
	if _uniform_row == null or _uniform_selector == null:
		return
	var variants := _uniform_variants_for_index(_preset_index)
	_uniform_row.visible = not variants.is_empty()
	_uniform_selector.clear()
	if variants.is_empty():
		return
	var selected_id := int(_profile.get("uniform_variant", 0))
	for variant: Dictionary in variants:
		var item_id := int(variant.get("id", _uniform_selector.item_count))
		_uniform_selector.add_item(String(variant.get("name", "Variante %d" % (item_id + 1))), item_id)
		if item_id == selected_id:
			_uniform_selector.select(_uniform_selector.item_count - 1)


func _on_uniform_selected(index: int) -> void:
	if _refreshing or _uniform_selector == null or index < 0:
		return
	var value := current_profile()
	value.uniform_variant = _uniform_selector.get_item_id(index)
	_commit_profile(value, true)


func _on_player_name_changed(value: String) -> void:
	if _refreshing:
		return
	var sanitized := _sanitize_name(value, PLAYER_NAME_LIMIT, false)
	if sanitized != value:
		_refreshing = true
		_player_name_edit.text = sanitized
		_player_name_edit.caret_column = sanitized.length()
		_refreshing = false
	var profile := current_profile()
	profile.player_name = sanitized
	_commit_profile(profile, false)


func _on_restaurant_name_changed(value: String) -> void:
	if _refreshing:
		return
	var sanitized := _sanitize_name(value, RESTAURANT_NAME_LIMIT, false)
	if sanitized != value:
		_refreshing = true
		_restaurant_name_edit.text = sanitized
		_restaurant_name_edit.caret_column = sanitized.length()
		_refreshing = false
	var profile := current_profile()
	profile.restaurant_name = sanitized
	_commit_profile(profile, false)


func _finalize_player_name() -> void:
	if _refreshing:
		return
	var value := current_profile()
	value.player_name = _sanitize_name(_player_name_edit.text, PLAYER_NAME_LIMIT, true)
	_commit_profile(value, true)


func _finalize_restaurant_name() -> void:
	if _refreshing:
		return
	var value := current_profile()
	var sanitized := _sanitize_name(_restaurant_name_edit.text, RESTAURANT_NAME_LIMIT, true)
	value.restaurant_name = sanitized if not sanitized.is_empty() else "DeGustibus"
	_commit_profile(value, true)


func _current_model_path() -> String:
	var preset := _current_preset()
	var variants := _uniform_variants_for_index(_preset_index)
	var selected_variant := int(_profile.get("uniform_variant", 0))
	for variant: Dictionary in variants:
		if int(variant.get("id", -1)) == selected_variant:
			var variant_model := String(variant.get("model", ""))
			if not variant_model.is_empty() and ResourceLoader.exists(variant_model):
				return variant_model
	return String(preset.get("model", ""))


func _readable_badge_name(badge_id: String) -> String:
	return "Starter" if badge_id == "starter" else badge_id.capitalize()


func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"
