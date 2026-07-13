extends Node3D

const LOBBY_SCENE_PATH := "res://Scenes/lobby_scene.tscn"
const INPUT_SEND_INTERVAL := 1.0 / 15.0
const FOOD_PROJECTILE_SCENE: PackedScene = preload("res://Scenes/projectiles/FoodProjectile.tscn")
const FoodItemScript = preload("res://Scripts/food_item.gd")

@onready var network: NetworkClient = get_node("/root/Network") as NetworkClient
@onready var player_one: PlayerController = $Player1 as PlayerController
@onready var player_two: PlayerController = $Player2 as PlayerController
@onready var food_spawner = $FoodSpawner

var _players_by_id: Dictionary = {}
var _local_player: PlayerController
var _match_id := ""
var _input_elapsed := 0.0
var _input_sequence := 0
var _configured := false
var _is_host := false
var _food_types_by_id: Dictionary = {}
var _network_items: Dictionary = {}
var _network_projectiles: Dictionary = {}


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
	_is_host = str(context.get("host_id", "")) == network.player_id
	_configure_network_food()
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
		player_node.network_projectile_requested.connect(_on_network_projectile_requested)
		player_node.network_item_drop_requested.connect(_on_network_item_drop_requested)
		_players_by_id[player_id] = player_node
		if player_id == network.player_id:
			_local_player = player_node

	if _local_player == null:
		push_error("Локальный player_id отсутствует в серверном матче")
		_return_to_lobby.call_deferred()
		return
	_sync_network_items(context.get("items", []))
	_configured = true


func _configure_network_food() -> void:
	food_spawner.set_network_controlled(true)
	for food_type: Variant in food_spawner.food_types:
		if food_type != null and food_type.has_method("get_network_id"):
			_food_types_by_id[str(food_type.get_network_id())] = food_type


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
		"game.item.spawn":
			_spawn_network_item(payload)
		"game.item.picked":
			_apply_item_picked(payload)
		"game.item.despawn":
			_remove_network_item(str(payload.get("item_id", "")))
		"game.projectile.spawn":
			_spawn_network_projectile(payload)
		"game.projectile.despawn":
			_remove_network_projectile(str(payload.get("projectile_id", "")))
		"game.round.started":
			_apply_round_reset(payload)
		"game.player_left":
			push_warning(str(payload.get("message", "Второй игрок отключился")))
			_return_to_lobby.call_deferred()


func _apply_game_state(payload: Dictionary) -> void:
	_sync_network_items(payload.get("items", []))
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
		var held_value: Variant = state.get("held_food", "")
		var held_food_id := str(held_value) if held_value != null else ""
		if held_food_id.is_empty():
			player_node.clear_network_held_food()
		elif _food_types_by_id.has(held_food_id):
			player_node.apply_network_held_food(_food_types_by_id[held_food_id])
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


func _on_network_projectile_requested(food_type_id: String, origin: Vector3,
		launch_velocity: Vector3, knockback_multiplier: float) -> void:
	if not _configured:
		return
	network.send_packet("game.projectile.spawn", {
		"match_id": _match_id,
		"food_type": food_type_id,
		"origin": _vector_to_payload(origin),
		"velocity": _vector_to_payload(launch_velocity),
		"knockback_multiplier": knockback_multiplier,
	})


func _on_network_item_drop_requested(food_type_id: String, drop_position: Vector3) -> void:
	if not _configured:
		return
	network.send_packet("game.item.drop", {
		"match_id": _match_id,
		"food_type": food_type_id,
		"position": _vector_to_payload(drop_position),
	})


func _on_item_pickup_requested(item_id: String) -> void:
	if _configured:
		network.send_packet("game.item.pickup", {"match_id": _match_id, "item_id": item_id})


func _on_item_bonk_requested(item_id: String, target_id: String, damage: int,
		knockback: Vector3) -> void:
	if _configured:
		network.send_packet("game.item.hit", {
			"match_id": _match_id,
			"item_id": item_id,
			"target_id": target_id,
			"damage": damage,
			"knockback": _vector_to_payload(knockback),
		})


func _on_item_finished(item_id: String) -> void:
	if _configured and _is_host:
		network.send_packet("game.item.despawn", {
			"match_id": _match_id,
			"item_id": item_id,
		}, true)


func _on_projectile_hit_requested(projectile_id: String, target_id: String, damage: int,
		knockback: Vector3) -> void:
	if _configured:
		network.send_packet("game.projectile.hit", {
			"match_id": _match_id,
			"projectile_id": projectile_id,
			"target_id": target_id,
			"damage": damage,
			"knockback": _vector_to_payload(knockback),
		})


func _on_projectile_finished(projectile_id: String) -> void:
	if _configured:
		network.send_packet("game.projectile.despawn", {
			"match_id": _match_id,
			"projectile_id": projectile_id,
		}, true)


func _apply_game_hit(payload: Dictionary) -> void:
	var target_id := str(payload.get("target_id", ""))
	var target: PlayerController = _players_by_id.get(target_id) as PlayerController
	if target == null:
		return
	target.apply_network_hit(
			int(payload.get("health", target.get_health())),
			_payload_to_vector(payload.get("knockback", {}), Vector3.ZERO))


func _sync_network_items(value: Variant) -> void:
	if not value is Array:
		return
	var server_item_ids: Dictionary = {}
	for item_data: Variant in value:
		if not item_data is Dictionary:
			continue
		var item_id := str(item_data.get("item_id", ""))
		if item_id.is_empty():
			continue
		server_item_ids[item_id] = true
		var existing: Variant = _network_items.get(item_id)
		if not is_instance_valid(existing):
			_network_items.erase(item_id)
			_spawn_network_item(item_data)
	for item_id: Variant in _network_items.keys():
		if not server_item_ids.has(str(item_id)):
			_remove_network_item(str(item_id))


func _spawn_network_item(payload: Dictionary) -> void:
	var item_id := str(payload.get("item_id", ""))
	var food_type_id := str(payload.get("food_type", ""))
	if item_id.is_empty() or _network_items.has(item_id) or not _food_types_by_id.has(food_type_id):
		return
	var item: FoodItemScript = food_spawner.spawn_network_item(
			item_id,
			_food_types_by_id[food_type_id],
			_payload_to_vector(payload.get("position", {}), Vector3.ZERO),
			float(payload.get("pickup_delay_ms", 0)) / 1000.0)
	item.network_pickup_requested.connect(_on_item_pickup_requested)
	item.network_bonk_requested.connect(_on_item_bonk_requested)
	if _is_host:
		item.network_finished.connect(_on_item_finished)
	_network_items[item_id] = item


func _remove_network_item(item_id: String) -> void:
	# В словаре может остаться ссылка на объект, который уже вызвал queue_free().
	# Не приводим такую ссылку через `as Node`: cast освобождённого Object сам
	# генерирует runtime-ошибку до проверки is_instance_valid().
	var item: Variant = _network_items.get(item_id)
	_network_items.erase(item_id)
	if is_instance_valid(item):
		item.queue_free()


func _apply_item_picked(payload: Dictionary) -> void:
	_remove_network_item(str(payload.get("item_id", "")))
	var player: PlayerController = _players_by_id.get(str(payload.get("player_id", ""))) as PlayerController
	var food_type_id := str(payload.get("food_type", ""))
	if player != null and _food_types_by_id.has(food_type_id):
		player.apply_network_held_food(_food_types_by_id[food_type_id])


func _spawn_network_projectile(payload: Dictionary) -> void:
	var projectile_id := str(payload.get("projectile_id", ""))
	var food_type_id := str(payload.get("food_type", ""))
	var source_id := str(payload.get("source_id", ""))
	if projectile_id.is_empty() or _network_projectiles.has(projectile_id) \
			or not _food_types_by_id.has(food_type_id):
		return
	var projectile: FoodProjectile = FOOD_PROJECTILE_SCENE.instantiate() as FoodProjectile
	projectile.network_projectile_id = projectile_id
	projectile.network_authoritative = source_id == network.player_id
	projectile.shooter = _players_by_id.get(source_id) as Node3D
	add_child(projectile)
	projectile.global_position = _payload_to_vector(payload.get("origin", {}), Vector3.ZERO)
	projectile.configure(
			_food_types_by_id[food_type_id],
			float(payload.get("knockback_multiplier", 1.0)))
	projectile.velocity = _payload_to_vector(payload.get("velocity", {}), Vector3.ZERO)
	if projectile.network_authoritative:
		projectile.network_hit_requested.connect(_on_projectile_hit_requested)
		projectile.network_finished.connect(_on_projectile_finished)
	_network_projectiles[projectile_id] = projectile
	var source: PlayerController = _players_by_id.get(source_id) as PlayerController
	if source != null:
		source.clear_network_held_food()


func _remove_network_projectile(projectile_id: String) -> void:
	var projectile: Variant = _network_projectiles.get(projectile_id)
	_network_projectiles.erase(projectile_id)
	if is_instance_valid(projectile):
		projectile.queue_free()


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
	var context := network.match_context.duplicate(true)
	context["items"] = payload.get("items", [])
	network.set_match_context(context)
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
