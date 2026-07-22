extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	var previous_writes_enabled := SaveManager.writes_enabled
	var original_state := GameState.serialize().duplicate(true)
	SaveManager.writes_enabled = false
	_test_export_package()
	_test_transactional_import(original_state)
	_test_import_rejections()
	_test_v11_atomic_migration()
	_test_recursive_fixture_rollback()
	_test_explicit_transaction_rollback()
	_test_runtime_diagnostics()
	_test_web_bridge_contract()
	GameState.deserialize(original_state)
	SaveManager.writes_enabled = previous_writes_enabled
	var result := "WEB PERSISTENCE + DIAGNOSTICS: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_export_package() -> void:
	var exported := SaveManager.export_package()
	var parsed: Variant = JSON.parse_string(exported)
	_expect(parsed is Dictionary, "export produces JSON object")
	if not parsed is Dictionary:
		return
	_expect(String(parsed.get("app_id", "")) == SaveManager.PACKAGE_APP_ID, "export identifies the application")
	_expect(int(parsed.get("package_version", 0)) == SaveManager.PACKAGE_VERSION, "export declares package schema")
	_expect(parsed.get("payload") is Dictionary, "export embeds a game-state payload")
	_expect(int(parsed.payload.get("save_version", -1)) == GameState.SAVE_VERSION, "export embeds the current save schema")
	_expect(not String(parsed.get("created_at_utc", "")).is_empty(), "export includes a UTC timestamp")


func _test_transactional_import(original_state: Dictionary) -> void:
	var candidate := original_state.duplicate(true)
	candidate.money = 2468
	candidate.restaurant_profile.restaurant_name = "Import Test"
	var package := {
		"app_id": SaveManager.PACKAGE_APP_ID,
		"package_version": SaveManager.PACKAGE_VERSION,
		"payload": candidate
	}
	var packaged_result := SaveManager.import_package_json(JSON.stringify(package))
	_expect(bool(packaged_result.success), "versioned package imports")
	_expect(GameState.money == 2468 and String(GameState.restaurant_profile.restaurant_name) == "Import Test", "versioned import applies the validated payload")
	var legacy := original_state.duplicate(true)
	legacy.money = 1357
	var legacy_result := SaveManager.import_package_json(JSON.stringify(legacy))
	_expect(bool(legacy_result.success) and bool(legacy_result.legacy), "legacy raw save remains importable")
	_expect(GameState.money == 1357, "legacy import applies game state")


func _test_import_rejections() -> void:
	var money_before := GameState.money
	var malformed := SaveManager.import_package_json("{not json")
	_expect(not bool(malformed.success) and GameState.money == money_before, "malformed JSON is rejected without touching state")
	var foreign := SaveManager.import_package_json(JSON.stringify({
		"app_id": "another-game",
		"package_version": 1,
		"payload": GameState.serialize()
	}))
	_expect(not bool(foreign.success) and GameState.money == money_before, "foreign package is rejected without touching state")
	var malformed_wrapper := SaveManager.import_package_json(JSON.stringify({
		"app_id": SaveManager.PACKAGE_APP_ID,
		"package_version": [1],
		"payload": GameState.serialize()
	}))
	_expect(not bool(malformed_wrapper.success) and GameState.money == money_before, "malformed package metadata is rejected before coercion or state changes")
	var invalid := GameState.serialize().duplicate(true)
	invalid.stock = []
	var invalid_result := SaveManager.import_package_json(JSON.stringify(invalid))
	_expect(not bool(invalid_result.success) and GameState.money == money_before, "invalid section types are rejected transactionally")
	var too_large := SaveManager.import_package_json("x".repeat(SaveManager.MAX_IMPORT_BYTES + 1))
	_expect(not bool(too_large.success) and "5 MiB" in String(too_large.error), "imports are capped at 5 MiB")


func _test_v11_atomic_migration() -> void:
	var fixture_text := FileAccess.get_file_as_string("res://tests/fixtures/save_v11_atomic_fixture.json")
	var result := SaveManager.import_package_json(fixture_text)
	_expect(bool(result.success) and bool(result.legacy), "a v11 raw fixture migrates through the transactional importer")
	var canonical := GameState.serialize()
	_expect(int(canonical.get("save_version", -1)) == 12, "the in-memory migration immediately produces canonical v12")
	_expect(GameState.money == 4321, "v11 migration preserves money")
	_expect(GameState.layout.any(func(record: Dictionary) -> bool:
		var cell: Variant = record.get("cell", [])
		return String(record.get("uid", "")) == "compat_table" and cell is Array and cell.size() == 2 and int(cell[0]) == 6 and int(cell[1]) == 6
	), "v11 migration preserves custom layout records")
	_expect(int(GameState.stock.get("tomato", {}).get("amount", -1)) == 17 and bool(GameState.stock.get("tomato", {}).get("unlocked", false)), "v11 migration preserves stock and ingredient unlocks")
	_expect(bool(GameState.menu.get("margherita", {}).get("active", false)) and bool(GameState.menu.get("margherita", {}).get("unlocked", false)) and int(GameState.menu.get("margherita", {}).get("price", 0)) == 27, "v11 migration preserves menu configuration and recipe unlocks")
	_expect(bool(GameState.album_discovered.get("tomato", false)), "v11 migration preserves Album discovery unlocks")
	var exported: Variant = JSON.parse_string(SaveManager.export_package())
	_expect(exported is Dictionary and int(exported.get("payload", {}).get("save_version", -1)) == 12, "an imported v11 save can only be exported as canonical v12")


func _test_recursive_fixture_rollback() -> void:
	var before := GameState.serialize().duplicate(true)
	for fixture_path: String in [
		"res://tests/fixtures/save_malformed_nested_stock.json",
		"res://tests/fixtures/save_malformed_layout.json",
	]:
		var result := SaveManager.import_package_json(FileAccess.get_file_as_string(fixture_path))
		_expect(not bool(result.success), "%s is rejected by recursive structural validation" % fixture_path.get_file())
		_expect(GameState.serialize() == before, "%s leaves the complete runtime snapshot untouched" % fixture_path.get_file())
	var too_deep: Variant = {"leaf": 1}
	for _depth: int in 70:
		too_deep = {"nested": too_deep}
	var deep_payload := {"save_version": 12, "stock": {}, "menu": {}, "progress": too_deep}
	var deep_result := SaveManager.import_package_json(JSON.stringify(deep_payload))
	_expect(not bool(deep_result.success), "excessively deep JSON is rejected before deserialization")
	_expect(GameState.serialize() == before, "depth rejection rolls back without any partial state")


func _test_explicit_transaction_rollback() -> void:
	var before := GameState.serialize().duplicate(true)
	var previous_dirty := SaveManager.dirty
	var previous_remaining := SaveManager._autosave_remaining
	SaveManager.dirty = true
	SaveManager._autosave_remaining = 0.75
	var candidate := before.duplicate(true)
	candidate.money = int(before.get("money", 0)) + 777
	var transaction := SaveManager._apply_payload_transactionally(candidate)
	_expect(bool(transaction.success) and GameState.money == int(candidate.money), "a valid candidate is fully applied before persistence is attempted")
	SaveManager._rollback_runtime_transaction(transaction)
	_expect(GameState.serialize() == before, "transaction rollback restores the complete GameState snapshot")
	_expect(SaveManager.dirty and is_equal_approx(SaveManager._autosave_remaining, 0.75), "transaction rollback restores autosave state as well as gameplay data")
	SaveManager.dirty = previous_dirty
	SaveManager._autosave_remaining = previous_remaining


func _test_runtime_diagnostics() -> void:
	RuntimeDiagnostics.reset()
	RuntimeDiagnostics.record_repath(2)
	RuntimeDiagnostics.record_neighbor_query(4)
	RuntimeDiagnostics.record_lease_conflict()
	RuntimeDiagnostics.record_navigation_timeout()
	RuntimeDiagnostics.set_gauge("active_agents", 17)
	RuntimeDiagnostics.record_event("test_event", {"local": true})
	RuntimeDiagnostics._process(0.016)
	RuntimeDiagnostics._process(0.034)
	var snapshot := RuntimeDiagnostics.snapshot()
	_expect(bool(snapshot.local_only), "diagnostics explicitly declare local-only collection")
	_expect(int(snapshot.counters.repaths) == 2 and int(snapshot.counters.neighbor_queries) == 4, "navigation counters are exportable")
	_expect(int(snapshot.counters.lease_conflicts) == 1 and int(snapshot.counters.navigation_timeouts) == 1, "lease and timeout counters are exportable")
	_expect(int(snapshot.gauges.active_agents) == 17, "runtime gauges are exportable")
	_expect(int(snapshot.frame_window.sample_count) == 2 and float(snapshot.frame_window.p95_ms) >= 33.9, "frame-time percentiles use the recorded window")
	var parsed: Variant = JSON.parse_string(RuntimeDiagnostics.export_json())
	_expect(parsed is Dictionary and parsed.get("events") is Array, "diagnostics export valid JSON with a bounded event log")


func _test_web_bridge_contract() -> void:
	var shell := FileAccess.get_file_as_string("res://web/pwa_shell.html")
	var project := FileAccess.get_file_as_string("res://project.godot")
	var save_source := FileAccess.get_file_as_string("res://scripts/autoload/save_manager.gd")
	var diagnostics_source := FileAccess.get_file_as_string("res://scripts/autoload/runtime_diagnostics.gd")
	_expect("navigator.storage.persisted()" in shell and "navigator.storage.persist()" in shell, "PWA requests durable browser storage")
	_expect("pagehide" in shell and "visibility-hidden" in shell, "PWA flushes on page hide and backgrounding")
	_expect("webglcontextlost" in shell and "degustibusRuntime?.emitEvent('webglcontextlost')" in shell, "WebGL context loss reaches local diagnostics")
	_expect("URL.createObjectURL" in shell and "downloadText" in shell, "save and diagnostics JSON can be downloaded locally")
	_expect(
		"_web_persistence_api.call(" not in save_source
			and "_web_runtime_api.call(" not in diagnostics_source
			and ".registerLifecycleCallback(" in save_source
			and ".registerEventCallback(" in diagnostics_source,
		"JavaScriptObject methods are invoked directly instead of routing through a missing JS call() member"
	)
	_expect('RuntimeDiagnostics="*res://scripts/autoload/runtime_diagnostics.gd"' in project, "runtime diagnostics is active in every build")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
