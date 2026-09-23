@tool
extends VBoxContainer

const STORE := preload("../gmorn_save/gmorn_save_store.gd")
const LOGIN_TIMEOUT_MSEC := 180000
const MAX_JWT_BYTES := 8192

var save_path := "user://gmorn_save_saver_preview.json"
var request: HTTPRequest
var _access_pid := -1
var _access_started_msec := 0
var _access_stdout: FileAccess
var _access_stderr: FileAccess
var _access_output := PackedByteArray()
var _requested_save_id := ""
var _requested_endpoint := ""

func _ready() -> void:
	$Fetch.pressed.connect(_fetch)
	request = HTTPRequest.new()
	request.timeout = 30.0
	request.body_size_limit = 300 * 1024
	add_child(request)
	request.request_completed.connect(_completed)

func _exit_tree() -> void:
	_stop_access_login()

func _process(_delta: float) -> void:
	var running := EditorInterface.is_playing_scene()
	if running and _access_pid > 0:
		_stop_access_login()
		_requested_save_id = ""
		_requested_endpoint = ""
		$Status.text = "実行が始まったため、Access認証を中止しました"
	$Fetch.disabled = running or _access_pid > 0 or request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED
	if _access_pid <= 0:
		return
	_drain_access_pipes()
	if _access_output.size() > MAX_JWT_BYTES:
		_fail_access_login("cloudflaredのJWT出力が上限を超えました")
	elif Time.get_ticks_msec() - _access_started_msec > LOGIN_TIMEOUT_MSEC:
		_fail_access_login("Cloudflare Access認証が時間切れです。もう一度取得してください")
	elif not OS.is_process_running(_access_pid):
		_drain_access_pipes()
		_finish_access_login()

func _fetch() -> void:
	if EditorInterface.is_playing_scene():
		return
	var save_id: String = $SaveId.text.strip_edges()
	var endpoint := OS.get_environment("GMORN_SAVE_SAVER_ENDPOINT")
	if endpoint.is_empty() and ProjectSettings.has_setting("gmorn_save_saver/endpoint"):
		endpoint = String(ProjectSettings.get_setting("gmorn_save_saver/endpoint"))
	endpoint = endpoint.trim_suffix("/")
	if save_id.is_empty() or endpoint.is_empty():
		$Status.text = "保存IDとendpointを確認してください"
		return
	var cloudflared := _find_cloudflared()
	if cloudflared.is_empty():
		$Status.text = "cloudflaredが見つかりません。インストールしてからEditorを再起動してください"
		return
	_requested_save_id = save_id
	_requested_endpoint = endpoint
	var app_url := endpoint + "/v1/admin"
	var process: Dictionary = OS.execute_with_pipe(cloudflared,
		PackedStringArray(["access", "login", "--no-verbose", "--app", app_url]), false)
	var process_pid := int(process.get("pid", -1))
	if process.is_empty() or not process.get("stdio", null) is FileAccess \
		or not process.get("stderr", null) is FileAccess or process_pid <= 0:
		if process_pid > 0:
			OS.kill(process_pid)
		_requested_save_id = ""
		_requested_endpoint = ""
		$Status.text = "cloudflaredを起動できませんでした"
		return
	_access_pid = int(process.pid)
	_access_stdout = process.stdio
	_access_stderr = process.stderr
	_access_output.clear()
	_access_started_msec = Time.get_ticks_msec()
	$Status.text = "Cloudflare Access認証中です。初回はブラウザーでログインしてください"

func _drain_access_pipes() -> void:
	if is_instance_valid(_access_stdout):
		while _access_stdout.get_length() > 0:
			var chunk: PackedByteArray = _access_stdout.get_buffer(mini(_access_stdout.get_length(), 4096))
			if chunk.is_empty():
				break
			_access_output.append_array(chunk)
			if _access_output.size() > MAX_JWT_BYTES:
				return
	if is_instance_valid(_access_stderr):
		while _access_stderr.get_length() > 0:
			var discarded: PackedByteArray = _access_stderr.get_buffer(mini(_access_stderr.get_length(), 4096))
			if discarded.is_empty():
				break

func _finish_access_login() -> void:
	var jwt := _access_output.get_string_from_utf8().strip_edges()
	var save_id := _requested_save_id
	var endpoint := _requested_endpoint
	_clear_access_login()
	_requested_save_id = ""
	_requested_endpoint = ""
	if not _is_jwt(jwt):
		$Status.text = "Cloudflare Access認証に失敗しました。JWTが返りませんでした"
		return
	var err := request.request(endpoint + "/v1/admin/saves/" + save_id.uri_encode(),
		["cf-access-token: " + jwt], HTTPClient.METHOD_GET)
	jwt = ""
	if err != OK:
		$Status.text = "取得要求を開始できません: " + error_string(err)
	else:
		$Status.text = "セーブを取得中…"

func _fail_access_login(message: String) -> void:
	_stop_access_login()
	_requested_save_id = ""
	_requested_endpoint = ""
	$Status.text = message

func _stop_access_login() -> void:
	if _access_pid > 0 and OS.is_process_running(_access_pid):
		OS.kill(_access_pid)
	_clear_access_login()

func _clear_access_login() -> void:
	_access_pid = -1
	_access_started_msec = 0
	_access_output.clear()
	for pipe: FileAccess in [_access_stdout, _access_stderr]:
		if is_instance_valid(pipe):
			pipe.close()
	_access_stdout = null
	_access_stderr = null

func _is_jwt(value: String) -> bool:
	var parts := value.split(".")
	return parts.size() == 3 and not parts[0].is_empty() and not parts[1].is_empty() and not parts[2].is_empty()

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

func _completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		$Status.text = "Access認証または取得に失敗しました (HTTP %d)" % code
		return
	var parsed := JSON.new()
	if parsed.parse(body.get_string_from_utf8()) != OK or not parsed.data is Dictionary:
		$Status.text = "サーバー応答がJSONオブジェクトではありません"
		return
	var response: Dictionary = parsed.data
	if EditorInterface.is_playing_scene():
		$Status.text = "実行が始まったため、取得結果を保存しませんでした"
		return
	var project_id := OS.get_environment("GMORN_SAVE_SAVER_PROJECT_ID")
	if project_id.is_empty() and ProjectSettings.has_setting("gmorn_save_saver/project_id"):
		project_id = String(ProjectSettings.get_setting("gmorn_save_saver/project_id"))
	if String(response.get("project_id", "")) != project_id or not response.get("data", null) is Dictionary:
		$Status.text = "別プロジェクトのデータ、または不正なセーブです"
		return
	if String(response.get("save_id", "")) != $SaveId.text.strip_edges():
		$Status.text = "取得したSave IDが要求と一致しません"
		return
	var store := _open_store(save_path)
	if not store.save(response.data):
		$Status.text = "プレビュー保存に失敗しました"
		return
	var marker := _open_store("user://gmorn_save_saver_preview_request.json")
	if not marker.save({"path": save_path}):
		$Status.text = "次回プレビューの指定に失敗しました"
		return
	$Status.text = "取得しました。次にEditorから実行するとこのセーブを使います"

func _open_store(path: String) -> RefCounted:
	var store: RefCounted = STORE.new()
	store.path = path
	return store
