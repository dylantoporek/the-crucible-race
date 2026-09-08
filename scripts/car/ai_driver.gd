class_name AIDriver
extends Node
## Spline-following opponent. Chases a point ahead on the track curve, slows for
## corners and low-grip surfaces, and leans on a nearby rival to trade paint.
## The course is point-to-point, so it eases off once past the finish line.

var track: SprintTrack
var rival: RaycastCar
## Preferred lateral position as a fraction of the road's half-width, so the same driver
## works on a narrow mountain road and a wide desert.
var lane_offset := 0.0
var aggression := 0.5         ## 0 = clean racer, 1 = wants your door panel
var skill := 1.0              ## Scales corner and top speed targets
var top_speed := 50.0
var corner_speed := 15.0

var car: RaycastCar
var _stuck_time := 0.0
var _reverse_timer := 0.0
var _offtrack_time := 0.0
var _best_offset := -INF      ## Furthest point reached, for the no-progress watchdog.
var _stall_time := 0.0
var _lane_wobble_phase := randf() * TAU


func _ready() -> void:
	process_physics_priority = -1
	car = get_parent() as RaycastCar


func _physics_process(delta: float) -> void:
	if track == null or car == null:
		return
	var length := track.length
	var pos := car.global_position
	var offset := track.track_offset(car)
	var half_width := track.width_at(offset)
	var speed := car.speed
	var speed_abs := absf(speed)

	# Look-ahead point grows with speed.
	var look := clampf(7.0 + speed_abs * 0.6, 8.0, 42.0)
	var ahead := track.frame_at(minf(offset + look, length))
	var far := track.frame_at(minf(offset + look * 2.6, length))
	var far_tangent: Vector3 = far.tangent
	var near_tangent: Vector3 = ahead.tangent
	var corner := clampf(near_tangent.angle_to(far_tangent) / 0.9, 0.0, 1.0)

	# Lateral target: preferred lane, a slow wobble, and a shove toward the rival when alongside.
	_lane_wobble_phase += delta * 0.4
	var lane := lane_offset * half_width + sin(_lane_wobble_phase) * 1.2
	if rival != null and is_instance_valid(rival):
		var rival_off := track.track_offset(rival)
		if absf(rival_off - offset) < 9.0:
			var rival_lane := track.lateral_offset_at(rival.global_position, rival_off)
			lane = lerpf(lane, rival_lane, aggression * 0.9)
	# Where hazards leave only a gap, thread it rather than holding a personal lane.
	var gate: Vector2 = track.hazard_gate(ahead.offset)
	if gate.y > 0.0:
		lane = gate.x + lane_offset * gate.y * 0.5
		lane = clampf(lane, gate.x - gate.y + 1.6, gate.x + gate.y - 1.6)
	else:
		lane = clampf(lane, -half_width + 1.2, half_width - 1.2)
	var target: Vector3 = track.to_global(ahead.pos + ahead.right * lane)
	if offset >= track.finish_offset:
		# Past the flag: coast to a stop rather than driving off the end of the course.
		car.input_throttle = 0.0
		car.input_brake = 0.35
		car.input_steer = 0.0
		car.input_handbrake = false
		return

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
	if speed_abs < 2.0 and throttle > 0.5:
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

	# Watchdog: speed alone misses a car that is bouncing off an obstacle without advancing,
	# so also give up if it has not made real ground for a while.
	if offset > _best_offset + 5.0:
		_best_offset = offset
		_stall_time = 0.0
	else:
		_stall_time += delta

	# Way off the road, or lost for too long: put it back on the track.
	if track.distance_from_center_at(pos, offset) > half_width + SprintTrack.SHOULDER_WIDTH + 4.0:
		_offtrack_time += delta
	else:
		_offtrack_time = 0.0
	if _offtrack_time > 3.0 or _stuck_time > 7.0 or _stall_time > 9.0:
		# Drop back on the road a little further up the course, clear of whatever caught us.
		car.reset_to(track.snap_to_track(pos, 12.0))
		_offtrack_time = 0.0
		_stuck_time = 0.0
		_reverse_timer = 0.0
		_stall_time = 0.0
		_best_offset = offset

	car.input_throttle = throttle
	car.input_brake = brake
	car.input_steer = steer_cmd
	car.input_handbrake = false
