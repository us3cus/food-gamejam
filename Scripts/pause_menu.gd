extends CanvasLayer

const SETTINGS_PATH := "user://settings.cfg"
const MAIN_MENU_SCENE_PATH := "res://Scenes/main_menu.tscn"
const SOUND_BUS_CANDIDATES := ["Sound", "SFX", "Master"]
const MUSIC_BUS_CANDIDATES := ["Music", "Master"]

@onready var overlay: Control = $Overlay
@onready var main_buttons: VBoxContainer = $Overlay/Center/MainPanel/Margin/MainButtons
@onready var settings_panel: VBoxContainer = $Overlay/Center/MainPanel/Margin/SettingsPanel
@onready var continue_button: Button = $Overlay/Center/MainPanel/Margin/MainButtons/ContinueButton
@onready var settings_button: Button = $Overlay/Center/MainPanel/Margin/MainButtons/SettingsButton
@onready var menu_button: Button = $Overlay/Center/MainPanel/Margin/MainButtons/MenuButton
@onready var back_button: Button = $Overlay/Center/MainPanel/Margin/SettingsPanel/BackButton
@onready var fullscreen_check: CheckBox = $Overlay/Center/MainPanel/Margin/SettingsPanel/FullscreenCheck
@onready var sound_slider: HSlider = $Overlay/Center/MainPanel/Margin/SettingsPanel/SoundSlider
@onready var music_slider: HSlider = $Overlay/Center/MainPanel/Margin/SettingsPanel/MusicSlider

var _config := ConfigFile.new()
var _sound_bus_index := -1
var _music_bus_index := -1
var _loading_settings := true
var _owns_pause := false


func _ready() -> void:
	_sound_bus_index = _find_bus_index(SOUND_BUS_CANDIDATES)
	_music_bus_index = _find_bus_index(MUSIC_BUS_CANDIDATES)

	continue_button.pressed.connect(_resume_round)
	settings_button.pressed.connect(_show_settings)
	menu_button.pressed.connect(_return_to_main_menu)
	back_button.pressed.connect(_show_main_buttons)
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	sound_slider.value_changed.connect(_on_sound_value_changed)
	music_slider.value_changed.connect(_on_music_value_changed)

	_load_settings()
	_show_main_buttons()
	overlay.visible = false
	_loading_settings = false


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return

	if _owns_pause:
		if settings_panel.visible:
			_show_main_buttons()
		else:
			_resume_round()
	elif not get_tree().paused:
		_pause_round()

	get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	# Не оставляем следующую сцену замороженной, если арена была закрыта извне.
	if _owns_pause:
		get_tree().paused = false


func _pause_round() -> void:
	_owns_pause = true
	overlay.visible = true
	_show_main_buttons()
	get_tree().paused = true
	continue_button.grab_focus()


func _resume_round() -> void:
	if not _owns_pause:
		return
	_owns_pause = false
	overlay.visible = false
	get_tree().paused = false


func _show_settings() -> void:
	main_buttons.visible = false
	settings_panel.visible = true
	back_button.grab_focus()


func _show_main_buttons() -> void:
	main_buttons.visible = true
	settings_panel.visible = false
	if overlay.visible:
		continue_button.grab_focus()


func _return_to_main_menu() -> void:
	var network := get_node_or_null("/root/Network") as NetworkClient
	if network != null:
		var lobby_id := str(network.match_context.get("lobby_id", ""))
		var is_test_match := bool(network.match_context.get("test_mode", false))
		if not is_test_match and not lobby_id.is_empty():
			network.send_packet("lobby.leave", {"lobby_id": lobby_id})
		network.clear_match_context()

	_owns_pause = false
	overlay.visible = false
	get_tree().paused = false
	get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)


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
