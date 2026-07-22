class_name RigCarryMarker
extends Node3D

## Runtime midpoint socket used by every rig. BoneAttachment3D nodes already
## follow the animation pose; this lightweight marker converts them into the
## stable two-handed carry target consumed by props and future asset packs.

var left_hand: Node3D
var right_hand: Node3D
var lift := 0.105
var forward_offset := 0.04


func configure(left: Node3D, right: Node3D) -> void:
	left_hand = left
	right_hand = right
	set_process(true)
	sync_now()


func _process(_delta: float) -> void:
	sync_now()


func sync_now() -> void:
	if left_hand == null or right_hand == null or not is_instance_valid(left_hand) or not is_instance_valid(right_hand):
		return
	var midpoint := (left_hand.global_position + right_hand.global_position) * 0.5
	var forward := -global_basis.z.normalized() * forward_offset
	global_position = midpoint + Vector3.UP * lift + forward
