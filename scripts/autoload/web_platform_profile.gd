extends Node

## Profilo conservativo per i browser mobili, in particolare WebKit su iPad.
## Riduce i render target e il carico continuo senza cambiare la build nativa.

var mobile_browser := false
var safe_mode := false
var _quality_ceiling := 1.0
var _sample_time := 0.0
var _sample_frames := 0
var _slow_samples := 0
var _fast_samples := 0


func _ready() -> void:
	if not OS.has_feature("web"):
		return
	mobile_browser = _query_browser_flag("window.degustibusMobileProfile === true")
	safe_mode = _query_browser_flag("window.degustibusSafeMode === true")
	var viewport := get_tree().root
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.use_debanding = false
	if mobile_browser or safe_mode:
		_quality_ceiling = 0.55 if safe_mode else 0.68
		viewport.scaling_3d_scale = _quality_ceiling
		Engine.max_fps = 24 if safe_mode else 30
	else:
		_quality_ceiling = 0.85
		viewport.scaling_3d_scale = _quality_ceiling
		Engine.max_fps = 60


func _process(delta: float) -> void:
	if not OS.has_feature("web") or delta > 0.25:
		return
	_sample_time += delta
	_sample_frames += 1
	if _sample_time < 3.0:
		return
	var measured_fps := float(_sample_frames) / maxf(_sample_time, 0.001)
	_sample_time = 0.0
	_sample_frames = 0
	var target := 24.0 if safe_mode else 30.0 if mobile_browser else 60.0
	if measured_fps < target * 0.72:
		_slow_samples += 1
		_fast_samples = 0
	elif measured_fps > target * 0.93:
		_fast_samples += 1
		_slow_samples = 0
	else:
		_slow_samples = 0
		_fast_samples = 0
	var viewport := get_tree().root
	var minimum_scale := 0.48 if safe_mode else 0.55 if mobile_browser else 0.62
	if _slow_samples >= 2 and viewport.scaling_3d_scale > minimum_scale:
		viewport.scaling_3d_scale = maxf(viewport.scaling_3d_scale - 0.08, minimum_scale)
		_slow_samples = 0
	elif _fast_samples >= 5 and viewport.scaling_3d_scale < _quality_ceiling:
		viewport.scaling_3d_scale = minf(viewport.scaling_3d_scale + 0.04, _quality_ceiling)
		_fast_samples = 0


func low_memory_mode() -> bool:
	return OS.has_feature("web") and (mobile_browser or safe_mode)


func _query_browser_flag(expression: String) -> bool:
	if not Engine.has_singleton("JavaScriptBridge"):
		return false
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	var result: Variant = bridge.call("eval", expression, true)
	return bool(result)
