extends Node3D

# Спавнер еды: раз в spawn_interval кидает FoodItem с неба в случайную точку
# прямоугольника spawn_area (центр — позиция этой ноды на арене).
# Предметы добавляются детьми спавнера, лимит считается по их количеству.

@export var food_item_scene: PackedScene  # FoodItem.tscn, назначается в инспекторе
@export var spawn_interval := 2.5         # сек между спавнами
@export var max_items := 6                # больше этого на арене одновременно не живёт
@export var spawn_height := 9.0           # м, высота начала падения
@export var spawn_area := Vector2(17.0, 9.0)  # зона спавна по X/Z, чуть меньше арены

var _time_left := 0.0  # первый предмет падает сразу после старта


func _process(delta: float) -> void:
	_time_left -= delta
	if _time_left <= 0.0 and get_child_count() < max_items:
		_spawn_item()
		_time_left = spawn_interval


func _spawn_item() -> void:
	var item := food_item_scene.instantiate() as Node3D
	# Позицию задаём до add_child, чтобы _ready предмета увидел верные координаты.
	item.position = Vector3(
			randf_range(-spawn_area.x / 2.0, spawn_area.x / 2.0),
			spawn_height,
			randf_range(-spawn_area.y / 2.0, spawn_area.y / 2.0))
	add_child(item)
