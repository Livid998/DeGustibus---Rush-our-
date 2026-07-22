class_name RuntimeLeaseRegistry
extends RefCounted

## Exclusive, owner-aware leases for stations, tasks, service slots and idle cells.
##
## All operations are safe to repeat. A lease can optionally expire; callers may
## pass an explicit clock value to make simulations and tests deterministic.

var _leases: Dictionary = {}


## Attempts to claim lease_id. Reacquiring as the current owner renews the TTL.
func try_acquire(
	lease_id: StringName,
	owner: Variant,
	now_seconds: float = -1.0,
	ttl_seconds: float = 0.0,
	metadata: Dictionary = {}
) -> bool:
	if lease_id.is_empty() or not _owner_is_live(owner):
		return false
	var now := _resolve_now(now_seconds)
	_cleanup_one(lease_id, now)
	var owner_key := _owner_key(owner)
	if _leases.has(lease_id):
		var current: Dictionary = _leases[lease_id]
		if String(current.get("owner_key", "")) != owner_key:
			return false
		current["expires_at"] = now + ttl_seconds if ttl_seconds > 0.0 else -1.0
		if not metadata.is_empty():
			current["metadata"] = metadata.duplicate(true)
		_leases[lease_id] = current
		return true
	_leases[lease_id] = {
		"owner": owner,
		"owner_key": owner_key,
		"acquired_at": now,
		"expires_at": now + ttl_seconds if ttl_seconds > 0.0 else -1.0,
		"metadata": metadata.duplicate(true),
	}
	return true


## Returns true only while owner holds a live lease.
func owns(lease_id: StringName, owner: Variant, now_seconds: float = -1.0) -> bool:
	if lease_id.is_empty() or not _owner_is_live(owner):
		return false
	_cleanup_one(lease_id, _resolve_now(now_seconds))
	if not _leases.has(lease_id):
		return false
	return String((_leases[lease_id] as Dictionary).get("owner_key", "")) == _owner_key(owner)


## Idempotent for the owner: releasing an already-free lease succeeds. It fails
## only when another live owner currently holds the requested lease.
func release(lease_id: StringName, owner: Variant) -> bool:
	if lease_id.is_empty():
		return false
	if not _leases.has(lease_id):
		return true
	if not _owner_is_live(owner):
		return false
	var record: Dictionary = _leases[lease_id]
	if String(record.get("owner_key", "")) != _owner_key(owner):
		return false
	_leases.erase(lease_id)
	return true


## Releases every lease owned by owner and returns the number actually removed.
func release_all(owner: Variant) -> int:
	if not _owner_is_live(owner):
		return 0
	var owner_key := _owner_key(owner)
	var removed := 0
	for lease_id: Variant in _leases.keys():
		var record: Dictionary = _leases[lease_id]
		if String(record.get("owner_key", "")) == owner_key:
			_leases.erase(lease_id)
			removed += 1
	return removed


## Reclaims expired leases and leases whose Object owner has been freed.
func cleanup(now_seconds: float = -1.0) -> int:
	var now := _resolve_now(now_seconds)
	var removed := 0
	for lease_id: Variant in _leases.keys():
		if _record_is_stale(_leases[lease_id], now):
			_leases.erase(lease_id)
			removed += 1
	return removed


func active_count() -> int:
	return _leases.size()


func owner_of(lease_id: StringName, now_seconds: float = -1.0) -> Variant:
	_cleanup_one(lease_id, _resolve_now(now_seconds))
	if not _leases.has(lease_id):
		return null
	return (_leases[lease_id] as Dictionary).get("owner")


func metadata_for(lease_id: StringName, now_seconds: float = -1.0) -> Dictionary:
	_cleanup_one(lease_id, _resolve_now(now_seconds))
	if not _leases.has(lease_id):
		return {}
	return Dictionary((_leases[lease_id] as Dictionary).get("metadata", {})).duplicate(true)


func clear() -> void:
	_leases.clear()


func _cleanup_one(lease_id: StringName, now: float) -> void:
	if _leases.has(lease_id) and _record_is_stale(_leases[lease_id], now):
		_leases.erase(lease_id)


func _record_is_stale(record_value: Variant, now: float) -> bool:
	if typeof(record_value) != TYPE_DICTIONARY:
		return true
	var record: Dictionary = record_value
	if not _owner_is_live(record.get("owner")):
		return true
	var expires_at := float(record.get("expires_at", -1.0))
	return expires_at >= 0.0 and now >= expires_at


func _owner_is_live(owner: Variant) -> bool:
	if owner == null:
		return false
	if typeof(owner) != TYPE_OBJECT:
		return true
	if not is_instance_valid(owner):
		return false
	return not (owner is Node and (owner as Node).is_queued_for_deletion())


func _owner_key(owner: Variant) -> String:
	if typeof(owner) == TYPE_OBJECT:
		return "object:%d" % (owner as Object).get_instance_id()
	return "%d:%s" % [typeof(owner), var_to_str(owner)]


func _resolve_now(explicit_seconds: float) -> float:
	if explicit_seconds >= 0.0:
		return explicit_seconds
	return Time.get_ticks_msec() * 0.001
