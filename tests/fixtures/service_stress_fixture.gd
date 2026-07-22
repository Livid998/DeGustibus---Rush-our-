class_name ServiceStressFixture
extends RefCounted


static func apply() -> void:
	# Crowd/traffic tests intentionally exercise a larger restaurant than the
	# player-facing starter. Keeping that setup local prevents future balance
	# changes from silently weakening the adversarial scenario.
	GameState.employees = DataRegistry.employee_data.get("hired", []).duplicate(true)
	GameState.layout = GameState.layout.filter(
		func(record: Dictionary) -> bool:
			var item_id := String(record.get("item", ""))
			return item_id != "chair" and not item_id.begins_with("table")
	)
	_append_four_seat_table("table_1", Vector2i(3, 3))
	_append_four_seat_table("table_2", Vector2i(11, 3))
	_append_if_missing({"uid":"plant_1", "item":"plant", "cell":[15,3], "rotation":0})
	_append_if_missing({"uid":"stove_1", "item":"stove", "cell":[9,12], "rotation":2})
	_append_if_missing({"uid":"hood_stove_1", "item":"extractor_hood", "cell":[9,12], "rotation":2, "support_uid":"stove_1", "attachment_slot":0})
	_append_if_missing({"uid":"support_oven_1", "item":"worktable", "cell":[12,12], "rotation":2})
	_append_if_missing({"uid":"oven_1", "item":"oven", "cell":[12,12], "rotation":2, "support_uid":"support_oven_1", "attachment_slot":0})
	_append_if_missing({"uid":"multi_1", "item":"multi_stove", "cell":[16,12], "rotation":2})
	_append_if_missing({"uid":"hood_multi_1", "item":"extractor_hood", "cell":[16,12], "rotation":2, "support_uid":"multi_1", "attachment_slot":0})
	_append_if_missing({"uid":"support_dessert_1", "item":"worktable", "cell":[1,12], "rotation":2})
	_append_if_missing({"uid":"dessert_1", "item":"dessert", "cell":[1,12], "rotation":2, "support_uid":"support_dessert_1", "attachment_slot":0})


static func _append_four_seat_table(uid: String, cell: Vector2i) -> void:
	GameState.layout.append({"uid":uid, "item":"table_medium", "cell":[cell.x, cell.y], "rotation":0})
	for slot: int in 4:
		GameState.layout.append({
			"uid":"%s_chair_%d" % [uid, slot],
			"item":"chair",
			"cell":[cell.x, cell.y],
			"rotation":[0, 3, 2, 1][slot],
			"support_uid":uid,
			"attachment_slot":slot,
		})


static func _append_if_missing(record: Dictionary) -> void:
	var uid := String(record.get("uid", ""))
	if GameState.layout.any(func(candidate: Dictionary): return String(candidate.get("uid", "")) == uid):
		return
	GameState.layout.append(record)
