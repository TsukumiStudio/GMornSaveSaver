extends SceneTree

const SAVER := preload("res://addons/gmorn_save_saver/gmorn_save_saver.gd")
const STORE := preload("res://addons/gmorn_save/gmorn_save_store.gd")

var saver: Node
var completed_revision := 0

func _initialize() -> void:
	var watchdog := create_timer(25.0)
	watchdog.timeout.connect(func() -> void:
		push_error("LIVE VERIFY TIMEOUT")
		quit(1))
	call_deferred("_run")

func _run() -> void:
	for name in ["GMORN_SAVE_SAVER_ENDPOINT", "GMORN_SAVE_SAVER_PROJECT_ID", "GMORN_SAVE_SAVER_ADMIN_TOKEN"]:
		if not _check(not OS.get_environment(name).is_empty(), name + " env required"):
			return
	saver = SAVER.new()
	root.add_child(saver)
	saver.upload_finished.connect(func(revision: int, success: bool) -> void:
		if success:
			completed_revision = revision)
	var save_path := "user://gmorn_save_saver_live_%d.json" % Time.get_ticks_usec()
	var sidecar_path := save_path + ".cloud.json"
	saver.submit({"money": 731, "day": 19}, save_path)
	if not await _wait_upload(1):
		_check(false, "first upload did not finish within 15 seconds")
		return
	var sidecar := _read_sidecar(sidecar_path)
	if not _check(sidecar.has("user_id") and sidecar.has("save_id") and sidecar.has("write_token"), "registration credentials missing"):
		return
	if not await _assert_admin_data(sidecar.save_id, {"money": 731, "day": 19}):
		return
	completed_revision = 0
	saver.submit({"money": 900, "day": 20}, save_path)
	if not await _wait_upload(2):
		_check(false, "second upload did not finish within 15 seconds")
		return
	if not await _assert_admin_data(sidecar.save_id, {"money": 900, "day": 20}):
		return
	_open_store(sidecar_path).erase()
	print("GMORN SAVE SAVER LIVE VERIFY: PASS")
	quit(0)

func _wait_upload(revision: int) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 15000:
		if completed_revision >= revision:
			return true
		await process_frame
	return false

func _read_sidecar(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not _check(file != null, "sidecar was not written"):
		return {}
	var json := JSON.new()
	if not _check(json.parse(file.get_as_text()) == OK and json.data is Dictionary, "sidecar is invalid"):
		return {}
	return json.data

func _assert_admin_data(save_id: String, expected: Dictionary) -> bool:
	var request := HTTPRequest.new()
	request.timeout = 15.0
	request.body_size_limit = 300 * 1024
	root.add_child(request)
	var endpoint := OS.get_environment("GMORN_SAVE_SAVER_ENDPOINT").trim_suffix("/")
	var err := request.request(endpoint + "/v1/admin/saves/" + save_id.uri_encode(),
		["Authorization: Bearer " + OS.get_environment("GMORN_SAVE_SAVER_ADMIN_TOKEN")], HTTPClient.METHOD_GET)
	if not _check(err == OK, "admin fetch request could not start"):
		return false
	var response: Array = await request.request_completed
	if not _check(response[0] == HTTPRequest.RESULT_SUCCESS and int(response[1]) == 200, "admin fetch failed: %s" % response[1]):
		request.queue_free()
		return false
	var json := JSON.new()
	if not _check(json.parse((response[3] as PackedByteArray).get_string_from_utf8()) == OK and json.data is Dictionary, "admin response invalid"):
		request.queue_free()
		return false
	var matches := json.data.project_id == OS.get_environment("GMORN_SAVE_SAVER_PROJECT_ID") and json.data.data == expected
	request.queue_free()
	return _check(matches, "admin response data or project_id mismatch")

func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error("LIVE VERIFY: " + message)
		quit(1)
	return condition

func _open_store(path: String) -> RefCounted:
	var store: RefCounted = STORE.new()
	store.path = path
	return store
