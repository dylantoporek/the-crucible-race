class_name CarWheel
extends Node3D
## One corner of a RaycastCar. This node sits at the suspension attach point;
## the car casts a ray straight down from here each physics tick and writes the
## runtime state below. `Visual` is moved/rotated to match, `Dust` emits on slip.

@export var is_steer := false
@export var is_drive := true
@export var radius := 0.34
## Suspension length at full extension (metres).
@export var suspension_rest := 0.32
@export var spring_stiffness := 32000.0
@export var damping_bump := 2600.0
@export var damping_rebound := 3800.0

# --- Runtime state written by RaycastCar ---
var grounded := false
var compression := 0.0
var hit_distance := 0.0
var contact_point := Vector3.ZERO
var contact_normal := Vector3.UP
var load := 0.0
var surface: SurfaceType
# Surface parameters low-pass filtered by the car so a change of terrain fades in over
# a fraction of a second instead of snapping between physics ticks.
var grip_eff := 1.0
var lateral_grip_eff := 1.0
var rolling_resistance_eff := 0.012
var sink_eff := 0.0
var steer_angle := 0.0
var slip_lateral := 0.0        # m/s sideways at the contact patch
var slip_ratio := 0.0          # 0..1+ how hard the tyre is being asked vs what it can give
var slipping := false
var spin_speed := 0.0          # rad/s for the visual

var _spin := 0.0

@onready var visual: Node3D = $Visual
@onready var dust: CPUParticles3D = $Dust


func ray_length() -> float:
	return suspension_rest + radius


## Move the effective surface parameters toward `target` with time constant `tau` seconds.
func blend_surface(target: SurfaceType, delta: float, tau: float) -> void:
	if surface == null or tau <= 0.0:
		grip_eff = target.grip
		lateral_grip_eff = target.lateral_grip
		rolling_resistance_eff = target.rolling_resistance
		sink_eff = target.sink
		return
	var k := 1.0 - exp(-delta / tau)
	grip_eff = lerpf(grip_eff, target.grip, k)
	lateral_grip_eff = lerpf(lateral_grip_eff, target.lateral_grip, k)
	rolling_resistance_eff = lerpf(rolling_resistance_eff, target.rolling_resistance, k)
	sink_eff = lerpf(sink_eff, target.sink, k)


func update_visual(delta: float) -> void:
	var extension := (hit_distance - radius) if grounded else suspension_rest
	visual.position = Vector3(0.0, -extension, 0.0)
	_spin = fmod(_spin + spin_speed * delta, TAU)
	visual.rotation = Vector3(_spin, steer_angle, 0.0)


func set_dust(on: bool, color: Color, at: Vector3) -> void:
	if on:
		dust.global_position = at
		dust.color = color
	dust.emitting = on
