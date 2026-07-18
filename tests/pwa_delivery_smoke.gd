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
	var main_script := FileAccess.get_file_as_string("res://scripts/main.gd")
	var icon_192_texture := load("res://web/pwa_icon_192.png") as Texture2D
	var icon_192 := icon_192_texture.get_image() if icon_192_texture != null else Image.new()

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
		"assets/ui/ingredient_icons.png" in export_config
		and "assets/ui/recipe_icons.png" in export_config
		and "assets/ui/generated_sources/*" in export_config
		and "assets/ui/generated/casual_system_icons_runtime.png" in export_config,
		"source atlases stay in the repository but are excluded from the runtime pack"
	)
	_expect(
		'window/stretch/mode="disabled"' in project
		and "window/dpi/allow_hidpi.web=false" in project
		and 'OS.has_feature("web")' in main_script,
		"phone UI uses CSS-pixel-native layout while 3D quality remains independently scalable"
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
		"const pwaInstallPromise" in shell
		and "engine.installServiceWorker().catch" in shell
		and "await pwaInstallPromise" in shell
		and "!GODOT_CONFIG.ensureCrossOriginIsolationHeaders" in shell,
		"the iOS-compatible single-thread launch registers its service worker before update checks"
	)
	_expect(
		'aria-hidden="true" inert' in shell
		and "button.tabIndex = actionable ? 0 : -1" in shell
		and "button.focus({ preventScroll: true })" in shell
		and "event.key === 'Escape'" in shell
		and "prefers-reduced-motion: reduce" in shell,
		"the update banner has safe keyboard focus, dismissal and reduced motion"
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
		and "build-info.json" in build_script
		and "cache.addAll(CACHED_FILES)" in build_script
		and "const CACHEABLE_FILES" in build_script
		and "DeGustibus first-install control" in build_script
		and "self.clients.claim()" in build_script
		and "runtime-cache-after-first-controlled-load" in build_script,
		"local PWA export gates UI, cache policy and deterministic first-install control"
	)
	_expect(
		"$dirty = $null" in build_script
		and "source_state = $sourceState" in build_script
		and "CODEX_GIT_EXECUTABLE" in build_script
		and "codex-runtimes" in build_script,
		"local build metadata reports clean/dirty/unknown with portable Git discovery"
	)
	_expect(
		not icon_192.is_empty()
		and icon_192.get_width() == 192
		and icon_192.get_height() == 192
		and icon_192.get_pixel(0, 0).a < 0.05
		and icon_192.get_pixel(96, 96).a > 0.95
		and "index.192x192.png" in workflow,
		"delivery pipeline adds a transparent, valid dedicated 192x192 install icon"
	)
	_expect(
		"cache.addAll(FULL_CACHE)" not in workflow
		and "runtime-cache-after-first-controlled-load" in workflow
		and "index.manifest.json" in workflow
		and "index.512x512.png" in workflow
		and "DeGustibus first-install control" in workflow
		and "self.clients.claim()" in workflow
		and "GITHUB_STEP_SUMMARY" in workflow,
		"CI verifies the manifest, install icons, cache ownership and artifact size"
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
		and "390x844" in documentation
		and "secondo caricamento" in documentation
		and "server spento" in documentation,
		"PWA documentation covers installation, update, offline and responsive targets"
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
