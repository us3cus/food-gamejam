extends Control

const SETTINGS_PATH := "user://settings.cfg"
const LOBBY_SCENE_PATH := "res://Scenes/lobby_scene.tscn"
const SOUND_BUS_CANDIDATES := ["Sound", "SFX", "Master"]
const MUSIC_BUS_CANDIDATES := ["Music", "Master"]

@onready var main_buttons: VBoxContainer = $CenterContainer/MainButtons
@onready var setting_container: VBoxContainer = $CenterContainer/SettingContainer
@onready var play_button: Button = $CenterContainer/MainButtons/PlayBunnton
@onready var settings_button: Button = $CenterContainer/MainButtons/BackButton
@onready var exit_button: Button = $CenterContainer/MainButtons/ExitButton
@onready var back_button: Button = $CenterContainer/SettingContainer/BackButton
@onready var fullscreen_check: CheckBox = $CenterContainer/SettingContainer/FullscreenCheck
@onready var sound_slider: HSlider = $CenterContainer/SettingContainer/SoundSlider
@onready var music_slider: HSlider = $CenterContainer/SettingContainer/MusicSlider

var _config := ConfigFile.new()
var _sound_bus_index := -1
var _music_bus_index := -1
var _loading_settings := true


func _ready() -> void:
	_sound_bus_index = _find_bus_index(SOUND_BUS_CANDIDATES)
	_music_bus_index = _find_bus_index(MUSIC_BUS_CANDIDATES)

	play_button.pressed.connect(_on_play_pressed)
	settings_button.pressed.connect(_show_settings)
	exit_button.pressed.connect(_on_exit_pressed)
	back_button.pressed.connect(_show_main_menu)
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	sound_slider.value_changed.connect(_on_sound_value_changed)
	music_slider.value_changed.connect(_on_music_value_changed)

	_load_settings()
	_show_main_menu()
	_loading_settings = false


func _show_settings() -> void:
	main_buttons.visible = false
	setting_container.visible = true


func _show_main_menu() -> void:
	main_buttons.visible = true
	setting_container.visible = false


func _on_exit_pressed() -> void:
	get_tree().quit()


func _on_play_pressed() -> void:
	get_tree().change_scene_to_file(LOBBY_SCENE_PATH)


func _on_fullscreen_toggled(enabled: bool) -> void:
	if _loading_settings:
		return

	_apply_fullscreen(enabled)
	_save_setting("video", "fullscreen", enabled)


func _on_sound_value_changed(value: float) -> void:
	if _loading_settings:
		return

	_apply_bus_volume(_sound_bus_index, value)
	_save_setting("audio", "sound_volume", value)


func _on_music_value_changed(value: float) -> void:
	if _loading_settings:
		return

	_apply_bus_volume(_music_bus_index, value)
	_save_setting("audio", "music_volume", value)


func _load_settings() -> void:
	_config.load(SETTINGS_PATH)

	var fullscreen := bool(_config.get_value("video", "fullscreen", _is_fullscreen()))
	var sound_volume := float(_config.get_value("audio", "sound_volume", _get_bus_volume(_sound_bus_index)))
	var music_volume := float(_config.get_value("audio", "music_volume", _get_bus_volume(_music_bus_index)))

	fullscreen_check.button_pressed = fullscreen
	sound_slider.value = clampf(sound_volume, sound_slider.min_value, sound_slider.max_value)
	music_slider.value = clampf(music_volume, music_slider.min_value, music_slider.max_value)

	_apply_fullscreen(fullscreen)
	_apply_bus_volume(_sound_bus_index, sound_slider.value)
	_apply_bus_volume(_music_bus_index, music_slider.value)


func _save_setting(section: String, key: String, value: Variant) -> void:
	_config.set_value(section, key, value)
	_config.save(SETTINGS_PATH)


func _apply_fullscreen(enabled: bool) -> void:
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if enabled else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)


func _is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


func _find_bus_index(bus_names: Array) -> int:
	for bus_name in bus_names:
		var bus_index := AudioServer.get_bus_index(bus_name)
		if bus_index != -1:
			return bus_index

	return AudioServer.get_bus_index("Master")


func _apply_bus_volume(bus_index: int, value: float) -> void:
	if bus_index == -1:
		return

	var volume := clampf(value, 0.0, 1.0)
	AudioServer.set_bus_mute(bus_index, is_zero_approx(volume))
	AudioServer.set_bus_volume_db(bus_index, linear_to_db(maxf(volume, 0.0001)))


func _get_bus_volume(bus_index: int) -> float:
	if bus_index == -1:
		return 1.0

	if AudioServer.is_bus_mute(bus_index):
		return 0.0

	return db_to_linear(AudioServer.get_bus_volume_db(bus_index))
