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

var current_stage_index := 0     # where the last (re)start put the field
var countdown := 0.0             # seconds until the field is released
var go_flash := 0.0              # how long "GO!" stays up after release

const COUNTDOWN_SETTLE := 0.6    # cars drop onto the grid before READY
const COUNTDOWN_BEAT := 1.0      # READY, then SET, each this long
const GO_FLASH := 0.9

var _grid_slot: Dictionary = {}  # car -> grid index

var _progress: Dictionary = {}   # car -> 0..1 along the course
var _finished: Dictionary = {}   # car -> finishing time
var _places := 0


func _ready() -> void:
	$Sun.rotation_degrees = Vector3(-52.0, -35.0, 0.0)
	# The player starts at the back of the pack; the AI fills the grid ahead.
	player = _spawn_car(ai_count, true)
	for i in ai_count:
		var ai := _spawn_car(i, false)
		(ai.get_node("AIDriver") as AIDriver).rival = player
	camera.target = player
	camera.snap_behind_target()
	hud.setup(self)
	var requested := _stage_from_url()
	if requested > 0:
		restart_at_stage(requested)
	else:
		_begin_countdown()


## `?stage=3` or `?stage=mountain` on the web build drops straight into that stage, so a
## tester can be sent a link to the part of the course under discussion.
func _stage_from_url() -> int:
	if not OS.has_feature("web"):
		return 0
	var query := str(JavaScriptBridge.eval("window.location.search", true))
	var re := RegEx.new()
	re.compile("[?&]stage=([A-Za-z0-9_]+)")
	var m := re.search(query)
	if m == null:
		return 0
	var value := m.get_string(1).to_lower()
	if value.is_valid_int():
		return clampi(int(value) - 1, 0, track.stages().size() - 1)
	var stages := track.stages()
	for i in stages.size():
		var spec: Dictionary = stages[i]["spec"]
		if String(spec["id"]) == value or String(spec["name"]).to_lower().begins_with(value):
			return i
	return 0


## Put the whole field on a grid at the start of a stage and restart the clock. Stage 0 is
## the real start line.
func restart_at_stage(index: int) -> void:
	var stages := track.stages()
	index = clampi(index, 0, stages.size() - 1)
	var line: float = track.start_offset if index == 0 else float(stages[index]["a"])
	for car in cars:
		car.reset_to(track.get_grid_transform(_grid_slot[car], line))
		track.invalidate_cursor(car)
		car.hits = 0
		car.repair()
		car.gadget_slot.reset()
		var driver := car.get_node_or_null("AIDriver") as AIDriver
		if driver:
			driver.reset_state()
	track.reset_pickups()
	race_time = 0.0
	player_finished = false
	player_finish_time = 0.0
	player_finish_place = 0
	_finished.clear()
	_places = 0
	for car in cars:
		_progress[car] = track.body_progress(car)
	camera.snap_behind_target()
	current_stage_index = index
	_begin_countdown()


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
		ai.others = cars
		ai.preferred_route = [&"", &"avenue", &"tunnel"][index % 3]
		# Every other grid slot is a bruiser; the rest would rather win than trade paint.
		if index % 2 == 0:
			ai.style = AIDriver.BRUISER
			ai.aggression = randf_range(0.28, 0.52)
			ai.skill = randf_range(0.86, 0.98)
			ai.preferred_gadget = [&"shield", &"oil"][randi() % 2]
			_add_bull_bar(car)
		else:
			ai.style = AIDriver.RACER
			ai.aggression = 0.0
			ai.skill = randf_range(0.92, 1.04)
			ai.preferred_gadget = [&"boost", &"jump"][randi() % 2]
		car.add_child(ai)
	cars.append(car)
	_grid_slot[car] = index
	_progress[car] = track.body_progress(car)
	return car


## A black bar across the nose marks a bruiser, so you can see who to keep away from.
func _add_bull_bar(car: RaycastCar) -> void:
	var body := car.get_node("Visual/Body") as MeshInstance3D
	var aabb := body.get_aabb()
	var bar := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(aabb.size.x + 0.1, 0.34, 0.18)
	bar.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.09)
	mat.roughness = 0.6
	bar.material_override = mat
	bar.position = body.position + Vector3(0.0, aabb.position.y + aabb.size.y * 0.55, aabb.position.z - 0.02)
	body.get_parent().add_child(bar)


## Hold the field on the grid: READY, SET, then release on GO.
func _begin_countdown() -> void:
	countdown = COUNTDOWN_SETTLE + 2.0 * COUNTDOWN_BEAT
	go_flash = 0.0
	for car in cars:
		car.controls_locked = true


## Release immediately (used by tests and handy for tuning).
func skip_countdown() -> void:
	countdown = 0.0
	go_flash = 0.0
	for car in cars:
		car.controls_locked = false


## What the big centre label should read right now, or "" for nothing.
func countdown_text() -> String:
	if countdown > 2.0 * COUNTDOWN_BEAT:
		return ""
	if countdown > COUNTDOWN_BEAT:
		return "READY"
	if countdown > 0.0:
		return "SET"
	if go_flash > 0.0:
		return "GO!"
	return ""


func _process(delta: float) -> void:
	if countdown > 0.0:
		countdown -= delta
		if countdown <= 0.0:
			go_flash = GO_FLASH
			for car in cars:
				car.controls_locked = false
	else:
		go_flash = maxf(go_flash - delta, 0.0)
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
	for i in 6:
		if Input.is_action_just_pressed("stage_%d" % (i + 1)):
			restart_at_stage(i)


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
	track.invalidate_cursor(player)


func _on_player_impact(strength: float, _other: Node) -> void:
	camera.add_shake(clampf(strength / 12000.0, 0.15, 1.0))
