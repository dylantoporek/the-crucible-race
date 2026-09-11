class_name SprintTrack
extends Node3D
## Point-to-point sprint course built from RouteSpec.STAGES.
##
## The route is generated rather than hand-placed: each stage contributes a length, a net
## heading change, a local S-bend wiggle and an elevation profile, which are integrated into
## a control-point path. That path becomes an open Curve3D; the road is then extruded along
## it with a per-offset width, split into one body per surface run so each stretch carries
## its own SurfaceType, and dressed with the hazards each stage asks for.

const SAMPLE_STEP := 2.5          ## Distance between road cross-sections, metres.
const CONTROL_STEP := 22.0        ## Distance between generated curve control points, metres.
const TRANSITION_LENGTH := 34.0   ## Length of a surface blend zone, metres.
const TRANSITION_BANDS := 6       ## Discrete grip steps inside a blend zone.
const SHOULDER_WIDTH := 4.0
const WALL_HEIGHT := 1.15
const GROUND_MASK := 0b101        ## world + props, matching RaycastCar.

## Search window and steps for the cached per-body offset lookup, metres.
## The S-bend is two harmonics so it does not read as a pure sine. WIGGLE_K is how much
## harder the pair corners than a single sine of the same amplitude, which is what lets a
## stage's min_radius be turned into an amplitude.
const WIGGLE_W1 := 0.72
const WIGGLE_W2 := 0.28
const WIGGLE_R2 := 0.41
const WIGGLE_K := WIGGLE_W1 + WIGGLE_W2 / WIGGLE_R2

## How far along the course the gap through a hazard field takes to sway across and back.
const GATE_PERIOD := 210.0
## How far before a hall the lane split starts steering drivers to one side.
const HALL_APPROACH := 70.0

## Fraction of ice's own traction limit that a patch's gradient may reach.
const ICE_PATCH_GRADE_MARGIN := 0.5

## Obstacle colours are kept dark so they read against the pale surfaces they stand on.
const STONE := Color(0.34, 0.29, 0.25)
const STONE_LIGHT := Color(0.44, 0.38, 0.32)
const ROCK := Color(0.28, 0.27, 0.26)
const ICE_BORDER := Color(0.16, 0.36, 0.58)

const CURSOR_RADIUS := 12.0
const CURSOR_COARSE_STEP := 2.0
const CURSOR_FINE_STEP := 0.25

@export var seed_value := 20260908

var curve := Curve3D.new()
var length := 0.0                 ## Total curve length including run-up and run-off.
var start_offset := 0.0           ## Where the start line sits.
var finish_offset := 0.0          ## Where the finish line sits.
var race_length := 0.0            ## finish_offset - start_offset.

var _rng := RandomNumberGenerator.new()
var _frames: Array[Dictionary] = []
var _stages: Array[Dictionary] = []      ## per stage: spec, a, b (offsets)
var _surface_runs: Array = []            ## [a, b, SurfaceType], blend bands included
var _boundaries: Array[float] = []       ## centre offset of each surface change
var _width_keys: Array = []              ## [offset, half_width] at stage edges
var _mogul_zones: Array = []             ## [a, b, amp, wave]
var _gates: Array = []                   ## [a, b, period, sway, gap_half] — clear line through hazards
var _halls: Array = []                   ## [a, b] — ruined halls with a colonnade down the centre
var _repair_stations: Array = []          ## [offset, lateral] for the AI to aim at
var _pickups: Array[PickupBox] = []
var _ground_y := 0.0                     ## Height of the plate under the whole course.
var _ground_centre := Vector2.ZERO
var _ground_span := 0.0
var _cursor_offset: Dictionary = {}
var _cursor_frame: Dictionary = {}


func _ready() -> void:
	_rng.seed = seed_value
	_generate_path()
	_sample_frames()
	_plan_surfaces()
	_compute_ground_level()
	_build_road()
	_build_shoulders_and_walls()
	_build_ground()
	_build_features()
	_build_pickups()
	_build_start_and_finish()


# ---------------------------------------------------------------- generation

## Integrate the stage table into a control-point path, recording where each stage starts
## and ends and how wide it is, then feed the points to an open Curve3D.
func _generate_path() -> void:
	var pts: Array[Vector3] = []
	var pos := Vector2.ZERO
	var heading := -PI * 0.5          # start facing -Z
	var y := 0.0
	var travelled := 0.0

	# Straight run-up so the grid has room behind the start line.
	var steps := int(RouteSpec.START_RUN_UP / CONTROL_STEP)
	for i in steps:
		pts.append(Vector3(pos.x, y, pos.y))
		pos += Vector2(cos(heading), sin(heading)) * CONTROL_STEP
		travelled += CONTROL_STEP
	start_offset = travelled

	for spec in RouteSpec.STAGES:
		var stage_len: float = float(spec["seconds"]) * float(spec["speed"])
		var n := maxi(int(stage_len / CONTROL_STEP), 4)
		var step := stage_len / float(n)
		var base_y := y
		var climb: float = spec.get("climb", 0.0)
		var tech: Dictionary = spec.get("tech", {})
		var stage_start := travelled

		# Spend the gradient budget: the climb takes its share first, rolling hills get the rest.
		var max_grade: float = spec.get("max_grade", 0.12)
		var hills_wave: float = spec.get("hills_wave", 320.0)
		var climb_grade: float = ELEV_PEAK_FACTOR * absf(climb) / stage_len
		var hills_amp: float = maxf(max_grade - climb_grade, 0.0) * hills_wave / TAU
		if climb_grade > max_grade:
			push_warning("Stage '%s' climbs %.0f m in %.0f m (%.0f%%), over its %.0f%% budget." % [
					spec["name"], climb, stage_len, climb_grade * 100.0, max_grade * 100.0])

		for i in n:
			var t := float(i) / float(n)
			# Heading: a steady net turn plus a local S-bend whose amplitude comes from the
			# tightest corner the stage allows, tightened further over tech stretches.
			var radius: float = spec.get("min_radius", 120.0)
			var bend_len: float = spec.get("bend_len", 220.0)
			if not tech.is_empty() and t >= float(tech["from"]) and t <= float(tech["to"]):
				radius = float(tech["min_radius"])
				bend_len = float(tech["bend_len"])
			var amp := bend_len / (TAU * maxf(radius, 1.0) * WIGGLE_K)
			var d := travelled
			var wiggle: float = amp * (
					sin(d / bend_len * TAU) * WIGGLE_W1
					+ sin(d / (bend_len * WIGGLE_R2) * TAU + 1.7) * WIGGLE_W2)
			heading += deg_to_rad(float(spec["turn"])) / float(n)

			pts.append(Vector3(pos.x, y, pos.y))
			var dir := heading + wiggle
			pos += Vector2(cos(dir), sin(dir)) * step
			travelled += step

			var tn := float(i + 1) / float(n)
			y = base_y + climb * _elev_ease(tn) + hills_amp * sin(travelled / hills_wave * TAU)

		_stages.append({"spec": spec, "a": stage_start, "b": travelled,
				"min_radius": float(spec.get("min_radius", 120.0)),
				"grade": climb_grade + hills_amp * TAU / hills_wave})

	finish_offset = travelled

	# Straight run-off past the finish.
	steps = int(RouteSpec.FINISH_RUN_OFF / CONTROL_STEP)
	for i in steps:
		pts.append(Vector3(pos.x, y, pos.y))
		pos += Vector2(cos(heading), sin(heading)) * CONTROL_STEP
	pts.append(Vector3(pos.x, y, pos.y))

	curve.clear_points()
	curve.bake_interval = 1.5
	var n_pts := pts.size()
	for i in n_pts:
		var prev: Vector3 = pts[maxi(i - 1, 0)]
		var next: Vector3 = pts[mini(i + 1, n_pts - 1)]
		var tangent := (next - prev) * 0.25
		curve.add_point(pts[i], -tangent, tangent)
	length = curve.get_baked_length()

	# Scale the recorded stage offsets from planned distance onto real baked length.
	var planned := travelled + RouteSpec.FINISH_RUN_OFF
	var k := length / maxf(planned, 1.0)
	start_offset *= k
	finish_offset *= k
	for st in _stages:
		st["a"] *= k
		st["b"] *= k
	race_length = finish_offset - start_offset

	# Width keyframes at stage edges, plus any arena widening.
	_width_keys.clear()
	_width_keys.append([0.0, float(RouteSpec.STAGES[0]["half_width"])])
	for st in _stages:
		var spec: Dictionary = st["spec"]
		var hw := float(spec["half_width"])
		_width_keys.append([float(st["a"]), hw])
		var arena: Dictionary = spec.get("features", {}).get("arena", {})
		if arena.is_empty():
			_width_keys.append([float(st["b"]), hw])
		else:
			var at: float = lerpf(st["a"], st["b"], float(arena["from"]))
			_width_keys.append([at, hw])
			_width_keys.append([at + RouteSpec.WIDTH_BLEND, float(arena["half_width"])])
			_width_keys.append([length, float(arena["half_width"])])
	_width_keys.append([length, float(RouteSpec.STAGES[-1]["half_width"])])
	_width_keys.sort_custom(func(a, b): return a[0] < b[0])

	# Mogul zones, in absolute offsets.
	_mogul_zones.clear()
	for st in _stages:
		var m: Dictionary = st["spec"].get("features", {}).get("moguls", {})
		if m.is_empty():
			continue
		_mogul_zones.append([lerpf(st["a"], st["b"], float(m["from"])),
				lerpf(st["a"], st["b"], float(m["to"])), float(m["amp"]), float(m["wave"])])


## Elevation eases in and out over the first and last fifth of a stage and runs straight
## between, so the steepest gradient is only ELEV_PEAK_FACTOR times the stage average
## instead of the 1.5x a smoothstep would give.
const ELEV_EASE := 0.2
const ELEV_PEAK_FACTOR := 1.0 / (1.0 - ELEV_EASE)

static func _elev_ease(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	if t <= ELEV_EASE:
		return t * t / (2.0 * ELEV_EASE * (1.0 - ELEV_EASE))
	if t >= 1.0 - ELEV_EASE:
		var u := 1.0 - t
		return 1.0 - u * u / (2.0 * ELEV_EASE * (1.0 - ELEV_EASE))
	return (t - ELEV_EASE * 0.5) / (1.0 - ELEV_EASE)


## Half-width of the road at an offset, easing across stage boundaries.
func width_at(offset: float) -> float:
	var n := _width_keys.size()
	for i in range(n - 1):
		var a: Array = _width_keys[i]
		var b: Array = _width_keys[i + 1]
		if offset < a[0] or offset > b[0]:
			continue
		if is_equal_approx(a[1], b[1]):
			return a[1]
		var span: float = maxf(b[0] - a[0], 0.001)
		var blend: float = minf(RouteSpec.WIDTH_BLEND, span)
		var t: float = clampf((offset - a[0]) / blend, 0.0, 1.0)
		return lerpf(a[1], b[1], smoothstep(0.0, 1.0, t))
	return _width_keys[-1][1] if n > 0 else 8.0


## Local gradient of the road at an offset, as a fraction (0.2 = 20%).
func grade_at(offset: float) -> float:
	var d := 6.0
	var a := frame_at(clampf(offset - d, 0.0, length))
	var b := frame_at(clampf(offset + d, 0.0, length))
	var run: float = Vector2(b.pos.x - a.pos.x, b.pos.z - a.pos.z).length()
	return (b.pos.y - a.pos.y) / maxf(run, 0.001)


## Where the clear line runs through a hazard field, as (lane centre, half-width of the gap).
## A zero half-width means there is nothing to dodge here. Drivers use this to thread the
## ruins rather than driving into a column. Inside a hall the road is split in two by the
## colonnade, so the gap returned is the lane on the side of `prefer_lateral`.
func hazard_gate(offset: float, prefer_lateral: float = 0.0) -> Vector2:
	for h in _halls:
		if offset >= h[0] - HALL_APPROACH and offset <= h[1]:
			var hw := width_at(offset)
			var side := 1.0 if prefer_lateral >= 0.0 else -1.0
			return Vector2(side * hw * 0.5, hw * 0.5 - 2.8)
	for g in _gates:
		if offset >= g[0] and offset <= g[1]:
			return Vector2(sin(offset / g[2] * TAU) * g[3], g[4])
	return Vector2.ZERO


func in_hall(offset: float) -> bool:
	for h in _halls:
		if offset >= h[0] and offset <= h[1]:
			return true
	return false


## Vertical displacement of the road surface at an offset — the moguls.
func bump_at(offset: float) -> float:
	var total := 0.0
	for z in _mogul_zones:
		if offset < z[0] or offset > z[1]:
			continue
		var t: float = (offset - z[0]) / maxf(z[1] - z[0], 0.001)
		var fade: float = sin(clampf(t, 0.0, 1.0) * PI)      # ease in and out of the zone
		total += z[2] * fade * sin(offset / z[3] * TAU)
	return total


# ---------------------------------------------------------------- frames

func frame_at(offset: float) -> Dictionary:
	offset = clampf(offset, 0.0, length)
	var pos := curve.sample_baked(offset, true)
	var ahead := curve.sample_baked(clampf(offset + 0.75, 0.0, length), true)
	var behind := curve.sample_baked(clampf(offset - 0.75, 0.0, length), true)
	var tangent := ahead - behind
	if tangent.length_squared() < 1.0e-6:
		tangent = Vector3.FORWARD
	tangent = tangent.normalized()
	var right := tangent.cross(Vector3.UP).normalized()
	var up := right.cross(tangent).normalized()
	return {"pos": pos, "tangent": tangent, "right": right, "up": up, "offset": offset}


func _sample_frames() -> void:
	_frames.clear()
	var o := 0.0
	while o < length:
		_frames.append(frame_at(o))
		o += SAMPLE_STEP
	_frames.append(frame_at(length))


func _frame_index_at(offset: float) -> int:
	return clampi(int(floor(offset / SAMPLE_STEP)), 0, _frames.size() - 1)


# ---------------------------------------------------------------- surfaces

## Expand each stage's surface shares into runs, then insert a blend band at every change.
func _plan_surfaces() -> void:
	var runs: Array = []
	for st in _stages:
		var spec: Dictionary = st["spec"]
		var a: float = st["a"]
		var b: float = st["b"]
		var shares: Array = spec["surfaces"]
		var total := 0.0
		for s in shares:
			total += float(s[1])
		var cursor := a
		for i in shares.size():
			var frac: float = float(shares[i][1]) / maxf(total, 0.001)
			var end: float = b if i == shares.size() - 1 else cursor + (b - a) * frac
			runs.append([cursor, end, Surfaces.get_type(shares[i][0])])
			cursor = end
	# The run-up shares the first stage's surface; the run-off shares the last.
	runs[0][0] = 0.0
	runs[-1][1] = length

	# Merge neighbouring runs of the same surface so we do not blend a surface into itself.
	var merged: Array = []
	for r in runs:
		if not merged.is_empty() and merged[-1][2] == r[2]:
			merged[-1][1] = r[1]
		else:
			merged.append([r[0], r[1], r[2]])

	_surface_runs.clear()
	_boundaries.clear()
	var half := TRANSITION_LENGTH * 0.5
	var band := TRANSITION_LENGTH / float(TRANSITION_BANDS)
	for i in merged.size():
		var run: Array = merged[i]
		var a: float = run[0] + (half if i > 0 else 0.0)
		var b: float = run[1] - (half if i < merged.size() - 1 else 0.0)
		_surface_runs.append([a, b, run[2]])
		if i < merged.size() - 1:
			var nxt: SurfaceType = merged[i + 1][2]
			_boundaries.append(run[1])
			for k in TRANSITION_BANDS:
				var t := (float(k) + 0.5) / float(TRANSITION_BANDS)
				_surface_runs.append([b + k * band, b + (k + 1) * band, Surfaces.blend(run[2], nxt, t)])


func surface_at(offset: float) -> SurfaceType:
	for r in _surface_runs:
		if offset >= r[0] and offset < r[1]:
			return r[2]
	return Surfaces.default_surface


## The stage covering an offset, for HUD labels and debugging.
func stage_at(offset: float) -> Dictionary:
	for st in _stages:
		if offset >= st["a"] and offset < st["b"]:
			return st["spec"]
	if offset < _stages[0]["a"]:
		return _stages[0]["spec"]
	return _stages[-1]["spec"]


func stages() -> Array[Dictionary]:
	return _stages


# ---------------------------------------------------------------- queries

func offset_of(global_pos: Vector3) -> float:
	return curve.get_closest_offset(to_local(global_pos))


## Offset for a moving body, cached per physics frame and found by searching near where the
## body was last tick. Falls back to the full scan on a miss, reset or teleport.
func track_offset(body: Node3D) -> float:
	var id := body.get_instance_id()
	var frame := Engine.get_physics_frames()
	if _cursor_frame.get(id, -1) == frame:
		return _cursor_offset[id]
	var offset: float
	if _cursor_offset.has(id):
		offset = _offset_near(body.global_position, _cursor_offset[id])
	else:
		offset = offset_of(body.global_position)
		_prune_cursors()
	_cursor_offset[id] = offset
	_cursor_frame[id] = frame
	return offset


func _offset_near(global_pos: Vector3, hint: float) -> float:
	var local := to_local(global_pos)
	var best := hint
	var best_d := INF
	var o := hint - CURSOR_RADIUS
	while o <= hint + CURSOR_RADIUS:
		var d := local.distance_squared_to(curve.sample_baked(clampf(o, 0.0, length), true))
		if d < best_d:
			best_d = d
			best = o
		o += CURSOR_COARSE_STEP
	if absf(best - hint) >= CURSOR_RADIUS - CURSOR_COARSE_STEP * 0.5:
		return offset_of(global_pos)
	var fine := best
	o = best - CURSOR_COARSE_STEP
	while o <= best + CURSOR_COARSE_STEP:
		var d := local.distance_squared_to(curve.sample_baked(clampf(o, 0.0, length), true))
		if d < best_d:
			best_d = d
			fine = o
		o += CURSOR_FINE_STEP
	return clampf(fine, 0.0, length)


## Forget a body's cached offset after it has been moved, so the next lookup starts fresh
## instead of trusting a position from before the teleport.
func invalidate_cursor(body: Node3D) -> void:
	var id := body.get_instance_id()
	_cursor_offset.erase(id)
	_cursor_frame.erase(id)


func _prune_cursors() -> void:
	for id in _cursor_offset.keys():
		if not is_instance_valid(instance_from_id(id)):
			_cursor_offset.erase(id)
			_cursor_frame.erase(id)


## 0 at the start line, 1 at the finish line.
func body_progress(body: Node3D) -> float:
	return clampf((track_offset(body) - start_offset) / maxf(race_length, 1.0), 0.0, 1.0)


func progress_of(global_pos: Vector3) -> float:
	return clampf((offset_of(global_pos) - start_offset) / maxf(race_length, 1.0), 0.0, 1.0)


func lateral_offset_at(global_pos: Vector3, offset: float) -> float:
	var f := frame_at(offset)
	return (to_local(global_pos) - f.pos).dot(f.right)


func lateral_offset(global_pos: Vector3) -> float:
	return lateral_offset_at(global_pos, offset_of(global_pos))


func distance_from_center_at(global_pos: Vector3, offset: float) -> float:
	return absf(lateral_offset_at(global_pos, offset))


func distance_from_center(global_pos: Vector3) -> float:
	return absf(lateral_offset(global_pos))


## Height of the driving surface, moguls included, at an offset.
func surface_point(offset: float, lateral: float) -> Vector3:
	var f := frame_at(offset)
	var p: Vector3 = f.pos + f.right * lateral
	p.y += bump_at(offset)
	return p


## Put a car back on the road near where it is now. `advance` moves it a little further up
## the course so it does not land back against whatever stopped it.
func snap_to_track(global_pos: Vector3, advance: float = 0.0) -> Transform3D:
	var off := clampf(offset_of(global_pos) + advance, 0.0, length)
	var f := frame_at(off)
	var hw := width_at(off)
	var lane := clampf(lateral_offset_at(global_pos, off), -hw + 2.0, hw - 2.0)
	# Inside a hazard field, drop it in the gap rather than back among the columns.
	var gate: Vector2 = hazard_gate(off, lane)
	if gate.y > 0.0:
		lane = clampf(lane, gate.x - gate.y + 2.0, gate.x + gate.y - 2.0)
	var origin: Vector3 = to_global(surface_point(off, lane) + Vector3.UP * 1.4)
	return Transform3D(Basis.looking_at(global_transform.basis * f.tangent, Vector3.UP), origin)


## Two-wide grid behind a line (the start by default, or any stage start for testing).
## Index 0 is front-left.
func get_grid_transform(index: int, line_offset: float = -1.0) -> Transform3D:
	if line_offset < 0.0:
		line_offset = start_offset
	@warning_ignore("integer_division")
	var row := index / 2
	var col := index % 2
	var off := maxf(line_offset - 12.0 - row * 9.5, 4.0)
	var f := frame_at(off)
	var lane := -3.4 if col == 0 else 3.4
	var gate: Vector2 = hazard_gate(off, lane)
	if gate.y > 0.0:
		lane = gate.x + signf(lane) * minf(3.4, maxf(gate.y - 2.0, 0.0))
	var origin: Vector3 = to_global(surface_point(off, lane) + Vector3.UP * 1.0)
	return Transform3D(Basis.looking_at(global_transform.basis * f.tangent, Vector3.UP), origin)


# ---------------------------------------------------------------- geometry helpers

## Left and right edge vertices of the road at a frame, width and moguls applied.
func _road_corners(f: Dictionary, extra: float = 0.0) -> Array:
	var off: float = f["offset"]
	var w: float = width_at(off) + extra
	var lift := Vector3.UP * bump_at(off)
	return [f["pos"] - f["right"] * w + lift, f["pos"] + f["right"] * w + lift]


## Extrude a quad strip between frame indices [i0, i1]; `corners` maps a frame to [left, right].
func _strip(st: SurfaceTool, i0: int, i1: int, corners: Callable) -> void:
	for i in range(i0, i1):
		var a: Dictionary = _frames[i]
		var b: Dictionary = _frames[i + 1]
		var qa: Array = corners.call(a)
		var qb: Array = corners.call(b)
		var n: Vector3 = a["up"]
		for v in [qa[0], qb[0], qb[1], qa[0], qb[1], qa[1]]:
			st.set_normal(n)
			st.add_vertex(v)


func _make_body(mesh: ArrayMesh, color: Color, surface_id: StringName, body_name: String,
		bands := 3.0, shadow_floor := 0.45) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = 1
	body.collision_mask = 0
	body.set_meta(&"surface", surface_id)
	var shape := CollisionShape3D.new()
	var tri := mesh.create_trimesh_shape()
	tri.backface_collision = true
	shape.shape = tri
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = ToonMaterial.make(color, bands, shadow_floor, 0.0)
	body.add_child(mi)
	add_child(body)
	return body


## A solid obstacle: collides with cars, carries no driving surface of its own.
func _make_obstacle(mesh: Mesh, shape: Shape3D, xform: Transform3D, color: Color,
		body_name: String) -> void:
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = 1
	body.collision_mask = 0
	body.transform = xform
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = ToonMaterial.make(color, 3.0, 0.34, 0.06)
	body.add_child(mi)
	add_child(body)


# ---------------------------------------------------------------- road & scenery

func _build_road() -> void:
	var corners := func(f: Dictionary) -> Array: return _road_corners(f)
	var idx := 0
	for run in _surface_runs:
		var i0 := _frame_index_at(run[0])
		var i1 := _frame_index_at(run[1]) if run[1] < length else _frames.size() - 1
		if i1 <= i0:
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_strip(st, i0, i1, corners)
		var surface: SurfaceType = run[2]
		_make_body(st.commit(), surface.color, surface.id, "Road_%d_%s" % [idx, surface.id])
		idx += 1
	for b in _boundaries:
		_build_boundary_stripe(b - TRANSITION_LENGTH * 0.5)
		_build_boundary_stripe(b + TRANSITION_LENGTH * 0.5)


func _build_boundary_stripe(offset: float) -> void:
	var f := frame_at(offset)
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width_at(offset) * 2.0, 0.04, 0.6)
	mi.mesh = box
	mi.material_override = ToonMaterial.make(Color(0.95, 0.95, 0.92), 2.0, 0.7, 0.0)
	var p: Vector3 = f.pos + f.up * (0.03 + bump_at(offset))
	mi.transform = Transform3D(Basis.looking_at(f.tangent, Vector3.UP), p)
	add_child(mi)


func _build_shoulders_and_walls() -> void:
	var last := _frames.size() - 1
	var grass := Surfaces.get_type(&"grass")

	var shoulders := SurfaceTool.new()
	shoulders.begin(Mesh.PRIMITIVE_TRIANGLES)
	_strip(shoulders, 0, last, func(f: Dictionary) -> Array:
		return [_road_corners(f, SHOULDER_WIDTH)[0], _road_corners(f)[0]])
	_strip(shoulders, 0, last, func(f: Dictionary) -> Array:
		return [_road_corners(f)[1], _road_corners(f, SHOULDER_WIDTH)[1]])
	_make_body(shoulders.commit(), grass.color, grass.id, "Shoulders")

	var walls := SurfaceTool.new()
	walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	_strip(walls, 0, last, func(f: Dictionary) -> Array:
		var base: Vector3 = _road_corners(f, SHOULDER_WIDTH)[0]
		return [base + Vector3.UP * WALL_HEIGHT, base])
	_strip(walls, 0, last, func(f: Dictionary) -> Array:
		var base: Vector3 = _road_corners(f, SHOULDER_WIDTH)[1]
		return [base, base + Vector3.UP * WALL_HEIGHT])
	_make_body(walls.commit(), Color(0.85, 0.16, 0.14), &"asphalt", "Walls", 2.0, 0.55)

	# The skirt runs all the way down to the ground plate, so an elevated stretch reads as a
	# ridge standing on the landscape instead of a floating ribbon with a gap under it.
	var skirts := SurfaceTool.new()
	skirts.begin(Mesh.PRIMITIVE_TRIANGLES)
	_strip(skirts, 0, last, func(f: Dictionary) -> Array:
		var top: Vector3 = _road_corners(f, SHOULDER_WIDTH)[0]
		return [Vector3(top.x, _ground_y, top.z), top])
	_strip(skirts, 0, last, func(f: Dictionary) -> Array:
		var top: Vector3 = _road_corners(f, SHOULDER_WIDTH)[1]
		return [top, Vector3(top.x, _ground_y, top.z)])
	var mi := MeshInstance3D.new()
	mi.mesh = skirts.commit()
	mi.material_override = ToonMaterial.make(Color(0.36, 0.30, 0.24), 2.0, 0.5, 0.0)
	add_child(mi)


func _compute_ground_level() -> void:
	var xs: Array[float] = []
	var zs: Array[float] = []
	var lowest := INF
	for f in _frames:
		var p: Vector3 = f["pos"]
		xs.append(p.x)
		zs.append(p.z)
		lowest = minf(lowest, p.y)
	_ground_y = lowest - 26.0
	_ground_centre = Vector2((xs.min() + xs.max()) * 0.5, (zs.min() + zs.max()) * 0.5)
	_ground_span = maxf(xs.max() - xs.min(), zs.max() - zs.min()) + 1200.0


## A single low plate under the whole course so a car that clears a wall still lands on something.
func _build_ground() -> void:
	var cx: float = _ground_centre.x
	var cz: float = _ground_centre.y
	var span: float = _ground_span
	var grass := Surfaces.get_type(&"grass")
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	body.collision_mask = 0
	body.set_meta(&"surface", grass.id)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(span, 2.0, span)
	shape.shape = box
	shape.position = Vector3(cx, _ground_y - 1.0, cz)
	body.add_child(shape)
	var plane_mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(span, span)
	plane_mi.mesh = plane
	plane_mi.position = Vector3(cx, _ground_y, cz)
	plane_mi.material_override = ToonMaterial.make(grass.color.darkened(0.3), 2.0, 0.6, 0.0)
	body.add_child(plane_mi)
	add_child(body)


func _build_start_and_finish() -> void:
	_build_gate(start_offset, Color(0.95, 0.95, 0.95), "StartGate", true)
	_build_gate(finish_offset, Color(0.15, 0.15, 0.17), "FinishGate", true)


func _build_gate(offset: float, banner_color: Color, gate_name: String, checkers: bool) -> void:
	var f := frame_at(offset)
	var hw := width_at(offset)
	var post_off := hw + SHOULDER_WIDTH + 0.8
	var gate := Node3D.new()
	gate.name = gate_name
	var base: Vector3 = f.pos + Vector3.UP * bump_at(offset)
	gate.transform = Transform3D(Basis.looking_at(f.tangent, Vector3.UP), base)
	add_child(gate)
	var white := ToonMaterial.make(Color(0.95, 0.95, 0.95), 2.0, 0.6, 0.0)
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.7, 8.0, 0.7)
		post.mesh = pm
		post.material_override = white
		post.position = Vector3(side * post_off, 4.0, 0.0)
		gate.add_child(post)
	var banner := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(post_off * 2.0 + 0.7, 1.6, 0.4)
	banner.mesh = bm
	banner.material_override = ToonMaterial.make(banner_color, 2.0, 0.55, 0.0)
	banner.position = Vector3(0.0, 7.2, 0.0)
	gate.add_child(banner)
	if not checkers:
		return
	var dark := ToonMaterial.make(Color(0.05, 0.05, 0.05), 2.0, 0.6, 0.0)
	var tiles := int(hw * 2.0)
	for i in tiles:
		var tile := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(1.0, 0.03, 1.2)
		tile.mesh = tm
		tile.material_override = white if i % 2 == 0 else dark
		tile.position = Vector3(-hw + 0.5 + i, 0.05, 0.0)
		gate.add_child(tile)


# ---------------------------------------------------------------- hazards & scenery

func _build_features() -> void:
	for st in _stages:
		var spec: Dictionary = st["spec"]
		var a: float = st["a"]
		var b: float = st["b"]
		var feats: Dictionary = spec.get("features", {})
		if feats.has("ruin_halls"):
			_build_ruin_halls(a, b, feats["ruin_halls"])
		for key in feats:
			var cfg: Dictionary = feats[key]
			match key:
				"ruin_halls": pass      # built first, above
				"fallen_columns": _build_fallen_columns(a, b, cfg)
				"pillars": _build_pillars(a, b, cfg)
				"ice_patches": _build_ice_patches(a, b, cfg)
				"rocks": _build_rocks(a, b, cfg)
				"buildings": _build_buildings(a, b, cfg)
				"arena": _build_arena(a, b, cfg)
				"pit_apron": _build_pit_apron(a, b, cfg)
				"repair": _build_repair_station(a, b, cfg)
				"debris": _build_debris(a, b, cfg)
				"moguls": pass          # folded into the road mesh by bump_at()


## Ruined columns standing in the road. A gap wanders side to side so a line always exists.
func _build_pillars(a: float, b: float, cfg: Dictionary) -> void:
	var from: float = lerpf(a, b, float(cfg["from"]))
	var to: float = lerpf(a, b, float(cfg["to"]))
	var spacing: float = float(cfg["spacing"])
	var gate_w: float = float(cfg["gate_width"])
	var radius: float = float(cfg["radius"])
	var height: float = float(cfg["height"])
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.86
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 10
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	# Broken stumps share the same footprint, so one shape serves both.
	var stump := CylinderMesh.new()
	stump.top_radius = radius * 0.95
	stump.bottom_radius = radius
	stump.height = height * 0.38
	stump.radial_segments = 10
	var stump_shape := CylinderShape3D.new()
	stump_shape.radius = radius
	stump_shape.height = height * 0.38

	# The gap sways across the road; register it so drivers can follow it.
	var sway: float = (width_at((from + to) * 0.5) - 2.0 - gate_w) * 0.7
	_gates.append([from - 40.0, to + 40.0, GATE_PERIOD, sway, gate_w])

	var o := from
	var i := 0
	while o < to:
		for k in int(cfg["per_cluster"]):
			# Jitter first, then keep the column clear of the gap *where it actually lands* —
			# checking against the cluster's nominal offset would let a jittered column drift
			# into the gap and close the line.
			var jitter := _rng.randf_range(-spacing * 0.35, spacing * 0.35)
			var oo := clampf(o + jitter, from, to)
			if _near_hall(oo, 30.0):
				continue
			var hw := width_at(oo) - 2.0
			var gate: float = sin(oo / GATE_PERIOD * TAU) * sway
			var lat := _rng.randf_range(-hw, hw)
			var tries := 0
			while absf(lat - gate) < gate_w and tries < 12:
				lat = _rng.randf_range(-hw, hw)
				tries += 1
			if absf(lat - gate) < gate_w:
				continue
			var broken := _rng.randf() < 0.35
			var h := stump.height if broken else height
			var p: Vector3 = surface_point(oo, lat) + Vector3.UP * (h * 0.5 - 0.6)
			var tilt := Basis(Vector3.FORWARD, _rng.randf_range(-0.09, 0.09)) * \
					Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
			var col := STONE.lerp(STONE_LIGHT, _rng.randf())
			_make_obstacle(stump if broken else mesh, stump_shape if broken else shape,
					Transform3D(tilt, p), col, "Pillar%d" % i)
			i += 1
		o += spacing


## Ice laid over the snow as separate patches, so the mountain is unpredictable rather than
## uniformly slippery. Each patch is its own body tagged as ice and sits just above the road.
func _build_ice_patches(a: float, b: float, cfg: Dictionary) -> void:
	var from: float = lerpf(a, b, float(cfg["from"]))
	var to: float = lerpf(a, b, float(cfg["to"]))
	var ice := Surfaces.get_type(&"ice")
	# A car that stops on ice cannot pull away on anything steeper than roughly its grip, so
	# patches are kept to shallow ground. Otherwise a spin on a climb is an unrecoverable trap.
	var max_grade: float = ice.grip * 1.15 * ICE_PATCH_GRADE_MARGIN
	for i in int(cfg["count"]):
		var start := 0.0
		var ok := false
		for attempt in 24:
			start = _rng.randf_range(from, to)
			if absf(grade_at(start)) <= max_grade:
				ok = true
				break
		if not ok:
			continue
		var patch_len: float = _rng.randf_range(float(cfg["min_len"]), float(cfg["max_len"]))
		var end: float = minf(start + patch_len, to)
		var hw := width_at(start)
		var half_span: float = _rng.randf_range(hw * 0.3, hw * 0.8)
		var centre: float = _rng.randf_range(-hw + half_span, hw - half_span)
		# A dark rim a little wider and longer than the patch, then the ice on top of it, so a
		# pale patch still reads against pale snow.
		var rim := _patch_mesh(start - 1.2, end + 1.2, centre, half_span + 1.0, 0.03)
		var rim_mi := MeshInstance3D.new()
		rim_mi.mesh = rim
		rim_mi.material_override = ToonMaterial.make(ICE_BORDER, 2.0, 0.6, 0.0)
		add_child(rim_mi)
		_make_body(_patch_mesh(start, end, centre, half_span, 0.045), ice.color, ice.id,
				"IcePatch%d" % i, 2.0, 0.62)


## Boulders near the edges of the mountain road — clippable, not a full block.
func _build_rocks(a: float, b: float, cfg: Dictionary) -> void:
	var from: float = lerpf(a, b, float(cfg["from"]))
	var to: float = lerpf(a, b, float(cfg["to"]))
	var rock := ROCK
	for i in int(cfg["count"]):
		var o: float = _rng.randf_range(from, to)
		var hw := width_at(o)
		var side: float = -1.0 if _rng.randf() < 0.5 else 1.0
		var lat: float = side * _rng.randf_range(hw * 0.72, hw + SHOULDER_WIDTH * 0.8)
		var s: float = _rng.randf_range(1.1, 2.6)
		var mesh := BoxMesh.new()
		mesh.size = Vector3(s, s * 0.8, s * 1.15)
		var shape := BoxShape3D.new()
		shape.size = mesh.size
		var p: Vector3 = surface_point(o, lat) + Vector3.UP * (s * 0.3)
		var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)) * \
				Basis(Vector3.RIGHT, _rng.randf_range(-0.25, 0.25))
		_make_obstacle(mesh, shape, Transform3D(basis, p), rock, "Rock%d" % i)


## Simple blocks set back behind the shoulder, to read as a village or city from the road.
func _build_buildings(a: float, b: float, cfg: Dictionary) -> void:
	var from: float = lerpf(a, b, float(cfg["from"]))
	var to: float = lerpf(a, b, float(cfg["to"]))
	var palette := [Color(0.82, 0.74, 0.62), Color(0.70, 0.60, 0.52), Color(0.86, 0.82, 0.74),
			Color(0.60, 0.55, 0.55), Color(0.78, 0.66, 0.50)]
	for i in int(cfg["count"]):
		var o: float = _rng.randf_range(from, to)
		var hw := width_at(o)
		var side: float = -1.0 if _rng.randf() < 0.5 else 1.0
		var depth: float = _rng.randf_range(4.0, 13.0)
		var lat: float = side * (hw + SHOULDER_WIDTH + 2.0 + depth * 0.5)
		var w: float = _rng.randf_range(6.0, 12.0)
		var d: float = _rng.randf_range(6.0, 12.0)
		var h: float = _rng.randf_range(float(cfg["min_h"]), float(cfg["max_h"]))
		var mesh := BoxMesh.new()
		mesh.size = Vector3(w, h, d)
		var shape := BoxShape3D.new()
		shape.size = mesh.size
		var f := frame_at(o)
		var p: Vector3 = f.pos + f.right * lat + Vector3.UP * (h * 0.5 - 1.0)
		var basis := Basis.looking_at(f.tangent, Vector3.UP).rotated(Vector3.UP, _rng.randf_range(-0.25, 0.25))
		_make_obstacle(mesh, shape, Transform3D(basis, p), palette[i % palette.size()], "Building%d" % i)


## The finishing straight: tiered stands packed with colour on both sides.
func _build_arena(a: float, b: float, cfg: Dictionary) -> void:
	var from: float = lerpf(a, b, float(cfg["from"]))
	var crowd := [Color(0.86, 0.30, 0.26), Color(0.24, 0.46, 0.86), Color(0.94, 0.78, 0.24),
			Color(0.28, 0.72, 0.44), Color(0.74, 0.36, 0.80)]
	var count := int(cfg["stands"])
	for i in count:
		var o: float = lerpf(from, length - 20.0, float(i) / float(maxi(count - 1, 1)))
		var hw := width_at(o)
		for side in [-1.0, 1.0]:
			for tier in 3:
				var h: float = 3.0 + tier * 2.6
				var mesh := BoxMesh.new()
				mesh.size = Vector3(9.0, h, 7.0)
				var shape := BoxShape3D.new()
				shape.size = mesh.size
				var f := frame_at(o)
				var lat: float = side * (hw + SHOULDER_WIDTH + 4.0 + tier * 7.2)
				var p: Vector3 = f.pos + f.right * lat + Vector3.UP * (h * 0.5 - 1.0)
				var col: Color = crowd[(i + tier) % crowd.size()]
				_make_obstacle(mesh, shape, Transform3D(Basis.looking_at(f.tangent, Vector3.UP), p),
						col, "Stand%d_%d_%d" % [i, int(side), tier])


## A widened asphalt apron beside the road — the pit lane's footprint.
func _build_pit_apron(a: float, b: float, cfg: Dictionary) -> void:
	var from: float = lerpf(a, b, float(cfg["at"]))
	var to: float = from + float(cfg["length"])
	var side: float = float(cfg["side"])
	var extra: float = float(cfg["width"])
	var asphalt := Surfaces.get_type(&"asphalt")
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var o := from
	while o < to:
		var o2: float = minf(o + SAMPLE_STEP, to)
		var t1: float = sin(clampf((o - from) / (to - from), 0.0, 1.0) * PI)
		var t2: float = sin(clampf((o2 - from) / (to - from), 0.0, 1.0) * PI)
		var w1: float = width_at(o)
		var w2: float = width_at(o2)
		var pa := surface_point(o, side * w1) + Vector3.UP * 0.02
		var pb := surface_point(o, side * (w1 + extra * t1)) + Vector3.UP * 0.02
		var pc := surface_point(o2, side * w2) + Vector3.UP * 0.02
		var pd := surface_point(o2, side * (w2 + extra * t2)) + Vector3.UP * 0.02
		for v in ([pa, pc, pd, pa, pd, pb] if side > 0.0 else [pa, pd, pc, pa, pb, pd]):
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
		o = o2
	_make_body(st.commit(), asphalt.color.lightened(0.06), asphalt.id, "PitApron")
	# A row of bays behind the apron so it reads as a pit stop.
	var bay := 0
	o = from + 14.0
	while o < to - 10.0:
		var f := frame_at(o)
		var mesh := BoxMesh.new()
		mesh.size = Vector3(6.0, 4.0, 8.0)
		var shape := BoxShape3D.new()
		shape.size = mesh.size
		var lat: float = side * (width_at(o) + extra + 5.0)
		var p: Vector3 = f.pos + f.right * lat + Vector3.UP * 1.0
		_make_obstacle(mesh, shape, Transform3D(Basis.looking_at(f.tangent, Vector3.UP), p),
				Color(0.30, 0.34, 0.40), "PitBay%d" % bay)
		bay += 1
		o += 22.0


## A flat strip of road surface between two offsets, `half_span` either side of `centre`.
func _patch_mesh(start: float, end: float, centre: float, half_span: float, lift: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var o := start
	while o < end:
		var o2: float = minf(o + 2.0, end)
		var pa := surface_point(o, centre - half_span) + Vector3.UP * lift
		var pb := surface_point(o, centre + half_span) + Vector3.UP * lift
		var pc := surface_point(o2, centre - half_span) + Vector3.UP * lift
		var pd := surface_point(o2, centre + half_span) + Vector3.UP * lift
		for v in [pa, pc, pd, pa, pd, pb]:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
		o = o2
	return st.commit()


func _near_hall(offset: float, margin: float) -> bool:
	for h in _halls:
		if offset >= h[0] - margin and offset <= h[1] + margin:
			return true
	return false


## Ruined halls: outer colonnades under a broken roof, and a central colonnade that splits
## the road into two lanes. Pick a side on the way in; the columns stop you changing it.
func _build_ruin_halls(a: float, b: float, cfg: Dictionary) -> void:
	var count := int(cfg["count"])
	var roof_h: float = float(cfg["roof_height"])
	var spacing: float = float(cfg["column_spacing"])
	var gap_chance: float = float(cfg["roof_gap_chance"])
	var usable_a: float = lerpf(a, b, 0.12)
	var usable_b: float = lerpf(a, b, 0.92)
	var col_mesh := CylinderMesh.new()
	col_mesh.top_radius = 1.45
	col_mesh.bottom_radius = 1.65
	col_mesh.height = roof_h
	col_mesh.radial_segments = 10
	var col_shape := CylinderShape3D.new()
	col_shape.radius = 1.6
	col_shape.height = roof_h

	for k in count:
		var hall_len: float = _rng.randf_range(float(cfg["min_len"]), float(cfg["max_len"]))
		var slot: float = (usable_b - usable_a) / float(count)
		var start: float = usable_a + slot * k + (slot - hall_len) * 0.5
		var end: float = start + hall_len
		_halls.append([start, end])

		# A low wedge on the centre line ahead of the first column, so the split is readable
		# from a distance and a car that misjudges it rides up rather than hitting a post.
		var wedge_len := 16.0
		var wedge := PrismMesh.new()
		wedge.size = Vector3(3.2, 1.3, wedge_len)
		wedge.left_to_right = 0.5
		var wedge_shape := ConvexPolygonShape3D.new()
		wedge_shape.points = PackedVector3Array([
			Vector3(-1.6, 0.0, wedge_len * 0.5), Vector3(1.6, 0.0, wedge_len * 0.5),
			Vector3(-1.6, 0.0, -wedge_len * 0.5), Vector3(1.6, 0.0, -wedge_len * 0.5),
			Vector3(-1.6, 1.3, -wedge_len * 0.5), Vector3(1.6, 1.3, -wedge_len * 0.5)])
		var wf := frame_at(start - wedge_len * 0.5 - 1.0)
		var wp: Vector3 = surface_point(start - wedge_len * 0.5 - 1.0, 0.0)
		# PrismMesh's tall face is at -Z, so looking along the tangent puts the high end at the column.
		_make_obstacle(wedge, wedge_shape, Transform3D(Basis.looking_at(wf.tangent, Vector3.UP), wp),
				STONE, "Hall%dWedge" % k)

		# Columns: centre line plus both outer edges, all the way through.
		var o := start
		var i := 0
		while o <= end:
			var hw := width_at(o)
			for lat in [0.0, -(hw - 2.2), hw - 2.2]:
				var p: Vector3 = surface_point(o, lat) + Vector3.UP * (roof_h * 0.5 - 0.6)
				var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
				_make_obstacle(col_mesh, col_shape, Transform3D(basis, p),
						STONE.lerp(STONE_LIGHT, _rng.randf() * 0.6), "Hall%dCol%d" % [k, i])
				i += 1
			o += spacing

		# Roof: a slab over the whole width, with spans knocked out so it reads as a ruin.
		# Purely visual, nothing ever gets up there.
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var span := spacing
		o = start
		while o < end:
			var o2: float = minf(o + span, end)
			if _rng.randf() >= gap_chance:
				var w1 := width_at(o) + 1.0
				var w2 := width_at(o2) + 1.0
				for lift: float in [roof_h - 0.6, roof_h + 0.4]:
					var pa := surface_point(o, -w1) + Vector3.UP * lift
					var pb := surface_point(o, w1) + Vector3.UP * lift
					var pc := surface_point(o2, -w2) + Vector3.UP * lift
					var pd := surface_point(o2, w2) + Vector3.UP * lift
					for v in [pa, pc, pd, pa, pd, pb]:
						st.set_normal(Vector3.UP)
						st.add_vertex(v)
				# Side beams hanging from the roof edge, so the silhouette closes from inside.
				for side in [-1.0, 1.0]:
					var t1 := surface_point(o, side * w1) + Vector3.UP * (roof_h + 0.4)
					var b1 := surface_point(o, side * w1) + Vector3.UP * (roof_h - 2.2)
					var t2 := surface_point(o2, side * w2) + Vector3.UP * (roof_h + 0.4)
					var b2 := surface_point(o2, side * w2) + Vector3.UP * (roof_h - 2.2)
					for v in [t1, t2, b2, t1, b2, b1]:
						st.set_normal(Vector3.UP)
						st.add_vertex(v)
			o = o2
		var roof_mi := MeshInstance3D.new()
		roof_mi.mesh = st.commit()
		roof_mi.material_override = ToonMaterial.make(STONE_LIGHT, 3.0, 0.3, 0.0)
		roof_mi.name = "Hall%dRoof" % k
		add_child(roof_mi)


## Toppled columns lying on the sand near the edges: low, wide, and easy to clip.
func _build_fallen_columns(a: float, b: float, cfg: Dictionary) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.3
	mesh.bottom_radius = 1.4
	mesh.height = 7.0
	mesh.radial_segments = 10
	var shape := CylinderShape3D.new()
	shape.radius = 1.4
	shape.height = 7.0
	for i in int(cfg["count"]):
		var o: float = _rng.randf_range(lerpf(a, b, 0.06), lerpf(a, b, 0.96))
		if _near_hall(o, 12.0):
			continue
		var hw := width_at(o)
		var side: float = -1.0 if _rng.randf() < 0.5 else 1.0
		var lat: float = side * _rng.randf_range(hw * 0.55, hw - 3.0)
		var f := frame_at(o)
		var yaw := _rng.randf_range(-0.6, 0.6)
		# Lay the cylinder on its side, roughly across the road.
		var basis := Basis.looking_at(f.tangent, Vector3.UP).rotated(Vector3.UP, yaw) * \
				Basis(Vector3.FORWARD, PI * 0.5)
		var p: Vector3 = surface_point(o, lat) + Vector3.UP * 1.3
		_make_obstacle(mesh, shape, Transform3D(basis, p), STONE, "FallenColumn%d" % i)


## A repair pad at the side of the road. The AI knows where these are.
func _build_repair_station(a: float, b: float, cfg: Dictionary) -> void:
	var o: float = lerpf(a, b, float(cfg["at"]))
	var side: float = float(cfg["side"])
	var lat: float = side * (width_at(o) - RepairStation.PAD_WIDTH * 0.5 - 0.6)
	var f := frame_at(o)
	var station := RepairStation.new()
	station.transform = Transform3D(Basis.looking_at(f.tangent, Vector3.UP), surface_point(o, lat) + Vector3.UP * 0.02)
	add_child(station)
	_repair_stations.append([o, lat])


## The nearest repair station ahead of an offset, as [offset, lateral], or [] if none within reach.
func next_repair_station(offset: float, within: float) -> Array:
	for st in _repair_stations:
		if st[0] > offset - 10.0 and st[0] < offset + within:
			return st
	return []


## A single gadget box every PICKUP_SPACING metres, wandering from one side of the road to
## the other so it is not always on the racing line, and kept out of the halls.
func _build_pickups() -> void:
	var o := start_offset + 170.0
	var n := 0
	while o < finish_offset - 80.0:
		if not _near_hall(o, 28.0):
			var hw := width_at(o)
			var lat := sin(float(n) * 1.9) * (hw - 2.5) * 0.7
			var box := PickupBox.new()
			box.position = surface_point(o, lat) + Vector3.UP * PickupBox.FLOAT_HEIGHT
			add_child(box)
			_pickups.append(box)
		n += 1
		o += RouteSpec.PICKUP_SPACING


func reset_pickups() -> void:
	for box in _pickups:
		box.respawn_now()


## Loose crates that scatter on contact.
func _build_debris(a: float, b: float, cfg: Dictionary) -> void:
	var mat := ToonMaterial.make(Color(0.93, 0.55, 0.15), 3.0, 0.5, 0.1)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.2, 1.2, 1.2)
	var shape := BoxShape3D.new()
	shape.size = mesh.size
	for i in int(cfg["count"]):
		var o: float = _rng.randf_range(a + 20.0, b - 20.0)
		var hw := width_at(o)
		var side: float = -1.0 if _rng.randf() < 0.5 else 1.0
		var lat: float = side * _rng.randf_range(hw * 0.55, hw + SHOULDER_WIDTH - 1.0)
		var crate := RigidBody3D.new()
		crate.name = "Debris_%.0f_%d" % [a, i]
		crate.mass = 70.0
		crate.collision_layer = 4
		crate.collision_mask = 0b111
		var cs := CollisionShape3D.new()
		cs.shape = shape
		crate.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		crate.add_child(mi)
		crate.transform = Transform3D(Basis(Vector3.UP, _rng.randf_range(0.0, TAU)),
				surface_point(o, lat) + Vector3.UP * 0.7)
		add_child(crate)
