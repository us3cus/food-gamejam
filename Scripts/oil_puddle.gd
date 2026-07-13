extends Area3D

# Лужа масла: пока едешь по ней на скорости — скользишь без контроля.
# В отличие от банана не тратится и не исчезает: slip() перезапускается,
# как только предыдущее скольжение закончилось, а сам игрок отказывает
# в скольжении, если стоит на месте (см. slip() у player_controller.gd).

@export var slip_duration := 0.5  # сек за одно "поскальзывание"; короче банана


func _physics_process(_delta: float) -> void:
	for body in get_overlapping_bodies():
		if body.has_method("slip"):
			body.slip(slip_duration)
