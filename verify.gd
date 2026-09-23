extends SceneTree

const SAVER := preload("res://addons/gmorn_save_saver/gmorn_save_saver.gd")
const STORE := preload("res://addons/gmorn_save/gmorn_save_store.gd")
const LIVE_VERIFY := preload("res://verify_http.gd")
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
	if not await _verify_pipe_output():
		return
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
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	var backup := FileAccess.open(SAVE + ".bak", FileAccess.WRITE)
	backup.store_string('{"project_id":"project","registration_key":"' + "b".repeat(64) + '","revision":4,"pending":{}}')
	backup.close()
	saver._loaded = false
	saver._sidecar_path = ""
	assert(not saver._load_sidecar(SIDECAR), "created a new registration despite a recoverable backup")
	assert(not FileAccess.file_exists(SAVE), "wrote a new sidecar beside the backup")
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

func _verify_pipe_output() -> bool:
	var started := Time.get_ticks_msec()
	var child: Dictionary = OS.execute_with_pipe("/bin/sh", PackedStringArray([
		"-c", "sleep 0.05; printf 'header.payload.signature\\n'; printf diagnostic >&2"
	]), false)
	if child.is_empty() or Time.get_ticks_msec() - started > 500:
		push_error("execute_with_pipe did not start asynchronously")
		quit(1)
		return false
	var stdout: FileAccess = child.stdio
	var stderr: FileAccess = child.stderr
	var pid := int(child.pid)
	var output := PackedByteArray()
	var error_output := PackedByteArray()
	var deadline := Time.get_ticks_msec() + 2000
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		_read_pipe(stdout, output)
		_read_pipe(stderr, error_output)
		await process_frame
	_read_pipe(stdout, output)
	_read_pipe(stderr, error_output)
	var passed := not OS.is_process_running(pid) \
		and output.get_string_from_utf8().strip_edges() == "header.payload.signature" \
		and error_output.get_string_from_utf8() == "diagnostic"
	stdout.close()
	stderr.close()
	if not passed:
		push_error("execute_with_pipe did not expose stdout/stderr pipe output")
		quit(1)
		return false
	return true

func _read_pipe(pipe: FileAccess, output: PackedByteArray) -> void:
	while pipe.get_length() > 0:
		var chunk: PackedByteArray = pipe.get_buffer(mini(pipe.get_length(), 4096))
		if chunk.is_empty():
			break
		output.append_array(chunk)

func _clean() -> void:
	for path in [SAVE, SAVE + ".bak", SAVE + ".tmp", MARKER, MARKER + ".bak", MARKER + ".tmp", PREVIEW, PREVIEW + ".bak", PREVIEW + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
