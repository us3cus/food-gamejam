extends Node

const SETTINGS_PATH := "user://settings.cfg"
const MUSIC_BUS_NAME := "Music"

const MENU_TRACK: AudioStream = preload("res://assets/music/music3.mp3")
const ROUND_TRACKS: Array[AudioStream] = [
	preload("res://assets/music/music1.mp3"),
	preload("res://assets/music/music2.mp3"),
]

var _player: AudioStreamPlayer
var _next_round_track := 0
var _mode := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_music_bus()
	_apply_saved_volume()

	_player = AudioStreamPlayer.new()
	_player.name = "Player"
	_player.bus = MUSIC_BUS_NAME
	add_child(_player)


func play_menu() -> void:
	if _mode == "menu" and _player.playing:
		return
	_mode = "menu"
	_play_looped(MENU_TRACK)


func stop_menu() -> void:
	if _mode == "menu":
		stop()


func start_round() -> void:
	if ROUND_TRACKS.is_empty():
		return
	var track := ROUND_TRACKS[_next_round_track]
	_next_round_track = (_next_round_track + 1) % ROUND_TRACKS.size()
	_mode = "round"
	_play_looped(track)


func stop_round() -> void:
	if _mode == "round":
		stop()


func stop() -> void:
	_mode = ""
	_player.stop()
	_player.stream = null


func _play_looped(source: AudioStream) -> void:
	var track := source.duplicate() as AudioStreamMP3
	if track != null:
		track.loop = true
		_player.stream = track
	else:
		_player.stream = source
	_player.play()


func _ensure_music_bus() -> void:
	if AudioServer.get_bus_index(MUSIC_BUS_NAME) != -1:
		return
	AudioServer.add_bus()
	var bus_index := AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(bus_index, MUSIC_BUS_NAME)


func _apply_saved_volume() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	var volume := clampf(float(config.get_value("audio", "music_volume", 1.0)), 0.0, 1.0)
	var bus_index := AudioServer.get_bus_index(MUSIC_BUS_NAME)
	AudioServer.set_bus_mute(bus_index, is_zero_approx(volume))
	AudioServer.set_bus_volume_db(bus_index, linear_to_db(maxf(volume, 0.0001)))
