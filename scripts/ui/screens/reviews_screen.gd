class_name ReviewsScreen
extends VBoxContainer

const TAG_LABELS := {
	"order_wait": "Attesa ordine",
	"food_wait": "Attesa piatti",
	"bill_wait": "Attesa conto",
	"food_quality": "Qualita del cibo",
	"waiter_service": "Servizio",
	"ambience": "Atmosfera",
	"beauty": "Bellezza",
	"cleanliness": "Pulizia",
	"sold_out_after_order": "Cambio ordine",
	"small_portion": "Porzione piccola",
	"undercooked": "Poco cotto",
	"overcooked": "Troppo cotto",
	"burned": "Bruciato",
	"poor_presentation": "Presentazione",
	"mouse_visible": "Topo visibile",
	"insect_visible": "Insetti visibili",
	"incident_resolved": "Problema risolto",
}

var _review_system: ReviewSystem
var _built := false
var _hierarchy_build_count := 0
var _refresh_count := 0
var _last_summary: Dictionary = {}

var _overview_grid: GridContainer
var _insights_grid: GridContainer
var _reputation_label: Label
var _average_label: Label
var _review_count_label: Label
var _distribution_counts: Array[Label] = []
var _reward_progress: ProgressBar
var _reward_progress_label: Label
var _latest_empty_label: Label
var _latest_meta_label: Label
var _latest_text_label: Label
var _latest_tip_label: Label
var _latest_tag_label: Label
var _latest_star_icons: Array[TextureRect] = []
var _positive_tags_label: Label
var _negative_tags_label: Label
var _history_scroll: ScrollContainer
var _history_list: VBoxContainer
var _history_empty_label: Label
var _history_cards: Array[PanelContainer] = []


static func create() -> ReviewsScreen:
	var screen := ReviewsScreen.new()
	screen.name = "ReviewsScreen"
	return screen


func _ready() -> void:
	_ensure_hierarchy()
	_connect_state_signals()
	refresh()


func _exit_tree() -> void:
	_disconnect_state_signals()


func refresh() -> void:
	_ensure_hierarchy()
	_ensure_review_system()
	_refresh_count += 1
	_last_summary = _review_system.recent_summary()
	_update_summary(_last_summary)
	_update_latest(_last_summary.get("latest", {}))
	_update_frequent_tags(_last_summary)
	_update_reward()
	_update_history()
	GameFonts.sanitize_control_tree(self)


func hierarchy_build_count() -> int:
	return _hierarchy_build_count


func refresh_count() -> int:
	return _refresh_count


func history_card_instance_ids() -> Array[int]:
	var result: Array[int] = []
	for card: PanelContainer in _history_cards:
		result.append(card.get_instance_id())
	return result


func visible_history_count() -> int:
	var result := 0
	for card: PanelContainer in _history_cards:
		if card.visible:
			result += 1
	return result


func summary_snapshot() -> Dictionary:
	return _last_summary.duplicate(true)


func apply_responsive_layout_for_width(available_width: float) -> void:
	if _overview_grid == null or _insights_grid == null:
		return
	var columns := 1 if available_width < 720.0 else 2
	_overview_grid.columns = columns
	_insights_grid.columns = columns
	_history_scroll.custom_minimum_size.y = 330.0 if available_width < 600.0 else 280.0


func _ensure_review_system() -> void:
	if _review_system == null:
		_review_system = ReviewSystem.new()


func _ensure_hierarchy() -> void:
	if _built:
		return
	_built = true
	_hierarchy_build_count += 1
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(0, 620)
	add_theme_constant_override("separation", 12)
	resized.connect(_apply_responsive_layout)

	var title_row := HBoxContainer.new()
	title_row.name = "ReviewsTitleRow"
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_theme_constant_override("separation", 10)
	add_child(title_row)
	title_row.add_child(_icon_rect(GameIcons.reputation_icon(), Vector2(44, 44), "ReviewsTitleIcon"))

	var title_column := VBoxContainer.new()
	title_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_column)
	var title := _label("RECENSIONI", GameFonts.bold(), 26)
	title.name = "ReviewsTitle"
	title_column.add_child(title)
	var subtitle := _label(
		"Scopri cosa ha funzionato e cosa puoi migliorare nel prossimo servizio.",
		GameFonts.medium(),
		16
	)
	subtitle.name = "ReviewsSubtitle"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_column.add_child(subtitle)

	_overview_grid = GridContainer.new()
	_overview_grid.name = "ReviewsOverviewGrid"
	_overview_grid.columns = 2
	_overview_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overview_grid.add_theme_constant_override("h_separation", 12)
	_overview_grid.add_theme_constant_override("v_separation", 12)
	add_child(_overview_grid)
	_build_reputation_panel()
	_build_reward_panel()

	_insights_grid = GridContainer.new()
	_insights_grid.name = "ReviewsInsightsGrid"
	_insights_grid.columns = 2
	_insights_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_insights_grid.add_theme_constant_override("h_separation", 12)
	_insights_grid.add_theme_constant_override("v_separation", 12)
	add_child(_insights_grid)
	_build_latest_panel()
	_build_tags_panel()

	var history_heading := _label("CRONOLOGIA", GameFonts.bold(), 20)
	history_heading.name = "ReviewsHistoryHeading"
	add_child(history_heading)

	_history_scroll = ScrollContainer.new()
	_history_scroll.name = "ReviewsHistoryScroll"
	_history_scroll.custom_minimum_size = Vector2(0, 280)
	_history_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_history_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_history_scroll.follow_focus = true
	add_child(_history_scroll)

	_history_list = VBoxContainer.new()
	_history_list.name = "ReviewsHistoryList"
	_history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_list.add_theme_constant_override("separation", 8)
	_history_scroll.add_child(_history_list)

	_history_empty_label = _label(
		"Le recensioni dei gruppi compariranno qui dopo il pagamento.",
		GameFonts.medium(),
		16
	)
	_history_empty_label.name = "ReviewsHistoryEmpty"
	_history_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_history_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_history_empty_label.custom_minimum_size = Vector2(0, 92)
	_history_list.add_child(_history_empty_label)

	_apply_responsive_layout()
	GameFonts.sanitize_control_tree(self)


func _build_reputation_panel() -> void:
	var body := _section_body(_overview_grid, "ReviewsReputationPanel")
	var heading_row := HBoxContainer.new()
	heading_row.add_theme_constant_override("separation", 8)
	body.add_child(heading_row)
	heading_row.add_child(_icon_rect(GameIcons.reputation_icon(), Vector2(36, 36), "ReputationIcon"))
	var heading := _label("REPUTAZIONE", GameFonts.bold(), 19)
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading_row.add_child(heading)

	_reputation_label = _label("1.00 / 5", GameFonts.bold(), 28)
	_reputation_label.name = "CurrentReputation"
	body.add_child(_reputation_label)
	_average_label = _label("Media recente: nessun dato", GameFonts.semibold(), 16)
	_average_label.name = "RecentReviewAverage"
	body.add_child(_average_label)
	_review_count_label = _label("0 recensioni", GameFonts.medium(), 15)
	_review_count_label.name = "ReviewCount"
	body.add_child(_review_count_label)

	var distribution := GridContainer.new()
	distribution.name = "StarDistribution"
	distribution.columns = 5
	distribution.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	distribution.add_theme_constant_override("h_separation", 4)
	body.add_child(distribution)
	for stars: int in range(1, 6):
		var cell := VBoxContainer.new()
		cell.name = "StarDistribution%d" % stars
		cell.custom_minimum_size = Vector2(48, 58)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.alignment = BoxContainer.ALIGNMENT_CENTER
		distribution.add_child(cell)
		var icon_row := HBoxContainer.new()
		icon_row.alignment = BoxContainer.ALIGNMENT_CENTER
		cell.add_child(icon_row)
		icon_row.add_child(_icon_rect(GameIcons.reputation_icon(), Vector2(20, 20), "StarIcon"))
		var level := _label(str(stars), GameFonts.semibold(), 14)
		icon_row.add_child(level)
		var count := _label("0", GameFonts.bold(), 17)
		count.name = "StarCount%d" % stars
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.add_child(count)
		_distribution_counts.append(count)


func _build_reward_panel() -> void:
	var body := _section_body(_overview_grid, "ReviewsRewardPanel")
	var heading_row := HBoxContainer.new()
	heading_row.add_theme_constant_override("separation", 8)
	body.add_child(heading_row)
	heading_row.add_child(_icon_rect(GameIcons.navigation_icon("Album"), Vector2(40, 40), "ReviewRewardIcon"))
	var heading := _label("PREMIO ALBUM", GameFonts.bold(), 19)
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading_row.add_child(heading)

	_reward_progress_label = _label("Prossimo premio: 0 / 5", GameFonts.bold(), 20)
	_reward_progress_label.name = "ReviewRewardProgressLabel"
	_reward_progress_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_reward_progress_label)
	_reward_progress = ProgressBar.new()
	_reward_progress.name = "ReviewRewardProgress"
	_reward_progress.custom_minimum_size = Vector2(0, 30)
	_reward_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reward_progress.show_percentage = false
	body.add_child(_reward_progress)
	var hint := _label(
		"Le recensioni da 4 o 5 stelle fanno avanzare il prossimo ingrediente.",
		GameFonts.medium(),
		15
	)
	hint.name = "ReviewRewardHint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)


func _build_latest_panel() -> void:
	var body := _section_body(_insights_grid, "LatestReviewPanel")
	body.custom_minimum_size = Vector2(0, 210)
	var heading := _label("ULTIMA RECENSIONE", GameFonts.bold(), 19)
	body.add_child(heading)

	_latest_empty_label = _label(
		"Ancora nessuna recensione. Apri il ristorante e servi il primo gruppo.",
		GameFonts.medium(),
		16
	)
	_latest_empty_label.name = "LatestReviewEmpty"
	_latest_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_latest_empty_label)

	var stars_row := HBoxContainer.new()
	stars_row.name = "LatestReviewStars"
	stars_row.add_theme_constant_override("separation", 3)
	body.add_child(stars_row)
	for index: int in 5:
		var star := _icon_rect(GameIcons.reputation_icon(), Vector2(26, 26), "LatestStar%d" % (index + 1))
		stars_row.add_child(star)
		_latest_star_icons.append(star)

	_latest_meta_label = _label("", GameFonts.semibold(), 15)
	_latest_meta_label.name = "LatestReviewMeta"
	_latest_meta_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_latest_meta_label)
	_latest_text_label = _label("", GameFonts.bold(), 19)
	_latest_text_label.name = "LatestReviewText"
	_latest_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_latest_text_label.custom_minimum_size = Vector2(0, 58)
	body.add_child(_latest_text_label)
	_latest_tip_label = _label("", GameFonts.semibold(), 15)
	_latest_tip_label.name = "LatestReviewTip"
	body.add_child(_latest_tip_label)
	_latest_tag_label = _label("", GameFonts.medium(), 14)
	_latest_tag_label.name = "LatestReviewTags"
	_latest_tag_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_latest_tag_label)


func _build_tags_panel() -> void:
	var body := _section_body(_insights_grid, "FrequentReviewTagsPanel")
	body.custom_minimum_size = Vector2(0, 210)
	var heading := _label("TEMI RICORRENTI", GameFonts.bold(), 19)
	body.add_child(heading)
	var positive_heading := _label("Apprezzati piu spesso", GameFonts.semibold(), 16)
	body.add_child(positive_heading)
	_positive_tags_label = _label("Nessun dato", GameFonts.medium(), 15)
	_positive_tags_label.name = "FrequentPositiveTags"
	_positive_tags_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_positive_tags_label.custom_minimum_size = Vector2(0, 52)
	body.add_child(_positive_tags_label)
	var negative_heading := _label("Da migliorare", GameFonts.semibold(), 16)
	body.add_child(negative_heading)
	_negative_tags_label = _label("Nessun dato", GameFonts.medium(), 15)
	_negative_tags_label.name = "FrequentNegativeTags"
	_negative_tags_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_negative_tags_label.custom_minimum_size = Vector2(0, 52)
	body.add_child(_negative_tags_label)


func _section_body(parent: Container, panel_name: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.name = panel_name
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.name = "%sBody" % panel_name
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 7)
	margin.add_child(body)
	return body


func _update_summary(summary: Dictionary) -> void:
	var count := maxi(int(summary.get("count", 0)), 0)
	var average := clampf(float(summary.get("average", 0.0)), 0.0, 5.0)
	_reputation_label.text = _safe_text("%.2f / 5" % clampf(float(GameState.reputation), 1.0, 5.0))
	_average_label.text = _safe_text(
		"Media recente: %.2f / 5" % average if count > 0 else "Media recente: nessun dato"
	)
	_review_count_label.text = _safe_text("%d recensione%s" % [count, "" if count == 1 else "i"])
	var distribution: Dictionary = summary.get("distribution", {})
	for index: int in _distribution_counts.size():
		_distribution_counts[index].text = str(maxi(int(distribution.get(index + 1, 0)), 0))


func _update_reward() -> void:
	var threshold := maxi(int(DataRegistry.balance_value("album.positive_reviews_per_reward", 5)), 1)
	var progress := clampi(int(GameState.review_reward_progress), 0, threshold - 1)
	_reward_progress.max_value = threshold
	_reward_progress.value = progress
	_reward_progress_label.text = _safe_text("Prossimo premio: %d / %d" % [progress, threshold])


func _update_latest(value: Variant) -> void:
	var review: Dictionary = value if value is Dictionary else {}
	var has_review := not review.is_empty()
	_latest_empty_label.visible = not has_review
	_latest_meta_label.visible = has_review
	_latest_text_label.visible = has_review
	_latest_tip_label.visible = has_review
	_latest_tag_label.visible = has_review
	for star: TextureRect in _latest_star_icons:
		star.visible = has_review
	if not has_review:
		return
	var stars := clampi(int(review.get("stars", 1)), 1, 5)
	for index: int in _latest_star_icons.size():
		_latest_star_icons[index].modulate = Color.WHITE if index < stars else Color(0.42, 0.48, 0.50, 0.30)
	var customer_type := _readable_tag(String(review.get("customer_type", "gruppo")))
	var day := maxi(int(review.get("day", 1)), 1)
	var minute := clampi(int(round(float(review.get("minute", 0.0)))), 0, 1439)
	_latest_meta_label.text = _safe_text(
		"%s, giorno %d alle %02d:%02d" % [customer_type, day, minute / 60, minute % 60]
	)
	_latest_text_label.text = _safe_text(String(review.get("text", "Recensione senza testo.")))
	_latest_tip_label.text = _safe_text(
		"Soddisfazione %d / 100, mancia %d" % [
			clampi(int(review.get("satisfaction", 0)), 0, 100),
			maxi(int(review.get("tip", 0)), 0),
		]
	)
	var tag_parts: Array[String] = []
	var positive_tags := _string_array(review.get("positive_tags", []))
	var negative_tags := _string_array(review.get("negative_tags", []))
	if not positive_tags.is_empty():
		tag_parts.append("Punti forti: %s" % _join_readable_tags(positive_tags, 2))
	if not negative_tags.is_empty():
		tag_parts.append("Da migliorare: %s" % _join_readable_tags(negative_tags, 2))
	_latest_tag_label.text = _safe_text(" | ".join(tag_parts))
	_latest_tag_label.visible = not tag_parts.is_empty()


func _update_frequent_tags(summary: Dictionary) -> void:
	_positive_tags_label.text = _safe_text(
		_format_frequent_tags(summary.get("positive_tag_counts", {}))
	)
	_negative_tags_label.text = _safe_text(
		_format_frequent_tags(summary.get("negative_tag_counts", {}))
	)


func _update_history() -> void:
	var history_limit := maxi(int(DataRegistry.balance_value("reviews.history_limit", 100)), 1)
	var available := mini(GameState.reviews.size(), history_limit)
	_ensure_history_card_count(available)
	_history_empty_label.visible = available == 0
	for pool_index: int in _history_cards.size():
		var card := _history_cards[pool_index]
		if pool_index >= available:
			card.visible = false
			continue
		card.visible = true
		var review_index := GameState.reviews.size() - 1 - pool_index
		_update_history_card(card, GameState.reviews[review_index])


func _ensure_history_card_count(required: int) -> void:
	while _history_cards.size() < required:
		_history_cards.append(_create_history_card(_history_cards.size()))


func _create_history_card(index: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "ReviewHistoryCard%d" % index
	panel.custom_minimum_size = Vector2(0, 116)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_list.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 9)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 9)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	margin.add_child(body)
	var top_row := HBoxContainer.new()
	top_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(top_row)
	top_row.add_child(_icon_rect(GameIcons.reputation_icon(), Vector2(24, 24), "HistoryStarIcon"))
	var rating := _label("", GameFonts.bold(), 16)
	rating.name = "HistoryRating"
	rating.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top_row.add_child(rating)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(spacer)
	var meta := _label("", GameFonts.semibold(), 14)
	meta.name = "HistoryMeta"
	meta.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_row.add_child(meta)
	var text := _label("", GameFonts.medium(), 16)
	text.name = "HistoryText"
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(text)
	var tags := _label("", GameFonts.medium(), 13)
	tags.name = "HistoryTags"
	tags.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tags)
	return panel


func _update_history_card(card: PanelContainer, value: Variant) -> void:
	var review: Dictionary = value if value is Dictionary else {}
	var rating := card.find_child("HistoryRating", true, false) as Label
	var meta := card.find_child("HistoryMeta", true, false) as Label
	var text := card.find_child("HistoryText", true, false) as Label
	var tags := card.find_child("HistoryTags", true, false) as Label
	if rating != null:
		rating.text = _safe_text("%d / 5" % clampi(int(review.get("stars", 1)), 1, 5))
	if meta != null:
		meta.text = _safe_text(
			"Giorno %d, mancia %d" % [
				maxi(int(review.get("day", 1)), 1),
				maxi(int(review.get("tip", 0)), 0),
			]
		)
	if text != null:
		text.text = _safe_text(String(review.get("text", "Recensione senza testo.")))
	if tags != null:
		var tag_parts: Array[String] = []
		var positives := _string_array(review.get("positive_tags", []))
		var negatives := _string_array(review.get("negative_tags", []))
		if not positives.is_empty():
			tag_parts.append("Bene: %s" % _join_readable_tags(positives, 2))
		if not negatives.is_empty():
			tag_parts.append("Attenzione: %s" % _join_readable_tags(negatives, 2))
		tags.text = _safe_text(" | ".join(tag_parts))
		tags.visible = not tag_parts.is_empty()


func _format_frequent_tags(value: Variant) -> String:
	if not value is Dictionary or (value as Dictionary).is_empty():
		return "Nessun dato"
	var remaining := (value as Dictionary).duplicate()
	var lines: Array[String] = []
	while not remaining.is_empty() and lines.size() < 3:
		var best_tag := ""
		var best_count := -1
		for tag: Variant in remaining:
			var count := int(remaining[tag])
			if count > best_count or (count == best_count and String(tag) < best_tag):
				best_tag = String(tag)
				best_count = count
		lines.append("%s (%d)" % [_readable_tag(best_tag), best_count])
		remaining.erase(best_tag)
	return "\n".join(lines)


func _join_readable_tags(tags: Array[String], limit: int) -> String:
	var values: Array[String] = []
	for tag: String in tags:
		if values.size() >= limit:
			break
		values.append(_readable_tag(tag))
	return ", ".join(values)


func _readable_tag(tag: String) -> String:
	if TAG_LABELS.has(tag):
		return String(TAG_LABELS[tag])
	var cleaned := tag.replace("_", " ").strip_edges()
	return cleaned.capitalize() if not cleaned.is_empty() else "Altro"


func _icon_rect(texture: Texture2D, minimum_size: Vector2, node_name: String) -> TextureRect:
	var icon := TextureRect.new()
	icon.name = node_name
	icon.texture = texture
	icon.custom_minimum_size = minimum_size
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return icon


func _label(text_value: String, font: Font, font_size: int) -> Label:
	var label := Label.new()
	label.text = _safe_text(text_value)
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font_size)
	return label


func _safe_text(value: String) -> String:
	var normalized := GameFonts.web_safe_text(value)
	var result := ""
	for index: int in normalized.length():
		var codepoint := normalized.unicode_at(index)
		if codepoint in [9, 10, 13] or codepoint >= 32 and GameFonts.FREDOKA_ONE.has_char(codepoint):
			result += normalized.substr(index, 1)
		else:
			result += "?"
	return result


func _apply_responsive_layout() -> void:
	if _overview_grid == null or _insights_grid == null:
		return
	var available_width := size.x
	if get_viewport() != null:
		var viewport_width := get_viewport_rect().size.x
		available_width = viewport_width if available_width <= 1.0 else minf(available_width, viewport_width)
	apply_responsive_layout_for_width(available_width)


func _connect_state_signals() -> void:
	var reviews_callback := Callable(self, "_on_reviews_changed")
	if not GameState.reviews_changed.is_connected(reviews_callback):
		GameState.reviews_changed.connect(reviews_callback)
	var reputation_callback := Callable(self, "_on_reputation_changed")
	if not GameState.reputation_changed.is_connected(reputation_callback):
		GameState.reputation_changed.connect(reputation_callback)
	var reward_callback := Callable(self, "_on_reward_progress_changed")
	if not GameState.review_reward_progress_changed.is_connected(reward_callback):
		GameState.review_reward_progress_changed.connect(reward_callback)


func _disconnect_state_signals() -> void:
	var reviews_callback := Callable(self, "_on_reviews_changed")
	if GameState.reviews_changed.is_connected(reviews_callback):
		GameState.reviews_changed.disconnect(reviews_callback)
	var reputation_callback := Callable(self, "_on_reputation_changed")
	if GameState.reputation_changed.is_connected(reputation_callback):
		GameState.reputation_changed.disconnect(reputation_callback)
	var reward_callback := Callable(self, "_on_reward_progress_changed")
	if GameState.review_reward_progress_changed.is_connected(reward_callback):
		GameState.review_reward_progress_changed.disconnect(reward_callback)


func _on_reviews_changed() -> void:
	refresh()


func _on_reputation_changed(_value: float) -> void:
	refresh()


func _on_reward_progress_changed(_value: int) -> void:
	refresh()


static func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for item: Variant in value:
			var text := String(item)
			if not text.is_empty() and not result.has(text):
				result.append(text)
	return result
