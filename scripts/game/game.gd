extends Node3D
## Session controller: spawns the player and AI cars on the grid, wires camera and HUD,
## tracks laps and race positions, and handles resets.

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

@export var ai_count := 5

@onready var track: TestTrack = $TestTrack
@onready var camera: ChaseCamera = $ChaseCamera
@onready var hud: CanvasLayer = $HUD
@onready var cars_root: Node3D = $Cars

var player: RaycastCar
var cars: Array[RaycastCar] = []
var lap := 0
var lap_time := 0.0
var best_lap := INF
var last_lap := 0.0
var race_time := 0.0

var _laps: Dictionary = {}          # car -> completed laps
var _prev_progress: Dictionary = {} # car -> last progress 0..1
var _half_passed: Dictionary = {}   # car -> bool


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
		ai.lane_offset = randf_range(-4.0, 4.0)
		ai.aggression = randf_range(0.3, 0.9)
		ai.skill = randf_range(0.88, 1.02)
		car.add_child(ai)
	cars.append(car)
	_laps[car] = 0
	_prev_progress[car] = track.progress_of(car.global_position)
	_half_passed[car] = false
	return car


func _process(delta: float) -> void:
	race_time += delta
	lap_time += delta
	for car in cars:
		_update_progress(car)
	if Input.is_action_just_pressed("toggle_debug"):
		hud.visible = not hud.visible


func _update_progress(car: RaycastCar) -> void:
	var p := track.progress_of(car.global_position)
	var prev: float = _prev_progress[car]
	if p > 0.45 and p < 0.55:
		_half_passed[car] = true
	if prev > 0.9 and p < 0.1 and _half_passed[car]:
		_laps[car] += 1
		_half_passed[car] = false
		if car == player:
			_complete_player_lap()
	elif prev < 0.1 and p > 0.9:
		# Crossed the line backwards; take the lap away so it can't be farmed.
		_laps[car] = maxi(_laps[car] - 1, 0)
	_prev_progress[car] = p


func _complete_player_lap() -> void:
	lap += 1
	last_lap = lap_time
	best_lap = minf(best_lap, lap_time)
	lap_time = 0.0


## 1-based race position of a car, by laps then distance around the loop.
func position_of(car: RaycastCar) -> int:
	var score := _score(car)
	var pos := 1
	for other in cars:
		if other != car and _score(other) > score:
			pos += 1
	return pos


func _score(car: RaycastCar) -> float:
	return float(_laps[car]) + _prev_progress[car]


func _on_player_reset() -> void:
	player.reset_to(track.snap_to_track(player.global_position))


func _on_player_impact(strength: float, _other: Node) -> void:
	camera.add_shake(clampf(strength / 12000.0, 0.15, 1.0))
