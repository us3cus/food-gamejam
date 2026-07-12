extends Area3D

# Конфорка: стоишь на ней — тикает урон с лёгким подбросом («горячо!»).
# Урон идёт через общий контракт take_hit, так что жжёт и игрока, и манекена.
# Конфорка пульсирует эмиссией, чтобы читалась как опасная зона.

@export var tick_interval := 0.8  # сек между ожогами
@export var damage := 1
@export var knockback_up := 3.5   # подброс вверх — выкидывает с плиты

var _tick_left := 0.0
var _time := 0.0
var _material := StandardMaterial3D.new()

@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	# Свой материал с эмиссией — пульс не трогает общие ресурсы сцены.
	_material.albedo_color = Color(0.45, 0.1, 0.05)
	_material.emission_enabled = true
	_material.emission = Color(1.0, 0.25, 0.05)
	_mesh.material_override = _material


func _process(delta: float) -> void:
	_time += delta
	_material.emission_energy_multiplier = 1.2 + sin(_time * 5.0) * 0.6


func _physics_process(delta: float) -> void:
	_tick_left -= delta
	if _tick_left > 0.0:
		return
	var burned_someone := false
	for body in get_overlapping_bodies():
		if body.has_method("take_hit"):
			body.take_hit(damage, Vector3.UP * knockback_up)
			burned_someone = true
	if burned_someone:
		_tick_left = tick_interval
