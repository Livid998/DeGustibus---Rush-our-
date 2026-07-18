class_name ReviewSystem
extends RefCounted

signal review_created(review: Dictionary)
signal reputation_updated(previous_value: float, current_value: float)
signal album_rewards_granted(rewards: Array)

const TEMPLATE_PATH := "res://data/review_templates.json"
const REQUIRED_TEMPLATE_KEYS: Array[String] = [
	"wait",
	"food_quality",
	"service",
	"ambience",
	"cleanliness",
	"sold_out",
	"small_portion",
	"undercooked",
	"overcooked",
	"burned",
	"poor_presentation",
	"mouse",
	"insect",
	"resolved_incident",
]
const DEFAULT_CONFIG := {
	"history_limit": 100,
	"reputation_ema_alpha": 0.06,
	"base_experience": 72.0,
	"star_thresholds": [40, 55, 70, 85],
	"tip_bands": [
		{"minimum": 0, "rate": 0.0},
		{"minimum": 50, "rate": 0.05},
		{"minimum": 70, "rate": 0.10},
		{"minimum": 85, "rate": 0.15},
		{"minimum": 95, "rate": 0.20},
	],
	"wait_comfort_seconds": 12.0,
	"wait_severe_seconds": 70.0,
	"pre_entry_review_chance": 0.12,
	"max_text_observations": 2,
	"service_tip_modifier_cap": 0.02,
}

var template_validation_errors: Array[String] = []
var configuration_errors: Array[String] = []

var _rng := RandomNumberGenerator.new()
var _config: Dictionary = {}
var _templates: Dictionary = {}
var _cause_serial := 0
var _submitted_ids: Dictionary = {}


func _init(seed_value: int = -1, config_overrides: Dictionary = {}) -> void:
	_config = DEFAULT_CONFIG.duplicate(true)
	if Engine.get_main_loop() != null:
		_config = _deep_merge(_config, DataRegistry.balance_section("reviews"))
	_config = _deep_merge(_config, config_overrides)
	configuration_errors = _validate_configuration(_config)
	_templates = load_template_data()
	template_validation_errors = validate_template_data(_templates)
	set_seed(seed_value)


func set_seed(seed_value: int) -> void:
	if seed_value < 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value


func configuration() -> Dictionary:
	return _config.duplicate(true)


func templates_are_valid() -> bool:
	return template_validation_errors.is_empty()


static func load_template_data(path: String = TEMPLATE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return (parsed as Dictionary).duplicate(true) if parsed is Dictionary else {}


static func validate_template_data(data: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	if int(data.get("schema_version", 0)) < 1:
		errors.append("schema_version must be at least 1")
	var observations: Variant = data.get("observations", {})
	if not observations is Dictionary:
		errors.append("observations must be an object")
		return errors
	for key: String in REQUIRED_TEMPLATE_KEYS:
		if not (observations as Dictionary).has(key):
			errors.append("missing observation template: %s" % key)
			continue
		var entry: Variant = (observations as Dictionary)[key]
		if not entry is Dictionary:
			errors.append("observation %s must be an object" % key)
			continue
		var fragment_count := 0
		for direction: String in ["positive", "negative"]:
			var fragments: Variant = (entry as Dictionary).get(direction, [])
			if not fragments is Array:
				errors.append("observation %s.%s must be an array" % [key, direction])
				continue
			for fragment: Variant in fragments:
				if not fragment is String or String(fragment).strip_edges().is_empty():
					errors.append("observation %s.%s contains an invalid fragment" % [key, direction])
				else:
					fragment_count += 1
		if fragment_count == 0:
			errors.append("observation %s has no text fragments" % key)
	var fallback: Variant = data.get("fallback", {})
	if not fallback is Dictionary:
		errors.append("fallback must be an object")
	else:
		for direction: String in ["positive", "neutral", "negative"]:
			var fragments: Variant = (fallback as Dictionary).get(direction, [])
			if not fragments is Array or (fragments as Array).is_empty():
				errors.append("fallback.%s must contain at least one fragment" % direction)
	var aliases: Variant = data.get("tag_aliases", {})
	if not aliases is Dictionary:
		errors.append("tag_aliases must be an object")
	else:
		for tag: String in aliases:
			var target := String((aliases as Dictionary)[tag])
			if not (observations as Dictionary).has(target):
				errors.append("tag alias %s references missing template %s" % [tag, target])
	return errors


func begin_experience(group_id: String, context: Dictionary = {}) -> Dictionary:
	var base_score := clampf(
		float(context.get("base_score", _config.get("base_experience", 72.0))),
		0.0,
		100.0
	)
	return {
		"group_id": group_id,
		"base_score": base_score,
		"causes": [],
		"stage": String(context.get("stage", "arrived")),
		"customer_type": String(context.get("customer_type", "gruppo")),
		"recipe_ids": _string_array(context.get("recipe_ids", [])),
		"incident_ids": _string_array(context.get("incident_ids", [])),
		"created_at": float(context.get("created_at", 0.0)),
		"metadata": (context.get("metadata", {}) as Dictionary).duplicate(true)
			if context.get("metadata", {}) is Dictionary else {},
	}


func set_stage(experience: Dictionary, stage: String) -> void:
	experience["stage"] = stage


func add_recipe(experience: Dictionary, recipe_id: String) -> void:
	if recipe_id.is_empty():
		return
	var recipe_ids: Array = experience.get("recipe_ids", [])
	if not recipe_ids.has(recipe_id):
		recipe_ids.append(recipe_id)
	experience["recipe_ids"] = recipe_ids


func add_incident(experience: Dictionary, incident_id: String) -> void:
	if incident_id.is_empty():
		return
	var incident_ids: Array = experience.get("incident_ids", [])
	if not incident_ids.has(incident_id):
		incident_ids.append(incident_id)
	experience["incident_ids"] = incident_ids


func record_cause(
	experience: Dictionary,
	cause_id: String,
	category: String,
	delta: float,
	tags: Array = [],
	template_key: String = "",
	metadata: Dictionary = {}
) -> Dictionary:
	_cause_serial += 1
	var clean_tags: Array[String] = _string_array(tags)
	var resolved_template := template_key
	if resolved_template.is_empty():
		resolved_template = _template_for_tags(clean_tags, category)
	var cause := {
		"id": cause_id if not cause_id.is_empty() else "cause_%d" % _cause_serial,
		"category": category,
		"delta": clampf(delta, -100.0, 100.0),
		"polarity": "positive" if delta > 0.0 else "negative" if delta < 0.0 else "neutral",
		"tags": clean_tags,
		"template_key": resolved_template,
		"metadata": metadata.duplicate(true),
		"serial": _cause_serial,
	}
	var causes: Array = experience.get("causes", [])
	causes.append(cause)
	experience["causes"] = causes
	experience.erase("_built_review")
	return cause


func set_cause(
	experience: Dictionary,
	cause_id: String,
	category: String,
	delta: float,
	tags: Array = [],
	template_key: String = "",
	metadata: Dictionary = {}
) -> Dictionary:
	var causes: Array = experience.get("causes", [])
	for index: int in range(causes.size() - 1, -1, -1):
		var existing: Variant = causes[index]
		if existing is Dictionary and String((existing as Dictionary).get("id", "")) == cause_id:
			causes.remove_at(index)
	experience["causes"] = causes
	return record_cause(experience, cause_id, category, delta, tags, template_key, metadata)


func record_wait(
	experience: Dictionary,
	phase: String,
	seconds: float,
	comfortable_seconds: float = -1.0,
	severe_seconds: float = -1.0
) -> Dictionary:
	var comfortable := comfortable_seconds
	if comfortable < 0.0:
		comfortable = float(_config.get("wait_comfort_seconds", 12.0))
	var severe := severe_seconds
	if severe <= comfortable:
		severe = float(_config.get("wait_severe_seconds", 70.0))
	var delta := 0.0
	if seconds <= comfortable:
		delta = lerpf(6.0, 0.0, clampf(seconds / maxf(comfortable, 0.01), 0.0, 1.0))
	else:
		delta = lerpf(0.0, -25.0, clampf((seconds - comfortable) / maxf(severe - comfortable, 0.01), 0.0, 1.0))
	var wait_tag := "%s_wait" % phase if phase in ["order", "food", "bill"] else "food_wait"
	return set_cause(
		experience,
		"wait_%s" % phase,
		"wait",
		delta,
		[wait_tag],
		"wait",
		{"phase": phase, "seconds": maxf(seconds, 0.0)}
	)


func record_food_quality(experience: Dictionary, average_quality: float) -> Dictionary:
	var normalized := clampf(average_quality, 0.0, 100.0)
	var delta := lerpf(-20.0, 20.0, normalized / 100.0)
	return set_cause(
		experience,
		"food_quality",
		"food_quality",
		delta,
		["food_quality"],
		"food_quality",
		{"quality_score": normalized}
	)


func record_service(experience: Dictionary, service_score: float) -> Dictionary:
	var normalized := clampf(service_score, 0.0, 100.0)
	return set_cause(
		experience,
		"waiter_service",
		"service",
		lerpf(-10.0, 10.0, normalized / 100.0),
		["waiter_service"],
		"service",
		{"service_score": normalized}
	)


func record_ambience(
	experience: Dictionary,
	beauty_score: float,
	cleanliness_score: float
) -> void:
	var beauty := clampf(beauty_score, 0.0, 100.0)
	var cleanliness := clampf(cleanliness_score, 0.0, 100.0)
	set_cause(
		experience,
		"ambience",
		"ambience",
		lerpf(-5.0, 5.0, beauty / 100.0),
		["ambience", "beauty"],
		"ambience",
		{"beauty_score": beauty}
	)
	set_cause(
		experience,
		"cleanliness",
		"cleanliness",
		lerpf(-5.0, 5.0, cleanliness / 100.0),
		["cleanliness"],
		"cleanliness",
		{"cleanliness_score": cleanliness}
	)


func record_change_order(
	experience: Dictionary,
	response_seconds: float,
	resolved: bool
) -> void:
	var penalty := -15.0
	if resolved:
		penalty = lerpf(-3.0, -10.0, clampf(response_seconds / 45.0, 0.0, 1.0))
	set_cause(
		experience,
		"sold_out_after_order",
		"availability",
		penalty,
		["sold_out_after_order"],
		"sold_out",
		{"response_seconds": maxf(response_seconds, 0.0), "resolved": resolved}
	)
	if resolved:
		record_incident_resolution(experience, "change_order_resolved", response_seconds)


func record_incident_resolution(
	experience: Dictionary,
	incident_id: String,
	response_seconds: float
) -> Dictionary:
	add_incident(experience, incident_id)
	var bonus := lerpf(8.0, 1.0, clampf(response_seconds / 60.0, 0.0, 1.0))
	return set_cause(
		experience,
		"resolved_%s" % incident_id,
		"incident",
		bonus,
		["incident_resolved"],
		"resolved_incident",
		{"incident_id": incident_id, "response_seconds": maxf(response_seconds, 0.0)}
	)


func record_visible_pest(experience: Dictionary, pest_type: String) -> Dictionary:
	var is_mouse := pest_type == "mouse"
	var template_key := "mouse" if is_mouse else "insect"
	var tag := "mouse_visible" if is_mouse else "insect_visible"
	var penalty := -15.0 if is_mouse else -8.0
	return set_cause(
		experience,
		"visible_pest_%s" % template_key,
		"pest",
		penalty,
		[tag],
		template_key,
		{"pest_type": template_key}
	)


func experience_score(experience: Dictionary) -> float:
	var total := float(experience.get("base_score", _config.get("base_experience", 72.0)))
	for value: Variant in experience.get("causes", []):
		if value is Dictionary:
			total += float((value as Dictionary).get("delta", 0.0))
	return clampf(total, 0.0, 100.0)


func stars_for_score(satisfaction: float) -> int:
	var score := clampf(satisfaction, 0.0, 100.0)
	var thresholds: Array = _config.get("star_thresholds", [40, 55, 70, 85])
	for index: int in thresholds.size():
		if score < float(thresholds[index]):
			return index + 1
	return 5


func tip_breakdown(
	group_total: float,
	satisfaction: float,
	service_modifier: float = 0.0
) -> Dictionary:
	var normalized_total := maxf(group_total, 0.0)
	var base_rate := 0.0
	for value: Variant in _config.get("tip_bands", []):
		if not value is Dictionary:
			continue
		var band := value as Dictionary
		if satisfaction >= float(band.get("minimum", 0.0)):
			base_rate = maxf(base_rate, float(band.get("rate", 0.0)))
	var modifier_cap := maxf(float(_config.get("service_tip_modifier_cap", 0.02)), 0.0)
	var applied_modifier := clampf(service_modifier, -modifier_cap, modifier_cap)
	var final_rate := 0.0 if base_rate <= 0.0 else clampf(base_rate + applied_modifier, 0.0, 1.0)
	var tip := maxi(int(round(normalized_total * final_rate)), 0)
	return {
		"group_total": normalized_total,
		"base_rate": base_rate,
		"service_modifier": applied_modifier,
		"final_rate": final_rate,
		"tip": tip,
	}


func calculate_group_tip(
	group_total: float,
	satisfaction: float,
	service_modifier: float = 0.0
) -> int:
	return int(tip_breakdown(group_total, satisfaction, service_modifier).tip)


func top_causes(
	experience: Dictionary,
	polarity: String,
	limit: int = 2
) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for value: Variant in experience.get("causes", []):
		if not value is Dictionary:
			continue
		var cause := value as Dictionary
		var delta := float(cause.get("delta", 0.0))
		if polarity == "positive" and delta <= 0.0:
			continue
		if polarity == "negative" and delta >= 0.0:
			continue
		candidates.append(cause)
	var result: Array[Dictionary] = []
	while not candidates.is_empty() and result.size() < maxi(limit, 0):
		var best_index := 0
		for index: int in range(1, candidates.size()):
			var candidate_strength := absf(float(candidates[index].get("delta", 0.0)))
			var best_strength := absf(float(candidates[best_index].get("delta", 0.0)))
			if candidate_strength > best_strength:
				best_index = index
			elif is_equal_approx(candidate_strength, best_strength):
				if int(candidates[index].get("serial", 0)) < int(candidates[best_index].get("serial", 0)):
					best_index = index
		result.append(candidates[best_index].duplicate(true))
		candidates.remove_at(best_index)
	return result


func should_generate_review(experience: Dictionary, outcome: String) -> bool:
	if experience.has("_review_eligibility"):
		return bool(experience["_review_eligibility"])
	var eligible := false
	if outcome == "paid":
		eligible = true
	elif outcome in ["abandoned", "left_after_seating", "left_after_order"]:
		var stage := String(experience.get("stage", "arrived"))
		eligible = stage in ["seated", "ordering", "ordered", "waiting_food", "eating", "paying"]
	elif outcome in ["pre_entry_left", "queue_abandoned"]:
		eligible = _rng.randf() < clampf(float(_config.get("pre_entry_review_chance", 0.12)), 0.0, 1.0)
	experience["_review_eligibility"] = eligible
	return eligible


func build_review(
	experience: Dictionary,
	group_total: float,
	context: Dictionary = {}
) -> Dictionary:
	if experience.has("_built_review"):
		return (experience["_built_review"] as Dictionary).duplicate(true)
	var satisfaction := experience_score(experience)
	var stars := stars_for_score(satisfaction)
	var service_modifier := float(context.get("service_tip_modifier", 0.0))
	var tip_data := tip_breakdown(group_total, satisfaction, service_modifier)
	var positives := top_causes(experience, "positive", 2)
	var negatives := top_causes(experience, "negative", 2)
	var positive_tags := _tags_from_causes(positives)
	var negative_tags := _tags_from_causes(negatives)
	var day := int(context.get("day", GameState.world_clock.get("day", 1)))
	var minute := float(context.get("minute", GameState.world_clock.get("minute", 0.0)))
	var review_id := String(context.get("review_id", ""))
	if review_id.is_empty():
		review_id = _make_review_id(String(experience.get("group_id", "group")), day, minute)
	var observation_data := _compose_observations(positives, negatives, stars)
	var review := {
		"id": review_id,
		"group_id": String(experience.get("group_id", "")),
		"day": day,
		"minute": minute,
		"stars": stars,
		"satisfaction": int(round(satisfaction)),
		"customer_type": String(context.get("customer_type", experience.get("customer_type", "gruppo"))),
		"recipe_ids": _string_array(context.get("recipe_ids", experience.get("recipe_ids", []))),
		"group_total": maxf(group_total, 0.0),
		"tip": int(tip_data.tip),
		"tip_rate": float(tip_data.final_rate),
		"positive_tags": positive_tags,
		"negative_tags": negative_tags,
		"top_positive_causes": positives,
		"top_negative_causes": negatives,
		"causes": (experience.get("causes", []) as Array).duplicate(true),
		"text": String(observation_data.text),
		"observation_keys": observation_data.keys,
		"incident_ids": _string_array(context.get("incident_ids", experience.get("incident_ids", []))),
		"outcome": String(context.get("outcome", "paid")),
	}
	experience["_built_review"] = review.duplicate(true)
	return review


func complete_group(
	experience: Dictionary,
	group_total: float,
	outcome: String = "paid",
	context: Dictionary = {}
) -> Dictionary:
	if not should_generate_review(experience, outcome):
		return {"accepted": false, "reason": "not_eligible", "review": {}}
	var review_context := context.duplicate(true)
	review_context["outcome"] = outcome
	var review := build_review(experience, group_total, review_context)
	var submission := submit_review(review)
	submission["review"] = review
	return submission


func submit_review(review: Dictionary) -> Dictionary:
	if review.is_empty() or String(review.get("id", "")).is_empty():
		return {"accepted": false, "reason": "invalid_review"}
	if _submitted_ids.has(String(review.id)):
		return {
			"accepted": false,
			"reason": "duplicate_review",
			"review": (_submitted_ids[String(review.id)] as Dictionary).duplicate(true),
		}
	for existing: Variant in GameState.reviews:
		if existing is Dictionary and String((existing as Dictionary).get("id", "")) == String(review.id):
			_submitted_ids[String(review.id)] = (existing as Dictionary).duplicate(true)
			return {
				"accepted": false,
				"reason": "duplicate_review",
				"review": (existing as Dictionary).duplicate(true),
			}

	var previous_reputation := float(GameState.reputation)
	var current_reputation := _apply_reputation_ema(int(review.get("stars", 3)))
	var rewards: Array = []
	rewards.append_array(CollectionManager.handle_reputation_changed(previous_reputation, current_reputation))
	rewards.append_array(CollectionManager.handle_review_completed(int(review.get("stars", 3))))
	review["album_rewards"] = rewards.duplicate(true)
	if not GameState.append_review(review):
		return {"accepted": false, "reason": "state_rejected"}
	_submitted_ids[String(review.id)] = review.duplicate(true)
	_trim_history_to_configured_limit()
	review_created.emit(review.duplicate(true))
	if not is_equal_approx(previous_reputation, current_reputation):
		reputation_updated.emit(previous_reputation, current_reputation)
	if not rewards.is_empty():
		album_rewards_granted.emit(rewards.duplicate(true))
	return {
		"accepted": true,
		"reason": "",
		"review": review.duplicate(true),
		"reputation_before": previous_reputation,
		"reputation_after": current_reputation,
		"album_rewards": rewards.duplicate(true),
	}


func recent_summary() -> Dictionary:
	var distribution := {1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
	var total := 0.0
	var positive_counts: Dictionary = {}
	var negative_counts: Dictionary = {}
	for value: Variant in GameState.reviews:
		if not value is Dictionary:
			continue
		var review := value as Dictionary
		var stars := clampi(int(review.get("stars", 3)), 1, 5)
		distribution[stars] = int(distribution.get(stars, 0)) + 1
		total += stars
		for tag: String in _string_array(review.get("positive_tags", [])):
			positive_counts[tag] = int(positive_counts.get(tag, 0)) + 1
		for tag: String in _string_array(review.get("negative_tags", [])):
			negative_counts[tag] = int(negative_counts.get(tag, 0)) + 1
	return {
		"count": GameState.reviews.size(),
		"average": total / float(GameState.reviews.size()) if not GameState.reviews.is_empty() else 0.0,
		"distribution": distribution,
		"positive_tag_counts": positive_counts,
		"negative_tag_counts": negative_counts,
		"latest": GameState.reviews[-1].duplicate(true) if not GameState.reviews.is_empty() else {},
	}


func _apply_reputation_ema(stars: int) -> float:
	var previous := clampf(float(GameState.reputation), 1.0, 5.0)
	var alpha := clampf(float(_config.get("reputation_ema_alpha", 0.06)), 0.0001, 1.0)
	var target := clampf(float(stars), 1.0, 5.0)
	var updated := clampf(previous + alpha * (target - previous), 1.0, 5.0)
	if GameState.has_method("set_reputation_value"):
		GameState.call("set_reputation_value", updated)
	elif GameState.has_method("set_reputation"):
		GameState.call("set_reputation", updated)
	else:
		GameState.reputation = updated
		if not is_equal_approx(previous, updated):
			GameState.reputation_changed.emit(updated)
			GameState.mark_save_dirty()
	GameState.reputation_weight = maxf(float(GameState.reputation_weight), 0.0) + 1.0
	GameState.mark_save_dirty()
	if GameState.has_method("check_progression"):
		GameState.call("check_progression", false)
	return float(GameState.reputation)


func _trim_history_to_configured_limit() -> void:
	var history_limit := maxi(int(_config.get("history_limit", 100)), 1)
	var changed := false
	while GameState.reviews.size() > history_limit:
		GameState.reviews.pop_front()
		changed = true
	if changed:
		GameState.reviews_changed.emit()
		GameState.mark_save_dirty()


func _compose_observations(
	positives: Array[Dictionary],
	negatives: Array[Dictionary],
	stars: int
) -> Dictionary:
	var candidates: Array[Dictionary] = []
	candidates.append_array(positives)
	candidates.append_array(negatives)
	var selected: Array[Dictionary] = []
	var used_keys: Array[String] = []
	var maximum := mini(maxi(int(_config.get("max_text_observations", 2)), 1), 2)
	while not candidates.is_empty() and selected.size() < maximum:
		var best_index := 0
		for index: int in range(1, candidates.size()):
			if absf(float(candidates[index].get("delta", 0.0))) > absf(float(candidates[best_index].get("delta", 0.0))):
				best_index = index
		var cause := candidates[best_index]
		candidates.remove_at(best_index)
		var template_key := String(cause.get("template_key", ""))
		if template_key.is_empty() or used_keys.has(template_key):
			continue
		var direction := "positive" if float(cause.get("delta", 0.0)) > 0.0 else "negative"
		var fragment := _select_fragment(template_key, direction)
		if fragment.is_empty():
			continue
		used_keys.append(template_key)
		selected.append({"key": template_key, "direction": direction, "text": fragment})
	if selected.is_empty():
		var fallback_direction := "positive" if stars >= 4 else "negative" if stars <= 2 else "neutral"
		selected.append({
			"key": "fallback",
			"direction": fallback_direction,
			"text": _select_fallback(fallback_direction),
		})
	var text_parts: Array[String] = []
	var keys: Array[String] = []
	for observation: Dictionary in selected:
		text_parts.append(String(observation.text))
		keys.append(String(observation.key))
	return {"text": " ".join(text_parts), "keys": keys, "observations": selected}


func _select_fragment(template_key: String, direction: String) -> String:
	var observations: Dictionary = _templates.get("observations", {})
	var entry: Dictionary = observations.get(template_key, {})
	var fragments: Array = entry.get(direction, [])
	if fragments.is_empty():
		return ""
	return String(fragments[_rng.randi_range(0, fragments.size() - 1)])


func _select_fallback(direction: String) -> String:
	var fallback: Dictionary = _templates.get("fallback", {})
	var fragments: Array = fallback.get(direction, [])
	if fragments.is_empty():
		return ""
	return String(fragments[_rng.randi_range(0, fragments.size() - 1)])


func _template_for_tags(tags: Array[String], category: String) -> String:
	var aliases: Dictionary = _templates.get("tag_aliases", {})
	for tag: String in tags:
		if aliases.has(tag):
			return String(aliases[tag])
	if _templates.get("observations", {}).has(category):
		return category
	return ""


func _tags_from_causes(causes: Array[Dictionary]) -> Array[String]:
	var result: Array[String] = []
	for cause: Dictionary in causes:
		var tags := _string_array(cause.get("tags", []))
		if tags.is_empty() and not String(cause.get("category", "")).is_empty():
			tags.append(String(cause.category))
		for tag: String in tags:
			if not result.has(tag):
				result.append(tag)
	return result


func _make_review_id(group_id: String, day: int, minute: float) -> String:
	var group_hash := absi(group_id.hash())
	return "review_d%d_m%d_g%d" % [maxi(day, 1), maxi(int(round(minute * 10.0)), 0), group_hash]


static func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for item: Variant in value:
			var text := String(item)
			if not text.is_empty() and not result.has(text):
				result.append(text)
	return result


static func _deep_merge(base: Dictionary, overrides: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	for key: Variant in overrides:
		var incoming: Variant = overrides[key]
		if result.get(key) is Dictionary and incoming is Dictionary:
			result[key] = _deep_merge(result[key], incoming)
		else:
			result[key] = incoming.duplicate(true) if incoming is Array or incoming is Dictionary else incoming
	return result


static func _validate_configuration(config: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	var star_thresholds: Variant = config.get("star_thresholds", [])
	if not star_thresholds is Array or (star_thresholds as Array).size() != 4:
		errors.append("reviews.star_thresholds must contain four values")
	else:
		var previous := 0.0
		for value: Variant in star_thresholds:
			var threshold := float(value)
			if threshold <= previous or threshold > 100.0:
				errors.append("reviews.star_thresholds must be strictly ascending within 1..100")
				break
			previous = threshold
	var tip_bands: Variant = config.get("tip_bands", [])
	if not tip_bands is Array or (tip_bands as Array).is_empty():
		errors.append("reviews.tip_bands must contain at least one band")
	else:
		var previous_minimum := -1.0
		for value: Variant in tip_bands:
			if not value is Dictionary:
				errors.append("reviews.tip_bands entries must be objects")
				break
			var band := value as Dictionary
			var minimum := float(band.get("minimum", -1.0))
			var rate := float(band.get("rate", -1.0))
			if minimum < previous_minimum or minimum > 100.0 or rate < 0.0 or rate > 1.0:
				errors.append("reviews.tip_bands must be ordered and contain valid rates")
				break
			previous_minimum = minimum
	var alpha := float(config.get("reputation_ema_alpha", 0.0))
	if alpha <= 0.0 or alpha > 1.0:
		errors.append("reviews.reputation_ema_alpha must be within (0, 1]")
	if int(config.get("history_limit", 0)) < 1:
		errors.append("reviews.history_limit must be positive")
	return errors
