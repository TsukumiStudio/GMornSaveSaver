extends Node

const STORE := preload("../gmorn_save/gmorn_save_store.gd")
const SIDECAR_SUFFIX := ".cloud.json"
const DEFAULT_ENDPOINT := ""

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

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	_http.body_size_limit = 300 * 1024
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
	var pending: Dictionary = value.pending
	return pending.is_empty() or (pending.get("data", null) is Dictionary and _is_integer_number(pending.get("revision", null)) \
		and int(pending.revision) > 0 and int(pending.revision) <= int(value.revision))

func _is_integer_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and floorf(float(value)) == float(value)

func _is_hex_token(value: String) -> bool:
	return value.length() == 64 and value.is_valid_hex_number(false)

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
	_request_kind = "save"
	_request_endpoint = endpoint
	_request_sidecar_path = _sidecar_path
	var headers := ["Content-Type: application/json", "Authorization: Bearer " + String(_state.write_token)]
	var pending: Dictionary = _state.pending
	_sent_revision = int(pending.revision)
	var err := _http.request(endpoint + "/v1/saves/" + String(_state.save_id), headers, HTTPClient.METHOD_PUT, JSON.stringify(pending))
	if err != OK:
		_retry_later()

func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var kind := _request_kind
	_request_kind = ""
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

func _retry_later() -> void:
	_request_kind = ""
	status_changed.emit("通信に失敗しました。保留データを残して再試行します")
	_retry.start(_retry_seconds)
	_retry_seconds = minf(_retry_seconds * 2.0, 60.0)

func _open_store(path: String) -> RefCounted:
	var store: RefCounted = STORE.new()
	store.path = path
	return store
