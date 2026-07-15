class_name GameIcons
extends RefCounted

const INGREDIENT_SHEET: Texture2D = preload("res://assets/ui/ingredient_icons_transparent.png")
const RECIPE_SHEET: Texture2D = preload("res://assets/ui/recipe_icons_transparent.png")
const NAVIGATION_SHEET: Texture2D = preload("res://assets/ui/navigation_icons.png")
const LOCK_TEXTURE: Texture2D = preload("res://assets/ui/lock_icon.png")

const NAVIGATION_INDICES := {
	"Ristorante": 0,
	"Menu": 1,
	"Album": 2,
	"Magazzino": 3,
	"Mercato": 4,
	"Personale": 5,
	"Statistiche": 6,
	"Impostazioni": 7,
}


static func ingredient_icon(definition: Dictionary) -> AtlasTexture:
	return _slice(INGREDIENT_SHEET, int(definition.get("icon_index", -1)), 5, 4)


static func recipe_icon(definition: Dictionary) -> AtlasTexture:
	return _slice(RECIPE_SHEET, int(definition.get("icon_index", -1)), 3, 4)


static func navigation_icon(screen_name: String) -> AtlasTexture:
	return _slice(NAVIGATION_SHEET, int(NAVIGATION_INDICES.get(screen_name, -1)), 4, 2)


static func lock_icon() -> Texture2D:
	return LOCK_TEXTURE


static func _slice(sheet: Texture2D, index: int, columns: int, rows: int) -> AtlasTexture:
	var icon := AtlasTexture.new()
	icon.atlas = sheet
	if index < 0 or index >= columns * rows:
		return icon
	var cell_size := Vector2(
		float(sheet.get_width()) / float(columns),
		float(sheet.get_height()) / float(rows)
	)
	icon.region = Rect2(Vector2(index % columns, index / columns) * cell_size, cell_size)
	# Ogni soggetto vive in una cella trasparente; il clip impedisce al filtro
	# lineare di campionare la cella adiacente lungo i bordi dell'atlante.
	icon.filter_clip = true
	return icon
