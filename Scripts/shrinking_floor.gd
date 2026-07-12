extends StaticBody3D

# Сужающаяся арена: HUD каждый кадр сообщает прогресс раунда через
# set_round_progress(0..1), после shrink_start пол плавно сжимается по X/Z.
# Вместе с нодой сжимаются меш, коллизия и «юбка» (дети) — игроки у края
# соскальзывают в пропасть, финал раунда происходит на пятачке.
# Ловушки и еда НЕ сжимаются (лежат в корне арены) — у края они повисают
# над пропастью; еда сама падает вниз (см. food_item.gd -> _has_floor_below).

@export var shrink_start := 0.4  # доля раунда, после которой начинается сжатие
@export var min_scale := 0.55    # доля исходного радиуса к самому концу раунда


func set_round_progress(progress: float) -> void:
	var t := clampf((progress - shrink_start) / (1.0 - shrink_start), 0.0, 1.0)
	var s := lerpf(1.0, min_scale, t)
	scale = Vector3(s, 1.0, s)  # равномерно в плоскости XZ — круг остаётся кругом
