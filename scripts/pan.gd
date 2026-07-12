extends Node3D

# Крутящаяся сковородка: Rotor вращается вокруг Y, зона удара — на ручке и «блине».
# Контакт — кнокбэк по касательной вращения (бьёт в сторону замаха) с добавкой вверх.
# Урона нет — только толчок через apply_knockback() у цели.

@export var rotation_speed := 2.0     # рад/с; знак меняет направление вращения
@export var knockback_strength := 9.0
@export var knockback_up_ratio := 0.35
@export var hit_cooldown := 0.5       # сек между ударами по одной и той же цели

var _recently_hit := {}  # body -> сколько секунд ещё не бить повторно

@onready var _rotor: Node3D = $Rotor
@onready var _hit_zone: Area3D = $Rotor/HitZone


func _physics_process(delta: float) -> void:
	_rotor.rotate_y(rotation_speed * delta)

	for body in _recently_hit.keys():  # keys() — копия, erase внутри цикла безопасен
		if not is_instance_valid(body):
			_recently_hit.erase(body)
			continue
		_recently_hit[body] -= delta
		if _recently_hit[body] <= 0.0:
			_recently_hit.erase(body)

	for body in _hit_zone.get_overlapping_bodies():
		if _recently_hit.has(body) or not body.has_method("apply_knockback"):
			continue
		_recently_hit[body] = hit_cooldown
		body.apply_knockback(_hit_direction(body) * knockback_strength)


func _hit_direction(body: Node3D) -> Vector3:
	var radial := body.global_position - global_position
	radial.y = 0.0
	radial = radial.normalized()
	# Касательная — направление движения лопасти в точке цели: удар "по ходу замаха".
	var tangent := Vector3.UP.cross(radial) * signf(rotation_speed)
	return ((radial + tangent * 1.5).normalized() + Vector3.UP * knockback_up_ratio).normalized()
