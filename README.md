# Universal I//O

> **2026-07-02**: 製品は **Universal I/O (I//O)** へ方針転換した。ビジョン・アーキテクチャ・
> 実装マイルストーンの正本は [docs/universal-io-master-plan.md](docs/universal-io-master-plan.md)。
> 以下はその土台となる現行実装（Bomb Squad 世代）の仕様。
>
> **2026-07-13**: macOS アプリの基盤作り直し（シャーシ交換）は新中枢へ切替済み。正本は
> [docs/foundation-rebuild-plan.md](docs/foundation-rebuild-plan.md)。経緯: ビッグバン
> リファクタリング（R0〜R4）が失敗 → 安定版へ巻き戻し → 中枢のみ新規実装・
> 実証済みサービスを移植 → `AppMode` / `SessionCoordinator` / モード別 Session へ切替。
> Gateway（web/）と本番 DB は
> リファクタリング後の世代（plan catalog / admin console）が本番稼働中で、作り直し対象外。
>
> 📚 **ドキュメントの入口は [docs/README.md](docs/README.md)**（全ドキュメントの索引と
> 正本/アーカイブの区別、ドキュメント管理ルール）。ここに載っていない doc は存在しない。

メール・Slack などのコミュニケーションで、送る前に「ちょっと待って」と一拍おくためのアプリ。会話のサンドボックス。受信したメッセージにも適用できるフィルター。macOS ネイティブアプリ版。

実際の入力フォーム／受信画面の **手前に擬似的な中間レイヤー（ステージング）を物理的に挟み**、
AI レビューを通してから本番（ライブ）へ「デプロイ」する。システム開発の
「ステージングで確認してから本番投下」を、人間のコミュニケーションに持ち込む発想。

最終的には双方向（送信レビュー／受信翻訳）で、認知モデル・能力・発達特性・精神状態の
ギャップを越えてコミュニケーションするための共通レイヤーを目指す。

## 現在のスコープ（MVP）

**送信側レビュー + Vision 読解支援の初期版**。**メニューバー常駐アプリ**（起動時はウィンドウなし／Dock アイコンなし）。

macOS の画面構成方針:
- 普段はメニューバーに常駐し、常設の大きな管理ウィンドウは出しっぱなしにしない。
- 右Shift 2回で出る入力補助は、軽い一時パネルとして扱う。
- アカウント、設定、履歴、料金プランは、メニューバーから必要な時だけ開く通常ウィンドウに分ける。一時パネル内には管理画面への動線を置かない。
- 入力補助のたびに管理ウィンドウへ勝手にフォーカスを移さない。
- Google 認証やメールリンク認証の途中だけは、ブラウザやメールへ移動してもログイン画面を閉じない。

操作（ジェスチャキー中心で完結。既定=右Shift、**設定 → キーボードで変更可能**）:
- **ジェスチャキー 2回タップ = 起動 / レビュー / ビジョン / 閉じる**: パネルが閉じていれば呼び出し。開いている時は**原文欄にフォーカスがある場合だけ**レビューを実行。原文が空ならビジョン入力（スクリーンショット撮影）へ移る。ビジョン表示中なら閉じる。レビュー結果欄では何もしない。
- **ジェスチャキー 1回タップ = フォーカス切替**: 原文欄とレビュー結果欄を行き来する。
- **ジェスチャキー 長押し = 喋る（ASR）**: 押している間だけ録音し、離すと Groq `whisper-large-v3` で文字起こしして原文欄に挿入（hold-to-talk）。
- **Enter = 送信**: カーソルがある側を直接送信（原文欄なら原文、レビュー欄ならレビュー結果）。Shift+Enter は改行。

> 喋る・レビューを ⌘ から **右Shift に統一**したのは、⌘ が日常のショートカット（⌘C/⌘V 等）と衝突し、保持した瞬間に誤発火していたため。右Shift は単独で握ることが稀で、覚えやすいよう両ジェスチャを同じキーに揃えた。ジェスチャキーは**設定 → キーボード**で右/左の Shift・Option・Control・⌘、fn（🌐）へ変更でき、2回タップ間隔・長押し判定時間も調整できる（[`KeybindingSettings`](BombSquad/Models/KeybindingSettings.swift)、UserDefaults 永続化）。

> かつて存在した「⌘J で単純にパネル開閉」する重複ホットキーは、右Shift2回（選択テキストの有無で送信/受信を自動分岐する上位版）と機能が被り混乱の元だったため撤去した。パネルはジェスチャキー、またはメニューバーの「パネルを表示」から開く。

フロー（M3-C で Spotlight 型の縦1カラム・3状態 = 空→原文→結果 に刷新）:
1. 任意のアプリのフォームにフォーカス → **右Shift2回** でパネルが画面中央に出現（入力欄に自動フォーカス）
2. 入力（手入力／ペースト／**右Shift長押しで音声**）。空の状態では下部に折りたたまれた**入力履歴（最大5件）**が出て、展開して選ぶと原文欄へ文面が入る（即送信はしない）。モデル・出力言語の選択は設定（管理ウィンドウ）へ移動済み
3. レビュー未開始時は入力面だけを表示。「レビュー」を実行して初めてレビュー面を開き、①誤字脱字 ②失礼・攻撃的 ③分かりにくさ の3観点を評価する（結果右上に使用モデルと処理時間 ms）。クラウド経由（I//O Cloud）の場合、修正文は**トークン単位でストリーミング表示**される。レビューは参考表示であり、完了してもフォーカスと Enter の採用対象は**原文のまま**。レビュー結果を使う場合だけ、ジェスチャキー1回または結果欄のクリックで明示的に切り替える
4. 送信:
   - **原文側の「送信」（紙飛行機）** = レビューを使わず原文のまま
   - **結果側の「送信」（紙飛行機）** = レビュー結果（編集可）
   - いずれも**呼び出し元のフィールドへ自動入力（⌘V 合成）**。Gmail・Slack・Mail・Notion など汎用に動く。

> 自動送信はしない。最終判断は常に人間が行う。メニューバーアイコンから設定・終了。

### Vision（画面を見せる → ナビゲーター）

空の原文欄で **右Shift2回** すると、テキスト入力を閉じる代わりに Vision モードへ入る。

- 右Shift2回で**選択オーバーレイ**が開き、**最初から全画面（カーソルのあるディスプレイ）が
  選択された状態**になる。**Enter でそのまま全画面を確定**（ScreenCaptureKit。モデルはユーザーが
  見ているものをそのまま見る）、**ドラッグすれば従来どおり範囲選択**。esc でパネルへ戻り、
  **右Shift2回ならセッションごと破棄して待機モード**（パネルが出る前の状態）へ。
  ScreenCaptureKit が失敗した場合のみ `screencapture -i` にフォールバックする。
- **キャプチャ後の分岐（正: [`VisionSession.startInitialFlowIfNeeded`](BombSquad/Core/VisionSession.swift)）**:
  - **画面ナビゲーターが利用可（ログイン済み＋設定 ON）= 既定**: そのまま**ナビゲーター
    セッション**が始まる。初回は**軽い現状認識のみ**（auto first turn、設定で OFF 可）を返し、
    以降は質問チャット（マルチターン SSE）で「どこを押すか」を案内。対象 UI は OCR grounding で
    **パネル内スクショの赤枠＋実画面のライブハイライト**として示される。案内がタスクプランに
    なったら**承認してコパイロット**（右下コーナーストリップ）へ移行し、実画面のクリックを
    追跡しながらステップごとに案内する。**正本は
    [docs/copilot-challenge-3.md](docs/copilot-challenge-3.md)**（2026-07-15 に
    ワンコール・アーキテクチャへピボット。UX仕様は同書 §7.1）。
  - **ナビゲーター利用不可（未ログイン等）のフォールバック**: 一回きりのフル解釈
    「状況 → 求められていること → 提案アクション（最大3件、文案付きは
    『承認して送信』＝⌘V 注入／『編集する』＝原文エディタへ引き継ぎ）→ 読み取った内容」を表示。
    文案生成には L1 コンテクストと Persona / Relationship カードを注入する。
- スクリーンショットは一時ディレクトリにのみ保存され、プレビュー左上の保存ボタンで
  明示的に保存した時だけユーザーの選んだ場所に書き出される（デスクトップに自動保存しない）。
- Vision 表示中に **右Shift2回** すると閉じる。

> 経緯: M4（2026-07-03）で「スクショ→OCR→コピー」を「見る→わかる→返す」のフル解釈に再定義し、
> その後 Navigator v3（2026-07-06〜07）で**キャプチャ直後の既定挙動はナビゲーターに置き換わった**。
> フル解釈はフォールバックとしてのみ残る。古い資料に「キャプチャ後は常にフル解釈」とあれば
> それは M4 世代の記述。

### 受信側（読解支援）— 送信側の鏡像

同じインターフェースを、相手から届いたメッセージの「読みやすく整理」に使う。コミュニケーションの
中間レイヤーは本来双方向で、不快・難解な受信文もこのレイヤーを通すことで安全に読み取れる。
発達特性・言語・能力面で読み取りに課題がある人の社会適応を支える、というアプリの主目的の受信側。

- **取り込み**: 任意のアプリ（Slack・Gmail 等）で相手のメッセージを**マウスで選択（反転）**した状態で
  **右Shift2回**。選択テキストが ⌘C 合成（[`SelectionGrabber`](BombSquad/Services/SelectionGrabber.swift)）で
  原文ペインに入る。**選択が無ければ**従来どおり空の原文ペイン（送信モード）になる＝1ジェスチャで自動分岐。
- **変換（M4-B で Vision と統合）**: 受信メッセージは Vision と同じ「わかる→返す」スキーマで解釈され、
  **状況 → 求められていること → 提案アクション（返信文案）→ 整理した内容**（攻撃性・感情・皮肉を除いた
  中立版）が右側に表示される（Gateway `/api/ai/vision` の `input.text`）。
- **出口**: 相手のメッセージは絶対に書き戻さない。「コピー」も提案アクションの「承認してコピー」も
  **クリップボードへコピーのみ**（[`ClipboardDeployer`](BombSquad/Services/Deployer.swift)）。
  引用・転送・保存・返信の下書きに使える。

> 入力と出力で**システム調整や行動変容を求めず**、中間地点を加工するだけで結果を変えるのが本アプリの肝。
> 送信も受信も「選択 or 入力 → 加工 → そのまま使える」という同じ操作で成立する。当面は UI も共通
> （`ReviewMode.compose` / `.transform` で分岐）。将来は受信専用 UI に分ける余地あり。

> **受信はワンストップ**: 選択して右Shift2回でパネルが立ち上がると同時に変換が走り、右ペインに整理済みが
> 出る（第2のジェスチャ不要）。処理中は右ペインにスピナーを表示。

### 出力言語

成果物（`revised_text` = 送る文／読みやすくした文）の言語を、**設定（管理ウィンドウ）で選択**する
（[`OutputLanguage`](BombSquad/Models/OutputLanguage.swift)、既定=日本語。現状は日本語／English。
UserDefaults に永続化され、次にパネルを開いた時から反映）。
プロンプトに明示注入するので、**入力が何語でも `revised_text` は選択言語**になる
（例: 日本語で書いて英語で送る／中国語をスキャンして日本語で読む）。
`issues` の説明・`summary` はユーザー向けメタなので日本語のまま。

> M3-C でパネルのプルダウンを撤去し設定へ移動（永続化により「パネルを開くたび日本語に戻る」も解消）。
> 受信時の自動言語判定などは引き続き検討。

### 必要な権限
- **アクセシビリティ**: フィールド自動入力（⌘V 合成）と右Shiftジェスチャ検出に必要。
- **マイク**: 右Shift長押しの音声入力に必要。
- **画面収録**: Vision 用スクリーンショットの撮影に必要。
（いずれもシステム設定 → プライバシーとセキュリティ で Bomb Squad を許可。未許可でもテキストはクリップボードに残り手動 ⌘V 可。）

## 技術スタック

- Swift / SwiftUI（macOS 14+）。**メニューバー常駐（`NSApp.setActivationPolicy(.accessory)` + `MenuBarExtra`）**、起動時ウィンドウなし。
- **中枢**: [`AppMode`](BombSquad/Core/AppMode.swift) が唯一の状態機械、
  [`SessionCoordinator`](BombSquad/Core/SessionCoordinator.swift) がジェスチャとセッション遷移、
  [`PanelController`](BombSquad/Core/PanelController.swift) がパネル形状と配置を所有。Compose / Transform / Vision・Navigator・Copilot は
  それぞれ専用 Session に分離され、`AppDelegate` はプロセス起動と入力配線のみを担当する。
- レビュー: OpenAI／Groq は OpenAI 互換 Chat Completions を [`OpenAICompatibleClient`](BombSquad/Services/OpenAICompatibleClient.swift) で共用、Anthropic は [`ClaudeClient`](BombSquad/Services/ClaudeClient.swift)。構造化出力は OpenAI=json_schema strict／Groq=json_object／Claude=Tool Use。`ReviewProvider` で抽象化。
- **音声入力（ASR）**: [`AudioRecorder`](BombSquad/Services/AudioRecorder.swift)（AVAudioRecorder, 16kHz mono m4a）＋ [`GroqTranscriber`](BombSquad/Services/GroqTranscriber.swift)（Groq `whisper-large-v3`, multipart）。右Shift 長押しで録音→離すと文字起こしして draft に挿入。
- **ジェスチャ**: [`ModifierGestureMonitor`](BombSquad/Services/ModifierGestureMonitor.swift) が設定されたジェスチャキー（既定=右Shift）の 1回タップ（=左右フォーカス切替）、2回タップ（=起動 / レビュー / Vision / 閉じる）、長押し（=音声）を判定する。キーコードは設定値を**イベントごとに参照**するため、キー変更はモニタ再登録なしで即反映される（割り当ては [`KeybindingSettings`](BombSquad/Models/KeybindingSettings.swift)、UI は [`KeyboardSettingsView`](BombSquad/Views/Management/KeyboardSettingsView.swift)）。
- **Vision / スクリーンショット**: [`ScreenshotSelectionOverlay`](BombSquad/Views/ScreenshotSelectionOverlay.swift) で全画面または範囲を選び、
  [`ScreenshotCaptureService`](BombSquad/Services/ScreenshotCaptureService.swift) が ScreenCaptureKit で撮影する。失敗時のみ `screencapture -i` へフォールバック。
  [`VisionSession`](BombSquad/Core/VisionSession.swift) が Navigator優先／one-shot Visionフォールバック、ハイライト、Copilot進行を所有する。
- **注入**: [`PasteDeployer`](BombSquad/Services/PasteDeployer.swift) がクリップボード＋⌘V 合成で元フィールドへ。`Deployer` で抽象化（将来 Accessibility 注入に差し替え可）。
- **クリップボード退避・復元（暫定）**: 送信の ⌘V（[`PasteDeployer`](BombSquad/Services/PasteDeployer.swift)）と受信取り込みの ⌘C（[`SelectionGrabber`](BombSquad/Services/SelectionGrabber.swift)）はシステムのクリップボードを一時的に借りる。ユーザーが元々コピーしていた内容を壊さないよう、操作の直前に全アイテム・全タイプを退避し、合成ペースト／コピーが処理された後に復元する（[`ClipboardBackup`](BombSquad/Services/Deployer.swift)）。これは TextExpander・Alfred・Raycast・Espanso 等の入力支援ツールで確立した定番パターン。ただし退避・復元も合成ペースト／コピーも遅延ベースのため原理的に 100% 完全ではない（重いアプリでの取りこぼし、一部アプリ独自形式、他のクリップボード管理ツールとの併用など）。**本筋はロードマップの「Accessibility API で実フォームへ直接注入」**で、それが入ればクリップボードを一切触らなくなりこの仕組みは不要になる。なお受信モードの出口（[`ClipboardDeployer`](BombSquad/Services/Deployer.swift)）は「クリップボードへコピー」自体が機能のため復元しない。
- **履歴**: ローカル履歴は SQLite（`~/Library/Application Support/BombSquad/history.sqlite`）に保存。既定 ON、最新100件まで。設定から OFF にできる。履歴一覧は最終的に注入した文章だけを表示する。
- 効果音: マイク ON/OFF の cue は `AVAudioPlayer` で `/System/Library/Sounds/Morse.aiff` / `Bottle.aiff` を再生。
- API キーは vendor 別に Keychain に保存（リポジトリには含めない）。署名は Apple Development 証明書で固定（Keychain の「常に許可」がリビルド後も持続）。
- プロジェクトは [XcodeGen](https://github.com/yonaskolb/XcodeGen) で生成。マイク権限は `INFOPLIST_KEY_NSMicrophoneUsageDescription`。

## モデルとエンジン

**本番経路は I//O Cloud（Gateway 経由）**。モデルの選択・ルーティングはサーバー側
（`web/lib/server/*-engine.ts`）が持ち、**クライアントにモデル選択 UI は無い**
（M3-C でパネルのプルダウンを撤去済み）。使用エンジン名と処理時間（ms）は
レビュー結果の右上に表示される。

**BYOK（自分の API キーを Keychain に登録して直叩き）は開発者向けフォールバック**に
格下げ済み — Gateway 未設定または未ログインの時だけ使われる。BYOK 用のモデルカタログは
[`ReviewModel.catalog`](BombSquad/Models/AIProvider.swift) が正本。
モデルごとの速度・品質の知見（gpt-oss-120b は意味理解可 / 20b は整形専用等）は
本ファイル末尾の「これまでの経緯」を参照。

## セットアップ

```bash
# プロジェクトを生成
xcodegen generate

# Xcode で開く
open BombSquad.xcodeproj

# もしくは CLI でビルド
xcodebuild -project BombSquad.xcodeproj -scheme BombSquad -configuration Debug \
  -derivedDataPath /tmp/universal-io-build CODE_SIGNING_ALLOWED=NO build

# unit testを含む未署名コンパイル検証（秘密鍵を使わない）
xcodebuild build-for-testing -project BombSquad.xcodeproj -scheme BombSquad \
  -configuration Debug -derivedDataPath /tmp/universal-io-tests CODE_SIGNING_ALLOWED=NO
```

ローカル認証設定（Supabase URL / anon key）は、リポジトリ直下の
`BombSquad.local.plist` から読み込む。読み取り順は `BombSquad.local.plist` →
Xcode Scheme の環境変数 → `Info.plist`。

Gateway の向き先は Info.plist の `https://api.universal-io.com` が唯一の既定値。
**通常起動はDebug・Releaseとも常に本番**を使い、`BombSquad.local.plist`や環境変数にlocalhost URLが
残っていても無視する。plistの空欄化・コメントアウト・復元作業は不要。

ローカルGatewayをテストする場合だけ、Xcodeで専用の**`BombSquad Local Gateway` Scheme**を選ぶ。
このSchemeだけがDebugプロセスへ`BOMB_SQUAD_GATEWAY_MODE=local`を設定する。この時のURLは環境変数
`BOMB_SQUAD_API_BASE_URL`、なければ`BombSquad.local.plist`から読む。localモードは本番へ
自動fallbackしないため、ローカル停止・設定不足はその場で失敗し、テストリクエストが本番へ流れない。
Releaseはmode指定も開発URLも常に無視する。

エンドポイント構築は base URL の `/api` 有無を吸収する
（[`GatewayAPI.endpoint`](BombSquad/Services/GatewayAPI.swift)）。

> 専用`BombSquad Local Gateway` Schemeの間だけ、パネル上部にオレンジの警告バー
> （現在の向き先URL付き）が出る
> （[`BombSquadConfig.isUsingOverriddenGateway`](BombSquad/Services/BombSquadConfig.swift)）。
> 通常のDebugとReleaseでは警告バーもローカル経路も存在しない。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>BOMB_SQUAD_SUPABASE_URL</key>
  <string>https://skcsbcyivjcvevxntvqa.supabase.co</string>
  <key>BOMB_SQUAD_SUPABASE_ANON_KEY</key>
  <string>YOUR_SUPABASE_ANON_KEY</string>
  <key>BOMB_SQUAD_API_BASE_URL</key>
  <string>http://localhost:3000</string>
</dict>
</plist>
```

初回起動後は**ログインするだけで使える**（I//O Cloud = Gateway 経由が本番経路。
API キー登録は不要）。設定での API キー登録は、Gateway を使わない開発者向け
BYOK フォールバックの場合のみ必要。

認証方式:
- Google 認証
- メールリンク認証

メール認証はコード入力ではなく、メール本文のリンクをこの Mac で開く方式。

### 現在の認証仕様

Bomb Squad のログイン方法は、現時点では次の 2 つだけ。

- Google OAuth
- メールリンク認証

ここでいう「メールリンク認証」は、メールアドレス宛てに届くリンクを開いて
ログインを完了する方式。アプリ内で認証コードを入力する方式ではない。

Supabase SDK ではメールリンク送信にも `signInWithOTP(...)` という API 名を使うが、
これは SDK 名称の都合であって、Bomb Squad のユーザー体験が OTP 入力であることを
意味しない。実際の挙動は、Supabase 側のメールテンプレートで
`{{ .ConfirmationURL }}` を使っているか `{{ .Token }}` を使っているかで決まる。

Bomb Squad では Web も macOS も `{{ .ConfirmationURL }}` 前提で揃える。

## 配布（ベータ）

App Store を通さず、公証済み DMG を Web から直接配布する。2026-07-04 に一連の経路が
完成し、「製品サイトのボタン → ダウンロード → 起動 → ログイン → 使える」を実機確認済み。

- **署名分岐**（[`project.yml`](project.yml) の `configs`）: Debug は `Apple Development`
  ＋チーム `TG68TFXG88`（このMacにある唯一の開発証明書。CN の「(48P276DZDB)」は証明書識別子で
  チームIDではない — 実チームは OU=TG68TFXG88）、Release は Developer ID Application
  （有料チーム `TG68TFXG88`）で署名し Hardened Runtime を有効化。マイク用 entitlement は
  [`BombSquad/BombSquad.entitlements`](BombSquad/BombSquad.entitlements)。
  **Debug を ad-hoc 署名にしてはいけない**: ad-hoc はビルドごとに CDHash が変わり、
  TCC 許可（画面収録・アクセシビリティ・マイク）と Keychain の「常に許可」がリビルドの
  たびに無効化される（設定画面ではオンに見えるのに実際は許可されない）。
  Apple の2チームの使い分けは `~/AGENTS.md` の「Apple Developer Accounts」に記録。
- **1コマンドリリース**: [`tools/release.sh`](tools/release.sh) が
  build → sign → notarize → staple → DMG → R2 アップロードまで実行する。

  ```bash
  bash tools/release.sh                   # フル（公証 + R2 アップロード）
  SKIP_NOTARIZE=1 bash tools/release.sh   # 署名構成の検証のみ（Apple 往復なし）
  ```

- **公証**: 初回のみ notarytool の資格情報をキーチェーンに保存する（app用パスワード方式、
  profile 名 `universal-io-notary`）。

  ```bash
  xcrun notarytool store-credentials universal-io-notary \
    --apple-id <apple-id> --team-id TG68TFXG88 --password <app-specific-password>
  ```

- **配布先**: Cloudflare R2 バケット `universal-io-downloads` → カスタムドメイン
  `dl.universal-io.com`。R2 の認証は aws CLI プロファイル `r2`、エンドポイント／バケット名は
  gitignore された `tools/release.env`。DMG はバージョン付き（`Universal-IO-<version>.dmg`）と
  固定名 `Universal-IO.dmg`（latest）の2つを置く。
- **ダウンロード導線**: 製品サイト（別リポジトリ `web-product`）のヒーロー主ボタンが
  `https://dl.universal-io.com/Universal-IO.dmg` を指す。latest 固定名なので、バージョンを
  上げてもボタンのリンクは不変（release.sh が毎回 latest を上書きする）。
- **配布ビルドの向き先**: Releaseコードは `BombSquad.local.plist` と環境変数の Gateway 値を
  構造的に無視し、Info.plist の本番 `https://api.universal-io.com` だけを使う。release.sh は
  gitignoreされたplistを変更・復元しない。

## Known issues（凍結中の残タスク）

### アプリ名リネーム完了

アプリ名・プロジェクト名・ターゲット名・Bundle ID は `Bomb Squad` / `BombSquad` /
`com.heywatchme.bombsquad` に統一済み。Bundle ID と Keychain service が変わったため、
リネーム後の初回起動ではアクセシビリティ／マイク権限の再許可と API キーの再登録が必要。

## ロードマップ（MVP の先）

- グローバルホットキー＋前面オーバーレイ（押している間だけ擬似入力欄）
- Accessibility API で実フォームへテキスト自動注入（`Deployer` 実装の差し替え）
- 視覚入力の強化（OCR / ScreenCaptureKit / 選択不要の画面理解）
- ローカル LLM 対応（`ReviewProvider` 実装の差し替え）

## これまでの経緯（覚書）

- **コンセプト**: 送受信の「物理的な中間ステージング層」。送信は下書きをレビューしてからデプロイ、
  受信は攻撃的メッセージを要件だけに翻訳。認知モデルのギャップを埋める共通レイヤー。
- **MVP は送信側レビューから**着手（独立ウィンドウ、ホットキー/注入は後フェーズ）。
- **モデル遍歴**:
  1. Claude Sonnet 4.6 から開始 → 品質は高いが**遅い**。中間レイヤーには摩擦が大きい。
  2. OpenAI `gpt-4.1-mini` を追加（速度重視）。
  3. Groq `gpt-oss` を追加 → **1秒未満**の応答で速度は理想形。
- **モデル選定の知見（重要）**:
  - `gpt-oss-20b`: 速いが**文章の意味を理解しきれていない**。トゲ取りはできず、テニヲハ／
    丁寧文化どまり。→ **高速スタイリング専用**ならパイプラインの一部に使えるが、単体では不可。
  - `gpt-oss-120b`: **意味内容まで理解**できる。現状はこれが本命（既定）。
  - → 将来は「120b で意味を理解 → 20b で高速整形」のような**役割分担パイプライン**も検討余地。
- **プロンプト**: 当初の「最小限の介入」方針だとテニヲハ修正止まりだったため、
  「トゲ取りを最優先ミッション」に全面改訂。攻撃性の7パターン定義＋before→after の few-shot を追加
  （[`ReviewPrompt.swift`](BombSquad/Resources/ReviewPrompt.swift)）。
- **署名**: アドホック署名だとビルドごとに Keychain が再確認してくるため、Apple Development
  証明書での固定署名に変更。

## フィードバック / TODO

- few-shot 例は**実際に使った before→after** を追加していくのが最も効く。良い実例が出たら追記する。
- 速度計測（ms）は結果右上に表示。ネットワーク往復が支配的で計測コストは無視できる。
