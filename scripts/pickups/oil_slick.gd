class_name OilSlick
extends StaticBody3D
## A puddle a car leaves behind. Tagged as ice, so wheels that cross it lose grip for as
## long as it lasts. Sits on the driving surface wherever the car happened to be.

const RADIUS := 3.4
const LIFETIME := 10.0

var _life := LIFETIME


static func drop_behind(car: RaycastCar) -> void:
	var back: Vector3 = car.global_position + car.global_transform.basis.z * 4.0 + Vector3.UP * 1.5
	var space := car.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(back, back + Vector3.DOWN * 6.0, RaycastCar.GROUND_MASK)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var slick := OilSlick.new()
	var normal: Vector3 = hit.normal
	var basis := Basis.looking_at(normal.cross(Vector3.RIGHT).normalized() if absf(normal.dot(Vector3.RIGHT)) < 0.99 else Vector3.FORWARD, normal)
	slick.transform = Transform3D(basis, hit.position + normal * 0.03)
	car.get_parent().add_child(slick)


func _ready() -> void:
	name = "OilSlick"
	collision_layer = 1
	collision_mask = 0
	set_meta(&"surface", &"ice")
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = 0.06
	shape.shape = cyl
	add_child(shape)
	var mi := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = RADIUS
	disc.bottom_radius = RADIUS * 0.9
	disc.height = 0.05
	disc.radial_segments = 18
	mi.mesh = disc
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.10, 0.08, 0.14, 0.92)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.05
	mat.metallic = 0.6
	mi.material_override = mat
	add_child(mi)


func _process(delta: float) -> void:
	_life -= delta
	if _life < 2.0:
		scale = Vector3.ONE * maxf(_life / 2.0, 0.05)
	if _life <= 0.0:
		queue_free()
