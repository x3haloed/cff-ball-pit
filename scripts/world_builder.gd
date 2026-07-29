class_name WorldBuilder
extends RefCounted

const BALL_COUNT := 180


static func build_world(parent: Node3D, dynamic_balls := true) -> Dictionary:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("182136")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("b7c9ea")
	env.ambient_light_energy = 0.7
	environment.environment = env
	parent.add_child(environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -25.0, 0.0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	parent.add_child(sun)

	_add_static_box(parent, "Floor", Vector3(0, -0.5, 0), Vector3(24, 1, 24), Color("536274"))
	_add_static_box(parent, "WallNorth", Vector3(0, 2, -12), Vector3(24, 5, 0.7), Color("253147"))
	_add_static_box(parent, "WallSouth", Vector3(0, 2, 12), Vector3(24, 5, 0.7), Color("253147"))
	_add_static_box(parent, "WallWest", Vector3(-12, 2, 0), Vector3(0.7, 5, 24), Color("253147"))
	_add_static_box(parent, "WallEast", Vector3(12, 2, 0), Vector3(0.7, 5, 24), Color("253147"))
	_add_static_box(parent, "Ramp", Vector3(0, 0.65, -5), Vector3(5, 0.5, 4), Color("d7a64a"), Vector3(-10, 0, 0))

	var balls := Node3D.new()
	balls.name = "Balls"
	parent.add_child(balls)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xCFFB411
	var colors := [Color("ff5d73"), Color("5db7ff"), Color("ffd166"), Color("70e000"), Color("b388ff")]
	for index in BALL_COUNT:
		var ball := RigidBody3D.new()
		ball.name = "Ball%03d" % index
		ball.mass = 0.35
		ball.freeze = not dynamic_balls
		ball.position = Vector3(rng.randf_range(-9.5, 9.5), rng.randf_range(0.4, 2.8), rng.randf_range(-9.5, 9.5))
		ball.linear_damp = 0.2
		ball.angular_damp = 0.2
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 0.32
		shape.shape = sphere
		ball.add_child(shape)
		var mesh := MeshInstance3D.new()
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = 0.32
		sphere_mesh.height = 0.64
		mesh.mesh = sphere_mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = colors[index % colors.size()]
		material.roughness = 0.75
		mesh.material_override = material
		ball.add_child(mesh)
		balls.add_child(ball)

	return {"balls": balls}


static func create_robot(participant_id: String, color: Color, at: Vector3) -> CharacterBody3D:
	var robot := CharacterBody3D.new()
	robot.name = "Robot_%s" % participant_id.validate_node_name()
	robot.position = at
	robot.set_meta("participant_id", participant_id)
	robot.set_meta("heading", 0.0)
	robot.set_meta("action", FrameContract.fallback_action())

	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.62
	shape.height = 1.3
	collision.shape = shape
	collision.position.y = 0.65
	robot.add_child(collision)

	var body := MeshInstance3D.new()
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(1.25, 0.7, 1.55)
	body.mesh = body_mesh
	body.position.y = 0.75
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.15
	material.roughness = 0.55
	body.material_override = material
	robot.add_child(body)

	for side in [-1.0, 1.0]:
		var wheel := MeshInstance3D.new()
		var wheel_mesh := CylinderMesh.new()
		wheel_mesh.top_radius = 0.34
		wheel_mesh.bottom_radius = 0.34
		wheel_mesh.height = 0.22
		wheel.mesh = wheel_mesh
		wheel.rotation_degrees.z = 90
		wheel.position = Vector3(0.72 * side, 0.43, 0)
		var wheel_material := StandardMaterial3D.new()
		wheel_material.albedo_color = Color("17191f")
		wheel.material_override = wheel_material
		robot.add_child(wheel)

	return robot


static func _add_static_box(
	parent: Node3D,
	label: String,
	at: Vector3,
	size: Vector3,
	color: Color,
	rotation := Vector3.ZERO,
) -> void:
	var body := StaticBody3D.new()
	body.name = label
	body.position = at
	body.rotation_degrees = rotation
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	mesh.material_override = material
	body.add_child(mesh)
	parent.add_child(body)
