extends SceneTree

const SAVER := preload("res://addons/gmorn_save_saver/gmorn_save_saver.gd")
const STORE := preload("res://addons/gmorn_save/gmorn_save_store.gd")
const SIDECAR := "user://gmorn_save_saver_verify.json"
const SAVE := "user://gmorn_save_saver_verify.json.cloud.json"
const MARKER := "user://gmorn_save_saver_preview_request.json"
const PREVIEW := "user://gmorn_save_saver_preview.json"
const IMAGE_SUCCESS := "user://gmorn_save_saver_image_success.json.cloud.json"
const IMAGE_FAILURE := "user://gmorn_save_saver_image_failure.json.cloud.json"
const IMAGE_URL := "https://drop.tsukumistudio.com/2026/09/23/0123456789abcdef0123456789abcdef.jpg"

class TestSaver extends SAVER:
	var fixture: Image
	var capture_count := 0
	var image_requests: Array[PackedByteArray] = []
	var save_requests: Array[Dictionary] = []
	var persist_allowed := true

	func _capture_viewport_image() -> Image:
		capture_count += 1
		return fixture

	func _request_screenshot_upload(endpoint: String, jpeg: PackedByteArray) -> Error:
		_request_kind = "screenshot"
		_request_endpoint = endpoint
		_request_sidecar_path = _sidecar_path
		_sent_revision = int(_state.pending.revision)
		image_requests.append(jpeg.duplicate())
		return OK

	func _request_save(_endpoint: String, _headers: PackedStringArray, body: String) -> Error:
		var json := JSON.new()
		assert(json.parse(body) == OK and json.data is Dictionary)
		save_requests.append(json.data)
		return OK

	func _persist() -> bool:
		return persist_allowed and super._persist()

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
	if not await _verify_screenshot_flow():
		return
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

func _verify_screenshot_flow() -> bool:
	OS.set_environment("GMORN_SAVE_SAVER_TEST_OPT_IN", "1")
	ProjectSettings.set_setting("gmorn_save_saver/endpoint", "https://save.example.invalid")
	var pixels := PackedByteArray()
	pixels.resize(800 * 600 * 3)
	var random := RandomNumberGenerator.new()
	random.seed = 731
	for index in pixels.size():
		pixels[index] = random.randi_range(0, 255)
	var image := Image.create_from_data(800, 600, false, Image.FORMAT_RGB8, pixels)
	var saver := TestSaver.new()
	saver.fixture = image
	root.add_child(saver)
	var jpeg := saver._encode_screenshot_jpeg(image)
	var decoded := Image.new()
	var encoded_ok := not jpeg.is_empty() and jpeg.size() <= 100 * 1024 \
		and decoded.load_jpg_from_buffer(jpeg) == OK and decoded.get_width() <= 640
	if not encoded_ok:
		push_error("JPEG encoder did not meet 640px / 100KiB limits")
		quit(1)
		return false
	var wide_image := Image.create(800, 600, false, Image.FORMAT_RGB8)
	wide_image.fill(Color(0.4, 0.5, 0.8))
	var wide_jpeg := saver._encode_screenshot_jpeg(wide_image)
	var wide_decoded := Image.new()
	if wide_jpeg.size() > 100 * 1024 or wide_decoded.load_jpg_from_buffer(wide_jpeg) != OK \
		or wide_decoded.get_width() > 640:
		push_error("wide but compressible images must still respect the 640px limit")
		quit(1)
		return false
	if not saver._valid_screenshot_url(IMAGE_URL) or saver._valid_screenshot_url("https://evil.example/" + IMAGE_URL.get_file()):
		push_error("MornDrop URL validation did not enforce the exact origin")
		quit(1)
		return false
	_prime_registered_saver(saver, IMAGE_SUCCESS)
	saver._send_pending()
	if saver.image_requests.size() != 1:
		push_error("new screenshot was not uploaded")
		quit(1)
		return false
	# A newer local save during the image request must receive its own revision and data.
	saver.submit({"day": 2}, IMAGE_SUCCESS.trim_suffix(".cloud.json"))
	saver._request_kind = ""
	saver._on_screenshot_completed(HTTPRequest.RESULT_SUCCESS, 201,
		("{\"url\":\"" + IMAGE_URL + "\"}").to_utf8_buffer(), "https://save.example.invalid")
	if saver.save_requests.size() != 1 or saver.save_requests[0].revision != 2 \
		or saver.save_requests[0].data.day != 2 or saver.save_requests[0].screenshot.url != IMAGE_URL \
		or not saver._valid_screenshot_record(saver.save_requests[0].screenshot):
		push_error("image response mixed the saved revision or metadata")
		quit(1)
		return false
	var sent_image: Dictionary = saver.save_requests[0].screenshot.duplicate(true)
	saver._request_kind = ""
	saver._send_pending() # Retry must resend the same screenshot without another upload.
	if saver.image_requests.size() != 1 or saver.save_requests.size() != 2 \
		or saver.save_requests[1].screenshot != sent_image:
		push_error("same-revision retry changed the screenshot")
		quit(1)
		return false
	# A new save less than 120 seconds later reuses the latest image.
	saver._request_kind = ""
	saver.submit({"day": 3}, IMAGE_SUCCESS.trim_suffix(".cloud.json"))
	saver._send_pending()
	if saver.image_requests.size() != 1 or saver.capture_count != 1 \
		or saver.save_requests[2].screenshot != sent_image:
		push_error("120-second cadence did not reuse the latest image")
		quit(1)
		return false
	# A failed image upload still produces a JSON save with screenshot=null, then no image-only retry.
	var failed := TestSaver.new()
	failed.fixture = image
	root.add_child(failed)
	_prime_registered_saver(failed, IMAGE_FAILURE)
	failed._send_pending()
	if failed.image_requests.size() != 1:
		push_error("failure fixture did not start its image attempt")
		quit(1)
		return false
	failed._request_kind = ""
	failed._on_screenshot_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedByteArray(), "https://save.example.invalid")
	if failed.save_requests.size() != 1 or failed.save_requests[0].screenshot != null:
		push_error("failed image did not continue with screenshot=null JSON")
		quit(1)
		return false
	failed._request_kind = ""
	failed.submit({"day": 2}, IMAGE_FAILURE.trim_suffix(".cloud.json"))
	failed._send_pending()
	if failed.image_requests.size() != 1 or failed.save_requests.size() != 2 or failed.save_requests[1].screenshot != null:
		push_error("failed image was retried before the 120-second limit")
		quit(1)
		return false
	# Persistence failure must block the JSON request; the same pending data sends after storage recovers.
	var blocked := TestSaver.new()
	root.add_child(blocked)
	_prime_registered_saver(blocked, IMAGE_FAILURE + ".blocked")
	blocked.persist_allowed = false
	blocked._send_save("https://save.example.invalid")
	if not blocked.save_requests.is_empty():
		push_error("JSON request started despite sidecar persistence failure")
		quit(1)
		return false
	blocked.persist_allowed = true
	blocked._send_save("https://save.example.invalid")
	if blocked.save_requests.size() != 1:
		push_error("pending JSON did not resume after sidecar persistence recovered")
		quit(1)
		return false
	for test_saver: TestSaver in [saver, failed, blocked]:
		test_saver._retry.stop()
		test_saver.queue_free()
	print("SCREENSHOT JSON FLOW VERIFY: PASS")
	return true

func _prime_registered_saver(saver: TestSaver, path: String) -> void:
	saver._sidecar_path = path
	saver._loaded = true
	saver._state = {
		"project_id": "project", "registration_key": "a".repeat(64),
		"user_id": "123e4567-e89b-12d3-a456-426614174001",
		"save_id": "123e4567-e89b-12d3-a456-426614174000", "write_token": "b".repeat(64),
		"revision": 1, "pending": {"data": {"day": 1}, "revision": 1}
	}
	assert(saver._persist())

func _clean() -> void:
	for path in [SAVE, SAVE + ".bak", SAVE + ".tmp", MARKER, MARKER + ".bak", MARKER + ".tmp", PREVIEW, PREVIEW + ".bak", PREVIEW + ".tmp", IMAGE_SUCCESS, IMAGE_SUCCESS + ".bak", IMAGE_SUCCESS + ".tmp", IMAGE_FAILURE, IMAGE_FAILURE + ".bak", IMAGE_FAILURE + ".tmp", IMAGE_FAILURE + ".blocked"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
