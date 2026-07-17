extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	var export_config := FileAccess.get_file_as_string("res://export_presets.cfg")
	var shell := FileAccess.get_file_as_string("res://web/pwa_shell.html")
	var project := FileAccess.get_file_as_string("res://project.godot")
	var build_script := FileAccess.get_file_as_string("res://BUILD_PWA.ps1")
	var workflow := FileAccess.get_file_as_string(
		"res://.github/workflows/deploy-pwa.yml"
	)
	var documentation := FileAccess.get_file_as_string("res://PWA.md")

	_expect(
		"progressive_web_app/enabled=true" in export_config
		and 'html/custom_html_shell="res://web/pwa_shell.html"' in export_config
		and "progressive_web_app/orientation=0" in export_config,
		"Web export enables an orientation-agnostic PWA with the custom shell"
	)
	_expect(
		"variant/thread_support=false" in export_config
		and "vram_texture_compression/for_mobile=true" in export_config
		and "ensure_cross_origin_isolation_headers=false" in export_config,
		"Web export keeps the iOS-compatible no-threads mobile profile"
	)
	_expect(
		"viewport-fit=cover" in shell
		and "env(safe-area-inset-top)" in shell
		and "env(safe-area-inset-bottom)" in shell,
		"the PWA shell handles phone and tablet safe areas"
	)
	_expect(
		"current.update()" in shell
		and "visibilitychange" in shell
		and "controllerchange" in shell
		and "current.waiting.postMessage('update')" in shell,
		"the installed PWA checks, activates and reloads a waiting update in place"
	)
	_expect(
		"webglcontextlost" in shell
		and "degustibus-webgl-safe" in shell
		and "?safe=1" not in shell,
		"WebGL loss has a one-time safe-mode recovery without changing the install URL"
	)
	_expect(
		'PwaUpdateManager="*res://scripts/autoload/pwa_update_manager.gd"' in project,
		"the in-game manual update bridge is an active autoload"
	)
	_expect(
		"ui_glyph_audit.tscn" in build_script
		and "responsive_ui_smoke.tscn" in build_script
		and "pwa_delivery_smoke.tscn" in build_script
		and "build-info.json" in build_script,
		"local PWA export gates glyphs, responsive UI and delivery configuration"
	)
	for required_scene: String in [
		"restaurant_ambience_smoke.tscn",
		"ambience_runtime_smoke.tscn",
		"staff_role_smoke.tscn",
		"reviews_screen_smoke.tscn",
		"review_quality_smoke.tscn",
		"review_runtime_integration_smoke.tscn",
		"responsive_ui_smoke.tscn",
		"pwa_delivery_smoke.tscn",
	]:
		_expect(
			required_scene in workflow,
			"GitHub Pages CI runs %s before deployment" % required_scene
		)
	_expect(
		"Aggiungi alla schermata Home" in documentation
		and "Aggiorna e riavvia" in documentation
		and "390x844" in documentation,
		"PWA documentation covers installation, update and responsive targets"
	)

	var result := "PWA DELIVERY: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/pwa-delivery-result.txt", FileAccess.WRITE)
	file.store_string(result)
	file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
