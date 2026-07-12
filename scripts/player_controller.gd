class_name PlayerController
extends CharacterBody3D

# Движение twin-stick: WASD двигает персонажа в мировых осях X/Z,
# прицел — курсор мыши, спроецированный лучом от камеры на плоскость пола (Y=0).
#
# РЕШЕНИЕ по повороту: визуально персонаж поворачивается К ПРИЦЕЛУ
# (не к направлению движения) — так всегда видно, куда полетит еда.
#
# Боезапаса по умолчанию НЕТ: бросить можно только еду, подобранную на арене
# (FoodItem падают с неба, подбор касанием — см. food_item.gd). В руках
# помещается один предмет, он виден над головой.

signal health_changed(current: int, max_hp: int)
signal died

# preload вместо глобального class_name: не зависит от кэша классов редактора.
const FoodProjectileScript = preload("res://scripts/food_projectile.gd")

const AIM_COLOR_ARMED := Color(1.0, 0.55, 0.1, 0.9)  # еда в руках — можно кидать
const AIM_COLOR_EMPTY := Color(1.0, 1.0, 1.0, 0.25)  # руки пусты — маркер тусклый
const SLIP_SPIN_SPEED := 12.0  # рад/с; во время скольжения персонаж вертится волчком

@export_group("Health")
@export var max_health := 3

@export_group("Movement")
@export var move_speed := 6.0          # м/с, базовая скорость
@export var sprint_multiplier := 1.6   # множитель скорости при удержании Shift
@export var jump_velocity := 5.0       # м/с, вертикальная скорость прыжка
@export var turn_speed := 12.0         # скорость доворота визуала к прицелу
@export var knockback_friction := 10.0 # м/с^2, затухание внешнего толчка

@export_group("Throwing")
@export var projectile_scene: PackedScene  # FoodProjectile.tscn, назначается в инспекторе
@export var throw_cooldown := 0.3          # сек; лимитирует в основном наличие еды
@export var throw_speed := 10.0            # горизонтальная скорость снаряда, м/с
@export var min_flight_time := 0.25        # сек; чтобы близкие броски тоже летели дугой

var _aim_point := Vector3.ZERO
var _has_aim := false
var _cooldown_left := 0.0
var _has_food := false
var _food_color := Color.WHITE
var _knockback := Vector3.ZERO      # внешний толчок (сковородка и т.п.), затухает трением
var _slip_left := 0.0               # сек скольжения на банане, 0 = контроль у игрока
var _slip_velocity := Vector3.ZERO  # куда несёт во время скольжения
var _health := 0

# Свои материалы на каждый инстанс игрока: меши в сцене делят общие ресурсы,
# а маркер прицела и еда в руках красятся индивидуально.
var _aim_material := StandardMaterial3D.new()
var _food_material := StandardMaterial3D.new()

@onready var _visual: Node3D = $Visual
@onready var _throw_origin: Marker3D = $Visual/ThrowOrigin
@onready var _held_food: MeshInstance3D = $Visual/HeldFood
@onready var _aim_marker: MeshInstance3D = $AimMarker


func _ready() -> void:
	_health = max_health
	_aim_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_aim_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_aim_marker.material_override = _aim_material
	_held_food.material_override = _food_material
	_update_held_visuals()


func _physics_process(delta: float) -> void:
	# Чтение инпута отдельно от применения движения/броска: для сети этот блок
	# оборачивается в проверку authority, остальной код не меняется.
	var move_input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var sprinting := Input.is_action_pressed("sprint")
	var jump_pressed := Input.is_action_just_pressed("jump")
	var throw_held := Input.is_action_pressed("throw")

	_update_aim()
	_apply_movement(move_input, sprinting, jump_pressed, delta)
	_update_facing(delta)

	_cooldown_left = maxf(_cooldown_left - delta, 0.0)
	if throw_held and _has_food and _has_aim and _cooldown_left == 0.0:
		_throw()


# Зовёт FoodItem при касании. false = руки заняты, предмет остаётся лежать.
func pick_up_food(food_color: Color) -> bool:
	if _has_food:
		return false
	_has_food = true
	_food_color = food_color
	_update_held_visuals()
	return true


# Урон от снаряда — общий контракт take_hit, как у манекена (см. food_projectile.gd).
func take_hit(damage: int, knockback: Vector3) -> void:
	if _health <= 0:
		return
	_health = maxi(_health - damage, 0)
	apply_knockback(knockback)
	health_changed.emit(_health, max_health)
	if _health == 0:
		died.emit()


# Внешний толчок (сковородка и т.п.): горизонталь копится отдельно от инпута
# и затухает трением, вертикаль уходит в velocity.y — её гасит гравитация.
func apply_knockback(impulse: Vector3) -> void:
	_knockback.x += impulse.x
	_knockback.z += impulse.z
	velocity.y += impulse.y


# Зовёт банановая кожура. true = поскользнулись (кожура при этом тратится).
func slip(duration: float) -> bool:
	if _slip_left > 0.0:
		return false
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if flat.length() < 1.0:
		return false  # стоим или ползём — на кожуре можно стоять
	_slip_left = duration
	_slip_velocity = flat * 1.15  # чуть разгоняет, чтобы "унесло" читалось
	return true


func _apply_movement(move_input: Vector2, sprinting: bool, jump_pressed: bool, delta: float) -> void:
	_knockback = _knockback.move_toward(Vector3.ZERO, knockback_friction * delta)

	if _slip_left > 0.0:
		# Скольжение: инпут не работает, несёт туда, куда бежал.
		_slip_left -= delta
		velocity.x = _slip_velocity.x + _knockback.x
		velocity.z = _slip_velocity.z + _knockback.z
	else:
		var speed := move_speed * (sprint_multiplier if sprinting else 1.0)
		velocity.x = move_input.x * speed + _knockback.x
		velocity.z = move_input.y * speed + _knockback.z

	if not is_on_floor():
		velocity += get_gravity() * delta
	elif jump_pressed and _slip_left <= 0.0:  # в скольжении и прыжок недоступен
		velocity.y = jump_velocity

	move_and_slide()


func _update_aim() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_has_aim = false
		_aim_marker.visible = false
		return
	var mouse_pos := get_viewport().get_mouse_position()
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(
			camera.project_ray_origin(mouse_pos), camera.project_ray_normal(mouse_pos))
	_has_aim = hit != null
	_aim_marker.visible = _has_aim
	if _has_aim:
		_aim_point = hit
		_aim_marker.global_position = _aim_point + Vector3.UP * 0.02


func _update_facing(delta: float) -> void:
	if _slip_left > 0.0:
		_visual.rotate_y(SLIP_SPIN_SPEED * delta)  # вертимся волчком — потеря контроля видна
		return
	if not _has_aim:
		return
	var to_aim := _aim_point - global_position
	to_aim.y = 0.0
	if to_aim.length_squared() < 0.09:
		return  # курсор на самом персонаже — не дёргаем поворот
	# Вперёд у Node3D — это -Z, отсюда знаки в atan2.
	var target_yaw := atan2(-to_aim.x, -to_aim.z)
	_visual.rotation.y = lerp_angle(_visual.rotation.y, target_yaw, minf(turn_speed * delta, 1.0))


func _throw() -> void:
	_cooldown_left = throw_cooldown
	_has_food = false
	var projectile: FoodProjectileScript = projectile_scene.instantiate()
	# Снаряд добавляем в сцену уровня, а не в игрока — он живёт сам по себе.
	get_tree().current_scene.add_child(projectile)
	projectile.global_position = _throw_origin.global_position
	projectile.shooter = self
	projectile.velocity = _ballistic_velocity(_throw_origin.global_position, _aim_point)
	projectile.set_food_color(_food_color)
	_update_held_visuals()


func _update_held_visuals() -> void:
	_held_food.visible = _has_food
	_food_material.albedo_color = _food_color
	_aim_material.albedo_color = AIM_COLOR_ARMED if _has_food else AIM_COLOR_EMPTY


# Скорость для полёта по параболе из from в to: горизонтальная составляющая
# постоянна (throw_speed), время полёта из неё, вертикальная скорость — из уравнения дуги.
func _ballistic_velocity(from: Vector3, to: Vector3) -> Vector3:
	var flat := to - from
	flat.y = 0.0
	var flight_time := maxf(flat.length() / throw_speed, min_flight_time)
	var g: float = -get_gravity().y
	var result := flat / flight_time
	result.y = (to.y - from.y + 0.5 * g * flight_time * flight_time) / flight_time
	return result
