class_name ChaseCamera
extends Camera3D
## Smooth chase camera that follows the car's velocity direction so drifts read on screen,
## and that leans over the car on a descent so you can see the road you are falling into
## rather than the horizon above it.

@export var target: Node3D
@export var distance := 7.5
@export var height := 2.8
@export var look_height := 1.0
@export var follow_speed := 6.0
@export var turn_speed := 3.5
@export var base_fov := 68.0
@export var speed_fov := 16.0

@export_group("Slopes")
## The road it reads to know a drop is coming. Without one it falls back to the gradient
## the car is already on, which works but cannot see over a crest.
var track: SprintTrack
@export var slope_look_ahead := 26.0   ## Metres up the road the gradient is read from
@export var slope_max := 0.30          ## Gradient at which the lean stops growing
@export var slope_rise := 4.0          ## Extra metres of camera height at slope_max downhill
@export var slope_aim_ahead := 18.0    ## Extra metres the aim point moves up the road
@export var slope_aim_gain := 1.1      ## How far past the road surface the aim point drops
@export var slope_smooth := 2.2        ## How quickly the camera reacts to a change of gradient

var _fwd := Vector3.FORWARD
var _slope := 0.0                      ## Smoothed gradient ahead; negative is downhill
var _track_offset := 0.0               ## Our own place on the course, kept out of the drivers' cache
var _shake := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	top_level = true


func snap_behind_target() -> void:
	if target == null:
		return
	if track != null:
		_track_offset = track.offset_of(target.global_position)
		_slope = track.grade_at(clampf(_track_offset + slope_look_ahead, 0.0, track.length))
	_fwd = -target.global_transform.basis.z
	_fwd.y = 0.0
	_fwd = _fwd.normalized() if _fwd.length_squared() > 0.001 else Vector3.FORWARD
	global_position = target.global_position - _fwd * distance + Vector3.UP * height
	look_at(target.global_position + Vector3.UP * look_height, Vector3.UP)


## The gradient of the road just ahead, negative downhill. Read from the course where we
## have it, so the camera starts leaning before the car tips over the edge; otherwise from
## the car's own climb rate, which only knows about the slope it is already on.
func _road_slope() -> float:
	if track != null and target != null:
		# Our own cursor, not the shared one: asking the track where a car is caches the
		# answer against the current physics frame, and a camera running every drawn frame
		# would be answering that question on the drivers' behalf at the wrong moment.
		_track_offset = track.offset_near(target.global_position, _track_offset)
		return track.grade_at(clampf(_track_offset + slope_look_ahead, 0.0, track.length))
	if target is RigidBody3D:
		var v: Vector3 = (target as RigidBody3D).linear_velocity
		var flat := Vector2(v.x, v.z).length()
		if flat > 3.0:
			return clampf(v.y / flat, -slope_max, slope_max)
	return 0.0


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

	_slope = lerpf(_slope, _road_slope(), clampf(slope_smooth * delta, 0.0, 1.0))
	# Only a drop needs the help: climbing, the road ahead already fills the screen.
	var drop := clampf(-_slope, 0.0, slope_max) / slope_max

	var desired_pos := target.global_position - _fwd * (distance + speed * 0.035) \
			+ Vector3.UP * (height + slope_rise * drop)
	global_position = global_position.lerp(desired_pos, clampf(follow_speed * delta, 0.0, 1.0))

	# Aim at the road rather than at the car: a point further up the course, dropped by the
	# gradient so it lands on the surface the car is about to reach. That pitches the camera
	# down the hill instead of leaving it staring at the horizon.
	var aim_ahead := 3.0 + slope_aim_ahead * drop
	var look_target := target.global_position + _fwd * aim_ahead \
			+ Vector3.UP * (look_height + _slope * aim_ahead * slope_aim_gain * drop)
	if _shake > 0.0:
		look_target += Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * _shake * 0.35
		_shake = move_toward(_shake, 0.0, delta * 2.5)
	look_at(look_target, Vector3.UP)
	fov = base_fov + speed_fov * clampf(speed / 60.0, 0.0, 1.0)
