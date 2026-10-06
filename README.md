# GMornSaveSaver（統合済み）

このアドオンは 2026-10-07 に [GMornSave](https://github.com/TsukumiStudio/GMornSave) へ統合した。クラウド保存の送信とEditorでの取り寄せは、GMornSave の `GMornSaveCloud` が引き継いでいる。サーバーは [GMornSaveServer](https://github.com/TsukumiStudio/GMornSaveServer)（旧 MornSaveSaver）。

移り方は GMornSave の README の「クラウド保存（GMornSaveCloud）」を参照。設定名は `gmorn_save_saver/*` から `gmorn_save_cloud/*`、環境変数は `GMORN_SAVE_SAVER_*` から `GMORN_SAVE_CLOUD_*` へ変わった。サイドカー `*.cloud.json` の形は同じなので、登録済みの利用者はそのまま送れる。

このリポジトリは更新しない。
