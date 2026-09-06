class_name SurfaceType
extends Resource
## Physical and cosmetic properties of one drivable surface (asphalt, sand, ice...).
## Tyre forces in RaycastCar scale by these values, so every terrain in the game is
## just a different SurfaceType tagged onto the geometry via `set_meta("surface", id)`.

@export var id: StringName = &"asphalt"
@export var display_name: String = "Asphalt"
@export var color: Color = Color(0.22, 0.22, 0.25)
@export var dust_color: Color = Color(0.5, 0.5, 0.5, 0.5)

## Peak friction multiplier. Asphalt is 1.0, ice is a fraction of that.
@export_range(0.05, 1.5) var grip: float = 1.0
## Fraction of grip available sideways. Lower values slide sideways more than they lose drive.
@export_range(0.1, 1.0) var lateral_grip: float = 1.0
## Rolling resistance as a fraction of wheel load.
@export_range(0.0, 0.2) var rolling_resistance: float = 0.012
## Soft-surface drag. 0 = hard ground, 1 = deep sand. Scales RaycastCar.sink_drag.
@export_range(0.0, 1.0) var sink: float = 0.0
## Random suspension noise amplitude in metres, felt as vibration on rough ground.
@export_range(0.0, 0.1) var bumpiness: float = 0.0
## Speed (m/s) above which the surface always kicks up dust. Negative = only when slipping.
@export var dust_speed: float = -1.0


func _init(
		p_id: StringName = &"asphalt",
		p_name: String = "Asphalt",
		p_color: Color = Color(0.22, 0.22, 0.25),
		p_grip: float = 1.0,
		p_lateral_grip: float = 1.0,
		p_rolling_resistance: float = 0.012,
		p_sink: float = 0.0,
		p_bumpiness: float = 0.0,
		p_dust_color: Color = Color(0.5, 0.5, 0.5, 0.5),
		p_dust_speed: float = -1.0) -> void:
	id = p_id
	display_name = p_name
	color = p_color
	grip = p_grip
	lateral_grip = p_lateral_grip
	rolling_resistance = p_rolling_resistance
	sink = p_sink
	bumpiness = p_bumpiness
	dust_color = p_dust_color
	dust_speed = p_dust_speed
