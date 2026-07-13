extends CharacterBody3D

# Тестовый манекен для проверки попаданий без второго игрока:
# получает урон и кнокбэк через take_hit(), при 0 HP временно исчезает
# и возвращается с полным здоровьем. Цвет тела показывает остаток HP.
#
# Контракт урона: у цели есть метод take_hit(damage: int, knockback: Vector3) —
# снаряд зовёт его у любого тела, у которого он есть (у игрока такой же).

signal health_changed(current: int, max_hp: int)
signal died

@export var max_health := 3
@export var respawn_delay := 2.0       # сек до возвращения после нокаута
@export var knockback_friction := 8.0  # м/с^2, скорость затухания скольжения от кнокбэка
@export var fall_y_threshold := -6.0   # ниже этой высоты считаем, что упал с арены

var _health: int
var _knocked_out := false
var _spawn_position := Vector3.ZERO
var _material := StandardMaterial3D.new()

@onready var _visual: Node3D = $Visual
@onready var _body_mesh: MeshInstance3D = $Visual/Body
@onready var _collision: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	_health = max_health
	_spawn_position = global_position
	# material_override, чтобы у каждого манекена был свой цвет (меш-материал общий).
	_body_mesh.material_override = _material
	_update_color()


func _physics_process(delta: float) -> void:
	# Кнокбэк скользит по полу и затухает трением, гравитация прижимает вниз.
	if not is_on_floor():
		velocity += get_gravity() * delta
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	flat = flat.move_toward(Vector3.ZERO, knockback_friction * delta)
	velocity.x = flat.x
	velocity.z = flat.z
	move_and_slide()

	# Столкнули с арены — минус 1 HP и возврат на точку старта.
	if global_position.y < fall_y_threshold and not _knocked_out:
		global_position = _spawn_position
		velocity = Vector3.ZERO
		take_hit(1, Vector3.ZERO)


func take_hit(damage: int, knockback: Vector3) -> void:
	if _knocked_out:
		return
	_health = maxi(_health - damage, 0)
	apply_knockback(knockback)
	_update_color()
	health_changed.emit(_health, max_health)
	if _health == 0:
		_knock_out()


# Чистый толчок без урона (сковородка) — общий контракт с игроком.
func apply_knockback(impulse: Vector3) -> void:
	if _knocked_out:
		return
	velocity += impulse


func _knock_out() -> void:
	_knocked_out = true
	died.emit()
	_visual.visible = false
	# set_deferred: менять коллизию прямо из физического колбэка нельзя.
	_collision.set_deferred("disabled", true)
	velocity = Vector3.ZERO
	await get_tree().create_timer(respawn_delay).timeout
	# Возвращаемся на точку старта — чтобы не воскреснуть за краем арены.
	global_position = _spawn_position
	_health = max_health
	_update_color()
	health_changed.emit(_health, max_health)
	_visual.visible = true
	_collision.set_deferred("disabled", false)
	_knocked_out = false


func _update_color() -> void:
	# Синий при полном HP -> красный перед нокаутом.
	var missing := 1.0 - float(_health) / float(max_health)
	_material.albedo_color = Color(0.4, 0.55, 0.9).lerp(Color(0.9, 0.2, 0.2), missing)
