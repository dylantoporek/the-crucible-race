class_name PickupBox
extends Area3D
## A gadget pickup. Floats, spins and glows so it reads as a prize rather than a crate;
## has no collision, so cars drive straight through it. The first car to reach it that is
## not already carrying a gadget takes it, and it is gone for the rest of the race. A car
## that already has a gadget passes through and leaves it for someone else.

const GLOW := Color(0.25, 0.95, 1.0)
const GLOW_ALT := Color(1.0, 0.45, 0.95)
const FLOAT_HEIGHT := 1.15               ## How far above the road the cube hovers
const ROW_COUNT := 3                     ## Boxes side by side at each spot

static var _rng := RandomNumberGenerator.new()

var _base_y := 0.0
var _phase := 0.0
var taken := false
var _cube: MeshInstance3D
var _ring: MeshInstance3D
var _beam: MeshInstance3D


func _ready() -> void:
	name = "Pickup"
	collision_layer = 0
	collision_mask = 2                   # vehicles
	monitorable = false
	_base_y = position.y
	_phase = _rng.randf() * TAU
	body_entered.connect(_on_body_entered)

	var trigger := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.7
	trigger.shape = sphere
	add_child(trigger)

	_cube = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.1, 1.1, 1.1)
	_cube.mesh = box
	_cube.material_override = _glow_material(GLOW, 0.55, 0.0)   # see-through so the core shows
	add_child(_cube)

	# Inner cube in the second colour, offset 45 degrees, so it sparkles as it turns.
	var inner := MeshInstance3D.new()
	var ibox := BoxMesh.new()
	ibox.size = Vector3(0.66, 0.66, 0.66)
	inner.mesh = ibox
	inner.material_override = _glow_material(GLOW_ALT, 1.0, 0.0)
	inner.rotation = Vector3(0.0, PI * 0.25, PI * 0.25)
	_cube.add_child(inner)

	_ring = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.5
	disc.bottom_radius = 1.5
	disc.height = 0.03
	disc.radial_segments = 24
	_ring.mesh = disc
	_ring.material_override = _glow_material(GLOW, 0.35, 0.0)
	_ring.position = Vector3(0.0, -FLOAT_HEIGHT + 0.06, 0.0)
	add_child(_ring)

	_beam = MeshInstance3D.new()
	var beam := BoxMesh.new()
	beam.size = Vector3(0.22, 7.0, 0.22)
	_beam.mesh = beam
	_beam.material_override = _glow_material(GLOW, 0.28, 0.0)
	_beam.position = Vector3(0.0, 3.2, 0.0)
	add_child(_beam)


static func _glow_material(color: Color, alpha: float, _unused: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 1.6
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _process(delta: float) -> void:
	if taken:
		return
	_phase += delta
	_cube.rotation.y += delta * 1.6
	_cube.rotation.x = sin(_phase * 0.7) * 0.25
	_cube.position.y = sin(_phase * 2.0) * 0.18
	_ring.rotation.y -= delta * 0.8
	_ring.scale = Vector3.ONE * (1.0 + 0.06 * sin(_phase * 3.0))


func _on_body_entered(body: Node3D) -> void:
	if taken or not (body is RaycastCar):
		return
	var car := body as RaycastCar
	if car.gadget_slot.gadget != &"":
		return                      # already armed: leave it for someone else
	car.gadget_slot.give(Gadgets.random_id(_rng))
	taken = true
	visible = false
	set_deferred("monitoring", false)


## Boxes only come back when the race itself restarts.
func respawn_now() -> void:
	taken = false
	visible = true
	set_deferred("monitoring", true)
