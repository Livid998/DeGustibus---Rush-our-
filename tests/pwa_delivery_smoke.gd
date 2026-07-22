extends Node

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	var export_config := FileAccess.get_file_as_string("res://export_presets.cfg")
	var shell := FileAccess.get_file_as_string("res://web/pwa_shell.html")
	var project := FileAccess.get_file_as_string("res://project.godot")
	var build_script := FileAccess.get_file_as_string("res://BUILD_PWA.ps1")
	var workflow := FileAccess.get_file_as_string("res://.github/workflows/deploy-pwa.yml")
	var documentation := FileAccess.get_file_as_string("res://PWA.md")
	var matrix := FileAccess.get_file_as_string("res://tools/release/test_matrix.txt")
	var matrix_runner := FileAccess.get_file_as_string("res://tools/release/run_godot_matrix.py")
	var preparer := FileAccess.get_file_as_string("res://tools/release/prepare_pwa_artifact.py")
	var verifier := FileAccess.get_file_as_string("res://tools/release/verify_pwa_artifact.py")
	var browser_smoke := FileAccess.get_file_as_string("res://tools/release/browser_smoke.py")
	var release_tools_smoke := FileAccess.get_file_as_string("res://tools/release/release_tools_smoke.py")
	var main_script := FileAccess.get_file_as_string("res://scripts/main.gd")
	var icon_texture := load("res://web/pwa_icon_192.png") as Texture2D
	var icon := icon_texture.get_image() if icon_texture != null else Image.new()

	_expect(
		"progressive_web_app/enabled=true" in export_config
			and 'html/custom_html_shell="res://web/pwa_shell.html"' in export_config
			and "progressive_web_app/orientation=0" in export_config
			and "variant/thread_support=false" in export_config
			and "vram_texture_compression/for_mobile=true" in export_config,
		"export PWA no-thread, mobile e orientation-agnostic"
	)
	_expect(
		'window/stretch/mode="disabled"' in project
			and "window/dpi/allow_hidpi.web=false" in project
			and 'OS.has_feature("web")' in main_script,
		"UI Web in pixel CSS e qualità 3D adattiva restano separate"
	)
	_expect(
		"viewport-fit=cover" in shell
			and "env(safe-area-inset-top)" in shell
			and "env(safe-area-inset-bottom)" in shell
			and "prefers-reduced-motion: reduce" in shell,
		"shell PWA gestisce safe area e riduzione movimento"
	)
	_expect(
		"current.update()" in shell
			and "controllerchange" in shell
			and "current.waiting.postMessage('update')" in shell
			and "engine.installServiceWorker().catch" in shell,
		"update interno conserva il worker controllato esistente"
	)
	_expect(
		"webglcontextlost" in shell and "degustibus-webgl-safe" in shell,
		"la perdita WebGL ha recovery sicuro una sola volta"
	)
	_expect(
		not icon.is_empty() and icon.get_width() == 192 and icon.get_height() == 192
			and icon.get_pixel(0, 0).a < 0.05 and icon.get_pixel(96, 96).a > 0.95,
		"icona installazione 192x192 trasparente e valida"
	)

	for group: String in ["[core]", "[m0]", "[m1]", "[m2]", "[m3]", "[release]", "[soak]"]:
		_expect(group in matrix, "matrice release contiene il gruppo %s" % group)
	for scene: String in [
		"m0_integrity_soak.tscn",
		"m1_runtime_infrastructure_smoke.tscn",
		"m1_staff_lease_smoke.tscn",
		"m2_starter_loop_smoke.tscn",
		"m2_first_loop_pacing_smoke.tscn",
		"builder_transaction_smoke.tscn",
		"m3_visual_contract_smoke.tscn",
		"m3_accessibility_quality_smoke.tscn",
		"audio_bus_smoke.tscn",
		"release_fresh_run_matrix.tscn",
		"release_runtime_soak.tscn",
		"agent_stress.tscn",
	]:
		_expect(scene in matrix, "matrice autorevole include %s" % scene)
	_expect(
		"subprocess.run" in matrix_runner and "timeout=args.timeout" in matrix_runner
			and "matrix-summary.tsv" in matrix_runner,
		"runner matrice applica timeout e conserva evidence per scena"
	)

	_expect(
		"--require-clean" in build_script
			and "run_godot_matrix.py" in build_script
			and "--isolate-test-results" in build_script
			and "release_tools_smoke.py" in build_script
			and "prepare_pwa_artifact.py" in build_script
			and "verify_pwa_artifact.py" in build_script
			and "'65'" in build_script and "'42'" in build_script and "'25'" in build_script,
		"build locale usa gli stessi gate pulizia, matrice e budget della CI"
	)
	_expect(
		'"commit"' in preparer and '"godot_version"' in preparer
			and '"built_at_utc"' in preparer and '"release"' in preparer
			and '"dirty"' in preparer and "--require-clean" in preparer,
		"build-info possiede commit, Godot, timestamp, release e prova clean"
	)
	_expect(
		"default=65.0" in verifier and "default=42.0" in verifier and "default=25.0" in verifier
			and "Hard release budget exceeded" in verifier
			and "--require-publishable" in verifier,
		"verificatore applica budget hard e dirty:false"
	)
	_expect(
		"chromium" in browser_smoke and "webkit" in browser_smoke
			and "BENIGN_CONSOLE_ERROR_RULES" in browser_smoke
			and "significant_browser_errors" in browser_smoke
			and "page_errors" in browser_smoke
			and "build-info.json" in browser_smoke
			and "fatal =" not in browser_smoke,
		"browser smoke blocca ogni pageerror/console error salvo favicon esplicitamente benigno"
	)
	_expect(
		"TestResultIsolation" in release_tools_smoke
			and "test mutated tracked non-result file" in release_tools_smoke
			and "ReferenceError: broken" in release_tools_smoke,
		"smoke Python prova ripristino result e policy errori browser"
	)

	for job_marker: String in ["verify:", "export:", "reuse:", "browser-smoke:", "deploy:"]:
		_expect(job_marker in workflow, "workflow separa il job %s" % job_marker.trim_suffix(":"))
	_expect(
		"pwa-release-ready" in workflow
			and "actions/upload-artifact@v4" in workflow
			and "actions/download-artifact@v4" in workflow
			and "retention-days: 90" in workflow
			and "run-id: ${{ inputs.rollback_run_id }}" in workflow,
		"artifact verificato è riusato e conservato per rollback"
	)
	_expect(
		"Soak breve e 10 fresh-run fino al giorno 3" in workflow
			and "--groups core,m0,m1,m2,m3,release" in workflow
			and "--groups soak" in workflow
			and workflow.count("--isolate-test-results") == 2
			and "release_tools_smoke.py" in workflow,
		"CI esegue matrice milestone, soak e dieci fresh-run"
	)
	_expect(
		"git diff --exit-code" in workflow
			and "--require-clean" in workflow
			and "--require-publishable" in workflow
			and "--max-total-mib 65" in workflow
			and "--max-wasm-mib 42" in workflow
			and "--max-pck-mib 25" in workflow,
		"export CI è clean e fail-fast sui budget"
	)
	_expect(
		"playwright==1.59.0" in workflow
			and "install --with-deps chromium webkit" in workflow
			and "browser_smoke.py" in workflow,
		"Chromium/WebKit sono pinned e riproducibili"
	)
	_expect(
		"inputs.publish" in workflow and "inputs.ipad_evidence != ''" in workflow
			and "github.event_name == 'push'" in workflow
			and "inputs.channel == 'test'" in workflow
			and "inputs.channel == 'beta'" in workflow
			and "upload-pages-artifact@v4" in workflow
			and workflow.count("include-hidden-files: true") >= 2,
		"Pages pubblica test da main e mantiene evidence iPad per la beta"
	)
	_expect(
		"Aggiungi alla schermata Home" in documentation
			and "secondo caricamento" in documentation
			and "server spento" in documentation
			and "390x844" in documentation and "800x1024" in documentation
			and "60 minuti" in documentation and "rollback_run_id" in documentation
			and "frame rate" in documentation and "diagnostica locale" in documentation
			and "non è automatizzato" in documentation,
		"documentazione copre installazione, offline, responsive, rollback e gate iPad reale"
	)

	var result := "PWA DELIVERY: %s | checks=%d failures=%d\n%s" % [
		"PASS" if failures.is_empty() else "FAIL",
		checks,
		failures.size(),
		"\n".join(failures),
	]
	print(result.strip_edges())
	var file := FileAccess.open("res://tests/pwa-delivery-result.txt", FileAccess.WRITE)
	if file != null:
		file.store_string(result)
		file.close()
	get_tree().quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: %s" % message)
