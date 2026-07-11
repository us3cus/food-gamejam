extends Area3D

# Пикап еды: спавнится в небе, падает по гравитации, ложится на пол и ждёт.
# Пока падает — на полу видна круглая "тень" в точке приземления.
# Подбор касанием (в том числе на лету): у тела должен быть метод
# pick_up_food(color: Color) -> bool; false = руки заняты, предмет остаётся.

const FOOD_COLORS: Array[Color] = [
	Color(0.85, 0.2, 0.15),  # помидор
	Color(0.95, 0.75, 0.2),  # сыр
	Color(0.4, 0.75, 0.25),  # салат
	Color(0.95, 0.5, 0.15),  # апельсин
]

@export var rest_height := 0.2  # радиус меша — на этой высоте лежим на полу

var color: Color

var _fall_velocity := 0.0
var _falling := true
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _shadow: MeshInstance3D = $Shadow


func _ready() -> void:
	color = FOOD_COLORS.pick_random()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	_mesh.material_override = material
	# Тень — top_level-нода: не падает вместе с предметом, а стоит на полу
	# в точке будущего приземления.
	_shadow.global_position = Vector3(global_position.x, 0.03, global_position.z)


func _physics_process(delta: float) -> void:
	if _falling:
		_fall_velocity += _gravity * delta
		global_position.y -= _fall_velocity * delta
		if global_position.y <= rest_height:
			global_position.y = rest_height
			_falling = false
			_shadow.visible = false

	# Подбор поллингом, а не body_entered: если игрок стоял вплотную с занятыми
	# руками и бросил еду, повторного "входа" в зону не будет — сигнал бы не сработал.
	for body in get_overlapping_bodies():
		if body.has_method("pick_up_food") and body.pick_up_food(color):
			queue_free()
			return
