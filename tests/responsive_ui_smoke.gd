extends Node

const TARGETS := [
	Vector2(390, 844),
	Vector2(412, 915),
	Vector2(800, 1024),
	Vector2(1280, 720),
	Vector2(1366, 768),
]

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var previous_writes_enabled := SaveManager.writes_enabled
	SaveManager.writes_enabled = false
	var orphan_baseline := Node.get_orphan_node_ids()
	var original_state := GameState.serialize().duplicate(true)
	GameState.reset_to_defaults(false)

	var ui := RestaurantUI.new()
	add_child(ui)
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(
		String(ProjectSettings.get_setting("display/window/stretch/mode", "")) == "disabled",
		"project uses pixel-native UI instead of stretching a desktop canvas"
	)

	ui.show_screen("Menu", false)
	await get_tree().process_frame
	var menu_page := ui.screen_page("Menu")
	var menu_page_id := menu_page.get_instance_id()
	var menu_grid := menu_page.find_child("MenuGrid", true, false) as GridContainer
	_expect(menu_grid != null and ui.screen_build_count("Menu") == 1, "Menu builds one cached page")
	# Keep the persistence check deterministic even if the fixture happens to
	# expose fewer recipes than a real save and would otherwise not overflow.
	menu_page.custom_minimum_size.y = 1200.0
	await get_tree().process_frame
	ui.screen_scroll.scroll_vertical = 96
	await get_tree().process_frame
	var saved_menu_scroll := ui.screen_scroll.scroll_vertical

	ui.show_screen("Album", false)
	await get_tree().process_frame
	ui.show_screen("Menu", false)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(
		ui.screen_page("Menu").get_instance_id() == menu_page_id
		and ui.screen_build_count("Menu") == 1,
		"switching management sections preserves the Menu page instance"
	)
	_expect(
		saved_menu_scroll > 0
		and ui.screen_scroll.scroll_vertical == saved_menu_scroll,
		"switching away and back restores the saved scroll position"
	)

	ui.show_screen("Statistiche", false)
	await get_tree().process_frame
	await get_tree().process_frame
	var statistics_page := ui.screen_page("Statistiche")
	var reviews := statistics_page.find_child("ReviewsScreen", true, false) as ReviewsScreen
	var operations := statistics_page.find_child("OperationalStatisticsScreen", true, false)
	var reviews_id := reviews.get_instance_id() if reviews != null else 0
	var operations_id := operations.get_instance_id() if operations != null else 0
	_expect(
		reviews != null
		and operations != null
		and reviews.hierarchy_build_count() == 1
		and int(operations.call("hierarchy_build_count")) == 1,
		"Statistics integrates one persistent Reviews and operational hierarchy"
	)
	ui._process(1.1)
	await get_tree().process_frame
	_expect(
		statistics_page.find_child("ReviewsScreen", true, false).get_instance_id() == reviews_id
		and statistics_page.find_child(
			"OperationalStatisticsScreen",
			true,
			false
		).get_instance_id() == operations_id
		and ui.screen_build_count("Statistiche") == 1,
		"one-second UI ticks do not rebuild the Statistics page"
	)
	ui.refresh_screen()
	await get_tree().process_frame
	_expect(
		statistics_page.find_child("ReviewsScreen", true, false).get_instance_id() == reviews_id
		and statistics_page.find_child(
			"OperationalStatisticsScreen",
			true,
			false
		).get_instance_id() == operations_id,
		"event refreshes update persistent Statistics children in place"
	)

	ui.show_screen("Personale", false)
	await get_tree().process_frame
	var staff := ui.screen_page("Personale").find_child(
		"StaffScreen",
		true,
		false
	) as StaffScreen
	_expect(
		staff != null and staff.hierarchy_build_count() == 1,
		"Personale uses the persistent event-driven StaffScreen"
	)

	for target: Vector2 in TARGETS:
		_verify_target(ui, target)

	ui._apply_responsive_layout(Vector2(390, 844))
	ui.more_button.pressed.emit()
	_expect(
		ui.more_sheet.visible
		and ui.more_sheet_grid.columns == 2
		and ui.more_sheet_buttons.size() == 4,
		"Altro opens a two-column touch bottom sheet with the four secondary destinations"
	)
	var statistics_button: Button = ui.more_sheet_buttons.get("Statistiche")
	statistics_button.pressed.emit()
	await get_tree().process_frame
	_expect(
		ui.current_screen == "Statistiche"
		and ui.screen_panel.visible
		and not ui.more_sheet.visible,
		"choosing a secondary destination closes Altro and opens its persistent page"
	)
	_expect(
		_all_runtime_text_is_web_safe(ui.root),
		"responsive shell and cached screens expose only Web-safe runtime text"
	)

	var result := "RESPONSIVE UI: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/responsive-ui-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()

	var exit_code := 0 if failures.is_empty() else 1
	await _teardown_fixture(
		ui,
		original_state,
		previous_writes_enabled,
		orphan_baseline
	)
	# A SceneTreeTimer survives this test scene and targets SceneTree directly,
	# so the test node and its script/resource dependencies can be destroyed
	# before rendering-server shutdown begins.
	var quit_timer := get_tree().create_timer(0.15)
	quit_timer.timeout.connect(Callable(get_tree(), "quit").bind(exit_code))
	queue_free()


func _teardown_fixture(
	ui: RestaurantUI,
	original_state: Dictionary,
	previous_writes_enabled: bool,
	orphan_baseline: PackedInt64Array
) -> void:
	if is_instance_valid(ui):
		ui.set_process(false)
		# RestaurantUI owns a transient Theme and generated scaled icon cache.
		# Detach the theme before freeing the tree so their RenderingServer RIDs
		# can be reclaimed during the following idle frames.
		if is_instance_valid(ui.root):
			ui.root.theme = null
		ui._theme = null
		ui.queue_free()
	for _frame: int in 4:
		await get_tree().process_frame
	_free_fixture_orphans(orphan_baseline)
	GameIcons._scaled_cache = {}
	GameFonts._medium = null
	GameFonts._semibold = null
	GameFonts._bold = null
	GameState.deserialize(original_state)
	SaveManager.writes_enabled = previous_writes_enabled
	for _frame: int in 3:
		await get_tree().process_frame


func _free_fixture_orphans(orphan_baseline: PackedInt64Array) -> void:
	for instance_id: int in Node.get_orphan_node_ids():
		if instance_id in orphan_baseline:
			continue
		var object := instance_from_id(instance_id)
		if is_instance_valid(object) and object is Node:
			(object as Node).free()


func _verify_target(ui: RestaurantUI, target: Vector2) -> void:
	ui._apply_responsive_layout(target)
	var phone := target.x <= 600.0
	var portrait := target.y > target.x
	var visible_primary: Array[String] = []
	for screen_name: String in ui.nav_buttons:
		var button: Button = ui.nav_buttons[screen_name]
		if button.visible:
			visible_primary.append(screen_name)
	var expected_visible := (
		RestaurantUI.PHONE_PRIMARY_SCREENS.size()
		if phone
		else RestaurantUI.SCREENS.size()
	)
	_expect(
		visible_primary.size() == expected_visible and ui.more_button.visible == phone,
		"%dx%d exposes %d destinations%s" % [
			int(target.x),
			int(target.y),
			expected_visible,
			" plus Altro" if phone else "",
		]
	)
	_expect(
		ui.nav_row.get_combined_minimum_size().x <= target.x - 28.0,
		"%dx%d navigation minimum width fits inside its panel" % [
			int(target.x),
			int(target.y),
		]
	)
	if phone:
		var exact_primary := true
		for screen_name: String in RestaurantUI.PHONE_PRIMARY_SCREENS:
			exact_primary = exact_primary and screen_name in visible_primary
			var button: Button = ui.nav_buttons[screen_name]
			exact_primary = (
				exact_primary
				and button.custom_minimum_size.y >= 54.0
				and not button.text.is_empty()
				and button.icon != null
			)
		_expect(
			exact_primary,
			"%dx%d keeps four labelled icon destinations with touch-sized targets" % [
				int(target.x),
				int(target.y),
			]
		)
		_expect(
			ui.screen_panel.offset_top >= ui.top_bar.offset_bottom
			and -ui.screen_panel.offset_bottom > -ui.nav_panel.offset_top,
			"%dx%d keeps management content between top bar and navigation" % [
				int(target.x),
				int(target.y),
			]
		)
	var album_page := ui.screen_page("Album")
	if album_page != null:
		var album_grid := album_page.find_child("AlbumGrid", true, false) as GridContainer
		var expected_columns := 2 if phone else 3 if portrait else 6
		_expect(
			album_grid != null and album_grid.columns == expected_columns,
			"%dx%d applies %d responsive Album columns" % [
				int(target.x),
				int(target.y),
				expected_columns,
			]
		)
	var menu_page := ui.screen_page("Menu")
	if menu_page != null:
		var card_layout := menu_page.find_child("MenuCardLayout", true, false) as GridContainer
		var controls_layout := menu_page.find_child(
			"MenuCardControls",
			true,
			false
		) as GridContainer
		var expected_card_columns := 1 if phone else 2
		_expect(
			card_layout != null
			and controls_layout != null
			and card_layout.columns == expected_card_columns
			and controls_layout.columns == expected_card_columns,
			"%dx%d applies %d-column Menu card internals without horizontal clipping" % [
				int(target.x),
				int(target.y),
				expected_card_columns,
			]
		)
	var statistics_page := ui.screen_page("Statistiche")
	if statistics_page != null:
		var overview := statistics_page.find_child(
			"ReviewsOverviewGrid",
			true,
			false
		) as GridContainer
		var expected_review_columns := 1 if target.x < 720.0 else 2
		_expect(
			overview != null and overview.columns == expected_review_columns,
			"%dx%d applies %d responsive review columns" % [
				int(target.x),
				int(target.y),
				expected_review_columns,
			]
		)


func _all_runtime_text_is_web_safe(node: Node) -> bool:
	var values: Array[String] = []
	if node is Label:
		values.append((node as Label).text)
	elif node is Button:
		values.append((node as Button).text)
	elif node is OptionButton:
		var option := node as OptionButton
		for index: int in option.item_count:
			values.append(option.get_item_text(index))
	elif node is TabBar:
		var tabs := node as TabBar
		for index: int in tabs.tab_count:
			values.append(tabs.get_tab_title(index))
	for value: String in values:
		if not GameFonts.unsupported_runtime_characters(value).is_empty():
			return false
	for child: Node in node.get_children():
		if not _all_runtime_text_is_web_safe(child):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
