extends SceneTree

const SAVER := preload("res://addons/gmorn_save_saver/gmorn_save_saver.gd")
const STORE := preload("res://addons/gmorn_save/gmorn_save_store.gd")
const SIDECAR := "user://gmorn_save_saver_verify.json"
const SAVE := "user://gmorn_save_saver_verify.json.cloud.json"
const MARKER := "user://gmorn_save_saver_preview_request.json"
const PREVIEW := "user://gmorn_save_saver_preview.json"

func _initialize() -> void:
	var watchdog := create_timer(5.0)
	watchdog.timeout.connect(func() -> void:
		push_error("VERIFY TIMEOUT")
		quit(1))
	call_deferred("_run")

func _run() -> void:
	_clean()
	var saver = SAVER.new()
	root.add_child(saver)
	ProjectSettings.set_setting("gmorn_save_saver/project_id", "project")
	# Credentials and latest pending JSON survive a fresh Store instance.
	var sidecar = _open_store(SAVE)
	assert(sidecar.save({"project_id": "project", "registration_key": "a".repeat(64), "revision": 3,
		"pending": {"data": {"day": 17}, "revision": 3}}))
	var loaded = _open_store(SAVE).load_data({})
	assert(loaded.pending.data.day == 17 and loaded.registration_key.length() == 64)
	assert(saver._load_sidecar(SIDECAR), "valid sidecar rejected after JSON round-trip")
	assert(saver._state.pending.data.day == 17, "pending data did not survive reload")
	# A malformed sidecar must not be overwritten or treated as a new registration.
	var bad = FileAccess.open(SAVE, FileAccess.WRITE)
	bad.store_string("not-json")
	bad.close()
	saver._loaded = false
	saver._sidecar_path = ""
	assert(not saver._load_sidecar(SIDECAR))
	assert(FileAccess.get_file_as_string(SAVE) == "not-json")
	# Preview marker is one-shot; test opt-in allows headless verification.
	assert(_open_store(PREVIEW).save({"day": 23}))
	assert(_open_store(MARKER).save({"path": PREVIEW}))
	OS.set_environment("GMORN_SAVE_SAVER_TEST_PREVIEW", "1")
	assert(saver.consume_preview() == PREVIEW)
	assert(saver.consume_preview().is_empty())
	assert(saver._preview_active)
	_clean()
	print("GMORN SAVE SAVER VERIFY: PASS")
	quit(0)

func _open_store(path: String) -> RefCounted:
	var store: RefCounted = STORE.new()
	store.path = path
	return store

func _clean() -> void:
	for path in [SAVE, SAVE + ".bak", SAVE + ".tmp", MARKER, MARKER + ".bak", MARKER + ".tmp", PREVIEW, PREVIEW + ".bak", PREVIEW + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
