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


## Atomically acquires a set of resources. The preflight checks every lease
## before writing any record, so callers never end up owning a task without its
## workstation (or vice versa). Repeating the same bundle for its owner renews
## every lease and remains safe.
func try_acquire_many(
	lease_ids: Array,
	owner: Variant,
	now_seconds: float = -1.0,
	ttl_seconds: float = 0.0,
	metadata_by_lease: Dictionary = {}
) -> bool:
	if lease_ids.is_empty() or not _owner_is_live(owner):
		return false
	var unique_ids: Array[StringName] = []
	for lease_value: Variant in lease_ids:
		var lease_id := StringName(String(lease_value))
		if lease_id.is_empty():
			return false
		if not unique_ids.has(lease_id):
			unique_ids.append(lease_id)
	var now := _resolve_now(now_seconds)
	var owner_key := _owner_key(owner)
	for lease_id: StringName in unique_ids:
		_cleanup_one(lease_id, now)
		if not _leases.has(lease_id):
			continue
		var current: Dictionary = _leases[lease_id]
		if String(current.get("owner_key", "")) != owner_key:
			return false
	for lease_id: StringName in unique_ids:
		var metadata: Dictionary = {}
		if metadata_by_lease.has(lease_id) and metadata_by_lease[lease_id] is Dictionary:
			metadata = metadata_by_lease[lease_id]
		elif metadata_by_lease.has(String(lease_id)) and metadata_by_lease[String(lease_id)] is Dictionary:
			metadata = metadata_by_lease[String(lease_id)]
		if not try_acquire(lease_id, owner, now, ttl_seconds, metadata):
			# This is only defensive (the registry is single-threaded), but keeps
			# the operation atomic if acquisition validation changes in the future.
			for acquired_id: StringName in unique_ids:
				if acquired_id == lease_id:
					break
				release(acquired_id, owner)
			return false
	return true


## Idempotently releases a bundle owned by owner. A conflicting live owner is
## preserved and makes the result false.
func release_many(lease_ids: Array, owner: Variant) -> bool:
	var success := true
	var seen: Dictionary = {}
	for lease_value: Variant in lease_ids:
		var lease_id := StringName(String(lease_value))
		if lease_id.is_empty() or seen.has(lease_id):
			continue
		seen[lease_id] = true
		if not release(lease_id, owner):
			success = false
	return success


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


## Read-only diagnostic copy. Owners are intentionally retained so an audit can
## release an orphan with the normal owner-aware API.
func records_snapshot(now_seconds: float = -1.0) -> Dictionary:
	cleanup(now_seconds)
	var result: Dictionary = {}
	for lease_id: Variant in _leases:
		var record: Dictionary = _leases[lease_id]
		result[lease_id] = {
			"owner": record.get("owner"),
			"owner_key": String(record.get("owner_key", "")),
			"acquired_at": float(record.get("acquired_at", 0.0)),
			"expires_at": float(record.get("expires_at", -1.0)),
			"metadata": Dictionary(record.get("metadata", {})).duplicate(true),
		}
	return result


func diagnostic_summary(now_seconds: float = -1.0) -> Dictionary:
	var records := records_snapshot(now_seconds)
	var by_kind: Dictionary = {}
	for record_value: Variant in records.values():
		var record: Dictionary = record_value
		var kind := String((record.get("metadata", {}) as Dictionary).get("kind", "unspecified"))
		by_kind[kind] = int(by_kind.get(kind, 0)) + 1
	return {"active": records.size(), "by_kind": by_kind}


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
