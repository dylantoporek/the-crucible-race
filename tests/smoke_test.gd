extends Node
## Headless smoke test: loads the main scene, holds full throttle on the player car for a
## few seconds and asserts it actually drives. Run with:
##   godot --headless --path . res://tests/smoke_test.tscn

const MAIN := "res://scenes/main.tscn"
## Long enough that a bad getaway from the back of a 16-car grid still clears traffic:
## the check is that the car can drive, not that it got a clean launch.
const DRIVE_FRAMES := 60 * 18
const SETTLE_FRAMES := 60

var _game: Node
var _player: RaycastCar
var _frame := 0
var _failed := false
var _max_speed := 0.0
var _surfaces_seen := {}


func _ready() -> void:
	# Opponent lane wobble and spawn tuning come from the global RNG, so an unseeded run
	# launches a slightly different pack every time and the player's run off the line
	# varies with it. Pin it so a failure here means the car changed, not the dice.
	var seed_arg := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seed="):
			seed_arg = a.trim_prefix("seed=")
	seed(int(seed_arg) if seed_arg != "" else 20260912)
	var scene: PackedScene = load(MAIN)
	_game = scene.instantiate()
	add_child(_game)
	_player = _game.player
	# Swap the input reader for an AI so the test can drive the player round the circuit.
	_player.get_node("PlayerDriver").queue_free()
	var driver := AIDriver.new()
	driver.name = "TestDriver"
	driver.track = _game.track
	driver.aggression = 0.0
	_player.add_child(driver)
	_game.skip_countdown()
	var track: SprintTrack = _game.track
	print("course: %.0f m total, %.0f m raced, %d stages, %d surface runs" % [
		track.length, track.race_length, track.stages().size(), track._surface_runs.size()])
	_check(track.race_length > 5000.0, "sprint course is a plausible length")
	_check(track.finish_offset > track.start_offset, "finish line is ahead of the start line")
	_check_route_clearance(track)
	_check(_game.cars.size() == 1 + _game.ai_count, "all cars spawned")


func _physics_process(_delta: float) -> void:
	_frame += 1
	if _frame % 120 == 0:
		print("  t=%4.1fs  speed %5.1f km/h  surface %-8s  progress %.3f  ticks/s %.0f" % [
			_frame / 60.0, _player.speed * 3.6, _player.current_surface.id,
			_game.track.body_progress(_player), Engine.get_frames_per_second()])
	if _frame == SETTLE_FRAMES:
		_check(_player.grounded_wheels == 4, "player settles on all four wheels (got %d)" % _player.grounded_wheels)
		_check(_player.global_transform.basis.y.y > 0.95, "player is upright")
	if _frame > SETTLE_FRAMES:
		_max_speed = maxf(_max_speed, _player.speed)
		if _player.current_surface:
			_surfaces_seen[_player.current_surface.id] = true
	if _frame == SETTLE_FRAMES + 120:
		print("speed after 2 s of throttle: %.1f km/h" % (_player.speed * 3.6))
		# The grid sits on dirt, so this is well below an asphalt launch (solo dirt is ~10.8 m/s
		# at this point, and a 16-car pack costs a little more).
		_check(_player.speed > 7.5, "car accelerates off the line on dirt")
	if _frame >= SETTLE_FRAMES + DRIVE_FRAMES:
		print("max speed: %.1f km/h" % (_max_speed * 3.6))
		print("surfaces driven: %s" % [_surfaces_seen.keys()])
		print("progress: %.3f  stage: %s" % [_game.track.body_progress(_player),
			_game.track.stage_at(_game.track.track_offset(_player)).get("name", "?")])
		_check(_max_speed > 25.0, "car reaches a sensible speed within %d s" % (DRIVE_FRAMES / 60))
		_check(_player.grounded_wheels >= 3, "car is still on the ground (grounded %d)" % _player.grounded_wheels)
		_check(_player.global_transform.basis.y.y > 0.8, "car has not rolled over")
		var off: float = _game.track.track_offset(_player)
		var off_centre: float = _game.track.distance_from_center_at(_player.global_position, off)
		_check(off_centre < _game.track.width_at(off) + 1.0,
			"AI-driven car stays on the road (%.1f m from centre of a %.1f m half-width)" % [off_centre, _game.track.width_at(off)])
		_check(_game.track.body_progress(_player) > 0.02, "car covers real distance along the course")
		var wheel_state: Array = []
		for w in _player.wheels:
			wheel_state.append("%s=%.3f" % [w.name.trim_prefix("Wheel"), w.compression])
		print("suspension compression: %s" % [wheel_state])
		var ai_moving := 0
		for car in _game.cars:
			if car != _player and car.speed > 5.0:
				ai_moving += 1
		print("AI cars moving: %d / %d" % [ai_moving, _game.ai_count])
		_check(ai_moving >= 1, "AI opponents drive off the grid")
		print("RESULT: %s" % ("FAIL" if _failed else "PASS"))
		get_tree().quit(1 if _failed else 0)


## The route is generated, so guard against it doubling back and overlapping itself:
## no two points more than a corner apart may come within the road's own width.
func _check_route_clearance(track: SprintTrack) -> void:
	var step := 12.0
	var pts: Array[Vector3] = []
	var widths: Array[float] = []
	var o := 0.0
	while o < track.length:
		var f: Dictionary = track.frame_at(o)
		pts.append(f["pos"])
		widths.append(track.width_at(o))
		o += step
	var worst := INF
	var worst_at := 0.0
	var skip := int(140.0 / step)
	for i in pts.size():
		for j in range(i + skip, pts.size()):
			var need: float = widths[i] + widths[j] + 6.0
			var d: float = pts[i].distance_to(pts[j])
			if d < need and d < worst:
				worst = d
				worst_at = i * step
	if worst == INF:
		print("route clearance: no overlap anywhere")
		_check(true, "route never overlaps itself")
	else:
		print("route clearance: closest non-adjacent approach %.1f m near %.0f m" % [worst, worst_at])
		_check(false, "route never overlaps itself")


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["  ok  " if ok else "  FAIL", what])
	if not ok:
		_failed = true
