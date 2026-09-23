@tool
extends VBoxContainer

const STORE := preload("../gmorn_save/gmorn_save_store.gd")
var save_path := "user://gmorn_save_saver_preview.json"
var request: HTTPRequest

func _ready() -> void:
	$Fetch.pressed.connect(_fetch)
	$AdminToken.text = OS.get_environment("GMORN_SAVE_SAVER_ADMIN_TOKEN")
	request = HTTPRequest.new()
	request.timeout = 30.0
	request.body_size_limit = 300 * 1024
	add_child(request)
	request.request_completed.connect(_completed)

func _process(_delta: float) -> void:
	var running := EditorInterface.is_playing_scene()
	$Fetch.disabled = running or request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED
	if running:
		$Status.text = "実行中は取得できません。ゲームを停止してください"

func _fetch() -> void:
	if EditorInterface.is_playing_scene():
		return
	var save_id := $SaveId.text.strip_edges()
	var token := $AdminToken.text
	var endpoint := OS.get_environment("GMORN_SAVE_SAVER_ENDPOINT")
	if endpoint.is_empty() and ProjectSettings.has_setting("gmorn_save_saver/endpoint"):
		endpoint = String(ProjectSettings.get_setting("gmorn_save_saver/endpoint"))
	endpoint = endpoint.trim_suffix("/")
	if save_id.is_empty() or token.is_empty() or endpoint.is_empty():
		$Status.text = "Save ID、endpoint、GMORN_SAVE_SAVER_ADMIN_TOKENを確認してください"
		return
	var err := request.request(endpoint + "/v1/admin/saves/" + save_id.uri_encode(), ["Authorization: Bearer " + token], HTTPClient.METHOD_GET)
	if err != OK:
		$Status.text = "取得要求を開始できません: " + error_string(err)
	else:
		$Status.text = "取得中…"

func _completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		$Status.text = "取得に失敗しました (HTTP %d)" % code
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
