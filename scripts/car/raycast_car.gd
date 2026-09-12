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
signal damaged(amount: float)
signal wrecked
signal repaired

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
@export var steer_speed := 6.0              ## How fast the wheels turn toward the input (1/s)
@export var steer_return_speed := 9.0
@export var high_speed_steer_scale := 0.38  ## Steering authority left at top speed

@export_group("Tyres")
@export var tyre_grip := 1.15               ## Base friction coefficient on asphalt
@export var peak_slip_angle_deg := 7.5      ## Slip angle at peak lateral grip
@export_range(0.0, 1.0) var slide_falloff := 0.78  ## Grip left once the tyre is sliding, as a fraction of peak
@export var longitudinal_grip := 1.1        ## Drive/brake friction relative to lateral friction
## How much sideways grip is protected when drive/brake and cornering compete for the tyre.
## 0 = everything scales down together (throttle steals cornering grip, power oversteer),
## 1 = cornering always wins (throttle can never push the car wide or spin it).
@export_range(0.0, 1.0) var lateral_priority := 0.3
@export var min_drive_fraction := 0.25      ## Drive/brake capacity kept while sliding sideways
@export var surface_blend_time := 0.15      ## Seconds for a terrain change to fade in per wheel
@export var sink_drag := 55.0               ## N per (m/s) per wheel on a surface with sink = 1

@export_group("Chassis")
@export var anti_roll := 9000.0             ## N per metre of compression difference per axle
@export var yaw_damping := 1200.0           ## N*m per rad/s of yaw rate while grounded; settles the tail
@export var drag_coefficient := 2.0         ## N per (m/s)^2
@export var downforce := 1.2                ## N per (m/s)^2
@export var air_stabilize_torque := 2500.0  ## Self-righting torque when airborne
@export var flip_recover_time := 2.5        ## Seconds upside-down before auto-righting
@export var impact_threshold := 1500.0      ## Contact impulse (N*s) that counts as a hit

@export_group("Damage")
@export var max_health := 100.0
@export var damage_soft_threshold := 1800.0 ## Sideways impulse (N*s) below which a hit is free
@export var damage_per_impulse := 1.0 / 430.0 ## Health lost per N*s above the threshold
@export var max_damage_per_hit := 18.0
@export var static_damage_scale := 0.4      ## Walls and rocks hurt less than cars
## How hard you were travelling matters as much as how hard you were hit: a hit at
## `damage_speed_ref` does its rated damage, a crawl does `damage_speed_floor` of it, and a
## flat-out shunt up to `damage_speed_ceiling` times as much.
@export var damage_speed_ref := 28.0
@export var damage_speed_floor := 0.35
@export var damage_speed_ceiling := 1.5
## Health above this fraction drives exactly like a fresh car. Dents are cosmetic until you
## are genuinely in trouble; below it, the losses below ramp in to their full value at zero.
@export_range(0.0, 1.0) var damage_grace := 0.5
@export var power_loss_when_wrecked := 0.28 ## Fraction of engine force lost at zero health
@export var speed_loss_when_wrecked := 0.12
@export var pull_when_wrecked := 0.07       ## Steering bias toward the damaged side at zero health

var paint_color := Color(0.9, 0.2, 0.15)

# Damage and gadget state.
var health := 100.0
var pull_sign := 1.0             ## Which way a damaged car pulls: +1 right, -1 left
var shielded := false            ## Immune, and throws anyone who touches us
var invulnerable := 0.0          ## Seconds of damage immunity left after a reset
var engine_multiplier := 1.0     ## Set by gadgets (boost)
var speed_multiplier := 1.0
var _paint_mat: ShaderMaterial

# Inputs, written by a driver each tick.
var input_throttle := 0.0      # 0..1
var input_brake := 0.0         # 0..1 (doubles as reverse when stopped)
var input_steer := 0.0         # -1 left .. +1 right
var input_handbrake := false
## While true the car ignores its driver and sits on the brakes (grid hold before GO).
var controls_locked := false

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
	health = max_health
	_apply_paint()
	_update_damage_visuals()


func _apply_paint() -> void:
	var paint := ToonMaterial.make(paint_color, 3.0, 0.5, 0.3)
	_paint_mat = paint
	var dark := ToonMaterial.make(Color(0.12, 0.12, 0.13), 2.0, 0.6, 0.0)
	for m in $Visual.get_children():
		if m is MeshInstance3D:
			m.material_override = paint
	for w in wheels:
		for m in w.visual.get_children():
			if m is MeshInstance3D:
				m.material_override = dark


func _physics_process(delta: float) -> void:
	if controls_locked:
		# Hold on the handbrake, not the foot brake: brake-while-stopped means reverse.
		input_throttle = 0.0
		input_steer = 0.0
		input_brake = 0.0
		input_handbrake = true
		reversing = false
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
	($ShieldBubble as MeshInstance3D).visible = shielded
	_pick_dominant_surface(surface_votes)

	if grounded_wheels == 0:
		_air_stabilize(up)
	_track_flip(delta, up)
	_impact_cooldown = maxf(0.0, _impact_cooldown - delta)
	if invulnerable > 0.0:
		invulnerable = maxf(invulnerable - delta, 0.0)
		# Blink while it lasts, so it is obvious the car cannot be hurt yet.
		($Visual as Node3D).visible = invulnerable <= 0.0 or fmod(invulnerable, 0.24) > 0.12


func _update_steering(delta: float, speed_abs: float) -> void:
	var wanted := input_steer
	if speed_abs > 3.0:
		wanted += pull_sign * pull_when_wrecked * handling_penalty()
	var rate := steer_speed if absf(wanted) > absf(steer) else steer_return_speed
	steer = move_toward(steer, clampf(wanted, -1.0, 1.0), rate * delta)
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


## Top speed after damage and any boost.
func effective_top_speed() -> float:
	return top_speed * speed_multiplier * (1.0 - speed_loss_when_wrecked * handling_penalty())


func _engine_force(speed_abs: float) -> float:
	var force := max_engine_force * engine_multiplier * (1.0 - power_loss_when_wrecked * handling_penalty())
	var top := effective_top_speed()
	if reversing:
		var rev_taper := 1.0 - clampf(speed_abs / (top * 0.3), 0.0, 1.0)
		return -input_brake * force * reverse_force_scale * rev_taper
	var taper := sqrt(1.0 - clampf(speed_abs / top, 0.0, 1.0))
	return input_throttle * force * taper


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
	var bump := surface.bumpiness + 0.02 * handling_penalty()
	if bump > 0.0:
		dist += randf_range(-bump, bump) * clampf(speed_abs / 8.0, 0.0, 1.0)

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
	var f_lat := -tyre_curve(slip_angle / _peak_slip_angle, slide_falloff) * max_friction * lat_grip
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

	# --- Friction ellipse ---
	# Two ways to resolve drive/brake competing with cornering for the same tyre, blended by
	# lateral_priority. Proportional: both shrink together, so throttle steals cornering grip
	# and the tail can step out. Lateral-first: cornering is served first and drive gets what
	# is left (with a floor so a sliding wheel can still spin up or lock).
	var f := Vector2(f_long, f_lat)
	w.slip_ratio = Vector2(f.x / longitudinal_grip, f.y).length() / maxf(max_friction, 1.0)
	w.slipping = false
	if max_friction <= 0.0:
		f = Vector2.ZERO
	else:
		var proportional := f
		var ellipse_demand := Vector2(f.x / longitudinal_grip, f.y).length()
		if ellipse_demand > max_friction:
			proportional = f * (max_friction / ellipse_demand)
			w.slipping = true
		var lateral_first := f
		lateral_first.y = clampf(f.y, -max_friction, max_friction)
		var lat_frac := absf(lateral_first.y) / max_friction
		var remaining := sqrt(maxf(1.0 - lat_frac * lat_frac, 0.0))
		var long_limit := max_friction * longitudinal_grip * maxf(remaining, min_drive_fraction)
		if absf(lateral_first.x) > long_limit:
			lateral_first.x = signf(f.x) * long_limit
			w.slipping = true
		# A wheel being locked by the handbrake gets no protection: it is meant to slide.
		var priority := 0.0 if (input_handbrake and not w.is_steer) else lateral_priority
		f = proportional.lerp(lateral_first, priority)
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
## then eases toward `falloff` for sliding. Odd function so sign is preserved.
static func tyre_curve(s: float, falloff: float = 0.78) -> float:
	var a := absf(s)
	var y: float
	if a < 1.0:
		y = a * (2.0 - a)
	else:
		y = lerpf(1.0, falloff, clampf((a - 1.0) * 0.5, 0.0, 1.0))
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
	# Only the part of the impulse across the car counts: landing a jump is not a crash.
	var up := global_transform.basis.y
	var strongest := 0.0
	var other: Object = null
	var side := 0.0
	for i in state.get_contact_count():
		var imp := state.get_contact_impulse(i)
		var across := (imp - up * imp.dot(up)).length()
		if across > strongest:
			strongest = across
			other = state.get_contact_collider_object(i)
			side = state.get_contact_local_position(i).x
	if strongest > impact_threshold and _impact_cooldown <= 0.0:
		_impact_cooldown = 0.25
		var is_car := other is RaycastCar
		if is_car:
			hits += 1
		impact.emit(strongest, other as Node)
		if shielded:
			if is_car:
				call_deferred("_shield_throw", other)
		else:
			take_damage(impact_damage(strongest, absf(speed), is_car), side)


## A shielded car throws whoever runs into it, and hurts them doing it.
func _shield_throw(other: RaycastCar) -> void:
	if not is_instance_valid(other):
		return
	var away := other.global_position - global_position
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = -global_transform.basis.z
	away = away.normalized() + Vector3.UP * 0.35
	other.apply_central_impulse(away.normalized() * other.mass * 7.5)
	other.apply_torque_impulse(Vector3.UP * other.mass * randf_range(-3.0, 3.0))
	other.take_damage(8.0, -sign(other.to_local(global_position).x))


# ---------------------------------------------------------------- damage

## How beaten up the car looks: 0 fresh, 1 at zero health.
func damage_fraction() -> float:
	return 1.0 - clampf(health / max_health, 0.0, 1.0)


## How beaten up the car drives: 0 anywhere above the grace band, ramping to 1 at zero
## health. Kept apart from damage_fraction() so a car can carry visible dents and still
## handle properly.
func handling_penalty() -> float:
	var left := clampf(health / max_health, 0.0, 1.0)
	return clampf((damage_grace - left) / maxf(damage_grace, 0.001), 0.0, 1.0)


## Health lost from one impact: how hard it caught us across the car, scaled by how fast we
## were going, and softened for walls and scenery.
func impact_damage(across_impulse: float, speed_abs: float, from_car: bool) -> float:
	var raw := (across_impulse - damage_soft_threshold) * damage_per_impulse
	if raw <= 0.0:
		return 0.0
	var speed_scale := clampf(speed_abs / damage_speed_ref, damage_speed_floor, damage_speed_ceiling)
	var dmg := clampf(raw * speed_scale, 0.0, max_damage_per_hit)
	return dmg if from_car else dmg * static_damage_scale


func is_wrecked() -> bool:
	return health <= 0.0


## `side` is the local x of the contact: positive means the right flank took it.
func take_damage(amount: float, side: float = 0.0) -> void:
	if amount <= 0.0 or shielded or invulnerable > 0.0:
		return
	var was_alive := health > 0.0
	health = maxf(health - amount, 0.0)
	if side != 0.0:
		pull_sign = signf(side)
	damaged.emit(amount)
	if was_alive and health <= 0.0:
		wrecked.emit()
	_update_damage_visuals()


func repair() -> void:
	if health >= max_health:
		return
	health = max_health
	repaired.emit()
	_update_damage_visuals()


func _update_damage_visuals() -> void:
	var d := damage_fraction()
	if _paint_mat != null:
		_paint_mat.set_shader_parameter("albedo", paint_color.lerp(Color(0.22, 0.21, 0.20), d * 0.85))
	$Visual.rotation.z = deg_to_rad(4.0) * handling_penalty() * pull_sign
	var smoke := $Smoke as CPUParticles3D
	smoke.emitting = d > 0.5
	smoke.amount = 18 if d < 0.8 else 34
	($ShieldBubble as MeshInstance3D).visible = shielded


## Hop: straight up with a little forward carry. Only from the ground.
func jump(strength: float = 6.8) -> void:
	if grounded_wheels < 2:
		return
	var fwd := -global_transform.basis.z
	apply_central_impulse((Vector3.UP * strength + fwd * 1.2) * mass)


var gadget_slot: GadgetSlot:
	get:
		return $GadgetSlot as GadgetSlot


## Teleport to a transform with zero velocity (used for resets and grid placement).
## About 40 mph. A reset that leaves you stopped in the middle of a race just hands the
## pack a stationary target, so a recovered car rejoins already rolling.
const RESET_SPEED := 17.9
const RESET_INVULN := 2.5        ## Seconds of immunity after a reset

## Put the car back on the road already moving, with a moment of immunity so it is not
## wiped out again before it has had a chance to go anywhere.
func respawn_at(t: Transform3D, launch_speed: float = RESET_SPEED, invuln: float = RESET_INVULN) -> void:
	reset_to(t)
	if not controls_locked:
		linear_velocity = -t.basis.z * launch_speed
		speed = launch_speed
	invulnerable = maxf(invulnerable, invuln)
	_impact_cooldown = maxf(_impact_cooldown, 0.25)
	_update_damage_visuals()


func reset_to(t: Transform3D) -> void:
	global_transform = t
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	steer = 0.0
	_flipped_time = 0.0
	invulnerable = 0.0
	($Visual as Node3D).visible = true
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
