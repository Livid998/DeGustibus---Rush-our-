class_name GameIcons
extends RefCounted

const INGREDIENT_SHEET: Texture2D = preload("res://assets/ui/ingredient_icons_transparent.png")
const RECIPE_SHEET: Texture2D = preload("res://assets/ui/recipe_icons_transparent.png")
const NAVIGATION_SHEET: Texture2D = preload("res://assets/ui/navigation_icons.png")
const LOCK_TEXTURE: Texture2D = preload("res://assets/ui/lock_icon.png")
const COIN_TEXTURE: Texture2D = preload("res://assets/ui/food_icon_pack/ui/coin_stack.png")
const REPUTATION_TEXTURE: Texture2D = preload("res://assets/ui/food_icon_pack/ui/star_filled.png")
const LEVEL_TEXTURE: Texture2D = preload("res://assets/ui/food_icon_pack/ui/restaurant_level_badge.png")
const ROTATE_LEFT_TEXTURE: Texture2D = preload("res://assets/ui/control_rotate_left.svg")
const ROTATE_RIGHT_TEXTURE: Texture2D = preload("res://assets/ui/control_rotate_right.svg")
const PREVIOUS_TEXTURE: Texture2D = preload("res://assets/ui/control_previous.svg")
const NEXT_TEXTURE: Texture2D = preload("res://assets/ui/control_next.svg")
const PLAY_TEXTURE: Texture2D = preload("res://assets/ui/control_play.svg")
const PAUSE_TEXTURE: Texture2D = preload("res://assets/ui/control_pause.svg")
const PRIORITY_TEXTURE: Texture2D = preload("res://assets/ui/control_priority.svg")
const MUSIC_TEXTURE: Texture2D = preload("res://assets/ui/food_icon_pack/ui/music.png")
const ZOOM_IN_TEXTURE: Texture2D = preload("res://assets/ui/food_icon_pack/ui/zoom_in.png")
const ZOOM_OUT_TEXTURE: Texture2D = preload("res://assets/ui/food_icon_pack/ui/zoom_out.png")
const RESTAURANT_EDIT_TEXTURE: Texture2D = preload(
	"res://assets/ui/food_icon_pack/ui/restaurant_edit_wrench_pencil.png"
)
const RARITY_TEXTURES := [
	preload("res://assets/ui/food_icon_pack/ui/rarity_one_star.png"),
	preload("res://assets/ui/food_icon_pack/ui/rarity_two_stars.png"),
	preload("res://assets/ui/food_icon_pack/ui/rarity_three_stars.png"),
	preload("res://assets/ui/food_icon_pack/ui/rarity_four_stars.png"),
	preload("res://assets/ui/food_icon_pack/ui/rarity_five_stars.png")
]
const SPEED_TEXTURES := [
	preload("res://assets/ui/food_icon_pack/ui/speed_1x.png"),
	preload("res://assets/ui/food_icon_pack/ui/speed_2x.png"),
	preload("res://assets/ui/food_icon_pack/ui/speed_4x.png")
]
const CASUAL_SYSTEM_TEXTURES := {
	"sun": preload("res://assets/ui/generated/casual_system/sun.png"),
	"moon": preload("res://assets/ui/generated/casual_system/moon.png"),
	"beauty": preload("res://assets/ui/generated/casual_system/beauty.png"),
	"dirt": preload("res://assets/ui/generated/casual_system/dirt.png"),
	"mouse": preload("res://assets/ui/generated/casual_system/mouse.png"),
	"insect": preload("res://assets/ui/generated/casual_system/insect.png"),
	"delivery_truck": preload("res://assets/ui/generated/casual_system/delivery_truck.png"),
	"storage_ambient": preload("res://assets/ui/generated/casual_system/storage_ambient.png"),
	"storage_refrigerated": preload(
		"res://assets/ui/generated/casual_system/storage_refrigerated.png"
	),
	"rush": preload("res://assets/ui/generated/casual_system/rush.png"),
	"role_chef": preload("res://assets/ui/generated/casual_system/role_chef.png"),
	"role_waiter": preload("res://assets/ui/generated/casual_system/role_waiter.png"),
	"role_handyman": preload("res://assets/ui/generated/casual_system/role_handyman.png"),
	"profile_avatar": preload("res://assets/ui/generated/casual_system/profile_avatar.png"),
	"extractor_hood": preload("res://assets/ui/generated/casual_system/extractor_hood.png"),
	"defect_small_portion": preload(
		"res://assets/ui/generated/casual_system/defect_small_portion.png"
	),
	"defect_undercooked": preload(
		"res://assets/ui/generated/casual_system/defect_undercooked.png"
	),
	"defect_overcooked": preload(
		"res://assets/ui/generated/casual_system/defect_overcooked.png"
	),
	"defect_burned": preload("res://assets/ui/generated/casual_system/defect_burned.png"),
	"defect_poor_plating": preload(
		"res://assets/ui/generated/casual_system/defect_poor_plating.png"
	),
}
static var _scaled_cache: Dictionary = {}

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


static func preparation_icon(definition: Dictionary) -> Texture2D:
	var icon_path := String(definition.get("icon", ""))
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		return load(icon_path) as Texture2D
	for ingredient_id: String in definition.get("inputs", {}):
		var ingredient: Dictionary = DataRegistry.ingredients_by_id.get(ingredient_id, {})
		if not ingredient.is_empty():
			return ingredient_icon(ingredient)
	return ingredient_icon({})


static func navigation_icon(screen_name: String) -> AtlasTexture:
	return _slice(NAVIGATION_SHEET, int(NAVIGATION_INDICES.get(screen_name, -1)), 4, 2)


static func lock_icon() -> Texture2D:
	return LOCK_TEXTURE


static func currency_icon() -> Texture2D:
	return COIN_TEXTURE


static func reputation_icon() -> Texture2D:
	return REPUTATION_TEXTURE


static func level_icon() -> Texture2D:
	return LEVEL_TEXTURE


static func rotate_left_icon() -> Texture2D:
	return ROTATE_LEFT_TEXTURE


static func rotate_right_icon() -> Texture2D:
	return ROTATE_RIGHT_TEXTURE


static func previous_icon() -> Texture2D:
	return PREVIOUS_TEXTURE


static func next_icon() -> Texture2D:
	return NEXT_TEXTURE


static func play_icon() -> Texture2D:
	return PLAY_TEXTURE


static func pause_icon() -> Texture2D:
	return PAUSE_TEXTURE


static func priority_icon() -> Texture2D:
	return PRIORITY_TEXTURE


static func music_icon() -> Texture2D:
	return MUSIC_TEXTURE


static func zoom_in_icon() -> Texture2D:
	return ZOOM_IN_TEXTURE


static func zoom_out_icon() -> Texture2D:
	return ZOOM_OUT_TEXTURE


static func restaurant_edit_icon() -> Texture2D:
	return RESTAURANT_EDIT_TEXTURE


static func casual_system_icon(icon_id: String) -> Texture2D:
	return CASUAL_SYSTEM_TEXTURES.get(icon_id) as Texture2D


static func rarity_icon(rarity: int) -> Texture2D:
	return RARITY_TEXTURES[clampi(rarity, 1, 5) - 1]


static func speed_icon(index: int) -> Texture2D:
	return SPEED_TEXTURES[clampi(index, 0, SPEED_TEXTURES.size() - 1)]


static func scaled_icon(texture: Texture2D, size: int) -> Texture2D:
	if not texture or size <= 0:
		return texture
	var cache_key := "%s:%d" % [texture.resource_path, size]
	if _scaled_cache.has(cache_key):
		return _scaled_cache[cache_key]
	var image := texture.get_image()
	if not image:
		return texture
	image.resize(size, size, Image.INTERPOLATE_LANCZOS)
	var scaled := ImageTexture.create_from_image(image)
	_scaled_cache[cache_key] = scaled
	return scaled


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
