extends Node
## Dumps the generated course (main road, alternative routes, obstacles) to JSON for the
## map drawing script. Run with:
##   MAP_JSON=/tmp/course.json godot --headless --path . res://tools/dump_course.tscn
func _ready() -> void:
	var track := SprintTrack.new()
	add_child(track)
	var d := {}
	var samples := []
	var o := 0.0
	while o < track.length:
		var f: Dictionary = track.frame_at(o)
		var st: SurfaceType = track.surface_at(o)
		samples.append({"o": o, "x": f.pos.x, "y": f.pos.y, "z": f.pos.z, "rx": f.right.x, "rz": f.right.z,
				"w": track.width_at(o), "c": st.color.to_html(false) if st else "888888"})
		o += 3.0
	d["samples"] = samples
	var stages := []
	for st in track.stages():
		var spec: Dictionary = st["spec"]
		var surfs := []
		var total := 0.0
		for pair in spec["surfaces"]:
			total += float(pair[1])
		var acc := 0.0
		for pair in spec["surfaces"]:
			var share: float = float(pair[1]) / maxf(total, 0.001)
			var mid_o: float = lerpf(float(st["a"]), float(st["b"]), acc + share * 0.5)
			acc += share
			var t: SurfaceType = track.surface_at(mid_o)
			surfs.append({"id": String(pair[0]), "share": share, "c": t.color.to_html(false) if t else "888888"})
		stages.append({"name": spec["name"], "a": st["a"], "b": st["b"], "seconds": spec["seconds"],
				"half_width": spec["half_width"], "surfaces": surfs, "min_radius": spec.get("min_radius", 0.0),
				"tech": spec.get("tech", {}).get("min_radius", 0.0), "max_grade": spec.get("max_grade", 0.0),
				"climb": spec.get("climb", 0.0), "features": spec.get("features", {}).keys(),
				"jogs": spec.get("jogs", {}).get("count", 0)})
	d["stages"] = stages
	var branches := []
	for br in track.branches():
		var pts := []
		var s := 0.0
		while s <= br.length:
			var f: Dictionary = track._curve_frame(br.curve, s, br.length)
			pts.append({"x": f.pos.x, "y": f.pos.y, "z": f.pos.z, "rx": f.right.x, "rz": f.right.z})
			s += 3.0
		branches.append({"id": String(br.id), "name": br.display_name, "kind": String(br.kind), "w": br.half_width,
				"length": br.length, "fork": br.fork, "merge": br.merge, "side": br.side,
				"covered": [br.covered.x, br.covered.y], "pts": pts})
	d["branches"] = branches
	var obs := {"building": [], "debris": [], "fallen": [], "hallcol": [], "ice": [], "pillar": [], "pit": [], "rock": [], "stand": [], "pickup": [], "repair": [], "portal": []}
	for c in track.get_children():
		var n: String = String(c.name).trim_prefix("@")
		var key := ""
		if n.begins_with("Building") or n.begins_with("Branch_") and n.contains("Building"): key = "building"
		elif n.begins_with("Stand"): key = "stand"
		elif n.begins_with("Pillar") or n.begins_with("Column"): key = "pillar"
		elif n.begins_with("HallCol") or n.begins_with("Hall") and n.contains("Col"): key = "hallcol"
		elif n.begins_with("Fallen"): key = "fallen"
		elif n.begins_with("Rock"): key = "rock"
		elif n.begins_with("Ice"): key = "ice"
		elif n.begins_with("PitBay"): key = "pit"
		elif n.begins_with("Debris"): key = "debris"
		elif n.begins_with("Portal"): key = "portal"
		elif c is PickupBox: key = "pickup"
		elif c is RepairStation: key = "repair"
		if key != "" and c is Node3D:
			var p: Vector3 = (c as Node3D).global_position
			obs[key].append({"x": p.x, "z": p.z})
	d["obstacles"] = obs
	var halls := []
	for h in track._halls:
		halls.append({"a": h[0], "b": h[1]})
	d["halls"] = halls
	var grid := []
	for i in 16:
		var tr: Transform3D = track.get_grid_transform(i)
		grid.append({"i": i, "x": tr.origin.x, "z": tr.origin.z})
	d["grid"] = grid
	d["shoulder"] = SprintTrack.SHOULDER_WIDTH
	d["length"] = track.length
	d["start"] = track.start_offset
	d["finish"] = track.finish_offset
	d["race_length"] = track.race_length
	var path := OS.get_environment("MAP_JSON")
	if path == "":
		path = "/tmp/sprint.json"
	var fa := FileAccess.open(path, FileAccess.WRITE)
	fa.store_string(JSON.stringify(d))
	fa.close()
	print("dumped %d samples, %d branches to %s" % [samples.size(), branches.size(), path])
	get_tree().quit()
