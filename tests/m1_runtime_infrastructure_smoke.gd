extends Node

const AgentSpatialIndexScript := preload("res://scripts/ai/agent_spatial_index.gd")
const RuntimeLeaseRegistryScript := preload("res://scripts/ai/runtime_lease_registry.gd")

var checks := 0
var failures: Array[String] = []


func _ready() -> void:
	_test_spatial_index()
	_test_runtime_leases()
	print("M1 RUNTIME INFRASTRUCTURE: %d checks, %d failures" % [checks, failures.size()])
	for failure: String in failures:
		print("FAIL: ", failure)
	get_tree().quit(0 if failures.is_empty() else 1)


func _test_spatial_index() -> void:
	var first := _agent_at(Vector3(0.25, 0.0, 0.25), "First")
	var second := _agent_at(Vector3(1.75, 0.0, 0.25), "Second")
	var across_bucket := _agent_at(Vector3(2.10, 0.0, 0.25), "AcrossBucket")
	var negative := _agent_at(Vector3(-0.10, 0.0, 0.25), "Negative")
	var distant := _agent_at(Vector3(7.0, 0.0, 7.0), "Distant")
	var index = AgentSpatialIndexScript.new(2.0)
	index.rebuild([first, first, second, across_bucket, negative, distant])
	_expect(index.size() == 5, "rebuild deduplicates repeated agents")
	_expect(index.bucket_count() == 4, "two-meter buckets include negative coordinates correctly")
	var nearby := index.query_radius(Vector3.ZERO, 2.2)
	_expect(nearby.size() == 4, "radius query crosses positive and negative bucket boundaries")
	_expect(nearby.count(first) == 1, "radius query never duplicates an agent")
	_expect(not nearby.has(distant), "radius query applies exact distance after bucket filtering")
	var without_first := index.query_radius(Vector3.ZERO, 2.2, first)
	_expect(not without_first.has(first) and without_first.size() == 3, "radius query supports caller exclusion")
	across_bucket.global_position = Vector3(9.0, 0.0, 9.0)
	index.rebuild([first, second, across_bucket, negative, distant])
	_expect(not index.query_radius(Vector3.ZERO, 2.2).has(across_bucket), "rebuild removes stale positions")
	index.clear()
	_expect(index.size() == 0 and index.bucket_count() == 0, "clear releases every spatial entry")


func _test_runtime_leases() -> void:
	var registry = RuntimeLeaseRegistryScript.new()
	var first_owner := Node.new()
	first_owner.name = "FirstOwner"
	add_child(first_owner)
	var second_owner := Node.new()
	second_owner.name = "SecondOwner"
	add_child(second_owner)
	_expect(registry.try_acquire(&"station:oven", first_owner, 10.0), "a free resource can be acquired")
	_expect(registry.try_acquire(&"station:oven", first_owner, 10.5), "acquire is idempotent for its owner")
	_expect(not registry.try_acquire(&"station:oven", second_owner, 10.5), "a live lease is exclusive")
	_expect(registry.owns(&"station:oven", first_owner, 10.5), "owns identifies the current owner")
	_expect(not registry.release(&"station:oven", second_owner), "another owner cannot release a lease")
	_expect(registry.release(&"station:oven", first_owner) and registry.release(&"station:oven", first_owner), "release is idempotent")
	registry.try_acquire(&"door:exit", first_owner, 20.0, 2.0, {"priority": 100})
	_expect(registry.cleanup(21.99) == 0 and registry.owns(&"door:exit", first_owner, 21.99), "TTL remains live before its deadline")
	_expect(registry.cleanup(22.0) == 1 and not registry.owns(&"door:exit", first_owner, 22.0), "cleanup reclaims a lease at its deadline")
	registry.try_acquire(&"task:a", first_owner)
	registry.try_acquire(&"task:b", first_owner)
	registry.try_acquire(&"task:c", second_owner)
	_expect(registry.release_all(first_owner) == 2 and registry.release_all(first_owner) == 0, "release_all is complete and idempotent")
	_expect(registry.active_count() == 1 and registry.owner_of(&"task:c") == second_owner, "release_all preserves leases held by others")
	_expect(registry.metadata_for(&"missing").is_empty(), "missing lease metadata is an empty dictionary")
	registry.try_acquire(&"idle:temporary", first_owner)
	first_owner.free()
	_expect(registry.cleanup() == 1, "cleanup reclaims leases held by freed Objects")
	registry.clear()
	_expect(registry.active_count() == 0, "clear releases every runtime lease")


func _agent_at(position: Vector3, label: String) -> Node3D:
	var agent := Node3D.new()
	agent.name = label
	add_child(agent)
	agent.global_position = position
	return agent


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
