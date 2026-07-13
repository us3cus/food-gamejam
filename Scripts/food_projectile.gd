class_name FoodProjectile
extends Area3D

# Снаряд летит по баллистической дуге на ручной интеграции (Area3D, а не RigidBody3D):
# так полёт полностью предсказуем, а попадание ловим через body_entered.
# Урон/кнокбэк/визуал приходят из FoodType через configure() — модель еды
# задаётся в .tres-ресурсе (см. food_type.gd -> create_visual).

const FoodTypeScript = preload("res://Scripts/food_type.gd")

@export var lifetime := 5.0  # сек; страховка, если снаряд ни во что не попал
@export var damage := 1                 # дефолты на случай, если configure() не звали
@export var knockback_strength := 6.0
@export var knockback_up_ratio := 0.25  # добавка вверх к кнокбэку, чтобы удар читался
@export var spin_speed := 9.0           # рад/с, кувырок снаряда в полёте

var velocity := Vector3.ZERO
var shooter: Node3D = null  # кто бросил — об него не разбиваемся
var aoe_radius := 0.0       # > 0 — взрыв по площади (арбуз)
var aoe_knockback := 8.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _age := 0.0
var _hit := false
var _visual: Node3D = null
var _splash_color := Color(0.9, 0.3, 0.2)

@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	body_entered.connect(_on_body_entered)


# Настройка из типа еды; knockback_multiplier > 1 — заряженный бросок.
func configure(food_type: FoodTypeScript, knockback_multiplier := 1.0) -> void:
	damage = food_type.damage
	knockback_strength = food_type.knockback_strength * knockback_multiplier
	aoe_radius = food_type.aoe_radius
	aoe_knockback = food_type.aoe_knockback * knockback_multiplier
	_splash_color = food_type.splash_color
	_mesh.visible = false
	_visual = food_type.create_visual()
	add_child(_visual)


func _physics_process(delta: float) -> void:
	if _hit:
		return
	velocity.y -= _gravity * delta
	global_position += velocity * delta
	if _visual != null:
		_visual.rotate_object_local(Vector3.RIGHT, spin_speed * delta)  # кувырок в полёте

	_age += delta
	if _age > lifetime or global_position.y < -2.0:
		_splash()
		queue_free()


func _on_body_entered(body: Node3D) -> void:
	if body == shooter or _hit:
		return
	_hit = true

	if aoe_radius > 0.0:
		# Бомба: прямого урона нет, взрыв бьёт всех в радиусе — включая бросившего.
		# call_deferred: физические запросы нельзя делать из колбэка физики.
		visible = false
		_explode.call_deferred()
		return

	# Контракт урона: бьём всё, у чего есть take_hit(damage, knockback).
	if body.has_method("take_hit"):
		body.take_hit(damage, _knockback_vector(body))
		get_tree().call_group("camera_shake", "shake", 0.18)
	_splash()
	queue_free()


func _explode() -> void:
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = aoe_radius
	params.shape = sphere
	params.transform = Transform3D(Basis(), global_position)
	for hit in get_world_3d().direct_space_state.intersect_shape(params, 16):
		var body: Node3D = hit["collider"]
		if body.has_method("take_hit"):
			var dir: Vector3 = body.global_position - global_position
			dir.y = 0.0
			dir = dir.normalized()
			body.take_hit(damage, (dir + Vector3.UP * 0.5).normalized() * aoe_knockback)
	_spawn_blast_visual()
	_splash(40, 7.0)  # взрыв — большой сноп мякоти
	get_tree().call_group("camera_shake", "shake", 0.55)
	queue_free()


# Брызги еды: одноразовые частицы цвета из FoodType, сами чистятся после выстрела.
func _splash(amount := 14, speed := 3.5) -> void:
	var particles := CPUParticles3D.new()
	particles.one_shot = true
	particles.emitting = false
	particles.amount = amount
	particles.lifetime = 0.55
	particles.direction = Vector3.UP
	particles.spread = 70.0
	particles.initial_velocity_min = speed * 0.5
	particles.initial_velocity_max = speed
	particles.gravity = Vector3(0, -12, 0)
	particles.scale_amount_min = 0.5
	particles.scale_amount_max = 1.0
	particles.color = _splash_color
	var drop := SphereMesh.new()
	drop.radius = 0.06
	drop.height = 0.12
	var material := StandardMaterial3D.new()
	material.albedo_color = _splash_color
	material.vertex_color_use_as_albedo = true
	drop.material = material
	particles.mesh = drop
	get_tree().current_scene.add_child(particles)
	particles.global_position = global_position
	particles.emitting = true
	particles.finished.connect(particles.queue_free)


# Заглушка-вспышка взрыва: растущая прозрачная сфера, потом заменится партиклами.
func _spawn_blast_visual() -> void:
	var blast := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.5
	sphere_mesh.height = 1.0
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.95, 0.35, 0.2, 0.6)
	sphere_mesh.material = material
	blast.mesh = sphere_mesh
	get_tree().current_scene.add_child(blast)
	blast.global_position = global_position
	var tween := blast.create_tween()
	tween.tween_property(blast, "scale", Vector3.ONE * (aoe_radius / 0.5), 0.25)
	tween.parallel().tween_property(material, "albedo_color:a", 0.0, 0.25)
	tween.tween_callback(blast.queue_free)


# Кнокбэк — по горизонтальному направлению полёта (вертикаль дуги отбрасываем),
# плюс небольшая добавка вверх.
func _knockback_vector(body: Node3D) -> Vector3:
	var dir := Vector3(velocity.x, 0.0, velocity.z).normalized()
	if dir == Vector3.ZERO:  # снаряд падал почти вертикально — толкаем от точки удара
		dir = body.global_position - global_position
		dir.y = 0.0
		dir = dir.normalized()
	return (dir + Vector3.UP * knockback_up_ratio).normalized() * knockback_strength
