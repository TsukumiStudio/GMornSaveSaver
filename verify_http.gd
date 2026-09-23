extends SceneTree

const SAVER := preload("res://addons/gmorn_save_saver/gmorn_save_saver.gd")
const STORE := preload("res://addons/gmorn_save/gmorn_save_store.gd")
const MAX_TOKEN_BYTES := 8192

var saver: Node
var completed_revision := 0

func _initialize() -> void:
	var watchdog := create_timer(25.0)
	watchdog.timeout.connect(func() -> void:
		push_error("LIVE VERIFY TIMEOUT")
		quit(1))
	call_deferred("_run")

func _run() -> void:
	for name in ["GMORN_SAVE_SAVER_ENDPOINT", "GMORN_SAVE_SAVER_PROJECT_ID"]:
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
	var endpoint := OS.get_environment("GMORN_SAVE_SAVER_ENDPOINT").trim_suffix("/")
	var jwt: String = await _cached_access_token(endpoint + "/v1/admin")
	if not _check(not jwt.is_empty(), "Access token cache missing; complete the Editor login once before live verification"):
		return false
	var request := HTTPRequest.new()
	request.timeout = 15.0
	request.body_size_limit = 300 * 1024
	root.add_child(request)
	var err := request.request(endpoint + "/v1/admin/saves/" + save_id.uri_encode(),
		["cf-access-token: " + jwt], HTTPClient.METHOD_GET)
	jwt = ""
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
	var matches: bool = json.data.project_id == OS.get_environment("GMORN_SAVE_SAVER_PROJECT_ID") \
		and json.data.data is Dictionary and json.data.data.size() == expected.size()
	if matches:
		for key in expected:
			matches = matches and json.data.data.get(key) == expected[key]
	request.queue_free()
	return _check(matches, "admin response data or project_id mismatch")

func _cached_access_token(app_url: String) -> String:
	var binary := _find_cloudflared()
	if binary.is_empty():
		_check(false, "cloudflared not found")
		return ""
	var process: Dictionary = OS.execute_with_pipe(binary,
		PackedStringArray(["access", "token", "--app", app_url]), false)
	if process.is_empty() or not process.get("stdio", null) is FileAccess or not process.get("stderr", null) is FileAccess:
		_check(false, "cloudflared access token could not start")
		return ""
	var stdout: FileAccess = process.stdio
	var stderr: FileAccess = process.stderr
	var pid := int(process.get("pid", -1))
	if not _check(pid > 0, "cloudflared access token returned no process ID"):
		stdout.close()
		stderr.close()
		return ""
	var output := PackedByteArray()
	var started := Time.get_ticks_msec()
	while OS.is_process_running(pid) and Time.get_ticks_msec() - started < 10000:
		_drain_pipes(stdout, stderr, output)
		if output.size() > MAX_TOKEN_BYTES:
			OS.kill(pid)
			break
		await process_frame
	_drain_pipes(stdout, stderr, output)
	var timed_out := OS.is_process_running(pid)
	if timed_out:
		OS.kill(pid)
	stdout.close()
	stderr.close()
	if timed_out or output.size() > MAX_TOKEN_BYTES:
		_check(false, "cloudflared access token timed out")
		return ""
	var jwt := output.get_string_from_utf8().strip_edges()
	if not _is_jwt(jwt):
		_check(false, "cloudflared access token failed")
		return ""
	return jwt

func _drain_pipes(stdout: FileAccess, stderr: FileAccess, output: PackedByteArray) -> void:
	while stdout.get_length() > 0:
		var chunk_size := mini(stdout.get_length(), mini(4096, MAX_TOKEN_BYTES + 1 - output.size()))
		if chunk_size <= 0:
			break
		var chunk: PackedByteArray = stdout.get_buffer(chunk_size)
		if chunk.is_empty():
			break
		output.append_array(chunk)
	while stderr.get_length() > 0:
		var discarded: PackedByteArray = stderr.get_buffer(mini(stderr.get_length(), 4096))
		if discarded.is_empty():
			break

func _find_cloudflared() -> String:
	var separator := ";" if OS.get_name() == "Windows" else ":"
	var executable := "cloudflared.exe" if OS.get_name() == "Windows" else "cloudflared"
	for directory: String in OS.get_environment("PATH").split(separator, false):
		var candidate := directory.path_join(executable)
		if FileAccess.file_exists(candidate):
			return candidate
	for candidate: String in ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]:
		if FileAccess.file_exists(candidate):
			return candidate
	return ""

func _is_jwt(value: String) -> bool:
	var parts := value.split(".")
	return parts.size() == 3 and not parts[0].is_empty() and not parts[1].is_empty() and not parts[2].is_empty()

func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error("LIVE VERIFY: " + message)
		quit(1)
	return condition

func _open_store(path: String) -> RefCounted:
	var store: RefCounted = STORE.new()
	store.path = path
	return store
