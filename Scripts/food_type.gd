class_name FoodType
extends Resource

# Тип еды — ресурс (.tres в assets/food/): один файл = один вид еды.
# Здесь и визуал, и параметры броска. КАК ЗАМЕНИТЬ ЗАГЛУШКУ НА МОДЕЛЬКУ:
# 3D-артист открывает .tres в инспекторе и кладёт свой Mesh в поле mesh
# (плюс правит visual_scale/rest_height под размер модели) — код не меняется.
# FoodItem (пикап), HeldFood (в руках) и FoodProjectile (снаряд) берут меш отсюда.

@export var display_name := "Еда"

@export_group("Visual")
@export var mesh: Mesh              # заглушка-примитив; сюда артист положит модельку
@export var visual_scale := 1.0     # общий масштаб меша во всех трёх ролях
@export var rest_height := 0.2      # на какой высоте лежит на полу (примерно радиус меша)

@export_group("Throw")
@export var throw_speed := 10.0         # горизонтальная скорость полёта, м/с
@export var damage := 1
@export var knockback_strength := 6.0   # м/с, толчок цели при прямом попадании

@export_group("Bomb")
@export var aoe_radius := 0.0     # > 0 — взрыв по площади при попадании (арбуз)
@export var aoe_knockback := 8.0  # толчок от эпицентра для всех в радиусе

@export_group("Spawning")
@export var spawn_weight := 1.0  # вес в лотерее спавнера: больше вес — чаще падает
