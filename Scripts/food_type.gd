class_name FoodType
extends Resource

# Тип еды — ресурс (.tres в assets/food/): один файл = один вид еды.
# ВИЗУАЛ: если задана visual_scene (glb-модель) — везде используется она;
# иначе fallback на mesh-заглушку. Пикап, еда в руках и снаряд собирают
# внешний вид через create_visual() — заменил модель в .tres, и она везде.
# override_color красит все меши модели (для glb со слетевшим материалом).

@export var display_name := "Еда"

@export_group("Visual")
@export var visual_scene: PackedScene  # 3D-модель (glb); приоритетнее mesh
@export var mesh: Mesh                 # заглушка-примитив, работает без модели
@export var visual_scale := 1.0        # общий масштаб визуала во всех трёх ролях
@export var rest_height := 0.2         # высота корня пикапа над полом (дно модели)
@export var override_color := Color(0, 0, 0, 0)  # alpha > 0 — перекрасить все меши
@export var splash_color := Color(0.9, 0.3, 0.2) # цвет брызг при попадании/разбивании

@export_group("Throw")
@export var throw_speed := 10.0         # горизонтальная скорость полёта, м/с
@export var damage := 1
@export var knockback_strength := 6.0   # м/с, толчок цели при прямом попадании

@export_group("Bomb")
@export var aoe_radius := 0.0     # > 0 — взрыв по площади при попадании (арбуз)
@export var aoe_knockback := 8.0  # толчок от эпицентра для всех в радиусе

@export_group("Spawning")
@export var spawn_weight := 1.0  # вес в лотерее спавнера: больше вес — чаще падает


# Собирает визуал еды: инстанс модели или MeshInstance3D с заглушкой.
func create_visual() -> Node3D:
	var node: Node3D
	if visual_scene != null:
		node = visual_scene.instantiate()
	else:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = mesh
		node = mesh_instance
	node.scale = Vector3.ONE * visual_scale
	if override_color.a > 0.0:
		var material := StandardMaterial3D.new()
		material.albedo_color = override_color
		if node is MeshInstance3D:
			node.material_override = material
		for child in node.find_children("*", "MeshInstance3D", true, false):
			child.material_override = material
	return node
