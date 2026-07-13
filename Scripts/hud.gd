extends CanvasLayer

# HUD матча: таймер и счёт сверху, здоровье слева/справа, экран конца раунда.
# МАТЧ = best of N: счёт побед хранится в static-переменных — они живут,
# пока запущена игра, и переживают reload_current_scene между раундами.
# Второй PlayerController — сетевой соперник; оба клиента получают одинаковый
# результат попаданий от TCP-сервера.
# HUD же двигает сужение арены: каждый кадр передаёт прогресс раунда полу
# (floor_path -> shrinking_floor.gd).
#
# process_mode = Always: на конце раунда игра ставится на паузу,
# а HUD и кнопка продолжают работать.

@export var round_length := 90.0     # сек
@export var wins_to_take_match := 2  # best of 3
@export var player_path: NodePath
@export var dummy_path: NodePath
@export var floor_path: NodePath     # пол со скриптом shrinking_floor.gd

# static: счёт матча переживает перезагрузку сцены между раундами.
static var _player_wins := 0
static var _dummy_wins := 0
static var _active_match_id := ""

var _time_left := 0.0
var _round_over := false
var _match_over := false
var _player_hp := 0
var _opponent_hp := 0
var _floor = null

@onready var _timer_label: Label = $TimerLabel
@onready var _score_label: Label = $ScoreLabel
@onready var _p1_name: Label = $P1Panel/NameLabel
@onready var _p2_name: Label = $P2Panel/NameLabel
@onready var _player_bar: ProgressBar = $P1Panel/HealthBar
@onready var _dummy_bar: ProgressBar = $P2Panel/HealthBar
@onready var _end_screen: Control = $EndScreen
@onready var _winner_label: Label = $EndScreen/PanelContainer/MarginContainer/VBox/WinnerLabel
@onready var _restart_button: Button = $EndScreen/PanelContainer/MarginContainer/VBox/RestartButton


func _ready() -> void:
	_apply_network_match_context()
	_time_left = round_length
	Music.start_round()
	_restart_button.pressed.connect(_on_restart_pressed)
	_floor = get_node_or_null(floor_path)
	_update_score_label()

	# Без типов: ноды берутся по NodePath из инспектора, обращаемся динамически.
	var player = get_node(player_path)
	var opponent = get_node(dummy_path)
	_player_hp = player.max_health
	_opponent_hp = opponent.max_health
	_init_bar(_player_bar, _player_hp)
	_init_bar(_dummy_bar, _opponent_hp)
	player.health_changed.connect(_on_player_health_changed)
	opponent.health_changed.connect(_on_opponent_health_changed)
	player.died.connect(_end_round.bind(2))
	opponent.died.connect(_end_round.bind(1))


# Настройки задаёт TCP-сервер при lobby.started. Один match_id сохраняется между
# раундами, а новый матч сбрасывает static-счёт предыдущей игры.
func _apply_network_match_context() -> void:
	var network := get_node_or_null("/root/Network") as NetworkClient
	if network == null or network.match_context.is_empty():
		return

	var match_id := str(network.match_context.get("match_id", ""))
	if not match_id.is_empty() and match_id != _active_match_id:
		_active_match_id = match_id
		_player_wins = 0
		_dummy_wins = 0

	var settings := network.get_match_settings()
	round_length = float(settings.get("round_time", round_length))
	wins_to_take_match = int(settings.get("wins_to_match", wins_to_take_match))
	var match_seed := int(network.match_context.get("seed", 0))
	if match_seed != 0:
		seed(match_seed)

	# Имена игроков из лобби вместо заглушек "Игрок"/"Манекен".
	var players: Variant = network.match_context.get("players", [])
	if players is Array and players.size() == 2:
		var ordered: Array = players.duplicate()
		ordered.sort_custom(func(a: Variant, b: Variant) -> bool:
			return int(a.get("spawn_slot", 0)) < int(b.get("spawn_slot", 0)))
		_p1_name.text = str(ordered[0].get("name", "Игрок 1"))
		_p2_name.text = str(ordered[1].get("name", "Игрок 2"))


func _process(delta: float) -> void:
	if _round_over:
		return
	_time_left = maxf(_time_left - delta, 0.0)
	var secs := ceili(_time_left)
	_timer_label.text = "%d:%02d" % [floori(secs / 60.0), secs % 60]
	if secs <= 10:  # финальный отсчёт — таймер краснеет и пульсирует
		var pulse := 0.6 + 0.4 * absf(sin(_time_left * TAU * 0.5))
		_timer_label.add_theme_color_override("font_color", Color(1.0, 0.25 * pulse, 0.2 * pulse))
	else:
		_timer_label.remove_theme_color_override("font_color")
	if _floor != null:
		_floor.set_round_progress(1.0 - _time_left / round_length)
	if _time_left <= 0.0:
		_end_round(_timeout_winner())


# Время вышло — раунд берёт тот, у кого больше здоровья (0 = ничья).
func _timeout_winner() -> int:
	if _player_hp > _opponent_hp:
		return 1
	if _opponent_hp > _player_hp:
		return 2
	return 0


func _init_bar(bar: ProgressBar, max_hp: int) -> void:
	bar.max_value = max_hp
	bar.value = max_hp


func _on_player_health_changed(current: int, _max_hp: int) -> void:
	_player_hp = current
	_player_bar.value = current


func _on_opponent_health_changed(current: int, _max_hp: int) -> void:
	_opponent_hp = current
	_dummy_bar.value = current


# winner: 1 = игрок, 2 = манекен, 0 = ничья (переигровка без очка).
func _end_round(winner: int) -> void:
	if _round_over:
		return
	_round_over = true
	Music.stop_round()

	match winner:
		1: _player_wins += 1
		2: _dummy_wins += 1
	_match_over = _player_wins >= wins_to_take_match or _dummy_wins >= wins_to_take_match
	_update_score_label()

	var winner_name := "Игрок 1" if winner == 1 else "Игрок 2"
	var winner_node = get_node(player_path if winner == 1 else dummy_path)
	if winner != 0 and not str(winner_node.network_player_name).is_empty():
		winner_name = str(winner_node.network_player_name)
	if winner == 0:
		_winner_label.text = "Ничья — переигровка!"
	elif _match_over:
		_winner_label.text = "%s победил матч %d:%d!" % [winner_name, _player_wins, _dummy_wins]
	else:
		_winner_label.text = "%s берёт раунд! Счёт %d:%d" % [winner_name, _player_wins, _dummy_wins]
	_restart_button.text = "Новый матч" if _match_over else "Следующий раунд"

	_end_screen.visible = true
	get_tree().paused = true


func _update_score_label() -> void:
	_score_label.text = "%d : %d" % [_player_wins, _dummy_wins]


func _on_restart_pressed() -> void:
	var network := get_node_or_null("/root/Network") as NetworkClient
	if network != null and not network.match_context.is_empty():
		var host_id := str(network.match_context.get("host_id", ""))
		if host_id != network.player_id:
			_restart_button.text = "Ожидание хоста..."
			_restart_button.disabled = true
			return
		if _match_over:
			_player_wins = 0
			_dummy_wins = 0
		_restart_button.disabled = true
		_restart_button.text = "Запуск раунда..."
		network.send_packet("game.round.reset", {
			"match_id": str(network.match_context.get("match_id", "")),
			"reset_match": _match_over,
		})
		return
	if _match_over:
		_player_wins = 0
		_dummy_wins = 0
	get_tree().paused = false
	get_tree().reload_current_scene()


func reset_network_match_score() -> void:
	_player_wins = 0
	_dummy_wins = 0
