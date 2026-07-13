extends Control

const SETTINGS_PATH := "user://settings.cfg"
const LOBBY_SCENE_PATH := "res://Scenes/lobby_scene.tscn"
const SOUND_BUS_CANDIDATES := ["Sound", "SFX", "Master"]
const MUSIC_BUS_CANDIDATES := ["Music", "Master"]
const HOW_TO_PAGES: Array[Dictionary] = [
	{
		"title": "Цель игры",
		"body": "[b]Стань чемпионом кухонной арены![/b]\n\nВы сражаетесь один на один. Подбирайте падающую еду, бросайте её в соперника и выталкивайте его из безопасной зоны.\n\n[color=#ffb84d]Раунд[/color] заканчивается, когда у игрока не остаётся здоровья или истекает время. При тайм-ауте побеждает игрок с большим запасом здоровья.\n\nДля победы в матче возьмите нужное число раундов — его задаёт хост в лобби."
	},
	{
		"title": "Управление",
		"body": "[table=2][cell][b]W A S D[/b][/cell][cell]Движение по арене[/cell][cell][b]Shift[/b][/cell][cell]Спринт[/cell][cell][b]Пробел[/b][/cell][cell]Прыжок[/cell][cell][b]Мышь[/b][/cell][cell]Навестись на точку броска[/cell][cell][b]ЛКМ[/b][/cell][cell]Удерживать для заряда, отпустить для броска[/cell][cell][b]G[/b][/cell][cell]Выбросить подобранный предмет[/cell][cell][b]Esc[/b][/cell][cell]Пауза и настройки[/cell][/table]\n\n[color=#ffb84d]Совет:[/color] чем дольше заряжаете бросок, тем дальше летит еда и сильнее отбрасывает цель."
	},
	{
		"title": "Предметы",
		"body": "Еда падает сверху. Следите за тенью: падающий предмет может ударить по голове. Для подбора достаточно коснуться еды с пустыми руками.\n\n[color=#ef5548][b]Помидор[/b][/color] — самый быстрый, но слабо отбрасывает.\n[color=#f2c633][b]Сыр[/b][/color] — сбалансированный бросок на среднюю дистанцию.\n[color=#f08a24][b]Тыква[/b][/color] — медленная и тяжёлая: наносит 2 урона и мощно толкает.\n[color=#68b96a][b]Арбуз[/b][/color] — взрывается при попадании и раскидывает всех в радиусе — включая бросившего."
	},
	{
		"title": "Препятствия арены",
		"body": "[color=#ffb84d][b]Сужающийся пол[/b][/color] — по ходу раунда безопасного места становится всё меньше. Не задерживайтесь у края.\n\n[b]Вращающаяся сковорода[/b] — не наносит урон, но сильно отбрасывает по ходу вращения.\n[b]Банановая кожура[/b] — заставляет бегущего игрока скользить без контроля; после срабатывания временно исчезает.\n[b]Лужа масла[/b] — не исчезает и повторно лишает управления, пока вы на ней.\n[b]Конфорка[/b] — периодически наносит урон и подбрасывает стоящего на ней игрока."
	},
]

@onready var main_buttons: VBoxContainer = $CenterContainer/MainButtons
@onready var setting_container: VBoxContainer = $CenterContainer/SettingContainer
@onready var play_button: Button = $CenterContainer/MainButtons/PlayBunnton
@onready var how_to_button: Button = $CenterContainer/MainButtons/HowToButton
@onready var settings_button: Button = $CenterContainer/MainButtons/BackButton
@onready var exit_button: Button = $CenterContainer/MainButtons/ExitButton
@onready var back_button: Button = $CenterContainer/SettingContainer/BackButton
@onready var fullscreen_check: CheckBox = $CenterContainer/SettingContainer/FullscreenCheck
@onready var sound_slider: HSlider = $CenterContainer/SettingContainer/SoundSlider
@onready var music_slider: HSlider = $CenterContainer/SettingContainer/MusicSlider
@onready var how_to_modal: Control = $HowToModal
@onready var how_to_page_title: Label = $HowToModal/Center/Panel/Margin/Content/PageTitle
@onready var how_to_page_body: RichTextLabel = $HowToModal/Center/Panel/Margin/Content/PageBody
@onready var how_to_page_indicator: Label = $HowToModal/Center/Panel/Margin/Content/Navigation/PageIndicator
@onready var how_to_previous_button: Button = $HowToModal/Center/Panel/Margin/Content/Navigation/PreviousButton
@onready var how_to_next_button: Button = $HowToModal/Center/Panel/Margin/Content/Navigation/NextButton
@onready var how_to_close_button: Button = $HowToModal/Center/Panel/Margin/Content/CloseButton

var _config := ConfigFile.new()
var _sound_bus_index := -1
var _music_bus_index := -1
var _loading_settings := true
var _how_to_page := 0


func _ready() -> void:
	_sound_bus_index = _find_bus_index(SOUND_BUS_CANDIDATES)
	_music_bus_index = _find_bus_index(MUSIC_BUS_CANDIDATES)
	Music.play_menu()

	play_button.pressed.connect(_on_play_pressed)
	how_to_button.pressed.connect(_show_how_to)
	settings_button.pressed.connect(_show_settings)
	exit_button.pressed.connect(_on_exit_pressed)
	back_button.pressed.connect(_show_main_menu)
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	sound_slider.value_changed.connect(_on_sound_value_changed)
	music_slider.value_changed.connect(_on_music_value_changed)
	how_to_previous_button.pressed.connect(_show_previous_how_to_page)
	how_to_next_button.pressed.connect(_show_next_how_to_page)
	how_to_close_button.pressed.connect(_close_how_to)

	_load_settings()
	_show_main_menu()
	_loading_settings = false


func _show_settings() -> void:
	main_buttons.visible = false
	setting_container.visible = true


func _show_main_menu() -> void:
	main_buttons.visible = true
	setting_container.visible = false
	how_to_modal.visible = false


func _show_how_to() -> void:
	_how_to_page = 0
	_update_how_to_page()
	how_to_modal.visible = true
	how_to_next_button.grab_focus()


func _close_how_to() -> void:
	how_to_modal.visible = false
	how_to_button.grab_focus()


func _show_previous_how_to_page() -> void:
	_how_to_page = maxi(_how_to_page - 1, 0)
	_update_how_to_page()


func _show_next_how_to_page() -> void:
	_how_to_page = mini(_how_to_page + 1, HOW_TO_PAGES.size() - 1)
	_update_how_to_page()


func _update_how_to_page() -> void:
	var page := HOW_TO_PAGES[_how_to_page]
	how_to_page_title.text = str(page["title"])
	how_to_page_body.text = str(page["body"])
	how_to_page_indicator.text = "%d / %d" % [_how_to_page + 1, HOW_TO_PAGES.size()]
	how_to_previous_button.disabled = _how_to_page == 0
	how_to_next_button.disabled = _how_to_page == HOW_TO_PAGES.size() - 1


func _unhandled_input(event: InputEvent) -> void:
	if not how_to_modal.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		_close_how_to()
	elif event.is_action_pressed("ui_left"):
		_show_previous_how_to_page()
	elif event.is_action_pressed("ui_right"):
		_show_next_how_to_page()
	else:
		return
	get_viewport().set_input_as_handled()


func _on_exit_pressed() -> void:
	get_tree().quit()


func _on_play_pressed() -> void:
	Music.stop_menu()
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
