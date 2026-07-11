extends CanvasLayer

# HUD раунда: таймер сверху по центру, здоровье слева/справа, экран конца раунда.
# Манекен пока играет за "второго игрока": его нокаут — победа игрока,
# 0 HP у игрока — победа манекена. Когда появится настоящий P2, достаточно
# подменить dummy_path и подпись в сцене HUD.
#
# process_mode = Always: на конце раунда игра ставится на паузу,
# а HUD и кнопка "Заново" продолжают работать.

@export var round_length := 90.0  # сек
@export var player_path: NodePath
@export var dummy_path: NodePath

var _time_left := 0.0
var _round_over := false
var _player_hp := 0
var _dummy_hp := 0

@onready var _timer_label: Label = $TimerLabel
@onready var _player_bar: ProgressBar = $P1Panel/HealthBar
@onready var _dummy_bar: ProgressBar = $P2Panel/HealthBar
@onready var _end_screen: Control = $EndScreen
@onready var _winner_label: Label = $EndScreen/PanelContainer/MarginContainer/VBox/WinnerLabel
@onready var _restart_button: Button = $EndScreen/PanelContainer/MarginContainer/VBox/RestartButton


func _ready() -> void:
	_time_left = round_length
	_restart_button.pressed.connect(_on_restart_pressed)

	# Без типов: ноды берутся по NodePath из инспектора, обращаемся динамически.
	var player = get_node(player_path)
	var dummy = get_node(dummy_path)
	_player_hp = player.max_health
	_dummy_hp = dummy.max_health
	_init_bar(_player_bar, _player_hp)
	_init_bar(_dummy_bar, _dummy_hp)
	player.health_changed.connect(_on_player_health_changed)
	dummy.health_changed.connect(_on_dummy_health_changed)
	player.died.connect(_end_round.bind("Победил Манекен!"))
	dummy.died.connect(_end_round.bind("Победил Игрок!"))


func _process(delta: float) -> void:
	if _round_over:
		return
	_time_left = maxf(_time_left - delta, 0.0)
	var secs := ceili(_time_left)
	_timer_label.text = "%d:%02d" % [floori(secs / 60.0), secs % 60]
	if _time_left <= 0.0:
		_end_round(_timeout_winner())


# Время вышло — побеждает тот, у кого больше здоровья.
func _timeout_winner() -> String:
	if _player_hp > _dummy_hp:
		return "Победил Игрок!"
	if _dummy_hp > _player_hp:
		return "Победил Манекен!"
	return "Ничья!"


func _init_bar(bar: ProgressBar, max_hp: int) -> void:
	bar.max_value = max_hp
	bar.value = max_hp


func _on_player_health_changed(current: int, _max_hp: int) -> void:
	_player_hp = current
	_player_bar.value = current


func _on_dummy_health_changed(current: int, _max_hp: int) -> void:
	_dummy_hp = current
	_dummy_bar.value = current


func _end_round(winner_text: String) -> void:
	if _round_over:
		return
	_round_over = true
	_winner_label.text = winner_text
	_end_screen.visible = true
	get_tree().paused = true


func _on_restart_pressed() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()
