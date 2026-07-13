extends Node
class_name NetworkClient

signal connected_to_server
signal session_ready(player_id: String)
signal connection_failed(reason: String)
signal disconnected_from_server
signal packet_received(packet: Dictionary)
signal diagnostic(message: String)

const DEFAULT_SERVER_HOST := "onk.temten.me"
const DEFAULT_SERVER_PORT := 7777
const MAX_RECEIVE_BUFFER_BYTES := 1_048_576
const CONNECT_TIMEOUT_SECONDS := 8.0
const LOG_FILE_PATH := "user://logs/network.log"

var player_name := "Игрок"
var player_id := ""
var match_context: Dictionary = {}

var _tcp: StreamPeerTCP
var _receive_buffer := ""
var _was_connected := false
var _connect_elapsed := 0.0
var _request_id := 0
var _last_tcp_status := -1


func _ready() -> void:
	# TCP должен продолжать читать game.round.started, даже когда HUD поставил
	# игровую сцену на паузу на экране результата раунда.
	process_mode = Node.PROCESS_MODE_ALWAYS


func connect_to_server() -> void:
	if has_connection() or is_connecting():
		_log("Запрос подключения пропущен: соединение уже активно")
		return

	close()
	_tcp = StreamPeerTCP.new()
	_connect_elapsed = 0.0

	var host := get_server_host()
	var port := get_server_port()
	_log("Открываем raw TCP к %s:%d" % [host, port])
	var connect_error := _tcp.connect_to_host(host, port)
	if connect_error != OK:
		_fail_connection("Не удалось начать подключение к %s:%d (код %d)" % [host, port, connect_error])


func configure_player_name(value: String) -> void:
	var normalized := value.strip_edges().substr(0, 24)
	var new_name := normalized if not normalized.is_empty() else "Игрок"
	if new_name == player_name:
		return
	player_name = new_name
	_log("Изменено имя игрока; повторяем session.hello: %s" % ["да" if has_connection() else "нет"])
	if has_connection():
		_send_hello()


func get_server_host() -> String:
	return str(ProjectSettings.get_setting("network/lobby/host", DEFAULT_SERVER_HOST))


func get_server_port() -> int:
	return int(ProjectSettings.get_setting("network/lobby/port", DEFAULT_SERVER_PORT))


func has_connection() -> bool:
	return _tcp != null and _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED


func is_connecting() -> bool:
	return _tcp != null and _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING


func has_session() -> bool:
	return has_connection() and not player_id.is_empty()


func send_packet(packet_type: String, payload: Dictionary = {}, quiet := false) -> bool:
	if not has_connection():
		_log("Не отправлен %s: TCP не подключён" % packet_type)
		return false

	_request_id += 1
	var packet := {
		"type": packet_type,
		"request_id": _request_id,
		"payload": payload,
	}
	var bytes := (JSON.stringify(packet) + "\n").to_utf8_buffer()
	var result := _tcp.put_data(bytes)
	if result == OK and not quiet:
		_log("Отправлен %s (request_id=%d, %d байт)" % [packet_type, _request_id, bytes.size()])
	else:
		_log("Ошибка отправки %s (код %d)" % [packet_type, result])
	return result == OK


func set_match_context(payload: Dictionary) -> void:
	match_context = payload.duplicate(true)


func clear_match_context() -> void:
	match_context.clear()


func get_match_settings() -> Dictionary:
	var settings: Variant = match_context.get("settings", {})
	return settings if settings is Dictionary else {}


func close() -> void:
	if _tcp != null:
		_log("Закрываем TCP-соединение")
		_tcp.disconnect_from_host()

	_tcp = null
	_receive_buffer = ""
	_was_connected = false
	_connect_elapsed = 0.0
	player_id = ""
	_last_tcp_status = -1


func _process(delta: float) -> void:
	if _tcp == null:
		return

	_tcp.poll()
	var status := _tcp.get_status()
	if status != _last_tcp_status:
		_last_tcp_status = status
		_log("Состояние TCP: %s" % _status_name(status))
	match status:
		StreamPeerTCP.STATUS_CONNECTING:
			_connect_elapsed += delta
			if _connect_elapsed >= CONNECT_TIMEOUT_SECONDS:
				_fail_connection("Сервер %s:%d не ответил" % [get_server_host(), get_server_port()])
		StreamPeerTCP.STATUS_CONNECTED:
			if not _was_connected:
				_was_connected = true
				_connect_elapsed = 0.0
				connected_to_server.emit()
				_send_hello()
			_read_packets()
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			var was_connected := _was_connected
			_log("TCP завершился со статусом %s" % _status_name(status))
			close()
			if was_connected:
				disconnected_from_server.emit()
			else:
				connection_failed.emit("Сервер %s:%d недоступен" % [get_server_host(), get_server_port()])


func _send_hello() -> void:
	_log("Отправляем session.hello (имя: %d символов)" % player_name.length())
	send_packet("session.hello", {
		"protocol": 1,
		"player_name": player_name,
	})


func _read_packets() -> void:
	var available_bytes := _tcp.get_available_bytes()
	if available_bytes <= 0:
		return
	_log("Получено %d байт от сервера" % available_bytes)

	var result: Array = _tcp.get_data(available_bytes)
	if result[0] != OK:
		_log("Ошибка чтения TCP (код %d)" % result[0])
		return

	_receive_buffer += result[1].get_string_from_utf8()
	if _receive_buffer.length() > MAX_RECEIVE_BUFFER_BYTES:
		_fail_connection("Сервер прислал слишком большой пакет")
		return

	while _receive_buffer.contains("\n"):
		var newline_index := _receive_buffer.find("\n")
		var line := _receive_buffer.left(newline_index)
		_receive_buffer = _receive_buffer.substr(newline_index + 1)
		_parse_packet(line)


func _parse_packet(line: String) -> void:
	if line.strip_edges().is_empty():
		return
	var packet: Variant = JSON.parse_string(line)
	if not packet is Dictionary or not packet.has("type"):
		_log("Получен некорректный JSON-пакет (%d символов)" % line.length())
		return
	var packet_type := str(packet.get("type", ""))
	if packet_type != "game.state":
		_log("Получен %s (request_id=%s)" % [packet_type, str(packet.get("request_id", "-"))])

	if packet_type == "session.welcome":
		var payload: Variant = packet.get("payload", {})
		if payload is Dictionary:
			player_id = str(payload.get("player_id", ""))
			if not player_id.is_empty():
				session_ready.emit(player_id)

	packet_received.emit(packet)


func _fail_connection(reason: String) -> void:
	_log("Ошибка подключения: %s" % reason)
	close()
	connection_failed.emit(reason)


func _status_name(status: int) -> String:
	match status:
		StreamPeerTCP.STATUS_NONE:
			return "NONE"
		StreamPeerTCP.STATUS_CONNECTING:
			return "CONNECTING"
		StreamPeerTCP.STATUS_CONNECTED:
			return "CONNECTED"
		StreamPeerTCP.STATUS_ERROR:
			return "ERROR"
	return "UNKNOWN(%d)" % status


func _log(message: String) -> void:
	var entry := "%s | %s" % [Time.get_datetime_string_from_system(), message]
	print("[Network] %s" % entry)
	diagnostic.emit(entry)

	var logs_dir := DirAccess.open("user://")
	if logs_dir != null:
		logs_dir.make_dir_recursive("logs")
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(LOG_FILE_PATH) else FileAccess.WRITE_READ
	var file := FileAccess.open(LOG_FILE_PATH, mode)
	if file == null:
		push_warning("Не удалось открыть %s для записи" % LOG_FILE_PATH)
		return
	file.seek_end()
	file.store_line(entry)
	file.close()
