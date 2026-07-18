class_name StaffPreferences
extends RefCounted

## One normalized source of truth for the role-specific preferences stored in
## GameState.  Older saves used either employee.preferred_station or a single
## string in staff_preferences; both remain readable and are upgraded the next
## time the player changes the selector.

const ROLE_COOK := "cook"
const ROLE_WAITER := "waiter"
const ROLE_HANDYMAN := "handyman"

const WAITER_ZONES: Array[String] = ["automatic", "dining", "pass", "entrance"]
const HANDYMAN_PRIORITIES: Array[String] = [
	"automatic",
	"dining",
	"kitchen",
	"dishes",
	"emergency",
]


static func for_employee(employee: Dictionary) -> Dictionary:
	return for_employee_id(
		String(employee.get("id", "")),
		String(employee.get("role", ROLE_COOK)),
		employee
	)


static func for_employee_id(
	employee_id: String,
	role: String,
	employee_fallback: Dictionary = {}
) -> Dictionary:
	var normalized_role := _normalized_role(role)
	var result := _default_for_role(normalized_role)
	var raw: Variant = GameState.staff_preferences.get(employee_id, null)
	if raw is Dictionary:
		result.merge(raw as Dictionary, true)
	elif raw is String:
		_merge_legacy_string(result, normalized_role, String(raw))
	elif normalized_role == ROLE_COOK:
		var old_station := String(employee_fallback.get("preferred_station", ""))
		if not old_station.is_empty():
			result.station = old_station
	result.role = normalized_role
	return normalize(normalized_role, result)


static func normalize(role: String, value: Dictionary) -> Dictionary:
	var normalized_role := _normalized_role(role)
	var result := _default_for_role(normalized_role)
	result.merge(value, true)
	result.role = normalized_role
	match normalized_role:
		ROLE_COOK:
			var station := String(result.get("station", "")).strip_edges()
			result.station = station if station != "automatic" else ""
		ROLE_WAITER:
			var zone := String(result.get("standby_zone", "automatic")).strip_edges().to_lower()
			result.standby_zone = zone if zone in WAITER_ZONES else "automatic"
		ROLE_HANDYMAN:
			var priority := String(result.get("priority", "automatic")).strip_edges().to_lower()
			result.priority = priority if priority in HANDYMAN_PRIORITIES else "automatic"
	return result


static func save(employee_id: String, role: String, value: Dictionary) -> bool:
	return GameState.set_staff_preference(employee_id, normalize(role, value))


static func cook_station(employee: Dictionary) -> String:
	return String(for_employee(employee).get("station", ""))


static func waiter_standby_zone(employee: Dictionary) -> String:
	return String(for_employee(employee).get("standby_zone", "automatic"))


static func handyman_priority(employee: Dictionary) -> String:
	return String(for_employee(employee).get("priority", "automatic"))


static func cook_station_bonus(employee: Dictionary, station_id: String) -> float:
	var preferred := cook_station(employee)
	return 30.0 if not preferred.is_empty() and preferred == station_id else 0.0


static func waiter_task_bonus(
	employee: Dictionary,
	action: String,
	target: Vector3,
	world: Node
) -> float:
	var zone := waiter_standby_zone(employee)
	if zone == "automatic":
		return 0.0
	match zone:
		"pass":
			return 28.0 if action == "serve" else 0.0
		"entrance":
			return 18.0 if action in ["take_order", "payment"] else 0.0
		"dining":
			if action in ["take_order", "payment", "collect_dishes"]:
				return 24.0
			if world != null and world.has_method("world_to_cell"):
				var cell: Vector2i = world.call("world_to_cell", target)
				return 12.0 if cell.y < 8 else 0.0
	return 0.0


static func handyman_task_bonus(
	employee: Dictionary,
	action: String,
	target: Vector3,
	world: Node,
	payload: Dictionary = {}
) -> float:
	var priority := handyman_priority(employee)
	if priority == "automatic":
		return 0.0
	var category := maintenance_category(action, target, world, payload)
	return 38.0 if category == priority else 0.0


static func maintenance_category(
	action: String,
	target: Vector3,
	world: Node,
	payload: Dictionary = {}
) -> String:
	var explicit := String(payload.get("maintenance_category", "")).strip_edges().to_lower()
	if explicit in ["dining", "kitchen", "dishes", "emergency"]:
		return explicit
	var normalized := action.to_lower()
	var incident := String(payload.get("incident_kind", payload.get("pest_type", ""))).to_lower()
	if (
		"pest" in normalized
		or "insect" in normalized
		or "mouse" in normalized
		or "infestation" in normalized
		or incident in ["pest", "insect", "mouse"]
	):
		return "emergency"
	if normalized in ["wash_dishes", "collect_dishes", "bus_tables"]:
		return "dishes"
	if world != null and world.has_method("world_to_cell"):
		var cell: Vector2i = world.call("world_to_cell", target)
		return "dining" if cell.y < 8 else "kitchen"
	return "kitchen" if normalized in ["clean_kitchen", "clean_floor"] else "dining"


static func _default_for_role(role: String) -> Dictionary:
	match role:
		ROLE_WAITER:
			return {"role": ROLE_WAITER, "standby_zone": "automatic"}
		ROLE_HANDYMAN:
			return {"role": ROLE_HANDYMAN, "priority": "automatic"}
		_:
			return {"role": ROLE_COOK, "station": ""}


static func _merge_legacy_string(result: Dictionary, role: String, value: String) -> void:
	var normalized := value.strip_edges().to_lower()
	match role:
		ROLE_COOK:
			result.station = "" if normalized in ["", "automatic", "auto"] else normalized
		ROLE_WAITER:
			var aliases := {
				"auto": "automatic",
				"sala": "dining",
				"ingresso": "entrance",
				"entrance": "entrance",
				"pass": "pass",
			}
			result.standby_zone = String(aliases.get(normalized, normalized))
		ROLE_HANDYMAN:
			var aliases := {
				"auto": "automatic",
				"sala": "dining",
				"cucina": "kitchen",
				"stoviglie": "dishes",
				"piatti": "dishes",
				"parassiti": "emergency",
				"infestazioni": "emergency",
			}
			result.priority = String(aliases.get(normalized, normalized))


static func _normalized_role(role: String) -> String:
	return role if role in [ROLE_COOK, ROLE_WAITER, ROLE_HANDYMAN] else ROLE_COOK
