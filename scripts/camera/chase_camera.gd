class_name ChaseCamera
extends Camera3D
## Smooth chase camera that follows the car's velocity direction so drifts read on screen.

@export var target: Node3D
@export var distance := 7.5
@export var height := 2.8
@export var look_height := 1.0
@export var follow_speed := 6.0
@export var turn_speed := 3.5
@export var base_fov := 68.0
@export var speed_fov := 16.0

var _fwd := Vector3.FORWARD
var _shake := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	top_level = true


func snap_behind_target() -> void:
	if target == null:
		return
	_fwd = -target.global_transform.basis.z
	_fwd.y = 0.0
	_fwd = _fwd.normalized() if _fwd.length_squared() > 0.001 else Vector3.FORWARD
	global_position = target.global_position - _fwd * distance + Vector3.UP * height
	look_at(target.global_position + Vector3.UP * look_height, Vector3.UP)


func add_shake(amount: float) -> void:
	_shake = minf(_shake + amount, 1.0)


func _process(delta: float) -> void:
	if target == null:
		return
	var car_fwd := -target.global_transform.basis.z
	car_fwd.y = 0.0
	if car_fwd.length_squared() < 0.001:
		car_fwd = _fwd
	car_fwd = car_fwd.normalized()

	var vel := Vector3.ZERO
	if target is RigidBody3D:
		vel = (target as RigidBody3D).linear_velocity
	vel.y = 0.0
	var speed := vel.length()

	var desired_fwd := car_fwd
	if speed > 4.0:
		var vdir := vel / speed
		# Reversing: keep looking forward over the car rather than swinging round.
		if vdir.dot(car_fwd) > 0.0:
			desired_fwd = car_fwd.lerp(vdir, 0.55).normalized()
	_fwd = _fwd.lerp(desired_fwd, clampf(turn_speed * delta, 0.0, 1.0)).normalized()

	var desired_pos := target.global_position - _fwd * (distance + speed * 0.035) + Vector3.UP * height
	global_position = global_position.lerp(desired_pos, clampf(follow_speed * delta, 0.0, 1.0))

	var look_target := target.global_position + Vector3.UP * look_height + _fwd * 3.0
	if _shake > 0.0:
		look_target += Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * _shake * 0.35
		_shake = move_toward(_shake, 0.0, delta * 2.5)
	look_at(look_target, Vector3.UP)
	fov = base_fov + speed_fov * clampf(speed / 60.0, 0.0, 1.0)
