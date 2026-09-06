extends Node
## Autoloaded as `Surfaces`. Registry of every SurfaceType keyed by id.
## Geometry declares its surface with `body.set_meta("surface", &"sand")`;
## RaycastCar looks it up here for each wheel every physics tick.

var default_surface: SurfaceType
var _types: Dictionary = {}


func _init() -> void:
	# id, name, colour, grip, lateral grip, rolling resistance, sink, bumpiness, dust colour, dust speed
	_register(SurfaceType.new(&"asphalt", "Asphalt", Color(0.23, 0.23, 0.27),
			1.00, 1.00, 0.012, 0.00, 0.000, Color(0.55, 0.55, 0.55, 0.35), -1.0))
	_register(SurfaceType.new(&"dirt", "Dirt", Color(0.46, 0.31, 0.17),
			0.72, 0.82, 0.030, 0.06, 0.018, Color(0.55, 0.40, 0.22, 0.65), 12.0))
	_register(SurfaceType.new(&"sand", "Sand", Color(0.86, 0.74, 0.47),
			0.60, 0.72, 0.070, 0.28, 0.010, Color(0.90, 0.80, 0.55, 0.70), 6.0))
	_register(SurfaceType.new(&"ice", "Ice", Color(0.70, 0.86, 0.97),
			0.22, 0.65, 0.006, 0.00, 0.000, Color(0.85, 0.93, 1.00, 0.35), -1.0))
	_register(SurfaceType.new(&"snow", "Snow", Color(0.94, 0.95, 0.97),
			0.45, 0.75, 0.060, 0.22, 0.012, Color(1.00, 1.00, 1.00, 0.75), 6.0))
	_register(SurfaceType.new(&"grass", "Grass", Color(0.34, 0.56, 0.23),
			0.62, 0.70, 0.060, 0.14, 0.030, Color(0.45, 0.55, 0.25, 0.55), 10.0))
	default_surface = _types[&"asphalt"]


func _register(t: SurfaceType) -> void:
	_types[t.id] = t


func get_type(id: StringName) -> SurfaceType:
	return _types.get(id, default_surface)


## Resolve the surface for whatever the wheel ray hit.
func for_collider(collider: Object) -> SurfaceType:
	if collider != null and collider.has_meta(&"surface"):
		return get_type(collider.get_meta(&"surface"))
	return default_surface


func all_types() -> Array:
	return _types.values()
