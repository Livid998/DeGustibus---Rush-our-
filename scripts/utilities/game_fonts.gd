class_name GameFonts
extends RefCounted

const FREDOKA_ONE: FontFile = preload("res://assets/ui/fonts/FredokaOne-Regular.ttf")

static var _medium: FontVariation
static var _semibold: FontVariation
static var _bold: FontVariation


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


static func _variation(embolden: float) -> FontVariation:
	var font := FontVariation.new()
	font.base_font = FREDOKA_ONE
	font.variation_embolden = embolden
	return font
