class_name AgentTrafficCoordinator
extends RefCounted

## Owns traffic policy and exclusive runtime leases. RestaurantWorld keeps the
## topology/geometric queries, while this coordinator provides one source of
## truth for priority, corridor/holding ownership and bounded stall timing.

const REPATH_SECONDS := 2.0
const RECOVERY_SECONDS := 2.0
const HARD_CANCEL_SECONDS := 8.0

var corridor_owners: Dictionary = {}
var agent_corridors: Dictionary = {}
var holding_by_agent: Dictionary = {}
var door_owner: Node

var _leases: RuntimeLeaseRegistry


func _init(leases: RuntimeLeaseRegistry = null) -> void:
	_leases = leases if leases != null else RuntimeLeaseRegistry.new()


func effective_priority(agent: AnimatedAgent) -> int:
	# Lower numbers win: exits, admission, active work, return and idle.
	if agent is CustomerPersonAgent:
		var guest := agent as CustomerPersonAgent
		var party_state := String(guest.party.get("state")) if guest.party != null else ""
		if guest.target_tag.begins_with("exit_") or party_state in ["standing_to_leave", "waiting_exit_door", "leaving"]:
			return 0
		if guest.target_tag.begins_with("seat_stage") or party_state in ["admitting", "walking_to_table", "seating"]:
			return 1
		if guest.target_tag == "queue":
			return 6
	if agent is EmployeeAgent:
		var employee := agent as EmployeeAgent
		if employee.state in ["moving", "working"] and not employee.active_task.is_empty():
			return 2
		if employee.state == "returning_idle":
			return 5
		if employee.state == "idle":
			return 7
	return agent.navigation_priority


func should_hard_cancel(stalled_seconds: float, _managed_wait: bool) -> bool:
	# A managed wait changes who yields and where they wait; it is not an
	# unlimited navigation lease. Every destination remains bounded so a stale
	# corridor owner or impossible holding route cannot strand an agent forever.
	return stalled_seconds >= HARD_CANCEL_SECONDS


func try_acquire_door(owner: Node) -> bool:
	cleanup_door()
	if owner == null or not is_instance_valid(owner):
		return false
	if door_owner != null and door_owner != owner:
		return false
	if not _leases.try_acquire(&"door:main", owner, -1.0, 0.0, {"kind": "door"}):
		return false
	door_owner = owner
	return true


func release_door(owner: Node) -> void:
	if door_owner != owner:
		return
	if owner != null and is_instance_valid(owner):
		_leases.release(&"door:main", owner)
	door_owner = null


func cleanup_door() -> void:
	if door_owner == null:
		_leases.owner_of(&"door:main")
		return
	if not is_instance_valid(door_owner) or door_owner.is_queued_for_deletion():
		_leases.owner_of(&"door:main")
		door_owner = null


func clear_door() -> void:
	if door_owner != null and is_instance_valid(door_owner):
		_leases.release(&"door:main", door_owner)
	else:
		_leases.owner_of(&"door:main")
	door_owner = null


func try_acquire_corridor(agent: AnimatedAgent, key: String) -> bool:
	if agent == null or key.is_empty():
		return false
	var lease_id := corridor_lease_id(key)
	if not _leases.try_acquire(lease_id, agent, -1.0, 0.0, {"kind": "corridor", "key": key}):
		return false
	corridor_owners[key] = agent.get_instance_id()
	agent_corridors[agent.get_instance_id()] = key
	return true


func release_corridor(agent: AnimatedAgent) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	var agent_id := agent.get_instance_id()
	var key := String(agent_corridors.get(agent_id, ""))
	if not key.is_empty() and int(corridor_owners.get(key, 0)) == agent_id:
		corridor_owners.erase(key)
		_leases.release(corridor_lease_id(key), agent)
	agent_corridors.erase(agent_id)


func try_acquire_holding(agent: AnimatedAgent, cell: Vector2i) -> bool:
	if agent == null:
		return false
	release_holding(agent)
	var lease_id := holding_lease_id(cell)
	if not _leases.try_acquire(lease_id, agent, -1.0, 0.0, {"kind": "holding", "cell": cell}):
		return false
	holding_by_agent[agent.get_instance_id()] = lease_id
	return true


func release_holding(agent: AnimatedAgent) -> void:
	if agent == null or not is_instance_valid(agent):
		return
	var agent_id := agent.get_instance_id()
	var lease_id := StringName(holding_by_agent.get(agent_id, &""))
	if not lease_id.is_empty():
		_leases.release(lease_id, agent)
	holding_by_agent.erase(agent_id)


func holding_is_available(agent: AnimatedAgent, cell: Vector2i) -> bool:
	var owner: Variant = _leases.owner_of(holding_lease_id(cell))
	return owner == null or owner == agent


func has_holding(agent: AnimatedAgent) -> bool:
	if agent == null or not is_instance_valid(agent):
		return false
	var lease_id := StringName(holding_by_agent.get(agent.get_instance_id(), &""))
	return not lease_id.is_empty() and _leases.owns(lease_id, agent)


func forget_dead_holding_owner(agent_id: int) -> void:
	holding_by_agent.erase(agent_id)


func clear() -> void:
	clear_door()
	corridor_owners.clear()
	agent_corridors.clear()
	holding_by_agent.clear()


func corridor_lease_id(key: String) -> StringName:
	return StringName("corridor:%s" % key)


func holding_lease_id(cell: Vector2i) -> StringName:
	return StringName("holding:%d,%d" % [cell.x, cell.y])
