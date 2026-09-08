extends Node3D
## Session controller: spawns the player and AI cars on the grid, wires camera and HUD,
## tracks progress toward the finish line, and handles resets.

const CAR_SCENE := preload("res://scenes/car.tscn")
const PLAYER_COLOR := Color(0.90, 0.20, 0.15)
const AI_COLORS: Array[Color] = [
	Color(0.15, 0.45, 0.95),
	Color(0.95, 0.75, 0.10),
	Color(0.20, 0.75, 0.35),
	Color(0.75, 0.25, 0.85),
	Color(0.95, 0.50, 0.10),
	Color(0.20, 0.80, 0.85),
	Color(0.55, 0.55, 0.60),
]

@export var ai_count := 15

@onready var track: SprintTrack = $SprintTrack
@onready var camera: ChaseCamera = $ChaseCamera
@onready var hud: CanvasLayer = $HUD
@onready var cars_root: Node3D = $Cars

var player: RaycastCar
var cars: Array[RaycastCar] = []
var race_time := 0.0
var player_finished := false
var player_finish_time := 0.0
var player_finish_place := 0

var _progress: Dictionary = {}   # car -> 0..1 along the course
var _finished: Dictionary = {}   # car -> finishing time
var _places := 0


func _ready() -> void:
	$Sun.rotation_degrees = Vector3(-52.0, -35.0, 0.0)
	player = _spawn_car(0, true)
	for i in ai_count:
		var ai := _spawn_car(i + 1, false)
		(ai.get_node("AIDriver") as AIDriver).rival = player
	camera.target = player
	camera.snap_behind_target()
	hud.setup(self)


func _spawn_car(index: int, is_player: bool) -> RaycastCar:
	var car: RaycastCar = CAR_SCENE.instantiate()
	car.name = "Player" if is_player else "AI%d" % index
	car.paint_color = PLAYER_COLOR if is_player else AI_COLORS[(index - 1) % AI_COLORS.size()]
	cars_root.add_child(car)
	car.reset_to(track.get_grid_transform(index))
	if is_player:
		var driver := PlayerDriver.new()
		driver.name = "PlayerDriver"
		car.add_child(driver)
		driver.reset_requested.connect(_on_player_reset)
		car.impact.connect(_on_player_impact)
	else:
		var ai := AIDriver.new()
		ai.name = "AIDriver"
		ai.track = track
		ai.lane_offset = randf_range(-0.45, 0.45)
		ai.aggression = randf_range(0.3, 0.9)
		ai.skill = randf_range(0.88, 1.02)
		car.add_child(ai)
	cars.append(car)
	_progress[car] = track.body_progress(car)
	return car


func _process(delta: float) -> void:
	if not player_finished:
		race_time += delta
	for car in cars:
		_progress[car] = track.body_progress(car)
		if not _finished.has(car) and _progress[car] >= 1.0:
			_places += 1
			_finished[car] = race_time
			if car == player:
				player_finished = true
				player_finish_time = race_time
				player_finish_place = _places
	if Input.is_action_just_pressed("toggle_debug"):
		hud.visible = not hud.visible


## 1-based race position, by distance covered; cars that have finished keep their place.
func position_of(car: RaycastCar) -> int:
	if _finished.has(car):
		var place := 1
		for other in cars:
			if other != car and _finished.has(other) and _finished[other] < _finished[car]:
				place += 1
		return place
	var pos := _finished.size() + 1
	for other in cars:
		if other != car and not _finished.has(other) and _progress[other] > _progress[car]:
			pos += 1
	return pos


func progress_of(car: RaycastCar) -> float:
	return _progress.get(car, 0.0)


func has_finished(car: RaycastCar) -> bool:
	return _finished.has(car)


## Metres of course still to cover.
func distance_remaining(car: RaycastCar) -> float:
	return maxf(track.race_length * (1.0 - progress_of(car)), 0.0)


func _on_player_reset() -> void:
	player.reset_to(track.snap_to_track(player.global_position))


func _on_player_impact(strength: float, _other: Node) -> void:
	camera.add_shake(clampf(strength / 12000.0, 0.15, 1.0))
