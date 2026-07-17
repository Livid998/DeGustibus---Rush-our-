extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var previous_writes_enabled := SaveManager.writes_enabled
	SaveManager.writes_enabled = false
	var original_window_size := get_window().size
	var original_state := GameState.serialize().duplicate(true)
	var original_review_balance: Dictionary = DataRegistry.balance_section("reviews")
	var limited_review_balance := original_review_balance.duplicate(true)
	limited_review_balance["history_limit"] = 3
	DataRegistry.gameplay_balance["reviews"] = limited_review_balance
	GameState.reset_to_defaults(false)

	var screen := ReviewsScreen.create()
	screen.size = Vector2(1000, 760)
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame

	var title := screen.find_child("ReviewsTitle", true, false) as Label
	var overview := screen.find_child("ReviewsOverviewGrid", true, false) as GridContainer
	var insights := screen.find_child("ReviewsInsightsGrid", true, false) as GridContainer
	var progress := screen.find_child("ReviewRewardProgress", true, false) as ProgressBar
	var progress_label := screen.find_child("ReviewRewardProgressLabel", true, false) as Label
	var reward_icon := screen.find_child("ReviewRewardIcon", true, false) as TextureRect
	var history_scroll := screen.find_child("ReviewsHistoryScroll", true, false) as ScrollContainer
	var history_empty := screen.find_child("ReviewsHistoryEmpty", true, false) as Label
	var latest_text := screen.find_child("LatestReviewText", true, false) as Label
	var positive_tags := screen.find_child("FrequentPositiveTags", true, false) as Label
	var negative_tags := screen.find_child("FrequentNegativeTags", true, false) as Label
	var title_id := title.get_instance_id() if title != null else 0
	var overview_id := overview.get_instance_id() if overview != null else 0
	var progress_id := progress.get_instance_id() if progress != null else 0

	_expect(screen.name == "ReviewsScreen" and screen.hierarchy_build_count() == 1, "ReviewsScreen.create builds one named persistent screen")
	_expect(
		title != null
		and overview != null
		and insights != null
		and progress != null
		and history_scroll != null,
		"reviews screen exposes reputation, reward, insight and scrollable history sections"
	)
	_expect(
		reward_icon != null
		and reward_icon.texture is AtlasTexture
		and GameIcons.navigation_icon("Album").atlas == (reward_icon.texture as AtlasTexture).atlas
		and GameIcons.navigation_icon("Album").region == (reward_icon.texture as AtlasTexture).region,
		"album reward uses the existing GameIcons album texture"
	)
	_expect(
		history_empty != null
		and history_empty.visible
		and screen.visible_history_count() == 0,
		"empty review history has a clear initial state"
	)

	var refresh_after_ready := screen.refresh_count()
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(screen.refresh_count() == refresh_after_ready, "screen has no per-frame or one-second rebuild loop")

	for index: int in 5:
		var positive: Array[String] = []
		var negative: Array[String] = []
		if index >= 3:
			positive.append("waiter_service" if index == 3 else "food_quality")
		elif index < 2:
			negative.append("food_wait" if index == 0 else "cleanliness")
		var unsafe_suffix := (
			" %s %s" % [String.chr(0x1F512), String.chr(0x2191)]
			if index == 4 else ""
		)
		GameState.append_review({
			"id": "ui_review_%d" % index,
			"day": index + 1,
			"minute": 600 + index * 35,
			"stars": index + 1,
			"satisfaction": 25 + index * 18,
			"customer_type": "gruppo_test",
			"tip": index * 2,
			"text": "Recensione numero %d%s" % [index, unsafe_suffix],
			"positive_tags": positive,
			"negative_tags": negative,
			"recipe_ids": ["margherita"],
			"incident_ids": [],
		})

	_expect(GameState.reviews.size() == 3, "GameState and screen source retain the configured review history limit")
	_expect(
		screen.visible_history_count() == 3
		and not history_empty.visible,
		"event-driven review signals populate exactly the retained history cards"
	)
	var external_summary := ReviewSystem.new(1).recent_summary()
	var screen_summary := screen.summary_snapshot()
	_expect(
		screen_summary.get("count") == external_summary.get("count")
		and is_equal_approx(float(screen_summary.get("average", 0.0)), float(external_summary.get("average", 0.0))),
		"screen consumes ReviewSystem.recent_summary without a parallel calculation"
	)
	var distribution_total := 0
	for stars: int in range(1, 6):
		var count_label := screen.find_child("StarCount%d" % stars, true, false) as Label
		distribution_total += int(count_label.text) if count_label != null else 0
	_expect(distribution_total == 3, "1-5 star distribution represents every retained review exactly once")
	_expect(
		latest_text != null
		and "Recensione numero 4" in latest_text.text
		and GameFonts.unsupported_runtime_characters(latest_text.text).is_empty(),
		"large latest review updates from state and sanitizes legacy Web-unsafe symbols"
	)
	_expect(
		positive_tags != null
		and ("Qualita del cibo" in positive_tags.text or "Servizio" in positive_tags.text)
		and negative_tags != null,
		"frequent positive and negative tag areas use readable labels"
	)

	GameState.reputation = 4.25
	var before_reputation_signal := screen.refresh_count()
	GameState.reputation_changed.emit(GameState.reputation)
	var reputation_label := screen.find_child("CurrentReputation", true, false) as Label
	_expect(
		screen.refresh_count() == before_reputation_signal + 1
		and reputation_label != null
		and "4.25" in reputation_label.text,
		"reputation signal updates existing summary nodes immediately"
	)
	var before_reward_signal := screen.refresh_count()
	GameState.set_review_reward_progress(2)
	var expected_threshold := maxi(int(DataRegistry.balance_value("album.positive_reviews_per_reward", 5)), 1)
	_expect(
		screen.refresh_count() == before_reward_signal + 1
		and progress != null
		and int(progress.value) == 2
		and int(progress.max_value) == expected_threshold
		and progress_label != null
		and "2 / %d" % expected_threshold in progress_label.text,
		"album progress signal updates the existing progress bar and label"
	)

	var pooled_ids := screen.history_card_instance_ids()
	var descendant_count := _descendant_count(screen)
	for _iteration: int in 5:
		screen.refresh()
	_expect(
		screen.hierarchy_build_count() == 1
		and _descendant_count(screen) == descendant_count
		and screen.history_card_instance_ids() == pooled_ids
		and title.get_instance_id() == title_id
		and overview.get_instance_id() == overview_id
		and progress.get_instance_id() == progress_id,
		"manual and signal refreshes update the persistent node pool without rebuilding controls"
	)

	GameState.append_review({
		"id": "ui_review_5",
		"day": 6,
		"minute": 900,
		"stars": 1,
		"satisfaction": 20,
		"customer_type": "gruppo_test",
		"tip": 0,
		"text": "Piatto bruciato",
		"positive_tags": [],
		"negative_tags": ["burned"],
	})
	_expect(
		GameState.reviews.size() == 3
		and screen.visible_history_count() == 3
		and screen.history_card_instance_ids() == pooled_ids,
		"rolling history reuses its existing card nodes when the configured limit is full"
	)

	get_window().size = Vector2i(390, 844)
	screen.size = Vector2(390, 844)
	await get_tree().process_frame
	_expect(
		overview.columns == 1
		and insights.columns == 1
		and history_scroll.custom_minimum_size.y >= 330.0,
		"phone width stacks panels and preserves a large touch-scroll history area (window=%s screen=%s columns=%d/%d history=%.1f)"
		% [get_window().size, screen.size, overview.columns, insights.columns, history_scroll.custom_minimum_size.y]
	)
	get_window().size = Vector2i(800, 1024)
	screen.size = Vector2(800, 1024)
	await get_tree().process_frame
	_expect(overview.columns == 2 and insights.columns == 2, "tablet width restores the two-column summary layout")
	_expect(
		history_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED
		and history_scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO
		and history_scroll.follow_focus,
		"history is touch-friendly and never requires horizontal scrolling"
	)
	_expect(_all_runtime_text_is_web_safe(screen), "all visible dynamic reviews and labels are Fredoka/Web-safe")
	_expect(_all_texture_rects_use_real_icons(screen), "screen uses real GameIcons textures instead of emoji or text glyph icons")

	var result := "REVIEWS SCREEN: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/reviews-screen-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()

	screen.queue_free()
	await get_tree().process_frame
	get_window().size = original_window_size
	DataRegistry.gameplay_balance["reviews"] = original_review_balance
	GameState.deserialize(original_state)
	SaveManager.writes_enabled = previous_writes_enabled
	get_tree().quit(0 if failures.is_empty() else 1)


func _descendant_count(root: Node) -> int:
	var result := 0
	for child: Node in root.get_children():
		result += 1 + _descendant_count(child)
	return result


func _all_runtime_text_is_web_safe(root: Node) -> bool:
	if root is Label:
		if not GameFonts.unsupported_runtime_characters((root as Label).text).is_empty():
			return false
	for child: Node in root.get_children():
		if not _all_runtime_text_is_web_safe(child):
			return false
	return true


func _all_texture_rects_use_real_icons(root: Node) -> bool:
	if root is TextureRect:
		var texture := (root as TextureRect).texture
		if texture == null or texture.get_width() <= 0 or texture.get_height() <= 0:
			return false
	for child: Node in root.get_children():
		if not _all_texture_rects_use_real_icons(child):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
