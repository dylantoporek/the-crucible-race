extends Node
## Headless check of damage, repair, pickups and each gadget. Run with:
##   godot --headless --path . res://tests/gadget_test.tscn

const MAIN := "res://scenes/main.tscn"

var game: Node
var player: RaycastCar
var track: SprintTrack
var t := 0.0
var step := 0
var fails := 0
var _mark := 0.0
var _force_before := 0.0
var _oil_before := 0
var _box: PickupBox
var _box2: PickupBox


func _ready() -> void:
	var scene: PackedScene = load(MAIN)
	game = scene.instantiate()
	add_child(game)
	game.skip_countdown()
	player = game.player
	track = game.track
	player.get_node("PlayerDriver").queue_free()
	for car in game.cars:
		if car != player:
			var d := car.get_node("AIDriver") as AIDriver
			d.process_mode = Node.PROCESS_MODE_DISABLED   # keep the pack out of the test
			car.controls_locked = true
	var boxes := 0
	var stations := 0
	for c in track.get_children():
		if c is PickupBox: boxes += 1
		if c is RepairStation: stations += 1
	_check(boxes >= 12 and boxes <= 24, "one gadget box roughly every %.0f m (%d boxes)" % [RouteSpec.PICKUP_SPACING, boxes])
	_check(stations == 3, "three repair stations (%d)" % stations)
	for c in track.get_children():
		if c is PickupBox:
			if _box == null:
				_box = c
			elif _box2 == null:
				_box2 = c


func _physics_process(delta: float) -> void:
	t += delta
	match step:
		0:
			# Damage: power drops, steering pulls, then repair restores.
			_force_before = player._engine_force(10.0) if player.input_throttle > 0.0 else 0.0
			player.input_throttle = 1.0
			_force_before = player._engine_force(10.0)
			player.take_damage(40.0, 1.0)
			_check(is_equal_approx(player.health, 60.0), "40 damage leaves 60 health (%.0f)" % player.health)
			var after: float = player._engine_force(10.0)
			_check(after < _force_before * 0.85, "damage cuts engine force (%.0f -> %.0f N)" % [_force_before, after])
			_check(player.effective_top_speed() < player.top_speed, "damage cuts top speed")
			_check(player.pull_sign > 0.0, "car pulls toward the side that was hit")
			player.take_damage(80.0, -1.0)
			_check(player.is_wrecked(), "health floors at zero and the car is wrecked")
			_check(player._engine_force(10.0) > 0.0, "a wrecked car can still move")
			player.repair()
			_check(is_equal_approx(player.health, 100.0), "repair restores full health")
			player.input_throttle = 0.0
			step = 1
		1:
			# Pickup: teleport onto a box and get a gadget.
			var slot := player.gadget_slot
			_check(slot.gadget == &"", "player starts with no gadget")
			var p: Vector3 = _box.global_position
			player.reset_to(Transform3D(Basis(), Vector3(p.x, p.y - 0.4, p.z)))
			track.invalidate_cursor(player)
			_mark = t
			step = 2
		2:
			if t - _mark > 0.6:
				var slot := player.gadget_slot
				_check(slot.gadget != &"", "driving through a box grants a gadget (%s)" % String(slot.gadget))
				_check(not _box.visible and _box.taken, "the box is gone once taken")
				# Already armed: the next box must be left alone.
				var p2: Vector3 = _box2.global_position
				player.reset_to(Transform3D(Basis(), Vector3(p2.x, p2.y - 0.4, p2.z)))
				track.invalidate_cursor(player)
				_mark = t
				step = 21
		21:
			if t - _mark > 0.6:
				_check(_box2.visible and not _box2.taken, "a car that already has a gadget passes through and leaves the box")
				var slot := player.gadget_slot
				slot.gadget = &""
				slot.give(&"jump")
				step = 3
		3:
			var slot := player.gadget_slot
			_check(slot.can_use(), "jump is ready")
			var ok := slot.try_use()
			_check(ok, "jump fires")
			_check(slot.cooldown > 19.0, "cooldown starts at %.0f s" % Gadgets.COOLDOWN)
			_check(not slot.can_use(), "cannot fire again during cooldown")
			_mark = t
			step = 4
		4:
			if t - _mark > 0.35:
				_check(player.grounded_wheels == 0, "car is airborne after the jump (grounded %d)" % player.grounded_wheels)
				var slot := player.gadget_slot
				slot.give(&"shield")
				_check(slot.gadget == &"shield", "picking up a different gadget replaces the old one")
				_check(slot.cooldown > 18.0, "...but the cooldown carries over (%.1f s)" % slot.cooldown)
				slot.cooldown = 0.0
				slot.try_use()
				_check(player.shielded, "shield is up")
				var h := player.health
				player.take_damage(30.0, 1.0)
				_check(is_equal_approx(player.health, h), "shielded car takes no damage")
				_mark = t
				step = 5
		5:
			if t - _mark > 5.3:
				_check(not player.shielded, "shield drops after its duration")
				var slot := player.gadget_slot
				slot.cooldown = 0.0
				slot.give(&"boost")
				slot.try_use()
				_check(player.engine_multiplier > 1.5, "boost raises engine power (x%.2f)" % player.engine_multiplier)
				_check(player.effective_top_speed() > player.top_speed, "boost raises top speed")
				_mark = t
				step = 6
		6:
			if t - _mark > 3.3:
				_check(is_equal_approx(player.engine_multiplier, 1.0), "boost wears off")
				var slot := player.gadget_slot
				slot.cooldown = 0.0
				slot.give(&"oil")
				_oil_before = _count_oil()
				# Put the car back on solid ground first so the slick has somewhere to land.
				player.reset_to(track.snap_to_track(player.global_position))
				track.invalidate_cursor(player)
				_mark = t
				step = 7
		7:
			if t - _mark > 0.5:
				player.gadget_slot.try_use()
				_mark = t
				step = 8
		8:
			if t - _mark > 0.2:
				_check(_count_oil() == _oil_before + 1, "oil slick is dropped behind the car")
				var slick := _find_oil()
				_check(slick != null and slick.get_meta(&"surface") == &"ice", "the slick drives like ice")
				# Repair station: hurt the car and teleport it onto the first pad.
				player.take_damage(55.0, 1.0)
				var st: Array = track.next_repair_station(0.0, 1.0e9)
				var pad := track.surface_point(float(st[0]), float(st[1])) + Vector3.UP * 0.9
				player.reset_to(Transform3D(Basis(), track.to_global(pad)))
				track.invalidate_cursor(player)
				_mark = t
				step = 9
		9:
			if t - _mark > 0.6:
				_check(is_equal_approx(player.health, 100.0), "repair station restores health on contact (%.0f)" % player.health)
				print("RESULT: %s" % ("FAIL" if fails > 0 else "PASS"))
				get_tree().quit(1 if fails > 0 else 0)
				step = 99


func _count_oil() -> int:
	var n := 0
	for c in game.get_node("Cars").get_children():
		if c is OilSlick:
			n += 1
	return n


func _find_oil() -> Node:
	for c in game.get_node("Cars").get_children():
		if c is OilSlick:
			return c
	return null


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["  ok  " if ok else "  FAIL", what])
	if not ok:
		fails += 1
