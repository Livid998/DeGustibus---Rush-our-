extends Node

const ReviewSystemScript := preload("res://scripts/simulation/review_system.gd")
const DishQualityResolverScript := preload("res://scripts/simulation/dish_quality_resolver.gd")

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	var previous_writes_enabled := SaveManager.writes_enabled
	SaveManager.writes_enabled = false
	var original_state := GameState.serialize().duplicate(true)
	GameState.reset_to_defaults(false)

	_test_template_validation_and_experience()
	_test_star_and_tip_bands()
	_test_seeded_offline_text()
	_test_submission_reputation_history_and_album()
	_test_quality_components_and_seed()
	_test_contextual_defects_and_recovery()
	_test_extreme_event_probability()

	GameState.deserialize(original_state)
	SaveManager.writes_enabled = previous_writes_enabled
	var result := "REVIEW QUALITY: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/review-quality-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_template_validation_and_experience() -> void:
	var template_data := ReviewSystemScript.load_template_data()
	var validation: Array[String] = ReviewSystemScript.validate_template_data(template_data)
	var review_system := ReviewSystemScript.new(101)
	_expect(validation.is_empty() and review_system.templates_are_valid(), "review template JSON is complete and valid")
	_expect(review_system.configuration_errors.is_empty(), "review tuning is valid")
	var experience: Dictionary = review_system.begin_experience("group_structured", {"base_score": 72})
	review_system.record_cause(experience, "fast_service", "service", 8.0, ["waiter_service"], "service")
	review_system.record_cause(experience, "slow_food", "wait", -12.0, ["food_wait"], "wait")
	review_system.record_cause(experience, "small_issue", "cleanliness", -2.0, ["cleanliness"], "cleanliness")
	_expect(is_equal_approx(review_system.experience_score(experience), 66.0), "group experience clamps and sums its structured causes")
	_expect(
		experience.causes.size() == 3
		and experience.causes[0].has("id")
		and experience.causes[0].has("category")
		and experience.causes[0].has("delta")
		and experience.causes[0].has("tags"),
		"every experience contribution remains inspectable as a structured cause"
	)
	var positives: Array[Dictionary] = review_system.top_causes(experience, "positive", 2)
	var negatives: Array[Dictionary] = review_system.top_causes(experience, "negative", 2)
	_expect(positives.size() == 1 and String(positives[0].id) == "fast_service", "debug exposes the strongest positive causes")
	_expect(
		negatives.size() == 2
		and String(negatives[0].id) == "slow_food"
		and String(negatives[1].id) == "small_issue",
		"debug exposes at most the two strongest negative causes in order"
	)
	review_system.record_wait(experience, "food", 80.0)
	review_system.record_food_quality(experience, 90.0)
	review_system.record_service(experience, 85.0)
	review_system.record_ambience(experience, 80.0, 25.0)
	_expect(experience.causes.size() >= 7, "wait, food, service, beauty and cleanliness helpers all emit causes")


func _test_star_and_tip_bands() -> void:
	var review_system := ReviewSystemScript.new(102)
	var star_cases := {
		0: 1,
		39: 1,
		40: 2,
		54: 2,
		55: 3,
		69: 3,
		70: 4,
		84: 4,
		85: 5,
		100: 5,
	}
	for score: int in star_cases:
		_expect(review_system.stars_for_score(score) == int(star_cases[score]), "star threshold maps score %d correctly" % score)
	_expect(review_system.calculate_group_tip(100.0, 49.0) == 0, "groups below 50 satisfaction leave no tip")
	_expect(review_system.calculate_group_tip(100.0, 50.0) == 5, "50 satisfaction uses one aggregated 5 percent group tip")
	_expect(review_system.calculate_group_tip(100.0, 70.0) == 10, "70 satisfaction uses one aggregated 10 percent group tip")
	_expect(review_system.calculate_group_tip(100.0, 85.0) == 15, "85 satisfaction uses one aggregated 15 percent group tip")
	_expect(review_system.calculate_group_tip(100.0, 95.0) == 20, "95 satisfaction uses one aggregated 20 percent group tip")
	_expect(
		review_system.calculate_group_tip(100.0, 85.0, 1.0) == 17,
		"waiter courtesy can only apply the configured small tip modifier"
	)


func _test_seeded_offline_text() -> void:
	var first_system := ReviewSystemScript.new(20260717)
	var second_system := ReviewSystemScript.new(20260717)
	var first_experience: Dictionary = first_system.begin_experience("seeded_group", {"base_score": 72})
	var second_experience: Dictionary = second_system.begin_experience("seeded_group", {"base_score": 72})
	for system_and_experience: Array in [
		[first_system, first_experience],
		[second_system, second_experience],
	]:
		var system: RefCounted = system_and_experience[0]
		var experience: Dictionary = system_and_experience[1]
		system.call("record_cause", experience, "great_food", "food_quality", 16.0, ["food_quality"], "food_quality")
		system.call("record_cause", experience, "slow_wait", "wait", -18.0, ["food_wait"], "wait")
		system.call("record_cause", experience, "small_plate", "defect", -8.0, ["small_portion"], "small_portion")
	var first := first_system.build_review(first_experience, 80.0, {"review_id": "seeded"})
	var second := second_system.build_review(second_experience, 80.0, {"review_id": "seeded"})
	_expect(first.text == second.text and first.observation_keys == second.observation_keys, "same seed and causes produce identical offline review text")
	_expect(first.observation_keys.size() <= 2, "review text combines at most two principal observations")
	_expect(
		first.positive_tags.has("food_quality")
		and (first.negative_tags.has("food_wait") or first.negative_tags.has("small_portion")),
		"review tags stay coherent with the structured causes"
	)
	_expect(not String(first.text).is_empty(), "offline review text never depends on a network service")


func _test_submission_reputation_history_and_album() -> void:
	GameState.reset_to_defaults(false)
	GameState.reputation = 3.0
	GameState.reviews = []
	GameState.set_review_reward_progress(0)
	for ingredient: Dictionary in DataRegistry.ingredients:
		GameState.set_album_ingredient_amount(String(ingredient.id), 0)
	CollectionManager.set_reward_seed(9981, 0)
	var review_system := ReviewSystemScript.new(77, {"history_limit": 3})
	var album_before := _album_total()
	var first_submission: Dictionary = {}
	for index: int in 5:
		var review := {
			"id": "positive_%d" % index,
			"stars": 4,
			"satisfaction": 80,
			"tip": 10,
			"text": "Test",
			"positive_tags": ["food_quality"],
			"negative_tags": [],
		}
		var submission := review_system.submit_review(review)
		if index == 0:
			first_submission = submission
		_expect(bool(submission.accepted), "unique completed group review %d is accepted once" % index)
	var reputation_after_positive := float(GameState.reputation)
	_expect(reputation_after_positive > 3.0 and reputation_after_positive < 3.3, "positive reviews raise reputation gradually")
	_expect(GameState.reviews.size() == 3, "review history obeys the configured maximum")
	_expect(_album_total() == album_before + 1, "five positive reviews grant exactly one album reward")
	_expect(GameState.review_reward_progress == 0, "positive review reward progress wraps at the configured threshold")
	var reward_progress_before_duplicate := GameState.review_reward_progress
	var duplicate := review_system.submit_review({
		"id": "positive_0",
		"stars": 4,
		"satisfaction": 80,
		"tip": 10,
	})
	_expect(
		not bool(duplicate.accepted)
		and String(duplicate.reason) == "duplicate_review"
		and GameState.reviews.size() == 3
		and GameState.review_reward_progress == reward_progress_before_duplicate,
		"duplicate group finalization cannot duplicate its review, tip record or album progress"
	)
	var negative := review_system.submit_review({
		"id": "negative_once",
		"stars": 1,
		"satisfaction": 25,
		"tip": 0,
		"text": "Test negativo",
		"positive_tags": [],
		"negative_tags": ["food_wait"],
	})
	_expect(bool(negative.accepted), "a paid negative visit still creates a review")
	var reputation_after_negative := float(GameState.reputation)
	_expect(
		reputation_after_negative < reputation_after_positive
		and reputation_after_positive - reputation_after_negative < 0.30,
		"one-star reviews lower reputation without erasing hours of progress"
	)
	_expect(float(GameState.reputation_weight) >= 6.0, "review EMA weight persists as part of review progression")
	_expect(bool(first_submission.accepted), "first positive review submission produced a valid result")


func _test_quality_components_and_seed() -> void:
	var first := DishQualityResolverScript.new(424242)
	var second := DishQualityResolverScript.new(424242)
	_expect(first.configuration_errors.is_empty(), "dish quality tuning is valid")
	var context := {
		"station": "stove",
		"ingredient_qualities": [2, 3, 4],
		"employee_skill": 0.82,
		"employee_precision": 0.88,
		"stress": 0.20,
		"cleanliness": 92,
		"station_condition": 95,
	}
	var first_result: Dictionary = first.resolve(context)
	var second_result: Dictionary = second.resolve(context)
	_expect(first_result == second_result, "dish quality and defect roll are deterministic with the same seed")
	_expect(
		int(first_result.quality_score) in range(0, 101)
		and String(first_result.quality_tier) in ["poor", "normal", "good", "excellent"],
		"dish quality always resolves to a 0-100 score and supported tier"
	)
	_expect(
		first_result.components.keys().size() == 6
		and first_result.components.has("ingredients")
		and first_result.components.has("stress_resilience"),
		"quality exposes ingredient, employee, stress, cleanliness and station contributions"
	)
	var no_random_config := {"random_variance": 0.0, "extreme_event_base_chance": 0.0}
	var high_resolver := DishQualityResolverScript.new(1, no_random_config)
	var low_resolver := DishQualityResolverScript.new(1, no_random_config)
	var high := high_resolver.resolve({
		"station": "pass",
		"ingredient_quality_score": 95,
		"skill": 0.95,
		"precision": 0.95,
		"stress": 0.05,
		"cleanliness": 100,
		"station_condition": 100,
	})
	var low := low_resolver.resolve({
		"station": "pass",
		"ingredient_quality_score": 30,
		"skill": 0.35,
		"precision": 0.35,
		"stress": 0.95,
		"cleanliness": 25,
		"station_condition": 30,
	})
	_expect(int(high.quality_score) > int(low.quality_score) + 40, "better physical ingredients and working conditions materially improve quality")
	_expect(
		high_resolver.quality_tier(54) == "poor"
		and high_resolver.quality_tier(55) == "normal"
		and high_resolver.quality_tier(70) == "good"
		and high_resolver.quality_tier(85) == "excellent",
		"quality tiers use configurable exact boundaries"
	)
	var order := {"quality_events": []}
	var applied := high_resolver.apply_to_order(order, {
		"station": "pass",
		"ingredient_quality_score": 90,
		"skill": 0.9,
		"precision": 0.9,
		"stress": 0.1,
		"cleanliness": 95,
		"station_condition": 100,
		"allow_defect_roll": false,
	})
	_expect(
		order.quality_score == applied.quality_score
		and order.has("quality_tier")
		and order.has("quality_events")
		and order.has("defect"),
		"resolver writes all required quality fields into an order"
	)


func _test_contextual_defects_and_recovery() -> void:
	var resolver := DishQualityResolverScript.new(123, {"random_variance": 0.0})
	_expect(
		resolver.contextual_defects("stove").has("undercooked")
		and resolver.contextual_defects("pizza_oven").has("burned")
		and not resolver.contextual_defects("pass").has("burned"),
		"cooking defects only appear on appropriate cooking stations"
	)
	_expect(
		resolver.contextual_defects("cutting_board").has("small_portion")
		and resolver.contextual_defects("dessert").has("small_portion")
		and resolver.contextual_defects("pass") == ["poor_presentation"],
		"prep, dessert and pass expose their contextual portion or plating defects"
	)
	var remake := resolver.resolve({
		"station": "stove",
		"force_defect": "burned",
		"remake_stock_available": true,
		"remake_attempts": 0,
	})
	_expect(
		String(remake.defect) == "burned"
		and String(remake.defect_severity) == "severe"
		and bool(remake.requires_remake)
		and not bool(remake.serveable),
		"a severe defect automatically requests a remake when stock exists"
	)
	var change_order := resolver.resolve({
		"station": "stove",
		"force_defect": "undercooked",
		"remake_stock_available": false,
	})
	_expect(
		bool(change_order.requires_change_order)
		and String(change_order.recovery.action) == "change_order",
		"a severe defect falls back to change order when a remake is impossible"
	)
	var mild := resolver.resolve({
		"station": "cutting_board",
		"force_defect": "small_portion",
		"remake_stock_available": true,
	})
	_expect(
		String(mild.defect_severity) == "mild"
		and bool(mild.serveable)
		and String(mild.recovery.action) == "serve_with_penalty",
		"a mild visible defect is served with an explicit reduced penalty"
	)
	var icon_ids := [
		String(remake.quality_events[0].icon_id),
		String(change_order.quality_events[0].icon_id),
		String(mild.quality_events[0].icon_id),
	]
	var icons_exist := true
	for icon_id: String in icon_ids:
		icons_exist = icons_exist and GameIcons.casual_system_icon(icon_id) != null
	_expect(icons_exist, "defect events reference the existing generated runtime icons")


func _test_extreme_event_probability() -> void:
	var resolver := DishQualityResolverScript.new(5519, {"extreme_event_cap": 0.08})
	var normal_context := {
		"station": "stove",
		"ingredient_quality_score": 80,
		"skill": 0.85,
		"precision": 0.90,
		"stress": 0.15,
		"cleanliness": 95,
		"station_condition": 100,
	}
	var normal_probability := resolver.defect_probability(normal_context)
	var stressed_probability := resolver.defect_probability({
		"station": "stove",
		"skill": 0.1,
		"precision": 0.1,
		"stress": 1.0,
		"cleanliness": 0,
		"station_condition": 0,
	})
	_expect(normal_probability < 0.01, "extreme defects remain below one percent in normal conditions")
	_expect(stressed_probability > normal_probability and stressed_probability <= 0.08, "risk can rise under bad conditions but never exceeds the configured cap")
	var samples := 5000
	var defects := 0
	for _index: int in samples:
		if not String(resolver.resolve(normal_context).defect).is_empty():
			defects += 1
	_expect(float(defects) / float(samples) < 0.01, "seeded empirical normal defect rate remains below one percent")


func _album_total() -> int:
	var total := 0
	for ingredient_id: String in GameState.album_inventory:
		total += int(GameState.album_inventory[ingredient_id])
	return total


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

