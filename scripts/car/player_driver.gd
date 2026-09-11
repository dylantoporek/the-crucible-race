class_name PlayerDriver
extends Node
## Feeds keyboard / gamepad input into the parent RaycastCar.

signal reset_requested

var car: RaycastCar


func _ready() -> void:
	process_physics_priority = -1
	car = get_parent() as RaycastCar


func _physics_process(_delta: float) -> void:
	car.input_throttle = Input.get_action_strength("accelerate")
	car.input_brake = Input.get_action_strength("brake")
	car.input_steer = Input.get_axis("steer_left", "steer_right")
	car.input_handbrake = Input.is_action_pressed("handbrake")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		reset_requested.emit()
	elif event.is_action_pressed("use_gadget"):
		car.gadget_slot.try_use()
