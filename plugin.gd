@tool
extends EditorPlugin

const AUTOLOAD := "GMornSaveSaver"
const PANEL := preload("gmorn_save_saver_panel.tscn")
var panel: Control
var added_autoload := false

func _enter_tree() -> void:
	var base := get_script().resource_path.get_base_dir()
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD):
		add_autoload_singleton(AUTOLOAD, base.path_join("gmorn_save_saver.gd"))
		added_autoload = true
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
