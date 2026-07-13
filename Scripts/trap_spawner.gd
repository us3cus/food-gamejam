extends Node3D

# Случайные ловушки: раз в spawn_interval в случайной точке арены вырастает
# случайная ловушка из trap_scenes и живёт lifetime_min..lifetime_max секунд,
# после чего утягивается обратно в пол. Ловушки — дети спавнера,
# лимит одновременных считается по их количеству.

@export var trap_scenes: Array = []   # PackedScene ловушек (Pan, BananaPeel, ...)
@export var spawn_interval := 4.0     # сек между появлениями
@export var max_traps := 3            # одновременно на арене
@export var lifetime_min := 5.0       # сек жизни ловушки
@export var lifetime_max := 10.0
@export var spawn_radius := 6.5       # м, базовый круг спавна
@export var floor_path: NodePath      # пол: его scale учитывает сжатие арены

var _floor: Node3D = null
var _time_left := 2.0  # первая ловушка почти сразу


func _ready() -> void:
	_floor = get_node_or_null(floor_path)


func _process(delta: float) -> void:
	_time_left -= delta
	if _time_left > 0.0 or get_child_count() >= max_traps or trap_scenes.is_empty():
		return
	_time_left = spawn_interval
	_spawn_trap()


func _spawn_trap() -> void:
	var trap := (trap_scenes.pick_random() as PackedScene).instantiate() as Node3D
	var radius := spawn_radius
	if _floor != null:
		radius *= _floor.scale.x  # арена сжалась — спавним в её текущих границах
	var angle := randf() * TAU
	var dist := sqrt(randf()) * radius
	trap.position = Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
	add_child(trap)

	# Появление: упруго вырастает из пола.
	trap.scale = Vector3.ONE * 0.05
	var tween := trap.create_tween()
	tween.tween_property(trap, "scale", Vector3.ONE, 0.35) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	get_tree().create_timer(randf_range(lifetime_min, lifetime_max)) \
			.timeout.connect(_despawn_trap.bind(trap))


func _despawn_trap(trap: Node3D) -> void:
	if not is_instance_valid(trap):
		return
	var tween := trap.create_tween()
	tween.tween_property(trap, "scale", Vector3.ONE * 0.05, 0.3) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tween.tween_callback(trap.queue_free)
