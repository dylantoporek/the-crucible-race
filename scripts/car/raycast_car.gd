class_name RaycastCar
extends RigidBody3D
## Arcade-realistic raycast vehicle.
##
## Each CarWheel child casts a ray down; a spring/damper pushes the chassis up, and a
## slip-based tyre model produces lateral and longitudinal forces that are scaled by
## the SurfaceType under that wheel and clamped by a friction circle. Anti-roll bars,
## quadratic aero drag and light downforce keep it planted without feeling glued.
##
## Drivers (PlayerDriver / AIDriver) are child nodes that write the `input_*` fields
## before this node's physics tick (they use process_physics_priority = -1).

signal impact(strength: float, other: Node)

const GROUND_MASK := 0b101  # world + props

@export_group("Drivetrain")
@export var max_engine_force := 12500.0     ## N total, split across drive wheels
@export var top_speed := 58.0               ## m/s (~209 km/h). Engine force tapers to zero here.
@export var reverse_force_scale := 0.45
@export var max_brake_force := 15000.0      ## N total
@export var handbrake_force := 9000.0       ## N across the rear wheels
@export var handbrake_lateral_grip := 0.45  ## Rear lateral grip multiplier while handbrake is held

@export_group("Steering")
@export var max_steer_deg := 32.0
@export var steer_speed := 6.5              ## How fast the wheels turn toward the input (1/s)
@export var steer_return_speed := 10.0
@export var high_speed_steer_scale := 0.4   ## Steering authority left at top speed

@export_group("Tyres")
@export var tyre_grip := 1.25               ## Base friction coefficient on asphalt
@export var peak_slip_angle_deg := 6.5      ## Slip angle at peak lateral grip
@export var longitudinal_grip := 1.2        ## Drive/brake friction relative to lateral friction
@export var min_drive_fraction := 0.25      ## Drive/brake capacity kept while sliding sideways
@export var surface_blend_time := 0.15      ## Seconds for a terrain change to fade in per wheel
@export var sink_drag := 55.0               ## N per (m/s) per wheel on a surface with sink = 1

@export_group("Chassis")
@export var anti_roll := 9000.0             ## N per metre of compression difference per axle
@export var yaw_damping := 3000.0           ## N*m per rad/s of yaw rate while grounded; settles the tail
@export var drag_coefficient := 2.0         ## N per (m/s)^2
@export var downforce := 1.2                ## N per (m/s)^2
@export var air_stabilize_torque := 2500.0  ## Self-righting torque when airborne
@export var flip_recover_time := 2.5        ## Seconds upside-down before auto-righting
@export var impact_threshold := 1500.0      ## Contact impulse (N*s) that counts as a hit

var paint_color := Color(0.9, 0.2, 0.15)

# Inputs, written by a driver each tick.
var input_throttle := 0.0      # 0..1
var input_brake := 0.0         # 0..1 (doubles as reverse when stopped)
var input_steer := 0.0         # -1 left .. +1 right
var input_handbrake := false

# Telemetry.
var wheels: Array[CarWheel] = []
var steer := 0.0               # smoothed steering -1..1
var speed := 0.0               # signed forward speed (m/s)
var grounded_wheels := 0
var current_surface: SurfaceType
var hits := 0
var reversing := false

var _peak_slip_angle := 0.0
var _flipped_time := 0.0
var _impact_cooldown := 0.0


func _ready() -> void:
	_peak_slip_angle = deg_to_rad(peak_slip_angle_deg)
	for child in get_children():
		if child is CarWheel:
			wheels.append(child)
	current_surface = Surfaces.default_surface
	_apply_paint()


func _apply_paint() -> void:
	var paint := ToonMaterial.make(paint_color, 3.0, 0.5, 0.3)
	var dark := ToonMaterial.make(Color(0.12, 0.12, 0.13), 2.0, 0.6, 0.0)
	for m in $Visual.get_children():
		if m is MeshInstance3D:
			m.material_override = paint
	for w in wheels:
		for m in w.visual.get_children():
			if m is MeshInstance3D:
				m.material_override = dark


func _physics_process(delta: float) -> void:
	var basis := global_transform.basis
	var up := basis.y
	var forward := -basis.z
	speed = linear_velocity.dot(forward)
	var speed_abs := absf(speed)

	_update_steering(delta, speed_abs)
	_update_reverse_state()

	var com := to_global(center_of_mass)
	var space := get_world_3d().direct_space_state
	var drive_wheels := 0
	for w in wheels:
		if w.is_drive:
			drive_wheels += 1
	var engine_force := _engine_force(speed_abs)

	grounded_wheels = 0
	var surface_votes := {}
	for w in wheels:
		_update_wheel(w, space, delta, up, com, engine_force, maxi(drive_wheels, 1), speed_abs)
		if w.grounded:
			grounded_wheels += 1
			surface_votes[w.surface] = surface_votes.get(w.surface, 0) + 1

	_apply_anti_roll(up)
	_apply_aero(up, speed_abs)
	_apply_yaw_damping(up)
	_pick_dominant_surface(surface_votes)

	if grounded_wheels == 0:
		_air_stabilize(up)
	_track_flip(delta, up)
	_impact_cooldown = maxf(0.0, _impact_cooldown - delta)


func _update_steering(delta: float, speed_abs: float) -> void:
	var rate := steer_speed if absf(input_steer) > absf(steer) else steer_return_speed
	steer = move_toward(steer, clampf(input_steer, -1.0, 1.0), rate * delta)
	var authority := lerpf(1.0, high_speed_steer_scale, clampf(speed_abs / top_speed, 0.0, 1.0))
	# +input = right = clockwise about up = negative rotation.
	var angle := -steer * deg_to_rad(max_steer_deg) * authority
	for w in wheels:
		w.steer_angle = angle if w.is_steer else 0.0


func _update_reverse_state() -> void:
	if input_brake > 0.1 and input_throttle < 0.1 and speed < 1.0:
		reversing = true
	elif input_throttle > 0.1 or speed > 1.5:
		reversing = false


func _engine_force(speed_abs: float) -> float:
	if reversing:
		var rev_taper := 1.0 - clampf(speed_abs / (top_speed * 0.3), 0.0, 1.0)
		return -input_brake * max_engine_force * reverse_force_scale * rev_taper
	var taper := sqrt(1.0 - clampf(speed_abs / top_speed, 0.0, 1.0))
	return input_throttle * max_engine_force * taper


func _update_wheel(w: CarWheel, space: PhysicsDirectSpaceState3D, delta: float, up: Vector3,
		com: Vector3, engine_force: float, drive_wheels: int, speed_abs: float) -> void:
	var origin := w.global_position
	var ray_len := w.ray_length()
	var query := PhysicsRayQueryParameters3D.create(origin, origin - up * ray_len, GROUND_MASK, [get_rid()])
	var hit := space.intersect_ray(query)

	if hit.is_empty():
		w.grounded = false
		w.compression = 0.0
		w.load = 0.0
		w.slipping = false
		w.slip_lateral = 0.0
		w.slip_ratio = 0.0
		w.spin_speed = speed / w.radius
		w.update_visual(delta)
		w.set_dust(false, Color.WHITE, origin)
		return

	var hit_pos: Vector3 = hit.position
	var normal: Vector3 = hit.normal
	var surface := Surfaces.for_collider(hit.collider)
	var dist := origin.distance_to(hit_pos)
	if surface.bumpiness > 0.0:
		dist += randf_range(-surface.bumpiness, surface.bumpiness) * clampf(speed_abs / 8.0, 0.0, 1.0)

	# --- Suspension ---
	var compression := clampf(ray_len - dist, 0.0, w.suspension_rest)
	var spring_vel := (compression - w.compression) / delta
	w.compression = compression
	w.hit_distance = dist
	var damping := w.damping_bump if spring_vel > 0.0 else w.damping_rebound
	var load := maxf(w.spring_stiffness * compression + damping * spring_vel, 0.0)
	w.grounded = true
	w.load = load
	w.contact_point = hit_pos
	w.contact_normal = normal
	w.blend_surface(surface, delta, surface_blend_time)
	w.surface = surface
	apply_force(up * load, origin - global_position)

	# --- Tyre frame on the contact plane ---
	var wheel_basis := global_transform.basis.rotated(up, w.steer_angle)
	var fwd := -wheel_basis.z
	var right := wheel_basis.x
	fwd = (fwd - normal * fwd.dot(normal)).normalized()
	right = (right - normal * right.dot(normal)).normalized()
	var hub := origin - up * (dist - w.radius)
	var vel := linear_velocity + angular_velocity.cross(hub - com)
	var v_fwd := vel.dot(fwd)
	var v_lat := vel.dot(right)
	var max_friction := tyre_grip * w.grip_eff * load
	var wheel_mass := mass / float(wheels.size())

	# --- Lateral: slip-angle curve, never overshooting what stops the slide this tick ---
	var slip_angle := atan2(v_lat, absf(v_fwd) + 0.6)
	var lat_grip := w.lateral_grip_eff
	if input_handbrake and not w.is_steer:
		lat_grip *= handbrake_lateral_grip
	var f_lat := -tyre_curve(slip_angle / _peak_slip_angle) * max_friction * lat_grip
	var lat_stop := absf(v_lat) * wheel_mass / delta
	f_lat = clampf(f_lat, -lat_stop, lat_stop)

	# --- Longitudinal: drive, brakes, rolling resistance, soft-surface drag ---
	var f_long := 0.0
	if w.is_drive:
		f_long += engine_force / float(drive_wheels)
	var brake := (0.0 if reversing else input_brake) * max_brake_force / float(wheels.size())
	if input_handbrake and not w.is_steer:
		brake += handbrake_force * 0.5
	brake += w.rolling_resistance_eff * load
	var brake_stop := absf(v_fwd) * wheel_mass / delta
	f_long += -signf(v_fwd) * minf(brake, brake_stop)
	f_long += -v_fwd * w.sink_eff * sink_drag

	# --- Friction ellipse, lateral first ---
	# Sideways grip is served before drive/brake so throttle does not push the car wide.
	# Whatever the tyre has left goes to longitudinal force, with a floor so a sliding
	# wheel can still spin up or lock.
	var f := Vector2(f_long, f_lat)
	w.slip_ratio = f.length() / maxf(max_friction, 1.0)
	w.slipping = false
	if max_friction <= 0.0:
		f = Vector2.ZERO
	else:
		f.y = clampf(f.y, -max_friction, max_friction)
		var lat_frac := absf(f.y) / max_friction
		var remaining := sqrt(maxf(1.0 - lat_frac * lat_frac, 0.0))
		var long_limit := max_friction * longitudinal_grip * maxf(remaining, min_drive_fraction)
		if absf(f.x) > long_limit:
			f.x = signf(f.x) * long_limit
			w.slipping = true
	if absf(slip_angle) > _peak_slip_angle * 1.3 and speed_abs > 3.0:
		w.slipping = true
	w.slip_lateral = v_lat
	apply_force(fwd * f.x + right * f.y, hub - global_position)

	# --- Visuals ---
	var spin_v := v_fwd
	if w.slipping and w.is_drive and (input_throttle > 0.5 or reversing):
		spin_v += 9.0 * signf(engine_force)
	w.spin_speed = spin_v / w.radius
	w.update_visual(delta)
	var dust_on := (w.slipping and speed_abs > 2.0) \
			or (surface.dust_speed >= 0.0 and speed_abs > surface.dust_speed)
	w.set_dust(dust_on, surface.dust_color, hit_pos)


## Normalised slip -> normalised force. Rises smoothly to 1.0 at s = 1 (peak grip),
## then eases toward 0.82 for sliding. Odd function so sign is preserved.
static func tyre_curve(s: float) -> float:
	var a := absf(s)
	var y: float
	if a < 1.0:
		y = a * (2.0 - a)
	else:
		y = lerpf(1.0, 0.82, clampf((a - 1.0) * 0.5, 0.0, 1.0))
	return y * signf(s)


func _apply_anti_roll(up: Vector3) -> void:
	var front: Array[CarWheel] = []
	var rear: Array[CarWheel] = []
	for w in wheels:
		if w.position.z < 0.0:
			front.append(w)
		else:
			rear.append(w)
	for axle in [front, rear]:
		if axle.size() != 2:
			continue
		var l: CarWheel = axle[0] if axle[0].position.x < axle[1].position.x else axle[1]
		var r: CarWheel = axle[1] if l == axle[0] else axle[0]
		if not (l.grounded or r.grounded):
			continue
		var force := (l.compression - r.compression) * anti_roll
		if l.grounded:
			apply_force(up * force, l.global_position - global_position)
		if r.grounded:
			apply_force(-up * force, r.global_position - global_position)


func _apply_yaw_damping(up: Vector3) -> void:
	if grounded_wheels == 0:
		return
	var grip := current_surface.grip if current_surface != null else 1.0
	var yaw_rate := angular_velocity.dot(up)
	apply_torque(-up * yaw_rate * yaw_damping * grip * (float(grounded_wheels) / float(wheels.size())))


func _apply_aero(up: Vector3, speed_abs: float) -> void:
	apply_central_force(-linear_velocity * linear_velocity.length() * drag_coefficient)
	if grounded_wheels > 0:
		apply_central_force(-up * downforce * speed_abs * speed_abs)


func _air_stabilize(up: Vector3) -> void:
	# Torque about (up x world_up) rotates the car's up toward world up.
	apply_torque(up.cross(Vector3.UP) * air_stabilize_torque)
	apply_torque(-angular_velocity * 400.0)


func _track_flip(delta: float, up: Vector3) -> void:
	if up.y < 0.2 and linear_velocity.length() < 2.5:
		_flipped_time += delta
		if _flipped_time > flip_recover_time:
			right_in_place()
	else:
		_flipped_time = 0.0


func _pick_dominant_surface(votes: Dictionary) -> void:
	var best: SurfaceType = null
	var best_n := 0
	for s in votes:
		if votes[s] > best_n:
			best_n = votes[s]
			best = s
	if best != null:
		current_surface = best


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var strongest := 0.0
	var other: Object = null
	for i in state.get_contact_count():
		var imp := state.get_contact_impulse(i).length()
		if imp > strongest:
			strongest = imp
			other = state.get_contact_collider_object(i)
	if strongest > impact_threshold and _impact_cooldown <= 0.0:
		_impact_cooldown = 0.25
		if other is RaycastCar:
			hits += 1
		impact.emit(strongest, other as Node)


## Teleport to a transform with zero velocity (used for resets and grid placement).
func reset_to(t: Transform3D) -> void:
	global_transform = t
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	steer = 0.0
	_flipped_time = 0.0
	for w in wheels:
		w.compression = 0.0


## Flip upright where the car is, keeping its heading.
func right_in_place() -> void:
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.01:
		fwd = Vector3.FORWARD
	var t := Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), global_position + Vector3.UP * 1.2)
	reset_to(t)


## Average of how hard the tyres are working, 0 = coasting, 1 = at the limit.
func grip_usage() -> float:
	var total := 0.0
	var n := 0
	for w in wheels:
		if w.grounded:
			total += minf(w.slip_ratio, 1.5)
			n += 1
	return total / float(n) if n > 0 else 0.0
