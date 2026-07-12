class_name FoodProjectile
extends Area3D

# Снаряд летит по баллистической дуге на ручной интеграции (Area3D, а не RigidBody3D):
# так полёт полностью предсказуем (не зависит от физматериалов и отскоков),
# а попадание ловим через body_entered.

@export var lifetime := 5.0  # сек; страховка, если снаряд ни во что не попал
@export var damage := 1
@export var knockback_strength := 6.0   # м/с, горизонтальный импульс цели при попадании
@export var knockback_up_ratio := 0.25  # добавка вверх к кнокбэку, чтобы удар читался

var velocity := Vector3.ZERO
var shooter: Node3D = null  # кто бросил — об него не разбиваемся

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _age := 0.0

@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	body_entered.connect(_on_body_entered)


# Снаряд перекрашивается в цвет брошенной еды (зовёт игрок после спавна).
func set_food_color(food_color: Color) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = food_color
	_mesh.material_override = material


func _physics_process(delta: float) -> void:
	velocity.y -= _gravity * delta
	global_position += velocity * delta

	_age += delta
	if _age > lifetime or global_position.y < -2.0:
		queue_free()


func _on_body_entered(body: Node3D) -> void:
	if body == shooter:
		return
	# Контракт урона: бьём всё, у чего есть take_hit(damage, knockback).
	# Стены/пол метода не имеют — снаряд просто разбивается.
	if body.has_method("take_hit"):
		body.take_hit(damage, _knockback_vector(body))
	queue_free()


# Кнокбэк — по горизонтальному направлению полёта (вертикаль дуги отбрасываем),
# плюс небольшая добавка вверх.
func _knockback_vector(body: Node3D) -> Vector3:
	var dir := Vector3(velocity.x, 0.0, velocity.z).normalized()
	if dir == Vector3.ZERO:  # снаряд падал почти вертикально — толкаем от точки удара
		dir = body.global_position - global_position
		dir.y = 0.0
		dir = dir.normalized()
	return (dir + Vector3.UP * knockback_up_ratio).normalized() * knockback_strength
