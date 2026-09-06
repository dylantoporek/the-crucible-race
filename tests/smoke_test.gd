extends Node
## Headless smoke test: loads the main scene, holds full throttle on the player car for a
## few seconds and asserts it actually drives. Run with:
##   godot --headless --path . res://tests/smoke_test.tscn

const MAIN := "res://scenes/main.tscn"
const DRIVE_FRAMES := 60 * 14
const SETTLE_FRAMES := 60

var _game: Node
var _player: RaycastCar
var _frame := 0
var _failed := false
var _max_speed := 0.0
var _surfaces_seen := {}


func _ready() -> void:
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
	var track: TestTrack = _game.track
	print("track length: %.1f m, segments: %d" % [track.length, track._segments.size()])
	_check(track.length > 1500.0, "track length is plausible")
	_check(_game.cars.size() == 1 + _game.ai_count, "all cars spawned")


func _physics_process(_delta: float) -> void:
	_frame += 1
	if _frame % 120 == 0:
		print("  t=%4.1fs  speed %5.1f km/h  surface %-8s  progress %.3f  ticks/s %.0f" % [
			_frame / 60.0, _player.speed * 3.6, _player.current_surface.id,
			_game.track.progress_of(_player.global_position), Engine.get_frames_per_second()])
	if _frame == SETTLE_FRAMES:
		_check(_player.grounded_wheels == 4, "player settles on all four wheels (got %d)" % _player.grounded_wheels)
		_check(_player.global_transform.basis.y.y > 0.95, "player is upright")
	if _frame > SETTLE_FRAMES:
		_max_speed = maxf(_max_speed, _player.speed)
		if _player.current_surface:
			_surfaces_seen[_player.current_surface.id] = true
	if _frame == SETTLE_FRAMES + 120:
		print("speed after 3 s: %.1f km/h" % (_player.speed * 3.6))
		_check(_player.speed > 12.0, "car accelerates off the line")
	if _frame >= SETTLE_FRAMES + DRIVE_FRAMES:
		print("max speed: %.1f km/h" % (_max_speed * 3.6))
		print("surfaces driven: %s" % [_surfaces_seen.keys()])
		print("progress: %.3f" % _game.track.progress_of(_player.global_position))
		_check(_max_speed > 25.0, "car reaches a sensible speed within %d s" % (DRIVE_FRAMES / 60))
		_check(_player.grounded_wheels >= 3, "car is still on the ground (grounded %d)" % _player.grounded_wheels)
		_check(_player.global_transform.basis.y.y > 0.8, "car has not rolled over")
		var off_centre: float = _game.track.distance_from_center(_player.global_position)
		_check(off_centre < _game.track.road_half_width + 1.0, "AI-driven car stays on the road (%.1f m from centre)" % off_centre)
		_check(_game.track.progress_of(_player.global_position) > 0.08, "car covers real distance around the loop")
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


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["  ok  " if ok else "  FAIL", what])
	if not ok:
		_failed = true
