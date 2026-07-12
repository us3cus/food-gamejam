extends Control

const MAIN_MENU_SCENE_PATH := "res://Scenes/main_menu.tscn"
const MAX_LOBBY_MEMBERS := 4

@onready var players_list: VBoxContainer = $Lobby/Center/LobbyPanel/MarginContainer/MainColumn/PlayersScroll/PlayersList
@onready var status_label: Label = $Lobby/Center/LobbyPanel/MarginContainer/MainColumn/StatusLabel
@onready var leave_button: Button = $Lobby/Center/LobbyPanel/MarginContainer/MainColumn/ButtonsRow/LeaveButton
@onready var invite_button: Button = $Lobby/Center/LobbyPanel/MarginContainer/MainColumn/ButtonsRow/InviteButton
@onready var start_button: Button = $Lobby/Center/LobbyPanel/MarginContainer/MainColumn/ButtonsRow/StartButton

@onready var network: NetworkClient = get_node("/root/Network") as NetworkClient

var lobby_id := ""


func _ready() -> void:
	leave_button.pressed.connect(_leave_lobby)
	invite_button.pressed.connect(_request_invite)
	start_button.pressed.connect(_start_match)
	invite_button.disabled = true
	start_button.disabled = true

	network.connected_to_server.connect(_on_network_connected)
	network.connection_failed.connect(_on_network_error)
	network.disconnected_from_server.connect(_on_network_disconnected)
	network.packet_received.connect(_on_network_packet)
	network.connect_to_server()
	status_label.text = "Подключение к серверу лобби..."


func _exit_tree() -> void:
	if not lobby_id.is_empty():
		network.send_packet("lobby.leave", {"lobby_id": lobby_id})


func _request_invite() -> void:
	network.send_packet("lobby.invite", {"lobby_id": lobby_id})
	status_label.text = "Запрос приглашения отправлен"


func _start_match() -> void:
	network.send_packet("lobby.start", {"lobby_id": lobby_id})
	status_label.text = "Запуск матча..."


func _leave_lobby() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)


func _on_network_connected() -> void:
	network.send_packet("lobby.create", {"max_members": MAX_LOBBY_MEMBERS})
	status_label.text = "Создание лобби..."


func _on_network_packet(packet: Dictionary) -> void:
	var type := str(packet.get("type", ""))
	var payload: Variant = packet.get("payload", {})
	if not payload is Dictionary:
		return

	match type:
		"lobby.created", "lobby.joined":
			lobby_id = str(payload.get("lobby_id", ""))
			invite_button.disabled = lobby_id.is_empty()
			start_button.disabled = bool(payload.get("can_start", false)) == false
			_update_players(payload.get("players", []))
		"lobby.members":
			_update_players(payload.get("players", []))
		"lobby.invite":
			status_label.text = str(payload.get("message", "Приглашение создано"))
		"lobby.started":
			status_label.text = "Матч запущен"
		"error":
			status_label.text = str(payload.get("message", "Ошибка сервера лобби"))


func _on_network_error(reason: String) -> void:
	status_label.text = reason
	_disable_lobby_actions()


func _on_network_disconnected() -> void:
	status_label.text = "Соединение с сервером потеряно"
	_disable_lobby_actions()


func _update_players(players: Variant) -> void:
	if not players is Array:
		return

	for player_node in players_list.get_children():
		player_node.queue_free()

	for player: Variant in players:
		var player_label := Label.new()
		player_label.custom_minimum_size = Vector2(0, 54)
		player_label.text = _get_player_name(player)
		players_list.add_child(player_label)

	status_label.text = "Игроков в лобби: %d / %d" % [players.size(), MAX_LOBBY_MEMBERS]


func _get_player_name(player: Variant) -> String:
	if player is Dictionary:
		return str(player.get("name", "Игрок"))

	return str(player)


func _disable_lobby_actions() -> void:
	invite_button.disabled = true
	start_button.disabled = true
