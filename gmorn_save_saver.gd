extends Node

const STORE := preload("../gmorn_save/gmorn_save_store.gd")
const SIDECAR_SUFFIX := ".cloud.json"
const DEFAULT_ENDPOINT := ""
const SCREENSHOT_ENDPOINT := "https://drop.tsukumistudio.com"
const SCREENSHOT_INTERVAL_SECONDS := 120
const SCREENSHOT_MAX_BYTES := 100 * 1024
const SCREENSHOT_MAX_WIDTH := 640

signal status_changed(message: String)
signal upload_finished(revision: int, success: bool)

var _http: HTTPRequest
var _retry: Timer
var _sidecar_path := ""
var _state: Dictionary = {}
var _loaded := false
var _preview_active := false
var _request_kind := ""
var _retry_seconds := 1.0
var _sent_revision := 0
var _request_endpoint := ""
var _request_sidecar_path := ""
var _screenshot_captured_at := ""

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	_http.body_size_limit = 64 * 1024
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_retry = Timer.new()
	_retry.one_shot = true
	add_child(_retry)
	_retry.timeout.connect(_send_pending)

func submit(data: Dictionary, save_path: String) -> void:
	if not _enabled() or _preview_active:
		return
	if _request_kind != "" and (_request_sidecar_path != save_path + SIDECAR_SUFFIX or _request_endpoint != _endpoint()):
		status_changed.emit("通信中は保存先とendpointを切り替えられません")
		return
	if not _load_sidecar(save_path):
		return
	_state["pending"] = {"data": data.duplicate(true), "revision": int(_state.get("revision", 0)) + 1}
	_state["revision"] = _state.pending.revision
	if not _persist():
		return
	_retry.stop()
	_retry.start(2.0)
	status_changed.emit("クラウド保存を予約しました")

func resume(save_path: String) -> void:
	if not _enabled() or _preview_active or not FileAccess.file_exists(save_path + SIDECAR_SUFFIX):
		return
	if _request_kind != "" and (_request_sidecar_path != save_path + SIDECAR_SUFFIX or _request_endpoint != _endpoint()):
		status_changed.emit("通信中は保存先とendpointを切り替えられません")
		return
	if not _load_sidecar(save_path):
		return
	if _state.get("pending", {}) is Dictionary and not _state.pending.is_empty():
		_send_pending()

## Editorから1回だけ指定されたプレビュー保存先を返す。ゲーム側でロード前に呼ぶ。
func consume_preview() -> String:
	if not OS.has_feature("editor") or Engine.is_editor_hint():
		return ""
	if DisplayServer.get_name() == "headless" and OS.get_environment("GMORN_SAVE_SAVER_TEST_PREVIEW") != "1":
		return ""
	var store = _open_store("user://gmorn_save_saver_preview_request.json")
	if not FileAccess.file_exists(store.path):
		return ""
	var json := JSON.new()
	var file := FileAccess.open(store.path, FileAccess.READ)
	if file == null or json.parse(file.get_as_text()) != OK or not json.data is Dictionary or not json.data.get("path", "") is String:
		status_changed.emit("プレビュー指定ファイルを読めません")
		return ""
	var path := String(json.data.path)
	var configured_path := "user://gmorn_save_saver_preview.json"
	if ProjectSettings.has_setting("gmorn_save_saver/preview_path"):
		configured_path = String(ProjectSettings.get_setting("gmorn_save_saver/preview_path"))
	if path != configured_path:
		status_changed.emit("プレビュー指定先が設定と一致しません")
		return ""
	if not FileAccess.file_exists(path):
		status_changed.emit("プレビューセーブが見つかりません")
		return ""
	if store.erase() != OK:
		status_changed.emit("プレビュー指定を削除できません")
		return ""
	_preview_active = true
	return path

func _enabled() -> bool:
	var endpoint := _endpoint()
	if endpoint.is_empty():
		return false
	if DisplayServer.get_name() == "headless" and OS.get_environment("GMORN_SAVE_SAVER_TEST_OPT_IN") != "1":
		return false
	if Engine.is_editor_hint() and OS.get_environment("GMORN_SAVE_SAVER_EDITOR_OPT_IN") != "1":
		return false
	return true

func _endpoint() -> String:
	var value := DEFAULT_ENDPOINT
	if ProjectSettings.has_setting("gmorn_save_saver/endpoint"):
		value = String(ProjectSettings.get_setting("gmorn_save_saver/endpoint"))
	if OS.get_environment("GMORN_SAVE_SAVER_ENDPOINT") != "":
		value = OS.get_environment("GMORN_SAVE_SAVER_ENDPOINT")
	return value.trim_suffix("/")

func _project_id() -> String:
	var value := ""
	if ProjectSettings.has_setting("gmorn_save_saver/project_id"):
		value = String(ProjectSettings.get_setting("gmorn_save_saver/project_id"))
	if OS.get_environment("GMORN_SAVE_SAVER_PROJECT_ID") != "":
		value = OS.get_environment("GMORN_SAVE_SAVER_PROJECT_ID")
	return value

func _load_sidecar(save_path: String) -> bool:
	var path := save_path + SIDECAR_SUFFIX
	if _loaded and _sidecar_path == path:
		return true
	_loaded = false
	_sidecar_path = path
	_state = {}
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		var json := JSON.new()
		if file == null or json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
			return _invalid_sidecar("サイドカーを読めません。上書きせず停止しました")
		var raw: Dictionary = json.data
		if not _valid_sidecar(raw):
			return _invalid_sidecar("サイドカーの形式が不正です。新規登録せず停止しました")
		if String(raw.project_id) != _project_id():
			return _invalid_sidecar("サイドカーのproject_idが現在の設定と違います")
		raw.revision = int(raw.revision)
		if not raw.pending.is_empty():
			raw.pending.revision = int(raw.pending.revision)
		_state = raw
		_loaded = true
		return true
	if FileAccess.file_exists(path + ".bak"):
		return _invalid_sidecar("サイドカー本体がなく控えが残っています。新規登録せず、控えを確認してください")
	var project_id := _project_id()
	if project_id.is_empty():
		return _invalid_sidecar("project_idが未設定です")
	var crypto := Crypto.new()
	_state = {"project_id": project_id, "registration_key": crypto.generate_random_bytes(32).hex_encode(), "revision": 0, "pending": {}}
	if not _persist():
		return false
	_loaded = true
	return true

func _valid_sidecar(value: Dictionary) -> bool:
	var valid := value.get("project_id", null) is String and not String(value.project_id).is_empty() \
		and value.get("registration_key", null) is String and _is_hex_token(String(value.registration_key)) \
		and _is_integer_number(value.get("revision", null)) \
		and value.get("pending", null) is Dictionary
	if not valid:
		return false
	var has_user := value.has("user_id") or value.has("save_id") or value.has("write_token")
	if has_user and (not value.get("user_id", null) is String or not value.get("save_id", null) is String \
		or not value.get("write_token", null) is String or not _is_hex_token(String(value.write_token))):
		return false
	if value.has("screenshot") and not _valid_screenshot_record(value.screenshot):
		return false
	if value.has("screenshot_last_attempt_unix") and (not _is_integer_number(value.screenshot_last_attempt_unix) \
		or int(value.screenshot_last_attempt_unix) < 0):
		return false
	var pending: Dictionary = value.pending
	if pending.is_empty():
		return true
	if pending.get("data", null) is not Dictionary or not _is_integer_number(pending.get("revision", null)) \
		or int(pending.revision) <= 0 or int(pending.revision) > int(value.revision):
		return false
	return not pending.has("screenshot") or _valid_screenshot_record(pending.screenshot)

func _is_integer_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and floorf(float(value)) == float(value)

func _is_hex_token(value: String) -> bool:
	return value.length() == 64 and value.is_valid_hex_number(false)

func _valid_screenshot_record(value: Variant) -> bool:
	if value == null:
		return true
	if not value is Dictionary:
		return false
	var image: Dictionary = value
	var captured_at := String(image.get("captured_at", ""))
	var pattern := RegEx.new()
	pattern.compile("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
	return _valid_screenshot_url(String(image.get("url", ""))) and pattern.search(captured_at) != null

func _invalid_sidecar(message: String) -> bool:
	status_changed.emit(message)
	return false

func _persist() -> bool:
	var store := _open_store(_sidecar_path)
	if not store.save(_state):
		status_changed.emit("サイドカーを書き込めません")
		return false
	return true

func _send_pending() -> void:
	if _request_kind != "" or _state.is_empty() or _state.get("pending", {}).is_empty():
		return
	var endpoint := _endpoint()
	if not _state.has("user_id"):
		_request_endpoint = endpoint
		_request_sidecar_path = _sidecar_path
		_request_kind = "register"
		var err := _http.request(endpoint + "/v1/users", ["Content-Type: application/json"], HTTPClient.METHOD_POST,
			JSON.stringify({"project_id": _state.project_id, "registration_key": _state.registration_key}))
		if err != OK:
			_retry_later()
		return
	var pending: Dictionary = _state.pending
	if not pending.has("screenshot"):
		var screenshot: Variant = _state.get("screenshot", null)
		var last_attempt := int(_state.get("screenshot_last_attempt_unix", 0))
		if Time.get_unix_time_from_system() - last_attempt >= SCREENSHOT_INTERVAL_SECONDS:
			_state.screenshot_last_attempt_unix = int(Time.get_unix_time_from_system())
			if not _persist():
				_retry_later()
				return
			_screenshot_captured_at = _utc_iso_seconds()
			var jpeg := _encode_screenshot_jpeg(_capture_viewport_image())
			if not jpeg.is_empty():
				var err := _request_screenshot_upload(endpoint, jpeg)
				if err == OK:
					return
				_request_kind = ""
				_screenshot_captured_at = ""
				status_changed.emit("画面の送信を開始できませんでした。セーブは送信します")
		pending["screenshot"] = screenshot
		if not _persist():
			_retry_later()
			return
	_send_save(endpoint)

func _send_save(endpoint: String) -> void:
	if _request_kind != "" or _state.is_empty() or _state.get("pending", {}).is_empty():
		return
	if not _persist():
		_retry_later()
		return
	_request_kind = "save"
	_request_endpoint = endpoint
	_request_sidecar_path = _sidecar_path
	_http.timeout = 30.0
	var headers := PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + String(_state.write_token)])
	var pending: Dictionary = _state.pending
	_sent_revision = int(pending.revision)
	var err := _request_save(endpoint, headers, JSON.stringify(pending))
	if err != OK:
		_retry_later()

func _request_save(endpoint: String, headers: PackedStringArray, body: String) -> Error:
	return _http.request(endpoint + "/v1/saves/" + String(_state.save_id), headers, HTTPClient.METHOD_PUT, body)

func _request_screenshot_upload(endpoint: String, jpeg: PackedByteArray) -> Error:
	_request_kind = "screenshot"
	_request_endpoint = endpoint
	_request_sidecar_path = _sidecar_path
	_sent_revision = int(_state.pending.revision)
	_http.timeout = 10.0
	return _http.request_raw(SCREENSHOT_ENDPOINT,
		["Content-Type: image/jpeg"], HTTPClient.METHOD_POST, jpeg)

func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var kind := _request_kind
	var endpoint := _request_endpoint
	_request_kind = ""
	if kind == "screenshot":
		_on_screenshot_completed(result, code, body, endpoint)
		return
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		_retry_later()
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK or not json.data is Dictionary:
		_retry_later()
		return
	var response: Dictionary = json.data
	if kind == "register":
		if not response.get("user_id", null) is String or String(response.user_id).is_empty() \
			or not response.get("save_id", null) is String or String(response.save_id).is_empty() \
			or not response.get("write_token", null) is String or not _is_hex_token(String(response.write_token)):
			_retry_later()
			return
		_state.merge(response, true)
		if not _persist():
			_retry_later()
			return
		_retry_seconds = 1.0
		_send_pending()
		return
	if kind == "save":
		if int(response.get("revision", -1)) != _sent_revision or String(response.get("save_id", _state.save_id)) != String(_state.save_id):
			_retry_later()
			return
		var done_revision := _sent_revision
		if int(_state.pending.get("revision", 0)) == _sent_revision:
			_state.pending = {}
		if not _persist():
			_retry_later()
			return
		upload_finished.emit(done_revision, true)
		_retry_seconds = 1.0
		status_changed.emit("クラウド保存済み")
		if not _state.pending.is_empty():
			_send_pending()

func _on_screenshot_completed(result: int, code: int, body: PackedByteArray, endpoint: String) -> void:
	_http.timeout = 30.0
	var latest: Variant = _state.get("screenshot", null)
	if result == HTTPRequest.RESULT_SUCCESS and code == 201:
		var json := JSON.new()
		if json.parse(body.get_string_from_utf8()) == OK and json.data is Dictionary:
			var url := String(json.data.get("url", ""))
			if _valid_screenshot_url(url):
				latest = {"url": url, "captured_at": _screenshot_captured_at}
				_state["screenshot"] = latest
			else:
				status_changed.emit("画像URLの応答が不正です。セーブは送信します")
		else:
			status_changed.emit("画像応答を読めません。セーブは送信します")
	else:
		status_changed.emit("画面を送れませんでした。セーブは送信します")
	_screenshot_captured_at = ""
	if _state.get("pending", {}) is Dictionary and not _state.pending.is_empty():
		var pending: Dictionary = _state.pending
		if not pending.has("screenshot"):
			pending["screenshot"] = latest
			if not _persist():
				_retry_later()
				return
		elif not _persist():
			_retry_later()
			return
		_send_save(endpoint)

func _can_capture_screenshot() -> bool:
	return not Engine.is_editor_hint() and DisplayServer.get_name() != "headless" and not _preview_active \
		and is_inside_tree() and get_viewport() != null and get_viewport().get_texture() != null

func _capture_viewport_image() -> Image:
	if not _can_capture_screenshot():
		return Image.new()
	return get_viewport().get_texture().get_image()

func _encode_screenshot_jpeg(image: Image) -> PackedByteArray:
	if image == null or image.is_empty():
		return PackedByteArray()
	image = image.duplicate()
	if image.get_width() > SCREENSHOT_MAX_WIDTH:
		var height := maxi(1, int(round(float(image.get_height()) * SCREENSHOT_MAX_WIDTH / image.get_width())))
		image.resize(SCREENSHOT_MAX_WIDTH, height, Image.INTERPOLATE_BILINEAR)
	var jpeg := image.save_jpg_to_buffer(0.65)
	while jpeg.size() > SCREENSHOT_MAX_BYTES and image.get_width() > 1:
		var width := maxi(1, image.get_width() / 2)
		var height := maxi(1, image.get_height() / 2)
		image.resize(width, height, Image.INTERPOLATE_BILINEAR)
		jpeg = image.save_jpg_to_buffer(0.65)
	return jpeg if jpeg.size() <= SCREENSHOT_MAX_BYTES else PackedByteArray()

func _valid_screenshot_url(value: String) -> bool:
	const PREFIX := "https://drop.tsukumistudio.com/"
	if not value.begins_with(PREFIX):
		return false
	var parts := value.substr(PREFIX.length()).split("/")
	if parts.size() != 4 or parts[0].length() != 4 or parts[1].length() != 2 or parts[2].length() != 2:
		return false
	if not parts[0].is_valid_int() or not parts[1].is_valid_int() or not parts[2].is_valid_int():
		return false
	var filename: String = parts[3]
	if not filename.ends_with(".jpg"):
		return false
	var key := filename.trim_suffix(".jpg")
	return key.length() == 32 and key.is_valid_hex_number(false)

func _utc_iso_seconds() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"

func _retry_later() -> void:
	_request_kind = ""
	status_changed.emit("通信に失敗しました。保留データを残して再試行します")
	_retry.start(_retry_seconds)
	_retry_seconds = minf(_retry_seconds * 2.0, 60.0)

func _open_store(path: String) -> RefCounted:
	var store: RefCounted = STORE.new()
	store.path = path
	return store
