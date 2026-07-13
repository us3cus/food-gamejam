extends Area3D

# Пикап еды: спавнится в небе, падает, лежит и ждёт подбора.
# Пока падает — ОПАСНА: удар по голове наносит урон (_try_bonk), а тень на полу
# показывает зону падения широкой и сжимается по мере приближения к земле,
# чтобы игрок успел среагировать и отойти.
# Визуал и параметры приходят из FoodType-ресурса (см. food_type.gd):
# артист меняет mesh в .tres-файлах, этот код не трогается.

const FoodTypeScript = preload("res://Scripts/food_type.gd")

@export var fall_hit_damage := 1
@export var fall_hit_knockback := 5.0  # подброс вверх при ударе по голове
@export var shadow_max_scale := 4.0    # ширина тени в начале падения (у земли -> 1)

var food_type: FoodTypeScript = null  # задаёт спавнер ДО add_child

var _fall_velocity := 0.0
var _falling := true
var _bonked := false  # урон сверху — не больше одного раза на предмет
var _start_height := 1.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _pickup_delay_left := 0.0

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _shadow: MeshInstance3D = $Shadow


func _ready() -> void:
	if food_type == null:
		push_warning("FoodItem без food_type: назначь FoodType-ресурс (спавнер делает это сам)")
		queue_free()
		return
	_mesh.mesh = food_type.mesh
	_mesh.scale = Vector3.ONE * food_type.visual_scale
	_start_height = maxf(global_position.y, 1.0)
	# Тень — top_level-нода: стоит на полу в точке будущего приземления.
	_shadow.global_position = Vector3(global_position.x, 0.03, global_position.z)


func _physics_process(delta: float) -> void:
	_pickup_delay_left = maxf(_pickup_delay_left - delta, 0.0)
	if _falling:
		_fall(delta)
	elif not _has_floor_below():
		# Арена сжалась и пол ушёл из-под предмета — падаем дальше в пропасть.
		_falling = true
	elif _pickup_delay_left <= 0.0:
		_try_pickup()

	if global_position.y < -2.0:
		queue_free()


func prepare_drop(seconds: float) -> void:
	_pickup_delay_left = maxf(seconds, 0.0)
	_bonked = true


func _fall(delta: float) -> void:
	_fall_velocity += _gravity * delta
	global_position.y -= _fall_velocity * delta

	# Тень-предупреждение: широкая вдалеке, сжимается к точке удара.
	var progress := clampf(1.0 - global_position.y / _start_height, 0.0, 1.0)
	var shadow_scale := lerpf(shadow_max_scale, 1.0, progress)
	_shadow.scale = Vector3(shadow_scale, 1.0, shadow_scale)

	_try_bonk()

	if global_position.y <= food_type.rest_height and _has_floor_below():
		global_position.y = food_type.rest_height
		_falling = false
		_fall_velocity = 0.0
		_shadow.visible = false


# Удар по голове того, кто оказался под падающей едой.
func _try_bonk() -> void:
	if _bonked:
		return
	for body in get_overlapping_bodies():
		if body.has_method("take_hit"):
			_bonked = true
			body.take_hit(fall_hit_damage, Vector3.UP * fall_hit_knockback)
			return


# Подбор поллингом, а не body_entered: если игрок стоял вплотную с занятыми
# руками и бросил еду, повторного "входа" в зону не будет — сигнал бы не сработал.
func _try_pickup() -> void:
	for body in get_overlapping_bodies():
		if body.has_method("pick_up_food") and body.pick_up_food(food_type):
			queue_free()
			return


func _has_floor_below() -> bool:
	var query := PhysicsRayQueryParameters3D.create(
			global_position + Vector3.UP * 0.1, global_position + Vector3.DOWN * 2.0)
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()
