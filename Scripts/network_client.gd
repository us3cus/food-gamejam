extends Node
class_name NetworkClient

signal connected_to_server
signal connection_failed(reason: String)
signal disconnected_from_server
signal packet_received(packet: Dictionary)

const DEFAULT_SERVER_HOST := "temten.me"
const DEFAULT_SERVER_PORT := 7777
const MAX_RECEIVE_BUFFER_BYTES := 1_048_576

var _tcp: StreamPeerTCP
var _receive_buffer := ""
var _was_connected := false
var _request_id := 0


func connect_to_server() -> void:
	if has_connection():
		return

	close()
	_tcp = StreamPeerTCP.new()

	var host := str(ProjectSettings.get_setting("network/lobby/host", DEFAULT_SERVER_HOST))
	var port := int(ProjectSettings.get_setting("network/lobby/port", DEFAULT_SERVER_PORT))
	var connect_error := _tcp.connect_to_host(host, port)
	if connect_error != OK:
		connection_failed.emit("Не удалось начать подключение к %s:%d" % [host, port])
		close()


func has_connection() -> bool:
	return _tcp != null and _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED


func send_packet(packet_type: String, payload: Dictionary = {}) -> void:
	if not has_connection():
		return

	_request_id += 1
	var packet := {
		"type": packet_type,
		"request_id": _request_id,
		"payload": payload,
	}
	var bytes := (JSON.stringify(packet) + "\n").to_utf8_buffer()
	_tcp.put_data(bytes)


func close() -> void:
	if _tcp != null:
		_tcp.disconnect_from_host()

	_tcp = null
	_receive_buffer = ""
	_was_connected = false


func _process(_delta: float) -> void:
	if _tcp == null:
		return

	_tcp.poll()
	match _tcp.get_status():
		StreamPeerTCP.STATUS_CONNECTING:
			return
		StreamPeerTCP.STATUS_CONNECTED:
			if not _was_connected:
				_was_connected = true
				connected_to_server.emit()
				_send_hello()
			_read_packets()
		StreamPeerTCP.STATUS_ERROR:
			var was_connected := _was_connected
			var reason := "Соединение с сервером потеряно" if was_connected else "Сервер недоступен"
			close()
			if was_connected:
				disconnected_from_server.emit()
			else:
				connection_failed.emit(reason)


func _send_hello() -> void:
	send_packet("session.hello", {
		"protocol": 1,
		"player_name": "Player",
	})


func _read_packets() -> void:
	var available_bytes := _tcp.get_available_bytes()
	if available_bytes <= 0:
		return

	var result: Array = _tcp.get_data(available_bytes)
	if result[0] != OK:
		return

	_receive_buffer += result[1].get_string_from_utf8()
	if _receive_buffer.length() > MAX_RECEIVE_BUFFER_BYTES:
		connection_failed.emit("Сервер прислал слишком большой пакет")
		close()
		return

	while _receive_buffer.contains("\n"):
		var newline_index := _receive_buffer.find("\n")
		var line := _receive_buffer.left(newline_index)
		_receive_buffer = _receive_buffer.substr(newline_index + 1)
		_parse_packet(line)


func _parse_packet(line: String) -> void:
	var packet: Variant = JSON.parse_string(line)
	if packet is Dictionary and packet.has("type"):
		packet_received.emit(packet)
