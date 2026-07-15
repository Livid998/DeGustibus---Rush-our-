extends Node


func is_available() -> bool:
	return OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge")


func check_for_updates() -> String:
	if not is_available():
		return "Aggiornamenti PWA disponibili solo nella versione Web"
	var bridge := Engine.get_singleton("JavaScriptBridge")
	var result: Variant = bridge.call(
		"eval",
		"window.degustibusPWA ? window.degustibusPWA.checkForUpdates(true) : 'Sistema aggiornamenti non ancora pronto'",
		true
	)
	return String(result) if result != null else "Controllo aggiornamenti avviato"
