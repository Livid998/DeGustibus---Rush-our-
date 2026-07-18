class_name DishQualityResolver
extends RefCounted

const DEFAULT_CONFIG := {
	"tier_thresholds": [55, 70, 85],
	"random_variance": 3.0,
	"extreme_event_base_chance": 0.002,
	"extreme_event_cap": 0.12,
	"max_automatic_remakes": 1,
	"weights": {
		"ingredients": 0.25,
		"skill": 0.22,
		"precision": 0.18,
		"stress_resilience": 0.14,
		"cleanliness": 0.12,
		"station_condition": 0.09,
	},
	"risk": {
		"inexperience_threshold": 0.60,
		"inexperience_addition": 0.035,
		"stress_threshold": 0.65,
		"stress_addition": 0.045,
		"dirty_threshold": 55.0,
		"dirty_addition": 0.040,
		"station_threshold": 65.0,
		"station_addition": 0.030,
	},
}

const DEFECTS := {
	"small_portion": {
		"severity": "mild",
		"quality_penalty": 8.0,
		"review_tag": "small_portion",
		"icon_id": "defect_small_portion",
	},
	"undercooked": {
		"severity": "severe",
		"quality_penalty": 22.0,
		"review_tag": "undercooked",
		"icon_id": "defect_undercooked",
	},
	"overcooked": {
		"severity": "moderate",
		"quality_penalty": 14.0,
		"review_tag": "overcooked",
		"icon_id": "defect_overcooked",
	},
	"burned": {
		"severity": "severe",
		"quality_penalty": 30.0,
		"review_tag": "burned",
		"icon_id": "defect_burned",
	},
	"poor_presentation": {
		"severity": "mild",
		"quality_penalty": 7.0,
		"review_tag": "poor_presentation",
		"icon_id": "defect_poor_plating",
	},
}

const COOKING_STATIONS: Array[String] = [
	"stove",
	"multi_stove",
	"oven",
	"pizza_oven",
]
const PREPARATION_STATIONS: Array[String] = [
	"prep",
	"prep_counter",
	"cutting_board",
	"dough",
]

var configuration_errors: Array[String] = []

var _rng := RandomNumberGenerator.new()
var _config: Dictionary = {}


func _init(seed_value: int = -1, config_overrides: Dictionary = {}) -> void:
	_config = DEFAULT_CONFIG.duplicate(true)
	if Engine.get_main_loop() != null:
		_config = _deep_merge(_config, DataRegistry.balance_section("dish_quality"))
	_config = _deep_merge(_config, config_overrides)
	configuration_errors = _validate_configuration(_config)
	set_seed(seed_value)


func set_seed(seed_value: int) -> void:
	if seed_value < 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value


func configuration() -> Dictionary:
	return _config.duplicate(true)


func quality_tier(score: float) -> String:
	var normalized := clampf(score, 0.0, 100.0)
	var thresholds: Array = _config.get("tier_thresholds", [55, 70, 85])
	if normalized < float(thresholds[0]):
		return "poor"
	if normalized < float(thresholds[1]):
		return "normal"
	if normalized < float(thresholds[2]):
		return "good"
	return "excellent"


func resolve(context: Dictionary) -> Dictionary:
	var components := component_scores(context)
	var weighted_score := _weighted_score(components)
	var variance := maxf(float(_config.get("random_variance", 3.0)), 0.0)
	var random_delta := _rng.randf_range(-variance, variance) if variance > 0.0 else 0.0
	var score_before_defect := clampf(weighted_score + random_delta, 0.0, 100.0)
	var probability := defect_probability(context)
	var defect_id := ""
	var forced := String(context.get("force_defect", ""))
	var candidates := contextual_defects(String(context.get("station", context.get("station_id", ""))), context)
	if not forced.is_empty() and candidates.has(forced):
		defect_id = forced
	elif bool(context.get("allow_defect_roll", true)) and _rng.randf() < probability:
		defect_id = _pick_defect(candidates, context)

	var events: Array[Dictionary] = []
	var outcome := {
		"action": "serve",
		"serveable": true,
		"requires_remake": false,
		"requires_change_order": false,
	}
	var score := score_before_defect
	var defect_severity := ""
	if not defect_id.is_empty():
		var event := _defect_event(defect_id, context)
		events.append(event)
		score = clampf(score - float(event.get("quality_penalty", 0.0)), 0.0, 100.0)
		defect_severity = String(event.get("severity", "mild"))
		outcome = recovery_outcome(event, context)

	return {
		"quality_score": int(round(score)),
		"quality_tier": quality_tier(score),
		"quality_events": events,
		"defect": defect_id,
		"defect_severity": defect_severity,
		"defect_probability": probability,
		"components": components,
		"weighted_score": weighted_score,
		"random_delta": random_delta,
		"score_before_defect": score_before_defect,
		"recovery": outcome,
		"requires_remake": bool(outcome.requires_remake),
		"requires_change_order": bool(outcome.requires_change_order),
		"serveable": bool(outcome.serveable),
	}


func apply_to_order(order: Dictionary, context: Dictionary) -> Dictionary:
	var result := resolve(context)
	order["quality_score"] = int(result.quality_score)
	order["quality_tier"] = String(result.quality_tier)
	order["quality_events"] = (result.quality_events as Array).duplicate(true)
	order["defect"] = String(result.defect)
	order["defect_severity"] = String(result.defect_severity)
	order["quality_components"] = (result.components as Dictionary).duplicate(true)
	order["quality_recovery"] = (result.recovery as Dictionary).duplicate(true)
	return result


func accumulate_order_quality(
	order: Dictionary,
	sample: Dictionary,
	weight: float = 1.0
) -> Dictionary:
	var normalized_weight := maxf(weight, 0.001)
	var previous_weight := maxf(float(order.get("_quality_weight", 0.0)), 0.0)
	var previous_score := clampf(float(order.get("quality_score", 0.0)), 0.0, 100.0)
	var sample_score := clampf(float(sample.get("quality_score", 0.0)), 0.0, 100.0)
	var total_weight := previous_weight + normalized_weight
	var aggregate := (
		(previous_score * previous_weight + sample_score * normalized_weight)
		/ maxf(total_weight, 0.001)
	)
	order["_quality_weight"] = total_weight
	order["quality_score"] = int(round(aggregate))
	order["quality_tier"] = quality_tier(aggregate)
	var events: Array = order.get("quality_events", [])
	for value: Variant in sample.get("quality_events", []):
		if value is Dictionary:
			events.append((value as Dictionary).duplicate(true))
	order["quality_events"] = events
	if String(order.get("defect", "")).is_empty() and not String(sample.get("defect", "")).is_empty():
		order["defect"] = String(sample.defect)
		order["defect_severity"] = String(sample.get("defect_severity", ""))
	return order


func component_scores(context: Dictionary) -> Dictionary:
	var ingredient_score := _ingredient_score(context)
	var skill := _normalize_unit_score(context.get("employee_skill", context.get("skill", 0.65)), 65.0)
	var precision := _normalize_unit_score(context.get("employee_precision", context.get("precision", 0.80)), 80.0)
	var stress := _normalize_unit_score(context.get("stress", 0.10), 10.0)
	var cleanliness := _normalize_unit_score(context.get("cleanliness", 90.0), 90.0)
	var station_condition := _normalize_unit_score(context.get("station_condition", 100.0), 100.0)
	return {
		"ingredients": ingredient_score,
		"skill": skill,
		"precision": precision,
		"stress_resilience": 100.0 - stress,
		"cleanliness": cleanliness,
		"station_condition": station_condition,
	}


func defect_probability(context: Dictionary) -> float:
	var base := maxf(float(_config.get("extreme_event_base_chance", 0.002)), 0.0)
	var cap := clampf(float(_config.get("extreme_event_cap", 0.12)), 0.0, 1.0)
	var risk: Dictionary = _config.get("risk", {})
	var skill := _normalize_unit_score(context.get("employee_skill", context.get("skill", 0.65)), 65.0) / 100.0
	var precision := _normalize_unit_score(context.get("employee_precision", context.get("precision", 0.80)), 80.0) / 100.0
	var competence := minf(skill, precision)
	var inexperience_threshold := clampf(float(risk.get("inexperience_threshold", 0.60)), 0.01, 1.0)
	var inexperience := clampf((inexperience_threshold - competence) / inexperience_threshold, 0.0, 1.0)
	var stress := _normalize_unit_score(context.get("stress", 0.10), 10.0) / 100.0
	var stress_threshold := clampf(float(risk.get("stress_threshold", 0.65)), 0.0, 0.99)
	var stress_risk := clampf((stress - stress_threshold) / maxf(1.0 - stress_threshold, 0.01), 0.0, 1.0)
	var cleanliness := _normalize_unit_score(context.get("cleanliness", 90.0), 90.0)
	var dirty_threshold := clampf(float(risk.get("dirty_threshold", 55.0)), 0.01, 100.0)
	var dirt_risk := clampf((dirty_threshold - cleanliness) / dirty_threshold, 0.0, 1.0)
	var station_condition := _normalize_unit_score(context.get("station_condition", 100.0), 100.0)
	var station_threshold := clampf(float(risk.get("station_threshold", 65.0)), 0.01, 100.0)
	var station_risk := clampf((station_threshold - station_condition) / station_threshold, 0.0, 1.0)
	var probability := base
	probability += inexperience * maxf(float(risk.get("inexperience_addition", 0.035)), 0.0)
	probability += stress_risk * maxf(float(risk.get("stress_addition", 0.045)), 0.0)
	probability += dirt_risk * maxf(float(risk.get("dirty_addition", 0.040)), 0.0)
	probability += station_risk * maxf(float(risk.get("station_addition", 0.030)), 0.0)
	return clampf(probability, 0.0, cap)


func contextual_defects(station: String, context: Dictionary = {}) -> Array[String]:
	if station in COOKING_STATIONS:
		return ["undercooked", "overcooked", "burned"]
	if station in PREPARATION_STATIONS:
		return ["small_portion", "poor_presentation"]
	if station == "pass":
		return ["poor_presentation"]
	if station in ["dessert", "ice_cream_machine"]:
		return ["small_portion", "poor_presentation"]
	var style := String(context.get("task_style", ""))
	if style in ["cook", "fry", "sear", "simmer", "bake", "roast"]:
		return ["undercooked", "overcooked", "burned"]
	if style in ["chop", "slice", "assemble", "plate", "scoop"]:
		return ["small_portion", "poor_presentation"]
	return ["poor_presentation"]


func recovery_outcome(event: Dictionary, context: Dictionary) -> Dictionary:
	var severity := String(event.get("severity", "mild"))
	if severity != "severe":
		return {
			"action": "serve_with_penalty",
			"serveable": true,
			"requires_remake": false,
			"requires_change_order": false,
			"reason": String(event.get("id", "")),
		}
	var remake_attempts := maxi(int(context.get("remake_attempts", 0)), 0)
	var max_remakes := maxi(int(context.get("max_automatic_remakes", _config.get("max_automatic_remakes", 1))), 0)
	var stock_available := bool(context.get("remake_stock_available", false))
	if stock_available and remake_attempts < max_remakes:
		return {
			"action": "remake",
			"serveable": false,
			"requires_remake": true,
			"requires_change_order": false,
			"reason": String(event.get("id", "")),
		}
	return {
		"action": "change_order",
		"serveable": false,
		"requires_remake": false,
		"requires_change_order": true,
		"reason": String(event.get("id", "")),
	}


func _weighted_score(components: Dictionary) -> float:
	var weights: Dictionary = _config.get("weights", {})
	var weighted_total := 0.0
	var weight_total := 0.0
	for component_id: String in [
		"ingredients",
		"skill",
		"precision",
		"stress_resilience",
		"cleanliness",
		"station_condition",
	]:
		var weight := maxf(float(weights.get(component_id, 0.0)), 0.0)
		weighted_total += clampf(float(components.get(component_id, 0.0)), 0.0, 100.0) * weight
		weight_total += weight
	return weighted_total / maxf(weight_total, 0.001)


func _ingredient_score(context: Dictionary) -> float:
	if context.has("ingredient_quality_score"):
		return _normalize_unit_score(context.ingredient_quality_score, 70.0)
	var value: Variant = context.get("ingredient_qualities", context.get("ingredient_quality", 3.0))
	var samples: Array[float] = []
	if value is Dictionary:
		for ingredient_id: Variant in value:
			var entry: Variant = (value as Dictionary)[ingredient_id]
			if entry is Dictionary:
				var quality := float((entry as Dictionary).get("quality", 3.0))
				var quantity := maxi(int((entry as Dictionary).get("quantity", 1)), 1)
				for _index: int in quantity:
					samples.append(_normalize_ingredient_quality(quality))
			else:
				samples.append(_normalize_ingredient_quality(float(entry)))
	elif value is Array:
		for entry: Variant in value:
			samples.append(_normalize_ingredient_quality(float(entry)))
	else:
		samples.append(_normalize_ingredient_quality(float(value)))
	if samples.is_empty():
		return 70.0
	var total := 0.0
	for sample: float in samples:
		total += sample
	return clampf(total / float(samples.size()), 0.0, 100.0)


func _normalize_ingredient_quality(value: float) -> float:
	if value <= 5.0:
		return clampf(45.0 + value * 10.0, 0.0, 100.0)
	return clampf(value, 0.0, 100.0)


func _normalize_unit_score(value: Variant, fallback: float) -> float:
	if value == null:
		return fallback
	var number := float(value)
	if number >= 0.0 and number <= 1.0:
		return number * 100.0
	return clampf(number, 0.0, 100.0)


func _pick_defect(candidates: Array[String], context: Dictionary) -> String:
	if candidates.is_empty():
		return ""
	var weights: Dictionary = {}
	for candidate: String in candidates:
		weights[candidate] = 1.0
	var stress := _normalize_unit_score(context.get("stress", 0.10), 10.0) / 100.0
	var skill := _normalize_unit_score(context.get("employee_skill", context.get("skill", 0.65)), 65.0) / 100.0
	var precision := _normalize_unit_score(context.get("employee_precision", context.get("precision", 0.80)), 80.0) / 100.0
	if weights.has("burned"):
		weights["burned"] = 0.6 + stress * 1.6
	if weights.has("overcooked"):
		weights["overcooked"] = 1.0 + stress
	if weights.has("undercooked"):
		weights["undercooked"] = 0.8 + (1.0 - skill) * 1.4
	if weights.has("small_portion"):
		weights["small_portion"] = 0.8 + (1.0 - precision) * 1.4
	if weights.has("poor_presentation"):
		weights["poor_presentation"] = 0.8 + stress + (1.0 - precision)
	var total := 0.0
	for candidate: String in candidates:
		total += maxf(float(weights[candidate]), 0.001)
	var roll := _rng.randf_range(0.0, total)
	var accumulated := 0.0
	for candidate: String in candidates:
		accumulated += maxf(float(weights[candidate]), 0.001)
		if roll <= accumulated:
			return candidate
	return candidates[-1]


func _defect_event(defect_id: String, context: Dictionary) -> Dictionary:
	var definition: Dictionary = DEFECTS.get(defect_id, {})
	return {
		"id": defect_id,
		"severity": String(definition.get("severity", "mild")),
		"quality_penalty": float(definition.get("quality_penalty", 0.0)),
		"review_tag": String(definition.get("review_tag", defect_id)),
		"icon_id": String(definition.get("icon_id", "")),
		"station": String(context.get("station", context.get("station_id", ""))),
		"employee_id": String(context.get("employee_id", "")),
		"visible": true,
	}


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
	var thresholds: Variant = config.get("tier_thresholds", [])
	if not thresholds is Array or (thresholds as Array).size() != 3:
		errors.append("dish_quality.tier_thresholds must contain three values")
	else:
		var previous := 0.0
		for value: Variant in thresholds:
			var threshold := float(value)
			if threshold <= previous or threshold > 100.0:
				errors.append("dish_quality.tier_thresholds must be strictly ascending")
				break
			previous = threshold
	var base_chance := float(config.get("extreme_event_base_chance", -1.0))
	var cap := float(config.get("extreme_event_cap", -1.0))
	if base_chance < 0.0 or base_chance >= 0.01:
		errors.append("normal extreme event chance must be below 1 percent")
	if cap < base_chance or cap > 1.0:
		errors.append("dish_quality.extreme_event_cap must be between base chance and 1")
	var weights: Variant = config.get("weights", {})
	if not weights is Dictionary:
		errors.append("dish_quality.weights must be an object")
	else:
		var total := 0.0
		for component_id: String in [
			"ingredients",
			"skill",
			"precision",
			"stress_resilience",
			"cleanliness",
			"station_condition",
		]:
			var weight := float((weights as Dictionary).get(component_id, 0.0))
			if weight < 0.0:
				errors.append("dish quality weights cannot be negative")
				break
			total += weight
		if total <= 0.0:
			errors.append("dish quality weights must have a positive total")
	return errors
