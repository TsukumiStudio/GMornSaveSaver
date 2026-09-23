# GMornSaveSaver

## 概要

GMornSaveへ保存したJSONをサーバーへバックアップし、EditorからSave IDで別のセーブをプレビュー起動できます。通常の保存データは置き換えません。

## 動作環境

- Godot 4.7+
- [GMornSave](https://github.com/TsukumiStudio/GMornSave) を隣接アドオンとして導入
- `GMornSaveSaver` のサーバーAPI

## 機能

- ローカル保存と独立した `.cloud.json` サイドカーへ資格情報と最新の保留データを保存
- 起動後の `resume()` で中断した送信を再開
- HTTP失敗時は保留データを保持して再試行
- EditorドックからSave IDで取得し、次のEditor実行だけ別ファイルを読み込む
- エディタープラグイン処理・headlessからの送信は明示的な環境変数opt-inがない限り停止（Editorのゲーム実行は通常送信）

## 使い方

1. このリポジトリを `addons/gmorn_save_saver` に追加し、GMornSaveも `addons/gmorn_save` に追加します。プロジェクト設定のプラグインから `GMornSaveSaver` を有効にしてください。
2. プロジェクト設定に `gmorn_save_saver/endpoint` と `gmorn_save_saver/project_id` を設定します。サーバーURLやproject_idは環境変数 `GMORN_SAVE_SAVER_ENDPOINT` / `GMORN_SAVE_SAVER_PROJECT_ID` でも指定できます。秘密値は設定へ置かないでください。
3. 保存が成功した後、現在のDictionaryと通常保存パスを渡します。通常保存処理を待たせません。

```gdscript
GMornSaveSaver.submit(game_data, save_path)
GMornSaveSaver.resume(save_path) # 起動時、通常保存をロードした後に呼ぶ
```

4. Editorから別ユーザーのセーブを試すには、Editorを停止した状態でGMornSaveSaverドックへSave IDを入れます。`GMORN_SAVE_SAVER_ADMIN_TOKEN` をEditorの環境変数に設定するか、ドックのAdmin token欄へ一時入力し、「別ユーザーのセーブを取得」を押します。入力値はEditorメモリ内だけに置きます。project_idが一致する辞書データだけを `gmorn_save_saver/preview_path` （既定 `user://gmorn_save_saver_preview.json`）へ保存します。
5. ゲーム起動時、保存を読む前に `var preview_path = GMornSaveSaver.consume_preview()` を呼び、空でなければゲーム側の保存パスをその値に切り替えます。プレビュー中は送信を止めます。マーカーはEditorからの通常実行に限って一度だけ消費されます。

送信のopt-in環境変数はEditorプラグイン中に限り `GMORN_SAVE_SAVER_EDITOR_OPT_IN=1`、headless中に限り `GMORN_SAVE_SAVER_TEST_OPT_IN=1` です。headlessでプレビュー消費テストを行う場合だけ `GMORN_SAVE_SAVER_TEST_PREVIEW=1` を指定します。`GMORN_SAVE_SAVER_LIVE_TEST=1` を付けて `verify.sh` を実行すると、設定済みのendpoint・project_id・admin tokenへ実際の登録、二段階アップロード、取得を行います。

## ライセンス

Unlicense（パブリックドメイン）。
