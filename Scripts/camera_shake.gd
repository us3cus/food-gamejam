extends Camera3D

# Тряска камеры: любой код зовёт get_tree().call_group("camera_shake", "shake", сила).
# Камера статична, поэтому просто дрожим вокруг базового трансформа и затухаем.

@export var decay_speed := 8.0      # как быстро тряска сходит на нет
@export var max_offset := 0.35      # м, максимальный сдвиг на силе 1.0

var _strength := 0.0
var _base_transform: Transform3D


func _ready() -> void:
	add_to_group("camera_shake")
	_base_transform = transform


func shake(strength: float) -> void:
	_strength = maxf(_strength, strength)


func _process(delta: float) -> void:
	if _strength <= 0.005:
		if _strength > 0.0:
			transform = _base_transform
			_strength = 0.0
		return
	_strength = lerpf(_strength, 0.0, decay_speed * delta)
	transform = _base_transform
	transform.origin += Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0)) * _strength * max_offset
