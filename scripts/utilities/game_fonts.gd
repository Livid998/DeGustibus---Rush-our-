class_name GameFonts
extends RefCounted

const FREDOKA_ONE: FontFile = preload("res://assets/ui/fonts/FredokaOne-Regular.ttf")

static var _medium: FontVariation
static var _semibold: FontVariation
static var _bold: FontVariation

# Questi caratteri venivano usati come icone testuali. Fredoka One non offre
# una copertura coerente di simboli/emoji nell'export Web e il fallback del
# browser non viene usato dal canvas di Godot. Le icone vere sono in GameIcons;
# questa lista rende anche sicuri toast o dati provenienti da salvataggi vecchi.
const WEB_UNSAFE_ICON_CODEPOINTS := [
	0x00B0, # degree
	0x00D7, # multiplication sign
	0x2014, # em dash
	0x2026, # ellipsis
	0x2161, # roman numeral two / pause placeholder
	0x2191, # up arrow
	0x21B6, # anticlockwise arrow
	0x21B7, # clockwise arrow
	0x25B6, # play triangle
	0x25C0, # previous triangle
	0x25CF, # coin placeholder
	0x1F512, # lock emoji
]


static func medium() -> FontVariation:
	if _medium == null:
		_medium = _variation(0.0)
	return _medium


static func semibold() -> FontVariation:
	if _semibold == null:
		_semibold = _variation(0.32)
	return _semibold


static func bold() -> FontVariation:
	if _bold == null:
		_bold = _variation(0.62)
	return _bold


static func web_safe_text(value: String) -> String:
	var result := ""
	for index: int in value.length():
		var codepoint := value.unicode_at(index)
		match codepoint:
			0x00B0:
				result += " gradi"
			0x00D7:
				result += "x"
			0x2014:
				result += "-"
			0x2026:
				result += "..."
			0x2161:
				result += "Pausa"
			0x2191:
				result += "Priorita"
			0x21B6, 0x25C0:
				result += "Precedente"
			0x21B7, 0x25B6:
				result += "Successivo"
			0x25CF:
				result += "monete"
			0x1F512:
				result += "Bloccato -"
			_:
				result += value.substr(index, 1)
	return result


static func unsupported_runtime_characters(value: String) -> PackedInt32Array:
	var unsupported := PackedInt32Array()
	for index: int in value.length():
		var codepoint := value.unicode_at(index)
		if codepoint < 32 or codepoint in unsupported:
			continue
		if codepoint in WEB_UNSAFE_ICON_CODEPOINTS or not FREDOKA_ONE.has_char(codepoint):
			unsupported.append(codepoint)
	return unsupported


static func sanitize_control_tree(root: Node) -> void:
	if root == null:
		return
	if root is OptionButton:
		var option := root as OptionButton
		for index: int in option.item_count:
			option.set_item_text(index, web_safe_text(option.get_item_text(index)))
	elif root is Button:
		var button := root as Button
		button.text = web_safe_text(button.text)
	elif root is Label:
		(root as Label).text = web_safe_text((root as Label).text)
	elif root is RichTextLabel:
		(root as RichTextLabel).text = web_safe_text((root as RichTextLabel).text)
	elif root is LineEdit:
		var line_edit := root as LineEdit
		line_edit.text = web_safe_text(line_edit.text)
		line_edit.placeholder_text = web_safe_text(line_edit.placeholder_text)
	elif root is SpinBox:
		var spin_box := root as SpinBox
		spin_box.prefix = web_safe_text(spin_box.prefix)
		spin_box.suffix = web_safe_text(spin_box.suffix)
	if root is Control:
		var control := root as Control
		control.tooltip_text = web_safe_text(control.tooltip_text)
	for child: Node in root.get_children():
		sanitize_control_tree(child)


static func _variation(embolden: float) -> FontVariation:
	var font := FontVariation.new()
	font.base_font = FREDOKA_ONE
	font.variation_embolden = embolden
	return font
