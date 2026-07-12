extends Node3D

# Спавнер еды: раз в spawn_interval кидает FoodItem с неба в случайную точку
# круга spawn_radius (центр — позиция этой ноды на арене).
# Тип еды выбирается взвешенной лотереей из food_types (FoodType-ресурсы,
# см. food_type.gd) — состав и частоту падения тюним в инспекторе Арены.
# Предметы добавляются детьми спавнера, лимит считается по их количеству.

@export var food_item_scene: PackedScene  # FoodItem.tscn, назначается в инспекторе
@export var food_types: Array = []        # FoodType-ресурсы (.tres из assets/food/)
@export var spawn_interval := 2.5         # сек между спавнами
@export var max_items := 6                # больше этого на арене одновременно не живёт
@export var spawn_height := 9.0           # м, высота начала падения
@export var spawn_radius := 7.0           # м, круг спавна — чуть меньше радиуса арены

var _time_left := 0.0  # первый предмет падает сразу после старта


func _process(delta: float) -> void:
	_time_left -= delta
	if _time_left <= 0.0 and get_child_count() < max_items:
		_spawn_item()
		_time_left = spawn_interval


func _spawn_item() -> void:
	if food_types.is_empty():
		push_warning("FoodSpawner: список food_types пуст — нечего спавнить")
		return
	var item := food_item_scene.instantiate() as Node3D
	item.food_type = _pick_type()
	# Случайная точка в круге: sqrt(randf) даёт равномерное распределение по площади.
	var angle := randf() * TAU
	var dist := sqrt(randf()) * spawn_radius
	# Позицию задаём до add_child, чтобы _ready предмета увидел верные координаты.
	item.position = Vector3(cos(angle) * dist, spawn_height, sin(angle) * dist)
	add_child(item)


# Взвешенная лотерея: чем больше spawn_weight у типа, тем чаще он падает.
func _pick_type() -> Resource:
	var total := 0.0
	for food_type in food_types:
		total += food_type.spawn_weight
	var roll := randf() * total
	for food_type in food_types:
		roll -= food_type.spawn_weight
		if roll <= 0.0:
			return food_type
	return food_types.back()
