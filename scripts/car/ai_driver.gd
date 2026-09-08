class_name AIDriver
extends Node
## Spline-following opponent. Chases a point ahead on the track curve, slows for
## corners and low-grip surfaces, and leans on a nearby rival to trade paint.

var track: TestTrack
var rival: RaycastCar
var lane_offset := 0.0        ## Preferred lateral position on the road (metres, + = right)
var aggression := 0.5         ## 0 = clean racer, 1 = wants your door panel
var skill := 1.0              ## Scales corner and top speed targets
var top_speed := 50.0
var corner_speed := 15.0

var car: RaycastCar
var _stuck_time := 0.0
var _reverse_timer := 0.0
var _offtrack_time := 0.0
var _lane_wobble_phase := randf() * TAU


func _ready() -> void:
	process_physics_priority = -1
	car = get_parent() as RaycastCar


func _physics_process(delta: float) -> void:
	if track == null or car == null:
		return
	var curve := track.curve
	var length := track.length
	var pos := car.global_position
	var offset := track.track_offset(car)
	var speed := car.speed
	var speed_abs := absf(speed)

	# Look-ahead point grows with speed.
	var look := clampf(7.0 + speed_abs * 0.6, 8.0, 42.0)
	var ahead := track.frame_at(fposmod(offset + look, length))
	var far := track.frame_at(fposmod(offset + look * 2.6, length))
	var far_tangent: Vector3 = far.tangent
	var near_tangent: Vector3 = ahead.tangent
	var corner := clampf(near_tangent.angle_to(far_tangent) / 0.9, 0.0, 1.0)

	# Lateral target: preferred lane, a slow wobble, and a shove toward the rival when alongside.
	_lane_wobble_phase += delta * 0.4
	var lane := lane_offset + sin(_lane_wobble_phase) * 1.2
	if rival != null and is_instance_valid(rival):
		var rival_off := track.track_offset(rival)
		var along := track.wrapped_delta(offset, rival_off)
		if absf(along) < 9.0:
			var rival_lane := track.lateral_offset_at(rival.global_position, rival_off)
			lane = lerpf(lane, rival_lane, aggression * 0.9)
	lane = clampf(lane, -track.road_half_width + 1.2, track.road_half_width - 1.2)
	var target: Vector3 = track.to_global(ahead.pos + ahead.right * lane)

	# Steering: signed angle from our heading to the target, positive = target is left.
	var fwd := -car.global_transform.basis.z
	fwd.y = 0.0
	var to_target := target - pos
	to_target.y = 0.0
	var steer_cmd := 0.0
	if fwd.length_squared() > 0.001 and to_target.length_squared() > 0.001:
		var angle := fwd.normalized().signed_angle_to(to_target.normalized(), Vector3.UP)
		var gain := lerpf(2.2, 1.0, clampf(speed_abs / 40.0, 0.0, 1.0))
		steer_cmd = -clampf(angle * gain / deg_to_rad(car.max_steer_deg), -1.0, 1.0)

	# Speed target from curvature and grip under the car.
	var grip := car.current_surface.grip if car.current_surface != null else 1.0
	var grip_scale := lerpf(0.5, 1.0, clampf(grip, 0.0, 1.0))
	var target_speed := lerpf(top_speed, corner_speed, corner) * grip_scale * skill

	var throttle := 0.0
	var brake := 0.0
	if speed < target_speed - 1.5:
		throttle = 1.0
	elif speed > target_speed + 3.0:
		brake = clampf((speed - target_speed) / 12.0, 0.25, 1.0)
	else:
		throttle = 0.45

	# Stuck handling: back up for a moment, reset if it keeps happening.
	if speed_abs < 0.8 and throttle > 0.5:
		_stuck_time += delta
	else:
		_stuck_time = maxf(0.0, _stuck_time - delta * 0.5)
	if _reverse_timer > 0.0:
		_reverse_timer -= delta
		throttle = 0.0
		brake = 1.0
		steer_cmd = -steer_cmd
	elif _stuck_time > 2.0:
		_reverse_timer = 1.4
		_stuck_time = 0.0

	# Way off the road, or lost for too long: put it back on the track.
	if track.distance_from_center_at(pos, offset) > track.road_half_width + track.shoulder_width + 4.0:
		_offtrack_time += delta
	else:
		_offtrack_time = 0.0
	if _offtrack_time > 3.0 or _stuck_time > 7.0:
		car.reset_to(track.snap_to_track(pos))
		_offtrack_time = 0.0
		_stuck_time = 0.0
		_reverse_timer = 0.0

	car.input_throttle = throttle
	car.input_brake = brake
	car.input_steer = steer_cmd
	car.input_handbrake = false
