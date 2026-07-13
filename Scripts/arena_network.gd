extends Node3D

const LOBBY_SCENE_PATH := "res://Scenes/lobby_scene.tscn"
const INPUT_SEND_INTERVAL := 1.0 / 15.0

@onready var network: NetworkClient = get_node("/root/Network") as NetworkClient
@onready var player_one: PlayerController = $Player1 as PlayerController
@onready var player_two: PlayerController = $Player2 as PlayerController

var _players_by_id: Dictionary = {}
var _local_player: PlayerController
var _match_id := ""
var _input_elapsed := 0.0
var _input_sequence := 0
var _configured := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	network.packet_received.connect(_on_network_packet)
	network.disconnected_from_server.connect(_on_network_disconnected)
	_configure_match()


func _process(delta: float) -> void:
	if get_tree().paused or not _configured or _local_player == null or not network.has_connection():
		return
	_input_elapsed += delta
	if _input_elapsed < INPUT_SEND_INTERVAL:
		return
	_input_elapsed = fmod(_input_elapsed, INPUT_SEND_INTERVAL)
	_input_sequence += 1
	network.send_packet("game.input", {
		"match_id": _match_id,
		"sequence": _input_sequence,
		"position": _vector_to_payload(_local_player.global_position),
		"velocity": _vector_to_payload(_local_player.velocity),
		"yaw": _local_player.get_network_yaw(),
	}, true)


func _configure_match() -> void:
	var context := network.match_context
	_match_id = str(context.get("match_id", ""))
	var players: Variant = context.get("players", [])
	if _match_id.is_empty() or not players is Array or players.size() != 2:
		push_error("Сетевой матч не содержит ровно двух игроков")
		_return_to_lobby.call_deferred()
		return

	var ordered_players: Array = players.duplicate(true)
	ordered_players.sort_custom(func(a: Variant, b: Variant) -> bool:
		return int(a.get("spawn_slot", 0)) < int(b.get("spawn_slot", 0)))
	var nodes: Array[PlayerController] = [player_one, player_two]
	for index in range(2):
		var player_data: Dictionary = ordered_players[index]
		var player_node := nodes[index]
		var player_id := str(player_data.get("id", ""))
		var spawn := _spawn_from_payload(player_data.get("spawn", {}), index)
		player_node.configure_network_player(
				player_id,
				str(player_data.get("name", "Игрок %d" % (index + 1))),
				player_id == network.player_id,
				spawn)
		player_node.network_hit_requested.connect(_on_network_hit_requested)
		_players_by_id[player_id] = player_node
		if player_id == network.player_id:
			_local_player = player_node

	if _local_player == null:
		push_error("Локальный player_id отсутствует в серверном матче")
		_return_to_lobby.call_deferred()
		return
	_configured = true


func _on_network_packet(packet: Dictionary) -> void:
	var type := str(packet.get("type", ""))
	var payload: Variant = packet.get("payload", {})
	if not payload is Dictionary or str(payload.get("match_id", _match_id)) != _match_id:
		return
	match type:
		"game.state":
			_apply_game_state(payload)
		"game.hit":
			_apply_game_hit(payload)
		"game.round.started":
			_apply_round_reset(payload)
		"game.player_left":
			push_warning(str(payload.get("message", "Второй игрок отключился")))
			_return_to_lobby.call_deferred()


func _apply_game_state(payload: Dictionary) -> void:
	var states: Variant = payload.get("players", [])
	if not states is Array:
		return
	for state: Variant in states:
		if not state is Dictionary:
			continue
		var player_id := str(state.get("id", ""))
		var player_node: PlayerController = _players_by_id.get(player_id) as PlayerController
		if player_node == null:
			continue
		if player_id != network.player_id:
			player_node.apply_network_state(
					_payload_to_vector(state.get("position", {}), player_node.global_position),
					_payload_to_vector(state.get("velocity", {}), Vector3.ZERO),
					float(state.get("yaw", 0.0)))


func _on_network_hit_requested(target_id: String, damage: int, knockback: Vector3) -> void:
	if not _configured or target_id == network.player_id:
		return
	network.send_packet("game.hit", {
		"match_id": _match_id,
		"target_id": target_id,
		"damage": damage,
		"knockback": _vector_to_payload(knockback),
	})


func _apply_game_hit(payload: Dictionary) -> void:
	var target_id := str(payload.get("target_id", ""))
	var target: PlayerController = _players_by_id.get(target_id) as PlayerController
	if target == null:
		return
	target.apply_network_hit(
			int(payload.get("health", target.get_health())),
			_payload_to_vector(payload.get("knockback", {}), Vector3.ZERO))


func _apply_round_reset(payload: Dictionary) -> void:
	if bool(payload.get("reset_match", false)) and $HUD.has_method("reset_network_match_score"):
		$HUD.reset_network_match_score()
	var states: Variant = payload.get("players", [])
	if states is Array:
		for state: Variant in states:
			if state is Dictionary:
				var player: PlayerController = _players_by_id.get(str(state.get("id", ""))) as PlayerController
				if player != null:
					player.reset_network_round(_payload_to_vector(
							state.get("position", {}), player.global_position))
	get_tree().paused = false
	get_tree().reload_current_scene()


func _return_to_lobby() -> void:
	Music.stop_round()
	get_tree().paused = false
	network.clear_match_context()
	get_tree().change_scene_to_file(LOBBY_SCENE_PATH)


func _on_network_disconnected() -> void:
	_return_to_lobby.call_deferred()


func _spawn_from_payload(value: Variant, fallback_slot: int) -> Vector3:
	var fallback := Vector3(-4.5, 0.1, 0.0) if fallback_slot == 0 else Vector3(4.5, 0.1, 0.0)
	return _payload_to_vector(value, fallback)


func _payload_to_vector(value: Variant, fallback: Vector3) -> Vector3:
	if not value is Dictionary:
		return fallback
	return Vector3(
			float(value.get("x", fallback.x)),
			float(value.get("y", fallback.y)),
			float(value.get("z", fallback.z)))


func _vector_to_payload(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}
