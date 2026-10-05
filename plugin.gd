@tool
extends EditorPlugin

const AUTOLOAD := "GMornSaveSaver"
const PANEL := preload("gmorn_save_saver_panel.tscn")
var panel: Control
var added_autoload := false

## プロジェクト設定の画面から変えられるように、型と既定値を登録する。
const MIN_INTERVAL_SETTING := "gmorn_save_saver/min_interval_seconds"

func _enter_tree() -> void:
	var base: String = get_script().resource_path.get_base_dir()
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD):
		add_autoload_singleton(AUTOLOAD, base.path_join("gmorn_save_saver.gd"))
		added_autoload = true
	# セーブの送信の最短間隔（秒）。0 なら保存のたびに（2秒の静かな間の後で）送る。
	if not ProjectSettings.has_setting(MIN_INTERVAL_SETTING):
		ProjectSettings.set_setting(MIN_INTERVAL_SETTING, 0.0)
	ProjectSettings.set_initial_value(MIN_INTERVAL_SETTING, 0.0)
	ProjectSettings.add_property_info({"name": MIN_INTERVAL_SETTING, "type": TYPE_FLOAT,
		"hint": PROPERTY_HINT_RANGE, "hint_string": "0,600,1,or_greater,suffix:s"})
	ProjectSettings.set_as_basic(MIN_INTERVAL_SETTING, true)
	panel = PANEL.instantiate()
	if ProjectSettings.has_setting("gmorn_save_saver/preview_path"):
		panel.save_path = String(ProjectSettings.get_setting("gmorn_save_saver/preview_path"))
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, panel)

func _exit_tree() -> void:
	if is_instance_valid(panel):
		remove_control_from_docks(panel)
		panel.queue_free()
	if added_autoload:
		remove_autoload_singleton(AUTOLOAD)
