class_name AIDriver
extends Node
## Spline-following opponent. Chases a point ahead on the track curve, slows for
## corners and low-grip surfaces. Comes in two temperaments: a BRUISER leans on the rival
## whenever it is alongside, a RACER wants the win and gives everyone room instead.
## The course is point-to-point, so it eases off once past the finish line.

const BRUISER := &"bruiser"
const RACER := &"racer"

var track: SprintTrack
var rival: RaycastCar
var others: Array = []        ## Every car in the field, for giving room / spotting blockers
var style: StringName = BRUISER
var preferred_gadget: StringName = &"shield"   ## What this driver picks at a pit stop
var preferred_route: StringName = &""          ## Branch id this driver takes at a fork; "" = main road
var resets := 0                                ## Times the watchdog has put the car back on the road
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
var _blocked_ahead := false   ## A car sits right in front of us (racers)
var _crowded := false         ## Someone is within touching distance (racers)
var _chased := false          ## Someone is close behind on our line (racers)


func _ready() -> void:
	process_physics_priority = -1
	car = get_parent() as RaycastCar


## Forget stuck/stall history, e.g. after the car has been moved.
func reset_state() -> void:
	_offtrack_time = 0.0
	_stuck_time = 0.0
	_reverse_timer = 0.0
	_stall_time = 0.0
	_best_offset = -INF


func _physics_process(delta: float) -> void:
	if track == null or car == null:
		return
	if car.controls_locked:
		reset_state()
		return
	var length := track.length
	var pos := car.global_position
	var offset := track.track_offset(car)
	# Two different routes matter here: the one we are actually driving on, which is what
	# our own position means, and the one we are steering at, which at a fork is the branch
	# we have not joined yet. Mixing them up makes a car peeling off read as off the road.
	var on_route: SprintTrack.RouteLine = track.route_of(car)
	var aim := on_route
	if aim == null and preferred_route != &"":
		for br in track.branches_forking(offset, 140.0, 170.0):
			if br.id == preferred_route:
				aim = br
	var half_width := track.width_at(offset, aim)
	var road_half := track.width_at(offset, on_route)
	var speed := car.speed
	var speed_abs := absf(speed)

	# Look-ahead point grows with speed.
	var look := clampf(7.0 + speed_abs * 0.6, 8.0, 42.0)
	var ahead := track.frame_at(minf(offset + look, length), aim)
	var mid := track.frame_at(minf(offset + look * 1.7, length), aim)
	var far := track.frame_at(minf(offset + look * 2.6, length), aim)
	# How much the road bends ahead: the largest heading change between any two of the
	# look-ahead points, so a chicane whose two arcs cancel out still reads as a corner.
	var near_tangent: Vector3 = ahead.tangent
	var mid_tangent: Vector3 = mid.tangent
	var far_tangent: Vector3 = far.tangent
	var bend := maxf(near_tangent.angle_to(far_tangent),
			maxf(near_tangent.angle_to(mid_tangent), mid_tangent.angle_to(far_tangent)))
	var corner := clampf(bend / 0.9, 0.0, 1.0)

	# Lateral target: preferred lane, a slow wobble, and a shove toward the rival when alongside.
	_lane_wobble_phase += delta * 0.4
	var lane := lane_offset * half_width + sin(_lane_wobble_phase) * 1.2
	var my_lateral := track.lateral_offset_at(pos, offset, on_route)
	if style == BRUISER and rival != null and is_instance_valid(rival):
		var rival_off := track.track_offset(rival)
		if absf(rival_off - offset) < 7.0:
			var rival_lane := track.lateral_offset_at(rival.global_position, rival_off)
			lane = lerpf(lane, rival_lane, aggression * 0.65)
	elif style == RACER:
		lane += _room_for_others(offset, my_lateral)
	# Hurt? Swing over to a repair pad if one is coming up (they are all on the main road).
	if car.health < 45.0 and aim == null:
		var station: Array = track.next_repair_station(offset, 220.0)
		if not station.is_empty():
			lane = float(station[1])

	# Where hazards leave only a gap, thread it rather than holding a personal lane. Inside a
	# ruined hall the gap is one of two lanes; asking with our own side keeps us in it.
	var gate: Vector2 = track.hazard_gate(ahead.offset, my_lateral, on_route)
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
	if track.distance_from_center_at(pos, offset, on_route) > road_half + SprintTrack.SHOULDER_WIDTH + 4.0:
		_offtrack_time += delta
	else:
		_offtrack_time = 0.0
	if _offtrack_time > 3.0 or _stuck_time > 7.0 or _stall_time > 9.0:
		# Drop back on the road a little further up the course, clear of whatever caught us.
		car.reset_to(track.snap_to_track(pos, 12.0))
		track.invalidate_cursor(car)
		reset_state()
		resets += 1

	car.input_throttle = throttle
	car.input_brake = brake
	car.input_steer = steer_cmd
	car.input_handbrake = false
	_consider_gadget(offset, my_lateral, corner, speed, target_speed)


## Racers steer clear of anyone alongside rather than into them. Returns a lateral nudge
## away from nearby cars and notes who is blocking, crowding or chasing us for the gadget
## logic. Bruisers never call this.
func _room_for_others(offset: float, my_lateral: float) -> float:
	var nudge := 0.0
	_blocked_ahead = false
	_crowded = false
	_chased = false
	for o in others:
		var oc := o as RaycastCar
		if oc == null or oc == car:
			continue
		var along: float = track.track_offset(oc) - offset
		if along < -14.0 or along > 14.0:
			continue
		var gap: float = track.lateral_offset_at(oc.global_position, offset + along) - my_lateral
		var agap := absf(gap)
		if along > 1.5 and along < 9.0 and agap < 2.4:
			_blocked_ahead = true
		if absf(along) < 6.0 and agap < 3.5:
			_crowded = true
		if along < -2.0 and agap < 3.0:
			_chased = true
		if along > -5.0 and along < 12.0 and agap < 4.2:
			# Closer means a harder push; a car dead ahead is dodged to whichever side is freer.
			var side := -signf(gap) if agap > 0.2 else (1.0 if my_lateral < 0.0 else -1.0)
			nudge += side * (4.2 - agap) * 0.9
	return clampf(nudge, -4.5, 4.5)


## Called every tick; during a pit window swap to the gadget this temperament likes.
func _pit_choice() -> void:
	var slot := car.gadget_slot
	if slot.in_pit() and slot.gadget != preferred_gadget:
		slot.select(preferred_gadget)


## Simple triggers for whatever gadget the car is carrying. Bruisers use theirs on the
## rival; racers use theirs to get past or to keep the pack off them.
func _consider_gadget(offset: float, my_lateral: float, corner: float, speed: float, target_speed: float) -> void:
	_pit_choice()
	var slot := car.gadget_slot
	if not slot.can_use():
		return
	var rival_along := INF
	var rival_side := INF
	if rival != null and is_instance_valid(rival):
		var r_off := track.track_offset(rival)
		rival_along = r_off - offset
		rival_side = track.lateral_offset_at(rival.global_position, r_off) - my_lateral
	var bruiser := style == BRUISER
	match slot.gadget:
		&"boost":
			var straight := corner < 0.25 and speed < target_speed + 4.0 and speed > 8.0
			var chasing := bruiser and rival_along > 4.0 and rival_along < 30.0 and corner < 0.4 and speed > 8.0
			if straight or chasing:
				slot.try_use()
		&"shield":
			if bruiser:
				if absf(rival_along) < 8.0 and absf(rival_side) < 5.0:
					slot.try_use()
			elif _crowded:
				slot.try_use()
		&"jump":
			var rival_blocks := rival_along > 2.0 and rival_along < 8.0 and absf(rival_side) < 2.5
			if _stuck_time > 0.8 or (speed > 10.0 and (rival_blocks or (not bruiser and _blocked_ahead))):
				slot.try_use()
		&"oil":
			var rival_behind := rival_along < -3.0 and rival_along > -16.0 and absf(rival_side) < 3.0
			if rival_behind or (not bruiser and _chased and speed > 10.0):
				slot.try_use()
