extends Node

## Profilo conservativo per i browser mobili, in particolare WebKit su iPad.
## Riduce i render target e il carico continuo senza cambiare la build nativa.

var mobile_browser := false
var safe_mode := false


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
		viewport.scaling_3d_scale = 0.55 if safe_mode else 0.68
		Engine.max_fps = 24 if safe_mode else 30
	else:
		viewport.scaling_3d_scale = 0.85
		Engine.max_fps = 60


func low_memory_mode() -> bool:
	return OS.has_feature("web") and (mobile_browser or safe_mode)


func _query_browser_flag(expression: String) -> bool:
	if not Engine.has_singleton("JavaScriptBridge"):
		return false
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	var result: Variant = bridge.call("eval", expression, true)
	return bool(result)
