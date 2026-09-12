class_name RepairStation
extends Area3D
## A repair pad at the side of the road. Drive onto it and the car is made whole; it costs
## you the line and a little time, which is the trade. It is also the pit: for a few
## seconds after rolling over it you can pick any gadget, or you are handed one if you had
## none. Green everything, so it cannot be mistaken for a hazard or a gadget box.

const GREEN := Color(0.30, 0.95, 0.45)
const PAD_LENGTH := 16.0
const PAD_WIDTH := 6.5

var _icon: Node3D
var _phase := 0.0


func _ready() -> void:
	name = "RepairStation"
	collision_layer = 0
	collision_mask = 2
	monitorable = false
	body_entered.connect(_on_body_entered)

	var trigger := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(PAD_WIDTH, 3.0, PAD_LENGTH)
	trigger.shape = box
	trigger.position = Vector3(0.0, 1.5, 0.0)
	add_child(trigger)

	var pad := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(PAD_WIDTH, 0.08, PAD_LENGTH)
	pad.mesh = pm
	pad.material_override = _mat(GREEN, 0.55)
	pad.position = Vector3(0.0, 0.05, 0.0)
	add_child(pad)

	var edge := MeshInstance3D.new()
	var em := BoxMesh.new()
	em.size = Vector3(PAD_WIDTH + 0.6, 0.04, PAD_LENGTH + 0.6)
	edge.mesh = em
	edge.material_override = _mat(Color(0.9, 1.0, 0.9), 0.9)
	edge.position = Vector3(0.0, 0.03, 0.0)
	add_child(edge)

	for z in [-PAD_LENGTH * 0.5, PAD_LENGTH * 0.5]:
		var post := MeshInstance3D.new()
		var post_mesh := BoxMesh.new()
		post_mesh.size = Vector3(0.35, 5.0, 0.35)
		post.mesh = post_mesh
		post.material_override = _mat(GREEN, 1.0)
		post.position = Vector3(PAD_WIDTH * 0.5 + 0.4, 2.5, z)
		add_child(post)
	var bar := MeshInstance3D.new()
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3(0.3, 0.3, PAD_LENGTH + 0.4)
	bar.mesh = bar_mesh
	bar.material_override = _mat(GREEN, 1.0)
	bar.position = Vector3(PAD_WIDTH * 0.5 + 0.4, 5.0, 0.0)
	add_child(bar)

	# A slowly turning plus sign above the pad.
	_icon = Node3D.new()
	_icon.position = Vector3(0.0, 4.2, 0.0)
	add_child(_icon)
	for size in [Vector3(2.2, 0.6, 0.5), Vector3(0.6, 2.2, 0.5)]:
		var arm := MeshInstance3D.new()
		var am := BoxMesh.new()
		am.size = size
		arm.mesh = am
		arm.material_override = _mat(GREEN, 1.0)
		_icon.add_child(arm)


static func _mat(color: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 1.3
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _process(delta: float) -> void:
	_phase += delta
	_icon.rotation.y += delta * 1.2
	_icon.position.y = 4.2 + sin(_phase * 1.5) * 0.15


func _on_body_entered(body: Node3D) -> void:
	if body is RaycastCar:
		var car := body as RaycastCar
		car.repair()
		car.gadget_slot.open_pit()
