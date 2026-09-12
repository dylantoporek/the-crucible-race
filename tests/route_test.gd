extends Node
## Headless check of the village's alternative routes. Drives one clean AI car through the
## old town, the avenue and the tunnel in turn and checks each is drivable, tracked, and
## takes about the same time. Run with:
##   godot --headless --path . res://tests/route_test.tscn

const MAIN := "res://scenes/main.tscn"

var game: Node
var track: SprintTrack
var car: RaycastCar
var driver: AIDriver
var routes: Array = [[&"", "old town"], [&"avenue", "avenue"], [&"tunnel", "tunnel"]]
var ri := 0
var t := 0.0
var fails := 0
var fork := 0.0
var merge := 0.0
var t_fork := -1.0
var last_off := 0.0
var jumps := 0
var on_route_mid := false
var times := {}


func _ready() -> void:
	var scene: PackedScene = load(MAIN)
	game = scene.instantiate()
	add_child(game)
	game.skip_countdown()
	track = game.track
	car = game.player
	car.get_node("PlayerDriver").queue_free()
	for other in game.cars:
		if other != car:
			(other.get_node("AIDriver") as AIDriver).process_mode = Node.PROCESS_MODE_DISABLED
			other.controls_locked = true
			other.global_position += Vector3.UP * 600.0
			other.freeze = true
	var brs: Array = track.branches()
	_check(brs.size() == 2, "two alternative routes through the village (%d)" % brs.size())
	_check(track.stages().size() == 7, "seven stages, ending in Crucible City (%d)" % track.stages().size())
	if brs.is_empty():
		_finish()
		return
	var ids := []
	for br in brs:
		ids.append(String(br.id))
		_check(br.length > 250.0, "%s is a real route (%.0f m)" % [br.display_name, br.length])
		_check(absf(br.length - (br.merge - br.fork)) < (br.merge - br.fork) * 0.25,
				"%s is within 25%% of the main road's length over the same stretch (%.0f vs %.0f m)" % [br.display_name, br.length, br.merge - br.fork])
	_check(ids.has("avenue") and ids.has("tunnel"), "routes are the avenue and the tunnel")
	fork = float(brs[0].fork)
	merge = float(brs[0].merge)
	# snap_to_track on a point inside the tunnel lands on the tunnel, not the road above.
	var tunnel: SprintTrack.RouteLine = brs[1] if brs[1].id == &"tunnel" else brs[0]
	var mid_pos: Vector3 = track.to_global(track._curve_frame(tunnel.curve, tunnel.length * 0.5, tunnel.length).pos + Vector3.UP * 3.0)
	var snapped: Transform3D = track.snap_to_track(mid_pos)
	_check(snapped.origin.distance_to(mid_pos) < 6.0, "reset inside the tunnel puts the car back in the tunnel (%.1f m)" % snapped.origin.distance_to(mid_pos))

	driver = AIDriver.new()
	driver.name = "RouteDriver"
	driver.track = track
	driver.style = AIDriver.RACER
	driver.aggression = 0.0
	driver.skill = 1.0
	driver.others = []
	car.add_child(driver)
	_start_route()


func _start_route() -> void:
	driver.preferred_route = routes[ri][0]
	var start: Vector3 = track.to_global(track.surface_point(fork - 170.0, 0.0) + Vector3.UP * 1.2)
	car.reset_to(track.snap_to_track(start, 0.0))
	car.repair()
	track.invalidate_cursor(car)
	driver.reset_state()
	driver.resets = 0
	t = 0.0
	t_fork = -1.0
	last_off = fork - 170.0
	jumps = 0
	on_route_mid = false


func _physics_process(delta: float) -> void:
	if driver == null:
		return
	t += delta
	var off: float = track.track_offset(car)
	if off - last_off > 40.0 or off < last_off - 15.0:
		jumps += 1
	last_off = off
	if t_fork < 0.0 and off >= fork:
		t_fork = t
	if absf(off - (fork + (merge - fork) * 0.5)) < 40.0:
		var line: SprintTrack.RouteLine = track.route_of(car)
		var want: StringName = routes[ri][0]
		if (line == null and want == &"") or (line != null and line.id == want):
			on_route_mid = true
	if off >= merge + 40.0 or t > 130.0:
		var label: String = routes[ri][1]
		var done := t_fork >= 0.0 and off >= merge + 40.0
		var dur := t - t_fork
		times[label] = dur
		_check(done, "%s: fork to merge in %.1f s" % [label, dur])
		_check(on_route_mid, "%s: car tracked on the intended route midway" % label)
		_check(jumps == 0, "%s: progress never jumped (%d jumps)" % [label, jumps])
		_check(driver.resets == 0, "%s: no watchdog resets (%d)" % [label, driver.resets])
		_check(car.health > 40.0, "%s: no heavy wall contact (health %.0f)" % [label, car.health])
		ri += 1
		if ri < routes.size():
			_start_route()
		else:
			var mx: float = times.values().max()
			var mn: float = times.values().min()
			_check(mx <= mn * 1.35, "routes take about the same time (%s)" % str(times))
			_finish()


func _finish() -> void:
	driver = null
	print("RESULT: %s" % ("FAIL" if fails > 0 else "PASS"))
	get_tree().quit(1 if fails > 0 else 0)


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["  ok  " if ok else "  FAIL", what])
	if not ok:
		fails += 1
