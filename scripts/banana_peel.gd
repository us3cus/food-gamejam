extends Area3D

# Банановая кожура: наступил на скорости — поскользнулся (см. slip() у игрока;
# сам игрок решает, скользит ли он — стоя на месте не поскользнёшься).
# После срабатывания кожура исчезает и возвращается через respawn_delay.

@export var slip_duration := 1.0   # сек потери контроля
@export var respawn_delay := 5.0   # сек до возвращения кожуры на место

var _armed := true


func _physics_process(_delta: float) -> void:
	if not _armed:
		return
	for body in get_overlapping_bodies():
		if body.has_method("slip") and body.slip(slip_duration):
			_trigger()
			return


func _trigger() -> void:
	_armed = false
	visible = false
	await get_tree().create_timer(respawn_delay).timeout
	visible = true
	_armed = true
