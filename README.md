# PachiAlarm(仮称) — Phase 0 検証アプリ

パチンコ演出アラームを作るための **技術検証専用アプリ** です。
AlarmKit(iOS 26以降)が、無料Apple ID・iOS 27.2の実機でどこまで動くかを確かめます。

made by hiro / ヒロ — https://github.com/h1ro223

---

## 検証すること(優先順)

| # | 項目 | 確認方法 |
|---|---|---|
| 1 | 無料Apple IDで実機にインストールできるか | 起動してAlarmKitの許可ダイアログが出るか |
| 2 | ロック画面でアラームが鳴るか | 「1分後」で登録 → 画面ロック → 待つ |
| 3 | カスタム音が鳴るか | 同梱wav/mp3/caf・取り込んだmp3と変換版 を順に試す |
| 4 | 停止ボタンで stopIntent が呼ばれるか | ログに `★stopIntent 呼び出し` が出るか |
| 5 | 停止後に大当たりBGMがロック中のまま鳴るか | ログに `play()=true`、15秒ごとの `再生中` が最後まで続くか |
| 6 | 「開く」ボタンでアプリが起動するか | 副ボタン「開く」で登録 → バナー表示とログ |

結果は `docs/phase0-results.md` に記入してください。

---

## 必要なもの

- Windows 11 / VS Code
- GitHubアカウント(公開リポジトリ)
- iPhone(iOS 26以降。今回は27.2)とUSBケーブル
- Apple ID(無料でOK。**検証専用の別Apple IDを作るのがおすすめ**)
- Windowsにインストールするもの
  - **iTunes**(Microsoft Store版ではなく、Appleサイトのダウンロード版)
  - **iCloud**(同上)
  - **Sideloadly**(https://sideloadly.io)

---

## 手順1:GitHubにアップロードしてビルド

1. GitHubで公開リポジトリ `PachiAlarm` を作成
2. このフォルダの中身をすべてpushする
   - **`.github` フォルダを必ず含める**(ブラウザのドラッグ&ドロップだと抜けることがあるので、GitHub Desktop か git 推奨)
   - `PachiAlarm.xcodeproj` は不要(Actions上で自動生成します)
3. GitHubの **Actions** タブ → 「Build unsigned IPA」が自動で動く(5〜10分)
   - 動かない場合は「Run workflow」ボタンで手動実行
4. 成功(緑のチェック)したら、実行結果ページ下部の **Artifacts** から
   `PachiAlarm-unsigned-ipa` をダウンロード → zipを展開すると `PachiAlarm-unsigned.ipa`
5. 失敗(赤)したら、`build-log` をダウンロードしてClaudeに渡してください

> Macで一度もビルドしていないため、**最初のビルドでコンパイルエラーが出る可能性があります**。
> その場合はエラーログを渡してもらえれば修正します。

### Xcodeのバージョンを変えたい時
Actions → Build unsigned IPA → Run workflow → `xcode_path` に
`/Applications/Xcode_26.4.1.app` のように入力(ログの「インストール済みXcode」に一覧が出ます)。

---

## 手順2:Sideloadlyで署名してiPhoneに入れる

1. iPhoneをUSBで接続し、iPhone側で「このコンピュータを信頼」
2. Sideloadlyを起動
3. `PachiAlarm-unsigned.ipa` をSideloadlyにドラッグ
4. Apple IDを入力して **Start**
   - 2ファクタ認証のコードを求められたら入力
5. iPhone側で:
   - **設定 → プライバシーとセキュリティ → デベロッパモード → オン**(再起動あり)
   - **設定 → 一般 → VPNとデバイス管理 → 自分のApple ID → 信頼**
6. PachiAlarmを起動 → 「アラームの使用を許可する」→ 許可

### 無料Apple IDの制限(重要)
- **7日で期限切れ**。期限が切れたらアプリが起動できなくなります
  → 同じIPA・同じApple IDでSideloadlyから再インストール(アプリを削除しないこと。データが残ります)
- 同時に入れられる自作アプリは **3個まで**
- App IDは **7日で10個まで**(このアプリは拡張機能なしの1個だけ使います)
- **期限切れ後に登録済みアラームが鳴るかは不明** → Phase 0で確認します

---

## 手順3:検証のやり方

### 基本(項目2・4・5)
1. アラーム音「システム標準」、副ボタン「スヌーズ」、「1分後」で登録
2. **画面をロックして**待つ
3. 鳴ったら **停止** を押す(ロックは解除しない)
4. 大当たりBGM(同梱ダミー30秒)が鳴るか確認
5. アプリを開いて「検証ログ」→「更新」

期待するログの例:
```
[ALARM] xxxxxxxx scheduled → alerting → 鳴動開始
[STOP] ★stopIntent 呼び出し id=xxxxxxxx アプリ状態=バックグラウンド 端末=ロック中
[AUDIO] セッション開始OK(通常)
[BGM] play()=true ...
[BGM] 再生中 15/30秒 playing=true
[BGM] 再生完了 successfully=true
```

### 音声(項目3)
- 本物の **20秒mp3** は「アラーム音を取り込む」から入れる
  → `u_ファイル名.mp3` と `u_ファイル名_pcm.caf` の2つができる。両方で試す
- 本物の **1分52秒mp3** は「BGMを取り込む」から入れる
- 鳴った長さ(1回で終わるか、ループするか、20秒後に無音のまま画面が残るか)をメモ

### 停止の経路(項目4)
次の方法で止めた時に `★stopIntent` がログに出るか、それぞれ確認:
- ロック中に停止ボタン
- ロック中に電源ボタン
- ロック解除して使用中にバナーの停止ボタン
- ロック解除して使用中にバナーを上にスワイプ

### スヌーズ
- スヌーズを押した時は `→ スヌーズされた` が出て、**`★stopIntent` は出ない** のが正しい動き

### 「開く」(項目6)
- 副ボタン「開く」で登録 → 鳴ったら「開く」→ アプリが開いてバナーが出るか

### 追加で見ておきたい条件
- アプリを上スワイプで終了した状態で鳴るか
- iPhone再起動後に鳴るか
- 消音モード・集中モードで鳴るか
- 時計アプリのアラームと同じ時刻にした時

---

## ファイル構成

```
PachiAlarm/
├── project.yml                      XcodeGen設定
├── .github/workflows/build-ios.yml  未署名IPAのビルド
├── ios/Info.plist
├── ios/PachiAlarm/
│   ├── App/PachiAlarmApp.swift      起動
│   ├── App/ContentView.swift        検証パネル(画面)
│   ├── Alarm/AlarmService.swift     AlarmKit 登録・取消・状態監視
│   ├── Alarm/AlarmIntents.swift     停止Intent / 開くIntent
│   ├── Audio/JackpotPlayer.swift    大当たりBGM再生
│   ├── Audio/SoundLibrary.swift     音声の取り込み・変換・一覧
│   ├── Support/DebugLog.swift       検証ログ
│   ├── Support/SettingsStore.swift  設定保存(壊れても起動できる)
│   └── Resources/Sounds/            検証用ダミー音(自作のビープ音)
└── docs/phase0-results.md           検証結果の記入表
```

## 注意
- 著作権のある本物の音源・映像は **リポジトリに入れないでください**(アプリ内で取り込みます)。
  パチンコ機種の素材を使う段階になったら、アプリ内に非公式ファンメイドの表記を追加します。
- 端末のシステム音量・アラーム音量はアプリから変更しません(Appleが公開APIを用意していないため)。
- 外部ツール: ビルド時のみ **XcodeGen**(Actions上でHomebrewからインストール)を使用。アプリ本体に外部ライブラリはありません。
