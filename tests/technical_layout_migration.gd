extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	SaveManager.writes_enabled = false
	var original_state := GameState.serialize().duplicate(true)
	_test_v10_technical_kitchen_migration()
	_test_v11_default_layout()
	GameState.deserialize(original_state)

	var result := "TECHNICAL LAYOUT MIGRATION: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open(
		"res://tests/technical-layout-migration-result.txt",
		FileAccess.WRITE
	)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_v10_technical_kitchen_migration() -> void:
	var payload := GameState.serialize().duplicate(true)
	payload.save_version = 10
	payload.money = 4321
	payload.layout = [
		{"uid":"legacy_stove","item":"stove","cell":[2,9],"rotation":1},
		{"uid":"legacy_multi","item":"multi_stove","cell":[5,9],"rotation":3},
		{"uid":"oven_support","item":"worktable","cell":[8,9],"rotation":0},
		{"uid":"legacy_oven","item":"oven","cell":[8,9],"rotation":0,"support_uid":"oven_support","attachment_slot":0},
		{"uid":"legacy_dessert","item":"dessert","cell":[11,9],"rotation":2},
		{"uid":"already_ventilated","item":"stove","cell":[14,9],"rotation":0},
		{"uid":"existing_hood","item":"extractor_hood","cell":[14,9],"rotation":0,"support_uid":"already_ventilated","attachment_slot":0},
	]

	GameState.deserialize(payload)
	_expect(GameState.money == 4321, "la migrazione tecnica non addebita denaro")
	_expect(_record("legacy_stove").get("item") == "stove", "preserva UID e record del fornello singolo")
	_expect(_record("legacy_multi").get("item") == "multi_stove", "preserva UID e record del fornello multiplo")
	_expect(_record("legacy_dessert").get("item") == "dessert", "preserva UID della gelatiera")

	var dessert := _record("legacy_dessert")
	var dessert_support_uid := String(dessert.get("support_uid", ""))
	var dessert_support := _record(dessert_support_uid)
	_expect(not dessert_support_uid.is_empty(), "la gelatiera legacy riceve un support_uid")
	_expect(
		String(dessert_support.get("item", "")) == "worktable",
		"la gelatiera legacy riceve gratuitamente un banco da lavoro"
	)
	_expect(
		dessert.get("cell", []) == dessert_support.get("cell", [])
		and int(dessert.get("rotation", -1)) == int(dessert_support.get("rotation", -2)),
		"gelatiera e banco migrati restano perfettamente allineati"
	)
	_expect(
		dessert.get("cell", []) == [11, 9],
		"la migrazione conserva la posizione quando la cella legacy e libera"
	)
	_expect(
		not dessert.has("model_scale")
		and not DataRegistry.build_by_id.dessert.has("model_scale")
		and String(DataRegistry.build_by_id.dessert.get("model", "")) == "res://assets/equipment/icecream_machine.gltf",
		"la gelatiera mantiene asset, scala e dimensioni visuali correnti"
	)

	var stove_hoods := _hoods_for("legacy_stove")
	var multi_hoods := _hoods_for("legacy_multi")
	_expect(stove_hoods.size() == 1, "il fornello legacy riceve esattamente una cappa gratuita")
	_expect(multi_hoods.size() == 1, "la cucina multipla legacy riceve esattamente una cappa gratuita")
	_expect(_hoods_for("already_ventilated").size() == 1, "una cappa esistente non viene duplicata")
	_expect(_hoods_for("legacy_oven").is_empty(), "il forno chiuso non richiede una cappa")
	_expect(_hoods_for("legacy_dessert").is_empty(), "la gelatiera non richiede una cappa")
	_expect(
		String(stove_hoods[0].get("uid", "")).begins_with("v11_hood_legacy_stove"),
		"la nuova UID cappa e deterministica e leggibile"
	)

	var first_layout := GameState.layout.duplicate(true)
	var migrated_payload := GameState.serialize().duplicate(true)
	GameState.deserialize(migrated_payload)
	_expect(GameState.layout == first_layout, "caricare nuovamente un save gia migrato non duplica supporti o cappe")

	GameState.deserialize(payload)
	_expect(GameState.layout == first_layout, "la stessa migrazione v10 produce sempre lo stesso layout")
	_expect(int(GameState.serialize().save_version) == 12, "il salvataggio migrato viene serializzato come v12")


func _test_v11_default_layout() -> void:
	GameState.reset_to_defaults(false)
	var dessert := _record("dessert_1")
	_expect(
		String(dessert.get("support_uid", "")) == "support_dessert_1"
		and String(_record("support_dessert_1").get("item", "")) == "worktable",
		"il layout nuovo nasce con la gelatiera gia appoggiata sul banco"
	)
	_expect(
		_hoods_for("stove_1").size() == 1 and _hoods_for("multi_1").size() == 1,
		"il layout nuovo nasce con entrambi i fornelli ventilati"
	)


func _record(uid: String) -> Dictionary:
	for record: Dictionary in GameState.layout:
		if String(record.get("uid", "")) == uid:
			return record
	return {}


func _hoods_for(support_uid: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in GameState.layout:
		if String(record.get("support_uid", "")) != support_uid:
			continue
		var definition: Dictionary = DataRegistry.build_by_id.get(
			String(record.get("item", "")),
			{}
		)
		if String(definition.get("placement", "")) == "overhead":
			result.append(record)
	return result


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
