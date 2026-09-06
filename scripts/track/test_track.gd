class_name TestTrack
extends Node3D
## Procedural test circuit. Builds a closed Curve3D from control points, then extrudes
## a road ribbon along it, one StaticBody3D per surface segment so each stretch carries
## its own SurfaceType meta. Also builds grass shoulders, barrier walls, skirts, a
## start gate, a ground plane and a scattering of crates to knock about.

## Surface segments in order along the loop: [id, length in metres].
## The final entry is padded to fill whatever is left of the loop.
const SEGMENT_PLAN := [
	[&"asphalt", 260.0],
	[&"dirt", 220.0],
	[&"asphalt", 160.0],
	[&"sand", 220.0],
	[&"asphalt", 140.0],
	[&"ice", 200.0],
	[&"snow", 220.0],
	[&"asphalt", 180.0],
	[&"dirt", 160.0],
	[&"asphalt", 1.0e9],
]

## Control points (x, y, z). Car starts at the first one heading -Z.
const CONTROL_POINTS: Array[Vector3] = [
	Vector3(0, 3, 0),
	Vector3(0, 3, -180),
	Vector3(30, 5, -300),
	Vector3(120, 9, -380),
	Vector3(240, 11, -390),
	Vector3(330, 8, -320),
	Vector3(360, 3, -200),
	Vector3(320, 1, -90),
	Vector3(400, 1, 0),
	Vector3(480, 3, 60),
	Vector3(470, 6, 180),
	Vector3(360, 7, 220),
	Vector3(260, 5, 170),
	Vector3(180, 3, 200),
	Vector3(120, 0, 300),
	Vector3(0, 0, 330),
	Vector3(-90, 3, 280),
	Vector3(-110, 5, 190),
	Vector3(-60, 4, 120),
	Vector3(0, 3, 60),
]

@export var road_half_width := 8.0
@export var shoulder_width := 4.0
@export var wall_height := 1.1
@export var sample_step := 3.0
@export var crate_count := 28
## Length of the blend zone where one surface fades into the next (metres).
@export var transition_length := 36.0
## Number of discrete grip bands inside a blend zone.
@export var transition_bands := 6
## How far (metres) a surface boundary may move to land on the straightest nearby road.
@export var transition_search := 60.0

var curve := Curve3D.new()
var length := 0.0
var _frames: Array[Dictionary] = []   # pos, tangent, right, up, offset
var _segments: Array = []             # [start_offset, end_offset, SurfaceType], blend bands included
var _boundaries: Array[float] = []    # centre offset of each surface change


func _ready() -> void:
	_build_curve()
	_sample_frames()
	_plan_segments()
	_build_road()
	_build_shoulders_walls_and_skirts()
	_build_ground()
	_build_start_gate()
	_build_crates()


# ---------------------------------------------------------------- curve

func _build_curve() -> void:
	var pts := CONTROL_POINTS
	var n := pts.size()
	curve.bake_interval = 1.0
	for i in n + 1:
		var idx := i % n
		var prev := pts[(idx - 1 + n) % n]
		var next := pts[(idx + 1) % n]
		var tangent := (next - prev) * 0.25   # Catmull-Rom style handles
		curve.add_point(pts[idx], -tangent, tangent)
	length = curve.get_baked_length()


func frame_at(offset: float) -> Dictionary:
	offset = fposmod(offset, length)
	var pos := curve.sample_baked(offset, true)
	var ahead := curve.sample_baked(fposmod(offset + 0.75, length), true)
	var tangent := (ahead - pos)
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
		o += sample_step
	_frames.append(frame_at(0.0))   # close the loop exactly on the start frame
	_frames[-1]["offset"] = length


func _plan_segments() -> void:
	# 1. Raw boundaries from the plan.
	var types: Array[SurfaceType] = []
	var bounds: Array[float] = []
	var start := 0.0
	for entry in SEGMENT_PLAN:
		if start >= length:
			break
		var end := minf(start + float(entry[1]), length)
		types.append(Surfaces.get_type(entry[0]))
		if end < length:
			bounds.append(end)
		start = end

	# 2. Slide each boundary onto the straightest road nearby, keeping them in order.
	var min_gap := transition_length + 20.0
	for i in bounds.size():
		bounds[i] = _straightest_offset_near(bounds[i], transition_search)
		var floor_off := (bounds[i - 1] + min_gap) if i > 0 else min_gap
		bounds[i] = clampf(bounds[i], floor_off, length - min_gap)
	_boundaries = bounds

	# 3. Emit road pieces: plain segments with a band of blended surfaces around each boundary.
	_segments.clear()
	var cursor := 0.0
	var band_len := transition_length / float(transition_bands)
	for i in bounds.size():
		var a := types[i]
		var b := types[i + 1]
		var zone_start := bounds[i] - transition_length * 0.5
		_segments.append([cursor, zone_start, a])
		for k in transition_bands:
			var t := (float(k) + 0.5) / float(transition_bands)
			_segments.append([zone_start + k * band_len, zone_start + (k + 1) * band_len, Surfaces.blend(a, b, t)])
		cursor = zone_start + transition_length
	_segments.append([cursor, length, types[bounds.size()]])


## Offset within +/- radius of `center` whose surrounding blend zone bends the least.
func _straightest_offset_near(center: float, radius: float) -> float:
	var half := transition_length * 0.5 + 12.0
	var best := center
	var best_score := INF
	var o := center - radius
	while o <= center + radius:
		var score := absf(o - center) * 0.0005   # slight preference for staying put
		var p := o - half
		var prev_t: Vector3 = frame_at(p).tangent
		p += 6.0
		while p <= o + half:
			var t: Vector3 = frame_at(p).tangent
			score += prev_t.angle_to(t)
			prev_t = t
			p += 6.0
		if score < best_score:
			best_score = score
			best = o
		o += 3.0
	return best


# ---------------------------------------------------------------- queries

func offset_of(global_pos: Vector3) -> float:
	return curve.get_closest_offset(to_local(global_pos))


func progress_of(global_pos: Vector3) -> float:
	return offset_of(global_pos) / length


## Signed distance along the loop from a to b, in (-length/2, length/2].
func wrapped_delta(a: float, b: float) -> float:
	var d := fposmod(b - a, length)
	if d > length * 0.5:
		d -= length
	return d


func lateral_offset(global_pos: Vector3) -> float:
	var f := frame_at(offset_of(global_pos))
	return (to_local(global_pos) - f.pos).dot(f.right)


func distance_from_center(global_pos: Vector3) -> float:
	return absf(lateral_offset(global_pos))


func surface_at(offset: float) -> SurfaceType:
	offset = fposmod(offset, length)
	for seg in _segments:
		if offset >= seg[0] and offset < seg[1]:
			return seg[2]
	return Surfaces.default_surface


## Transform on the road nearest to a position, facing along the track, ready to drop a car.
func snap_to_track(global_pos: Vector3) -> Transform3D:
	var f := frame_at(offset_of(global_pos))
	var lane := clampf(lateral_offset(global_pos), -road_half_width + 2.0, road_half_width - 2.0)
	var origin: Vector3 = to_global(f.pos + f.right * lane + f.up * 0.9)
	return Transform3D(Basis.looking_at(global_transform.basis * f.tangent, Vector3.UP), origin)


## Two-wide starting grid behind the start line. Index 0 is front-left.
func get_grid_transform(index: int) -> Transform3D:
	@warning_ignore("integer_division")
	var row := index / 2
	var col := index % 2
	var f := frame_at(fposmod(-10.0 - row * 9.0, length))
	var lane := -3.2 if col == 0 else 3.2
	var origin: Vector3 = to_global(f.pos + f.right * lane + f.up * 0.9)
	return Transform3D(Basis.looking_at(global_transform.basis * f.tangent, Vector3.UP), origin)


# ---------------------------------------------------------------- geometry

## Extrude a quad strip between frame indices [i0, i1].
## `corners` maps a frame to [left_vertex, right_vertex], so the same routine builds roads and walls.
func _strip(st: SurfaceTool, i0: int, i1: int, corners: Callable, normal_up := true) -> void:
	for i in range(i0, i1):
		var a := _frames[i]
		var b := _frames[i + 1]
		var qa: Array = corners.call(a)   # [left, right]
		var qb: Array = corners.call(b)
		var n: Vector3 = a.up if normal_up else Vector3.UP
		# Godot front faces are clockwise. Top view with tangent up-screen and right right-screen.
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


func _frame_index_at(offset: float) -> int:
	return clampi(int(floor(offset / sample_step)), 0, _frames.size() - 1)


func _build_road() -> void:
	var hw := road_half_width
	var road_corners := func(f: Dictionary) -> Array:
		return [f.pos - f.right * hw, f.pos + f.right * hw]
	var seg_index := 0
	for seg in _segments:
		var i0 := _frame_index_at(seg[0])
		var i1 := _frame_index_at(seg[1]) if seg[1] < length else _frames.size() - 1
		if i1 <= i0:
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_strip(st, i0, i1, road_corners)
		var surface: SurfaceType = seg[2]
		_make_body(st.commit(), surface.color, surface.id, "Road_%d_%s" % [seg_index, surface.id])
		seg_index += 1
	# Thin stripes mark where each blend zone begins and ends so the change is readable.
	for b in _boundaries:
		_build_boundary_stripe(b - transition_length * 0.5)
		_build_boundary_stripe(b + transition_length * 0.5)


func _build_boundary_stripe(offset: float) -> void:
	var f := frame_at(offset)
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(road_half_width * 2.0, 0.04, 0.6)
	mi.mesh = box
	mi.material_override = ToonMaterial.make(Color(0.95, 0.95, 0.92), 2.0, 0.7, 0.0)
	mi.transform = Transform3D(Basis.looking_at(f.tangent, Vector3.UP), f.pos + f.up * 0.03)
	add_child(mi)


func _build_shoulders_walls_and_skirts() -> void:
	var hw := road_half_width
	var sw := shoulder_width
	var last := _frames.size() - 1
	var grass := Surfaces.get_type(&"grass")

	var shoulders := SurfaceTool.new()
	shoulders.begin(Mesh.PRIMITIVE_TRIANGLES)
	_strip(shoulders, 0, last, func(f: Dictionary) -> Array:
		return [f.pos - f.right * (hw + sw), f.pos - f.right * hw])
	_strip(shoulders, 0, last, func(f: Dictionary) -> Array:
		return [f.pos + f.right * hw, f.pos + f.right * (hw + sw)])
	_make_body(shoulders.commit(), grass.color, grass.id, "Shoulders")

	var wall_off := hw + sw
	var wh := wall_height
	var walls := SurfaceTool.new()
	walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	_strip(walls, 0, last, func(f: Dictionary) -> Array:
		var base: Vector3 = f.pos - f.right * wall_off
		return [base + Vector3.UP * wh, base])
	_strip(walls, 0, last, func(f: Dictionary) -> Array:
		var base: Vector3 = f.pos + f.right * wall_off
		return [base, base + Vector3.UP * wh])
	_make_body(walls.commit(), Color(0.85, 0.16, 0.14), &"asphalt", "Walls", 2.0, 0.55)

	var skirts := SurfaceTool.new()
	skirts.begin(Mesh.PRIMITIVE_TRIANGLES)
	_strip(skirts, 0, last, func(f: Dictionary) -> Array:
		var top: Vector3 = f.pos - f.right * wall_off
		return [Vector3(top.x, -1.0, top.z), top])
	_strip(skirts, 0, last, func(f: Dictionary) -> Array:
		var top: Vector3 = f.pos + f.right * wall_off
		return [top, Vector3(top.x, -1.0, top.z)])
	var skirt_mi := MeshInstance3D.new()
	skirt_mi.mesh = skirts.commit()
	skirt_mi.material_override = ToonMaterial.make(Color(0.36, 0.30, 0.24), 2.0, 0.5, 0.0)
	add_child(skirt_mi)


func _build_ground() -> void:
	var grass := Surfaces.get_type(&"grass")
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	body.collision_mask = 0
	body.set_meta(&"surface", grass.id)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3000.0, 1.0, 3000.0)
	shape.shape = box
	shape.position = Vector3(180.0, -1.0, -30.0)
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(3000.0, 3000.0)
	mi.mesh = plane
	mi.position = Vector3(180.0, -0.5, -30.0)
	mi.material_override = ToonMaterial.make(grass.color.darkened(0.15), 2.0, 0.6, 0.0)
	body.add_child(mi)
	add_child(body)


func _build_start_gate() -> void:
	var f := frame_at(0.0)
	var post_off := road_half_width + shoulder_width + 0.8
	var gate := Node3D.new()
	gate.name = "StartGate"
	gate.transform = Transform3D(Basis.looking_at(f.tangent, Vector3.UP), f.pos)
	add_child(gate)
	var white := ToonMaterial.make(Color(0.95, 0.95, 0.95), 2.0, 0.6, 0.0)
	var red := ToonMaterial.make(Color(0.85, 0.16, 0.14), 2.0, 0.55, 0.0)
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.6, 7.0, 0.6)
		post.mesh = pm
		post.material_override = white
		post.position = Vector3(side * post_off, 3.5, 0.0)
		gate.add_child(post)
	var banner := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(post_off * 2.0 + 0.6, 1.4, 0.4)
	banner.mesh = bm
	banner.material_override = red
	banner.position = Vector3(0.0, 6.3, 0.0)
	gate.add_child(banner)
	# Checkered line on the road.
	for i in 16:
		var tile := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(1.0, 0.03, 1.0)
		tile.mesh = tm
		tile.material_override = white if i % 2 == 0 else ToonMaterial.make(Color(0.05, 0.05, 0.05), 2.0, 0.6, 0.0)
		tile.position = Vector3(-7.5 + i, 0.05, 0.0)
		gate.add_child(tile)


func _build_crates() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var mat := ToonMaterial.make(Color(0.93, 0.55, 0.15), 3.0, 0.5, 0.1)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.2, 1.2, 1.2)
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.2, 1.2, 1.2)
	for i in crate_count:
		var off := rng.randf_range(60.0, length - 30.0)
		var f := frame_at(off)
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		var lateral := side * rng.randf_range(road_half_width - 1.5, road_half_width + shoulder_width - 1.0)
		var crate := RigidBody3D.new()
		crate.name = "Crate%d" % i
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
		crate.transform = Transform3D(Basis(Vector3.UP, rng.randf_range(0.0, TAU)), f.pos + f.right * lateral + f.up * 0.7)
		add_child(crate)
