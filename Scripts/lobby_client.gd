extends Control

const MAIN_MENU_SCENE_PATH := "res://Scenes/main_menu.tscn"
const ARENA_SCENE_PATH := "res://Scenes/arena/Arena.tscn"
const PROFILE_PATH := "user://profile.cfg"

@onready var network: NetworkClient = get_node("/root/Network") as NetworkClient

@onready var connection_label: Label = $Center/LobbyPanel/Margin/MainColumn/ConnectionLabel
@onready var diagnostics_label: Label = $Center/LobbyPanel/Margin/MainColumn/DiagnosticsLabel
@onready var setup_panel: VBoxContainer = $Center/LobbyPanel/Margin/MainColumn/SetupPanel
@onready var room_panel: VBoxContainer = $Center/LobbyPanel/Margin/MainColumn/RoomPanel
@onready var player_name_edit: LineEdit = $Center/LobbyPanel/Margin/MainColumn/SetupPanel/PlayerNameEdit
@onready var create_max_players: SpinBox = $Center/LobbyPanel/Margin/MainColumn/SetupPanel/CreateSettings/MaxPlayers
@onready var create_round_time: SpinBox = $Center/LobbyPanel/Margin/MainColumn/SetupPanel/CreateSettings/RoundTime
@onready var create_wins: SpinBox = $Center/LobbyPanel/Margin/MainColumn/SetupPanel/CreateSettings/Wins
@onready var create_button: Button = $Center/LobbyPanel/Margin/MainColumn/SetupPanel/CreateButton
@onready var join_code_edit: LineEdit = $Center/LobbyPanel/Margin/MainColumn/SetupPanel/JoinRow/JoinCodeEdit
@onready var join_button: Button = $Center/LobbyPanel/Margin/MainColumn/SetupPanel/JoinRow/JoinButton
@onready var reconnect_button: Button = $Center/LobbyPanel/Margin/MainColumn/SetupPanel/SetupButtons/ReconnectButton
@onready var menu_button: Button = $Center/LobbyPanel/Margin/MainColumn/SetupPanel/SetupButtons/MenuButton

@onready var room_code_label: Label = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/RoomCodeLabel
@onready var room_max_players: SpinBox = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/RoomSettings/MaxPlayers
@onready var room_round_time: SpinBox = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/RoomSettings/RoundTime
@onready var room_wins: SpinBox = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/RoomSettings/Wins
@onready var apply_settings_button: Button = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/ApplySettingsButton
@onready var players_list: VBoxContainer = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/PlayersScroll/PlayersList
@onready var status_label: Label = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/StatusLabel
@onready var leave_button: Button = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/ButtonsRow/LeaveButton
@onready var copy_button: Button = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/ButtonsRow/CopyButton
@onready var ready_button: Button = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/ButtonsRow/ReadyButton
@onready var start_button: Button = $Center/LobbyPanel/Margin/MainColumn/RoomPanel/ButtonsRow/StartButton

var lobby_id := ""
var _is_host := false
var _is_ready := false
var _can_start := false
var _starting_match := false
var _updating_settings_controls := false


func _ready() -> void:
	create_button.pressed.connect(_create_lobby)
	join_button.pressed.connect(_join_lobby)
	reconnect_button.pressed.connect(_connect)
	menu_button.pressed.connect(_return_to_menu)
	apply_settings_button.pressed.connect(_apply_room_settings)
	leave_button.pressed.connect(_leave_room)
	copy_button.pressed.connect(_copy_invite_code)
	ready_button.pressed.connect(_toggle_ready)
	start_button.pressed.connect(_start_match)
	join_code_edit.text_submitted.connect(func(_value: String) -> void: _join_lobby())
	player_name_edit.text_changed.connect(_on_player_name_changed)

	network.connected_to_server.connect(_on_network_connected)
	network.session_ready.connect(_on_session_ready)
	network.connection_failed.connect(_on_network_error)
	network.disconnected_from_server.connect(_on_network_disconnected)
	network.packet_received.connect(_on_network_packet)
	network.diagnostic.connect(_on_network_diagnostic)

	_load_profile()
	_show_setup()
	_connect()


func _exit_tree() -> void:
	if not lobby_id.is_empty() and not _starting_match:
		network.send_packet("lobby.leave", {"lobby_id": lobby_id})


func _connect() -> void:
	_set_setup_actions_enabled(false)
	reconnect_button.disabled = true
	connection_label.text = "Подключение к %s:%d (TCP)..." % [network.get_server_host(), network.get_server_port()]
	network.configure_player_name(player_name_edit.text)
	if network.has_session():
		_on_session_ready(network.player_id)
	else:
		network.connect_to_server()


func _create_lobby() -> void:
	_save_player_name()
	network.configure_player_name(player_name_edit.text)
	if network.send_packet("lobby.create", {"settings": _settings_from_controls(
			create_max_players, create_round_time, create_wins)}):
		_set_setup_actions_enabled(false)
		connection_label.text = "Создание лобби..."


func _join_lobby() -> void:
	var code := join_code_edit.text.strip_edges().to_upper()
	if code.is_empty():
		connection_label.text = "Введите код лобби"
		join_code_edit.grab_focus()
		return

	_save_player_name()
	network.configure_player_name(player_name_edit.text)
	if network.send_packet("lobby.join", {"lobby_id": code}):
		_set_setup_actions_enabled(false)
		connection_label.text = "Вход в лобби %s..." % code


func _apply_room_settings() -> void:
	if not _is_host or _updating_settings_controls:
		return
	network.send_packet("lobby.settings", {
		"lobby_id": lobby_id,
		"settings": _settings_from_controls(room_max_players, room_round_time, room_wins),
	})
	status_label.text = "Сохранение настроек..."


func _toggle_ready() -> void:
	network.send_packet("lobby.ready", {"lobby_id": lobby_id, "ready": not _is_ready})
	ready_button.disabled = true


func _start_match() -> void:
	start_button.disabled = true
	status_label.text = "Сервер запускает матч..."
	network.send_packet("lobby.start", {"lobby_id": lobby_id})


func _leave_room() -> void:
	if not lobby_id.is_empty():
		network.send_packet("lobby.leave", {"lobby_id": lobby_id})
	lobby_id = ""
	_is_host = false
	_is_ready = false
	_show_setup()
	_set_setup_actions_enabled(network.has_session())
	connection_label.text = "Подключено к %s:%d" % [network.get_server_host(), network.get_server_port()]


func _copy_invite_code() -> void:
	if lobby_id.is_empty():
		return
	DisplayServer.clipboard_set(lobby_id)
	status_label.text = "Код %s скопирован" % lobby_id
	network.send_packet("lobby.invite", {"lobby_id": lobby_id})


func _return_to_menu() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)


func _on_network_connected() -> void:
	connection_label.text = "Соединение установлено, авторизация..."


func _on_session_ready(_player_id: String) -> void:
	if not lobby_id.is_empty():
		return
	connection_label.text = "Подключено к %s:%d" % [network.get_server_host(), network.get_server_port()]
	_set_setup_actions_enabled(true)
	reconnect_button.disabled = true


func _on_network_packet(packet: Dictionary) -> void:
	var type := str(packet.get("type", ""))
	var payload: Variant = packet.get("payload", {})
	if not payload is Dictionary:
		return

	match type:
		"lobby.created", "lobby.joined", "lobby.updated":
			_apply_lobby(payload)
		"lobby.invite":
			var invite_code := str(payload.get("invite_code", lobby_id))
			if not invite_code.is_empty():
				DisplayServer.clipboard_set(invite_code)
			status_label.text = "Код %s скопирован" % invite_code
		"lobby.left":
			if str(payload.get("lobby_id", "")) == lobby_id:
				lobby_id = ""
				_show_setup()
		"lobby.closed":
			lobby_id = ""
			_show_setup()
			connection_label.text = str(payload.get("message", "Лобби закрыто"))
			_set_setup_actions_enabled(network.has_session())
		"lobby.started":
			_starting_match = true
			network.set_match_context(payload)
			status_label.text = "Матч начинается..."
			get_tree().call_deferred("change_scene_to_file", ARENA_SCENE_PATH)
		"error":
			_show_server_error(payload)


func _on_network_error(reason: String) -> void:
	connection_label.text = reason
	lobby_id = ""
	_show_setup()
	_set_setup_actions_enabled(false)
	reconnect_button.disabled = false
	_disable_room_actions()


func _on_network_disconnected() -> void:
	connection_label.text = "Соединение с игровым сервером потеряно"
	lobby_id = ""
	_show_setup()
	_set_setup_actions_enabled(false)
	reconnect_button.disabled = false
	_disable_room_actions()


func _on_network_diagnostic(message: String) -> void:
	diagnostics_label.text = message


func _apply_lobby(payload: Dictionary) -> void:
	lobby_id = str(payload.get("lobby_id", lobby_id))
	if lobby_id.is_empty():
		return

	setup_panel.visible = false
	room_panel.visible = true
	room_code_label.text = "Код лобби: %s" % lobby_id
	_is_host = str(payload.get("host_id", "")) == network.player_id

	var settings: Variant = payload.get("settings", {})
	if settings is Dictionary:
		_update_settings_controls(settings)

	var players: Variant = payload.get("players", [])
	_update_players(players)
	_update_local_ready(players)

	for control: Control in [room_max_players, room_round_time, room_wins]:
		control.mouse_filter = Control.MOUSE_FILTER_STOP if _is_host else Control.MOUSE_FILTER_IGNORE
		control.focus_mode = Control.FOCUS_ALL if _is_host else Control.FOCUS_NONE
	apply_settings_button.visible = _is_host
	ready_button.visible = not _is_host
	ready_button.disabled = false
	ready_button.text = "Отменить готовность" if _is_ready else "Готов"
	start_button.visible = _is_host
	_can_start = bool(payload.get("can_start", false))
	start_button.disabled = not _can_start
	copy_button.disabled = false
	apply_settings_button.disabled = false

	var message := str(payload.get("status_message", ""))
	if message.is_empty():
		message = "Можно начинать" if _can_start else "Ожидание готовности игроков"
	status_label.text = message
	connection_label.text = "Лобби на %s:%d" % [network.get_server_host(), network.get_server_port()]


func _update_players(players: Variant) -> void:
	if not players is Array:
		return
	for player_node in players_list.get_children():
		player_node.queue_free()

	for player: Variant in players:
		var player_label := Label.new()
		player_label.custom_minimum_size = Vector2(0, 42)
		player_label.add_theme_font_size_override("font_size", 18)
		if player is Dictionary:
			var suffix := ""
			if bool(player.get("is_host", false)):
				suffix = "  [Хост]"
			elif bool(player.get("ready", false)):
				suffix = "  ✓ Готов"
			else:
				suffix = "  Не готов"
			player_label.text = str(player.get("name", "Игрок")) + suffix
		else:
			player_label.text = str(player)
		players_list.add_child(player_label)


func _update_local_ready(players: Variant) -> void:
	_is_ready = false
	if not players is Array:
		return
	for player: Variant in players:
		if player is Dictionary and str(player.get("id", "")) == network.player_id:
			_is_ready = bool(player.get("ready", false))
			return


func _update_settings_controls(settings: Dictionary) -> void:
	_updating_settings_controls = true
	room_max_players.value = int(settings.get("max_players", 2))
	room_round_time.value = int(settings.get("round_time", 90))
	room_wins.value = int(settings.get("wins_to_match", 2))
	_updating_settings_controls = false


func _settings_from_controls(max_players: SpinBox, round_time: SpinBox, wins: SpinBox) -> Dictionary:
	return {
		"max_players": int(max_players.value),
		"round_time": int(round_time.value),
		"wins_to_match": int(wins.value),
		"arena": "kitchen",
	}


func _show_server_error(payload: Dictionary) -> void:
	var message := str(payload.get("message", "Ошибка игрового сервера"))
	if lobby_id.is_empty():
		connection_label.text = message
		_set_setup_actions_enabled(network.has_session())
	else:
		status_label.text = message
		ready_button.disabled = false
		start_button.disabled = not _can_start


func _show_setup() -> void:
	setup_panel.visible = true
	room_panel.visible = false


func _set_setup_actions_enabled(enabled: bool) -> void:
	var has_name := not player_name_edit.text.strip_edges().is_empty()
	create_button.disabled = not enabled or not has_name
	join_button.disabled = not enabled or not has_name


func _disable_room_actions() -> void:
	apply_settings_button.disabled = true
	ready_button.disabled = true
	start_button.disabled = true
	copy_button.disabled = true


func _on_player_name_changed(value: String) -> void:
	var cleaned := value.strip_edges()
	create_button.disabled = cleaned.is_empty() or not network.has_session()
	join_button.disabled = cleaned.is_empty() or not network.has_session()


func _load_profile() -> void:
	var config := ConfigFile.new()
	config.load(PROFILE_PATH)
	player_name_edit.text = str(config.get_value("player", "name", "Игрок"))


func _save_player_name() -> void:
	var config := ConfigFile.new()
	config.set_value("player", "name", player_name_edit.text.strip_edges())
	config.save(PROFILE_PATH)
