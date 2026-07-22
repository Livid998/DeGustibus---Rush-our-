class_name AgentSpatialIndex
extends RefCounted

## Lightweight XZ-plane spatial index for runtime agents.
##
## The index deliberately owns no agents and must be rebuilt by its caller. A
## rebuild is cheap for the restaurant-sized crowds used by the game and makes
## stale entries impossible when an agent moves or is freed between AI ticks.

const DEFAULT_BUCKET_SIZE := 2.0

var bucket_size: float = DEFAULT_BUCKET_SIZE

var _buckets: Dictionary = {}
var _entries: Dictionary = {}


func _init(p_bucket_size: float = DEFAULT_BUCKET_SIZE) -> void:
	bucket_size = maxf(p_bucket_size, 0.01)


## Replaces the complete index. By default, entries must be Node3D instances.
## A resolver may be supplied for another Object type and must return Vector3.
func rebuild(agents: Array, position_resolver: Callable = Callable()) -> void:
	clear()
	for value: Variant in agents:
		if typeof(value) != TYPE_OBJECT:
			continue
		var agent: Object = value as Object
		if not _agent_is_live(agent):
			continue
		var instance_id := agent.get_instance_id()
		# Duplicate source entries must never multiply query results.
		if _entries.has(instance_id):
			continue
		var position_value: Variant
		if position_resolver.is_valid():
			position_value = position_resolver.call(agent)
		elif agent is Node3D:
			position_value = (agent as Node3D).global_position
		else:
			continue
		if typeof(position_value) != TYPE_VECTOR3:
			continue
		var position := position_value as Vector3
		var bucket := _bucket_for(position)
		_entries[instance_id] = {
			"agent": agent,
			"position": position,
			"bucket": bucket,
		}
		var bucket_entries: Array = _buckets.get(bucket, [])
		bucket_entries.append(instance_id)
		_buckets[bucket] = bucket_entries


## Returns live agents whose XZ distance from center is at most radius.
## Results are unique even if malformed input contained duplicate agents.
func query_radius(center: Vector3, radius: float, exclude: Object = null) -> Array[Object]:
	var results: Array[Object] = []
	if radius < 0.0 or _entries.is_empty():
		return results
	var minimum := _bucket_for(center - Vector3(radius, 0.0, radius))
	var maximum := _bucket_for(center + Vector3(radius, 0.0, radius))
	var radius_squared := radius * radius
	var seen: Dictionary = {}
	for bucket_x: int in range(minimum.x, maximum.x + 1):
		for bucket_y: int in range(minimum.y, maximum.y + 1):
			var bucket := Vector2i(bucket_x, bucket_y)
			for instance_id: int in _buckets.get(bucket, []):
				if seen.has(instance_id) or not _entries.has(instance_id):
					continue
				seen[instance_id] = true
				var entry: Dictionary = _entries[instance_id]
				var agent: Object = entry.get("agent") as Object
				if not _agent_is_live(agent) or agent == exclude:
					continue
				var position: Vector3 = entry.get("position", Vector3.ZERO)
				var delta := Vector2(position.x - center.x, position.z - center.z)
				if delta.length_squared() <= radius_squared:
					results.append(agent)
	return results


func clear() -> void:
	_buckets.clear()
	_entries.clear()


func size() -> int:
	return _entries.size()


func bucket_count() -> int:
	return _buckets.size()


func _bucket_for(position: Vector3) -> Vector2i:
	return Vector2i(
		floori(position.x / bucket_size),
		floori(position.z / bucket_size)
	)


func _agent_is_live(agent: Object) -> bool:
	if agent == null or not is_instance_valid(agent):
		return false
	return not (agent is Node and (agent as Node).is_queued_for_deletion())
