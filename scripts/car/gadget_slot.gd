class_name GadgetSlot
extends Node
## The one gadget a car is carrying, its cooldown, and the effect while it is active.
## Child of a RaycastCar. Drivers call try_use(); pickups call give().

signal changed
signal used(id: StringName)

var gadget: StringName = &""
var cooldown := 0.0        ## Seconds until it can be used again
var active := 0.0          ## Seconds the current effect has left

var car: RaycastCar


func _ready() -> void:
	car = get_parent() as RaycastCar


## Hand the car a gadget. Picking up the one it already holds changes nothing; a different
## one replaces it, but the cooldown carries over so boxes cannot be used to skip it.
func give(id: StringName) -> bool:
	if id == gadget or not Gadgets.DEFS.has(id):
		return false
	if active > 0.0:
		_deactivate()
	gadget = id
	changed.emit()
	return true


func can_use() -> bool:
	return gadget != &"" and cooldown <= 0.0 and active <= 0.0 \
			and car != null and not car.controls_locked


func try_use() -> bool:
	if not can_use():
		return false
	_activate()
	cooldown = Gadgets.COOLDOWN
	used.emit(gadget)
	changed.emit()
	return true


func reset() -> void:
	_deactivate()
	gadget = &""
	cooldown = 0.0
	active = 0.0
	changed.emit()


func _process(delta: float) -> void:
	if cooldown > 0.0:
		cooldown = maxf(cooldown - delta, 0.0)
	if active > 0.0:
		active -= delta
		if active <= 0.0:
			active = 0.0
			_deactivate()


func _activate() -> void:
	match gadget:
		&"jump":
			car.jump(6.8)
		&"shield":
			car.shielded = true
			active = Gadgets.duration_of(gadget)
		&"boost":
			car.engine_multiplier = 1.75
			car.speed_multiplier = 1.3
			active = Gadgets.duration_of(gadget)
		&"oil":
			OilSlick.drop_behind(car)


func _deactivate() -> void:
	if car == null:
		return
	car.shielded = false
	car.engine_multiplier = 1.0
	car.speed_multiplier = 1.0
