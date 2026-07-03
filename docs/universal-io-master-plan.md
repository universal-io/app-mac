# Universal I/O (I//O) マスタープラン

最終更新: 2026-07-03
ステータス: 承認済み（オーナー承認済みの製品方針。実装はマイルストーン M1 から開始）

このドキュメントは、Bomb Squad から **Universal I/O**（ロゴ: **I//O**）への製品転換の正本である。
別のエージェント／開発者がこのドキュメントだけを読んで実装を進められることを目的とする。
各マイルストーンの開始・完了・方針変更時には必ずこのファイルを更新すること。

関連ドキュメント:
- [implementation-roadmap.md](implementation-roadmap.md) — 旧ロードマップ（認証・課金インフラの経緯）
- [api-contract.md](api-contract.md) / [auth-billing-infra-plan.md](auth-billing-infra-plan.md) — M3 で更新対象
- [../README.md](../README.md) — 現行実装（Bomb Squad 世代）の仕様

---

## 1. 製品ビジョン

### 1.1 コンセプト: 意味的 I/O レイヤー

Universal I/O は「インプットとアウトプットの間にあるもの」。
人間とアプリケーションの間には物理的な I/O レイヤー（キーボード・マイク・カメラ・スクリーン）が
既に存在する。I//O はその上に**意味・意図・認知の変換層**を新設する。

```
人間
 ↕ 物理層: キーボード / マイク / カメラ / スクリーン
 ↕ OS 層:  HID / ドライバ / イベント
 ↕ I//O:   意図・意味・認知の変換層   ← この製品
アプリケーション
```

- **Input 方向（人間→機械）**: 打鍵・音声を「意図」として受け取り、文脈と人格に沿った
  最適な文章へ変換して注入する。
- **Output 方向（機械→人間）**: スクリーン上の情報を、ユーザーの認知特性と目的に合わせて
  変換して提示する。

一言でいえば**「認知の眼鏡・補聴器」のデジタル拡張**。眼鏡が光を、補聴器が音を補正するように、
I//O は「意味」を双方向に補正する。当面の軸は **Vision（見る）** と **Voice（喋る）**。

### 1.2 北極星体験（North Star）

> **ホットキーを押してスクリーンを見せるだけで、「今何をすべきか」が分かり、
> そのアクション（メール返信なら文案まで）がエージェンティックに準備されていて、
> ユーザーはスクリーンをベースにただ承認していくだけですべてのタスクが終わっていく。**

- ユーザーの操作は「呼び出す」と「承認する」の 2 つに収束する。
- これは秘書型エージェントに接近するが、I//O の立場はあくまで
  **能力に大きなハンディキャップがある人のディスアビリティを限界まで埋めるレイヤー**である。
  自動実行はせず、最終判断（承認）は常に人間が行う。この原則は Bomb Squad 世代から不変。
- 全マイルストーンは、この北極星に向かう距離で優先度を判断する。

### 1.3 成立条件: ステートレスからの脱却

現行のレビューはステートレスで、レイヤーとして成立するには 2 軸が欠けている。

1. **Situational Context** — 入力中の文章の周辺文脈（どのアプリで、誰に、どんな会話の中で
   書いているか）。
2. **Personal Consistency** — ユーザーの人格的一貫性（文体・語彙・トーン・関係性ごとの距離感）。

瞬時に判断するのは不可能なので、**常に参照できるプロファイルを裏側でコツコツ積み上げる**
設計にする。ただし「使うほど良くなる」だけでは弱く、**初回でも成果が出る**ように
ブートストラップ（既存データの取り込み）を用意する。

### 1.4 ビジネス原則

- **最高のモデルでリッチな体験を優先する**。コストが高くても構わない。体験そのものが
  マーケティングである。
- したがって**ユーザー課金（サブスクリプション）が製品の中核**。BYOK（ユーザーが API キーを
  持ち込む方式）は開発者向けフォールバックに格下げする。
- モデル選択 UI はユーザーから隠す方向（プランと自動ルーティングが品質を決める）。

### 1.5 マルチデバイス前提

macOS の後、iOS（カスタムキーボード。`app-ios/BombSquadKeyboard` に着手済み）、
Android、Windows へ展開する。**ペルソナ・メモリ・課金はデバイス間で共有**されなければ
ならないため、知能とステートはサーバー側（Gateway）に集約する（M3）。

---

## 2. 用語定義

| 用語 | 意味 |
|---|---|
| **I//O パネル** | 右Shift 2回で呼び出す一時パネル（現 `ReviewPanelView` 系）。限界まで切り詰める |
| **管理ウィンドウ / マイページ** | メニューバーから開く通常ウィンドウ（現 `ManagementView`）。メモリ・履歴・プラン・設定 |
| **L1 / Situational Context** | 起動瞬間の周辺文脈（前面アプリ、会話スレッド、画面内容） |
| **L2 / Relationship Card** | 相手ごとのカード（呼称・敬語レベル・関係性・やり取り要約） |
| **L3 / Persona Card** | ユーザー自身のスタイルプロファイル（語彙・文体・NG 表現・価値観） |
| **Context Engine** | L1〜L3 を収集・蒸留・注入する仕組みの総称 |
| **Gateway** | サーバー側 API（FastAPI）。モデルルーティング・メモリ・課金メータリングを担う |
| **Deploy** | 変換結果を呼び出し元フィールドへ注入する操作（Bomb Squad 世代からの用語） |

---

## 3. アーキテクチャ全体像

### 3.1 3層コンテクストエンジン

| 層 | 寿命 | 収集タイミング | 保存先 | 注入方法 |
|---|---|---|---|---|
| L1 Situational | パネル1セッション | パネル召喚の瞬間に自動 | メモリ上のみ（保存しない） | プロンプトの context ブロック |
| L2 Relationship | 永続 | 送信後にバックグラウンド蒸留 | ローカル SQLite → M3 で Supabase | L1 から相手を特定してカードを注入 |
| L3 Persona | 永続 | オンボーディング＋送信ごとの増分＋定期蒸留 | 同上 | 常にシステムプロンプトへ注入 |

実装原則:
- **fine-tuning はしない**。構造化カード（Markdown）のプロンプト注入＋類似実例の few-shot 検索
  （M3 以降 pgvector）で実現する。モデル世代交代に追従でき、ユーザーがカードを直接編集できる。
- **教師データの本命は「レビュー結果をユーザーがどう編集して送信したかの差分」**。
  `LocalHistoryStore` には既に `source_text` / `final_text` があり、この資産をそのまま使う。
- メモリは**マイページで全件閲覧・編集・削除できる**こと。透明性が信頼と継続動機を生む。

### 3.2 Thin Client / Fat Gateway（M3 で移行）

```
[macOS: NSPanel + AX 注入]  [iOS: カスタムキーボード + 共有シート]  [Windows: 後発]
         └──────────────────────┬──────────────────────┘
                    I//O Gateway（FastAPI）
      ・モデルルーティング（タスク × プラン × レイテンシ）
      ・Context Engine（カード生成 / pgvector 検索 / 蒸留）
      ・課金メータリング / レート制御（Stripe）
      ・プロンプト管理（アプリリリース不要で改善）
         └── Supabase: Auth（既存）/ Postgres + pgvector / Realtime 同期
    クライアント側: SQLite キャッシュ + オフラインフォールバック
```

- クライアントは「キャプチャ（画面・音声・選択テキスト）と注入（⌘V 合成 → 将来 AX 直接注入）」
  だけを担うセンサー＆アクチュエータに徹する。
- LLM プロバイダの API キーはクライアントに置かない（現 Keychain BYOK は開発者モードに格下げ）。
- M1〜M2 の段階では既存のクライアント直叩き（`ReviewProvider`）のまま進めてよい。
  抽象化（`ReviewProvider` / `VisionProvider` / `Deployer` プロトコル）が既にあるので、
  M3 で `GatewayReviewProvider` を差し込むだけで移行できる構造を維持すること。

### 3.3 モデル戦略

- 既定は最高品質（Claude Opus / Sonnet 系）＋**ストリーミング必須**。
  最初のトークンが数百 ms で出れば、リッチモデルの遅さは体感から消える。
- 速度が命の箇所（ASR、L1 抽出、先行プレビュー）のみ高速モデル（Groq 系）。
  「大きいモデルで理解 → 速いモデルで整形」の知見（README 参照）は
  「速いモデルで先行プレビュー → リッチモデルの本結果で差し替え」として活かす。
- 課金プラン: Standard ¥1,980/月 / Pro ¥4,980/月（2026-07-03 オーナー決定）＋
  フェアユース上限。原価は 1 変換あたり数円〜十数円で吸収可能。
- **可用性の原則（2026-07-03 オーナー決定）**: 事業者側の都合（プロバイダ障害・
  プロバイダ側レート制限・事業者クォータ設定ミス）でユーザーが機能を使えない状態を
  作らない。Gateway の各機能（ASR・レビュー・Vision）はプロバイダ障害時に**自動で
  第二エンジンへフォールバック**する。ユーザー自身のプランクォータによる停止は正当。
  事業者側のコスト上限（青天井破産の防止）は必要であり、リリース時に慎重に設定する。
  最初の適用対象は ASR（Groq whisper がクォータ/障害でダウンする事象を確認済み）。

### 3.4 プライバシー原則（機能ではなく約束）

画面と私信を扱う製品なので、以下をマーケティングレベルの約束として全マイルストーンで守る:

1. **送信前に何が送られるか見える**（L1 コンテクストはパネル上でチップ表示、クリックで内容確認・除外可能）
2. **メモリは全件編集・削除可能**（マイページ）
3. **学習利用なし**（LLM プロバイダの no-training 設定 / DPA を利用）
4. L1 は保存しない。永続化するのは蒸留後のカードと履歴のみ（履歴は既存どおり設定で OFF 可）

### 3.5 UI デザイン原則

- **徹底的に OS ネイティブ**。macOS 26 (Tahoe) の Liquid Glass を採用
  （SwiftUI `glassEffect` / NSGlassEffectView。macOS 14 デプロイターゲットを引き上げる場合は
  可用性チェックとフォールバック=現行 material を用意）。
- SF Symbols・システムカラー・vibrancy・標準コントロールのみ。独自デザインは
  I//O ロゴグリフと diff 配色だけに絞る。
- I//O パネルは Spotlight / Raycast 型: 1 入力欄＋結果。状態は 3 つだけ
  （空 → 原文あり → 結果あり）。**モデル選択・言語選択プルダウンはパネルから撤去**し、
  管理ウィンドウへ移す。
- コア UI は **diff 表示**（`DiffView` を昇格）。「何を・なぜ変えたか」が 1 秒で読めること。
- メニューバーアイコンはテンプレート画像のモノクロ「I//O」グリフ。
- VoiceOver・フルキーボード操作・コントラストを最初から満たす。
  認知アクセシビリティの製品が UI アクセシビリティを欠くのは思想矛盾。
- アニメーションはシステムのスプリングとクロスフェードのみ。

---

## 4. 現状コードベースの地図（実装者向け）

リポジトリ: `git@github.com:universal-io/app-mac.git`（ローカル: `~/projects/universal-io/app-mac`。
2026-07-02 に GitHub org を `hey-watchme/mac-bomb-squad` から `universal-io/app-mac` へ移行し、
同日ローカルの親フォルダも `bomb-squad` から `universal-io` へ改名済み）
ビルド: `xcodegen generate` → `xcodebuild -project BombSquad.xcodeproj -scheme BombSquad -configuration Debug build`
コード内コメント・識別子は英語（CLAUDE.md 規約）。リネームは M5 まで行わず `BombSquad` 名前空間のまま実装する。

| 責務 | 場所 |
|---|---|
| アプリ起動・右Shift ジェスチャのハンドリング・パネル召喚 | `BombSquad/AppDelegate.swift`（`summon()`, `advance()`, `showPanel(prefill:mode:)`, `startScreenshotCapture()`） |
| 右Shift 1回/2回/長押し判定 | `BombSquad/Services/ShiftGestureMonitor.swift` |
| レビュー状態・実行 | `BombSquad/ViewModels/ReviewViewModel.swift`（`runReview()`, `draft`, `result`, `sessionKind`, `visionResult`） |
| プロンプト正本 | `BombSquad/Resources/ReviewPrompt.swift`（`system`, `transformSystem`, `languageInstruction`） |
| LLM クライアント抽象 | `BombSquad/Services/ReviewProvider.swift`, `OpenAICompatibleClient.swift`, `ClaudeClient.swift`, `VisionProvider.swift`, `OpenAIVisionClient.swift` |
| モデルカタログ | `BombSquad/Models/AIProvider.swift`（`ReviewModel.catalog`） |
| 注入・クリップボード | `BombSquad/Services/PasteDeployer.swift`, `Deployer.swift`（`ClipboardBackup`, `ClipboardDeployer`）, `SelectionGrabber.swift` |
| スクリーンショット | `BombSquad/Services/ScreenshotCaptureService.swift`（現状 `screencapture -i`） |
| 音声 | `BombSquad/Services/AudioRecorder.swift`, `GroqTranscriber.swift` |
| ローカル履歴 | `BombSquad/Services/LocalHistoryStore.swift`（SQLite `history_entries`: `source_text`, `final_text`, `mode`, `action` 等） |
| パネル UI | `BombSquad/Views/ReviewPanelView.swift`（`VisionPanelView` 含む）, `StagingEditorView.swift`, `DiffView.swift` |
| 管理ウィンドウ | `BombSquad/Views/Management/`（`ManagementView`, `AccountView`, `GeneralSettingsView`, `PricingView`, `HistoryPlaceholderView`） |
| 認証（Supabase） | `BombSquad/Services/BombSquadAuthClient.swift`, `ViewModels/AuthViewModel.swift` |
| 権限 | `BombSquad/Services/AccessibilityPermission.swift`, `ScreenCapturePermission.swift` |

---

## 5. マイルストーン

進め方の原則:
- 1 マイルストーン = 1 ブランチ（`feature/universal-io-m1` のように切る。ベースは `feature/universal-io`）。
- 各マイルストーンの完了条件は「受け入れ基準」をすべて満たし、ビルドが通り、実機で動作確認済みであること。
- スコープ外のリファクタリング・機能追加はしない（CLAUDE.md「過剰設計の回避」）。

### M1: Situational Context 注入（L1）

ステータス: 完了（`feature/universal-io-m1`、2026-07-02 実機確認済み）。

実装済み: AX 収集（フォーカス要素起点の拡張探索＋Electron 向け AXManualAccessibility リトライ）、
チップ UI（内容確認・セッション除外）、設定トグル、全プロバイダへのプロンプト注入。
Slack で会話本文、VS Code で開いているファイル内容の取得を実機確認。

**既知の制約（意図的に先送り）**:
- 「直近の返信対象メッセージ」が抜けることがある（Slack のスレッド末尾、VS Code のチャットパネル等）。
  改善はアプリ個別ルール化しやすく、投資対効果が薄いので、汎用解（LLM による抽出、
  M4 の Vision 連携＝画面キャプチャからの文脈取得）とまとめて再検討する。
- ScreenCaptureKit + Vision フォールバックは未実装（同上、M4 と統合判断）。

**既知の不具合（横断）**:
- アプリ起動直後、右Shift 2回が数回反応しないことがある（2026-07-02 報告）。
  M3-C C5 で対応（同日）: (1) **確定バグ修正** — アクセシビリティ未許可の状態で登録した
  グローバルモニタは許可後も発火しない（初回起動は再起動が必要だった）。許可を監視して
  モニタを再登録するようにした。(2) 間欠ケース向けにジェスチャ受信の診断ログ
  （起動直後の数イベント）を追加。再発したら Console.app の `BombSquad gesture:` で切り分ける。
- 受信モード（transform）は「呼び出し時に選択があった」だけで暗黙に入るため、意図せず入ると
  「送信したのにコピーされる」ように見える（2026-07-02 報告 → 同日、モードバッジ・ボタン文言・
  トースト文言で可視化対応済み。モード切替 UI は M3-C で検討）。

**目的**: ステートレス脱却の第一歩。最小工数で体感品質を最大に変える。初回ユーザーでも効果が出る。

**スコープ**:

1. **新規サービス `SituationalContextService`**（`BombSquad/Services/`）
   - パネル召喚の瞬間（`AppDelegate.summon()` 内、**パネルがキーウィンドウになる前**）に収集する。
     `SelectionGrabber` の ⌘C 合成と同じタイミング制約（前面アプリがパネルに切り替わる前に読む）。
   - 収集内容:
     - 前面アプリ名・Bundle ID（`NSWorkspace.shared.frontmostApplication`）
     - ウィンドウタイトル（AX API: `kAXFocusedWindowAttribute` → `kAXTitleAttribute`）
     - フォーカス中フィールドの周辺テキスト: AX API でフォーカス要素
       （`kAXFocusedUIElementAttribute`）から親を辿り、`kAXValueAttribute` /
       `kAXSelectedTextAttribute` / static text 子要素を収集して会話スレッドらしきテキストを得る
     - AX で十分なテキストが取れない場合のフォールバック: ScreenCaptureKit
       （`SCScreenshotManager`）で前面ウィンドウのみをキャプチャし、Vision モデルで
       会話コンテクストを抽出（「誰と誰の会話か・直近の話題・トーン」を JSON で返す軽量プロンプト。
       高速モデルを使いレイテンシ 1 秒以内を目標。抽出完了前にレビューが走る場合は L1 なしで実行し、
       完了していれば注入する — ブロッキングにしない）
   - 産物はモデル `SituationalContext`（新規、`BombSquad/Models/`）:
     `appName`, `windowTitle`, `conversationExcerpt`(String, 上限 ~2000 文字), `capturedAt`。
     **永続化しない**（メモリ上のみ、パネルを閉じたら破棄）。

2. **プロンプト注入**（`ReviewPrompt.swift`）
   - `static func contextBlock(_ context: SituationalContext?) -> String` を追加し、
     `system` / `transformSystem` と組み合わせる。内容例:
     「You are assisting inside {appName} ({windowTitle}). The surrounding conversation is: ...
     Use this only to infer recipient, tone, and what is being asked. Do not quote it back.」
   - `ReviewViewModel.runReview()` で `SituationalContext` をプロバイダへ渡す
     （`ReviewProvider.review(...)` のシグネチャに optional 引数を追加）。

3. **プライバシー UI**
   - パネル上部に L1 チップを表示（例: 「📎 Slack — #general の会話を参照中」）。
     クリックで取得内容をポップオーバー表示、「×」で除外（除外したらそのセッションでは注入しない）。

4. **設定**
   - `GeneralSettingsView` に「周辺コンテクストを読み取る」トグル（既定 ON）。
     OFF なら収集自体を行わない。

**非スコープ**: 相手の特定・カード化（M2）、コンテクストの保存、受信モードの変更。

**受け入れ基準**:
- [ ] Slack / Gmail / Mail のスレッド途中で返信を書き、右Shift 2回 → レビュー結果が会話の文脈
      （相手・話題・問われていること）を踏まえた修正になる
- [ ] チップから取得内容を確認・除外できる。除外・設定 OFF 時は従来と同一動作
- [ ] AX が効かないアプリでもフォールバック経由で文脈が入る（またはグレースフルに L1 なしで動く)
- [ ] レビュー開始までの体感遅延が増えない（L1 収集はレビュー実行をブロックしない）
- [ ] `xcodebuild` が通り、アクセシビリティ権限のみで AX 経路が動く（画面収録権限はフォールバック時のみ要求）

### M2: Persona / Relationship メモリとマイページ（L2・L3）

ステータス: 完了（`feature/universal-io` にコミット済み: `ed42931`、2026-07-02 実機確認済み）。
メモリ生成・蒸留の LLM 呼び出しは暫定で Groq `gpt-oss-120b` 直叩き（`MemoryDistiller`）。
M3 の Gateway 移行時にサーバー側へ移す。

**目的**: 人格的一貫性の実体を作り、「使うほど良くなる」と「初回から良い」を両立する。
メモリページを製品の顔にする。

**スコープ**:

1. **データモデル**（ローカル SQLite。`LocalHistoryStore` と同じ流儀で新規 `MemoryStore` を作る）
   ```sql
   CREATE TABLE memory_cards (
       id TEXT PRIMARY KEY NOT NULL,
       kind TEXT NOT NULL,          -- 'persona' | 'relationship'
       subject TEXT,                -- relationship の相手識別子（表示名）。persona は NULL
       content_md TEXT NOT NULL,    -- カード本文（Markdown、ユーザー編集可能）
       source TEXT NOT NULL,        -- 'bootstrap' | 'distilled' | 'user_edited'
       created_at REAL NOT NULL,
       updated_at REAL NOT NULL
   );
   ```
   - M3 で Supabase（`bs_` プレフィックステーブル）へ同期する前提で、スキーマは
     サーバー側と揃えられる素直な形にしておく。

2. **ブートストラップ（オンボーディング）**
   - 管理ウィンドウに「メモリ」タブを新設。空状態では
     「あなたが過去に送ったメール・メッセージを 3〜5 通貼り付けてください」フローを表示。
   - 貼り付けテキストをリッチモデルに渡し Persona Card を生成
     （新プロンプト `PersonaPrompt.bootstrap`: 語彙・文長・敬語傾向・絵文字/記号の癖・
     署名・避けるべき表現を Markdown の定型セクションで出力）。
   - 生成結果をユーザーに見せ、編集して保存できる。

3. **増分蒸留（使うほど良くなる）**
   - Deploy 完了後にバックグラウンドで実行:
     `source_text`（原文）/ レビュー提案 / `final_text`（実際に送った文）の 3 つ組を入力に、
     「ユーザーが AI 提案をどう直したか」から Persona Card への追記候補と
     Relationship Card（L1 で相手が特定できた場合）の更新候補を生成。
   - 自動で即書き換えるのではなく、確度の高い差分のみ適用し、カードの `updated_at` と
     `source='distilled'` を更新。メモリページで変更履歴が分かるようにする（最低限:
     最終更新日時と source 表示）。
   - 実行頻度は Deploy ごと（高速モデルで数百トークンの軽い処理）。失敗しても本体機能に影響させない。

4. **注入**
   - Persona Card は常にシステムプロンプトへ。
   - Relationship Card は L1 の `conversationExcerpt` / `windowTitle` から相手を推定して
     `subject` に一致するカードがあれば注入（推定も蒸留時に高速モデルで実施し、
     カード側に相手のエイリアスを蓄積していく）。

5. **マイページ（管理ウィンドウ「メモリ」タブ）**
   - Persona Card の閲覧・編集（Markdown エディタ＋プレビューで十分）・リセット。
   - Relationship Card の一覧・編集・削除。
   - 「I//O はあなたをこう理解しています」という見出しトーンで、透明性を演出する。
   - 併せて `HistoryPlaceholderView` を実装に置き換え、履歴一覧（before→after diff 表示）を出す。

**非スコープ**: サーバー同期（M3）、embedding 検索（M3 以降）、複数デバイス。

**受け入れ基準**:
- [ ] 新規ユーザーがオンボーディングで過去メールを貼ると、直後のレビューから文体が本人に寄る
      （敬語レベル・署名・語彙が反映される）
- [ ] 同じ相手に数回送ると Relationship Card が生成され、メモリページで確認・編集できる
- [ ] メモリページでカードを編集すると次のレビューに即反映される。削除も可能
- [ ] メモリを全削除すると素の動作に戻る
- [ ] 履歴タブで過去の before→after が diff で見られる

### M3: Gateway 移行・課金・同期

ステータス: M3-A 完了・実機検証済み（2026-07-02、`feature/universal-io` ブランチにコミット済み: `e4e0dd7`）。
**決定（2026-07-02、オーナー確認済み）**: Gateway は FastAPI ではなく
**Next.js Route Handlers（`web/`、Vercel）**。既存の
[auth-billing-infra-plan.md](auth-billing-infra-plan.md)・[api-contract.md](api-contract.md)・
適用済み Supabase スキーマ（`bs_` テーブル群）に従う。段階分割で進める:

- **M3-A（完了・実機検証済み）**: `web/app/api/ai/review` Gateway（Supabase JWT 検証、
  テナント解決、無料枠クォータ 50/月、Groq/OpenAI 呼び出し、`bs_usage_events` 記録）＋
  macOS `GatewayReviewClient`（既定。BYOK 直叩きは Gateway 未設定時のフォールバック）。
  context/memory はリクエストで受け取りプロンプトにのみ使用（保存しない、契約書参照）。
- **M3-B（実装中、`feature/universal-io`）**: Stripe 課金（アカウント構造はオーナー整理待ちのため
  最後に回す）、クォータ UI、Vision/ASR/メモリ蒸留の Gateway 移行、メモリ同期。
  macOS 側は `GatewayAPI` に共通化し、BYOK 直叩きは従来どおりフォールバック。
  ASR/Vision/蒸留にハードクォータは未設定（使用量記録のみ。上限は Stripe プラン導入時に設定）。
  実機確認済み（2026-07-02、ローカル Gateway `npm run dev` + macOS アプリ）:
  - ASR（`/api/ai/transcribe`）: 右Shift長押しの音声入力→文字起こし→レビューまで成功
  - Vision（`/api/ai/vision`）: 空欄で右Shift2回→撮影→読み取り成功。マイページの利用量カウントも確認
  - メモリ bootstrap（`/api/ai/memory/distill`）: プロファイル生成成功。生成ボタンは
    貼り付けが50文字未満だと無効化される仕様だが、理由の表示が無く分かりにくかったため、
    不足文字数のヒント表示を追加（[`MemoryView.swift`](../BombSquad/Views/Management/MemoryView.swift)）
  - メモリ post-deploy distillation（送信後の自動学習）は未確認（別途確認予定）
  - **メモリ同期（2026-07-03 完了・実機確認済み）**: `bs_memory_cards`（tombstone 付き、
    user スコープ RLS。migration `0002_bs_memory_cards.sql`）＋ Gateway `GET/PUT /api/memory/cards`
    （`updated_at` 勝ちマージ、PUT 1往復で push+pull 完結、削除は tombstone 伝搬）＋
    macOS [`MemorySyncService`](../BombSquad/Services/MemorySyncService.swift)（起動時＋編集時
    2.5秒デバウンス同期、Gateway 未設定/未ログイン時は no-op）。実機で起動時同期・編集同期・
    ループ無しを確認。検証中に発見・修正した 2 件: (1) 通常起動は `.signedIn` でなく
    `.initialSession` イベントで復元されるため起動時同期が発火しなかった、(2) Swift の
    `UUID().uuidString` は大文字・Postgres uuid は小文字を返すため、同期のたびカードが二重化
    （生成時小文字化＋既存 ID 正規化マイグレーションで解消）。
  残り: Stripe 課金（アカウント構造オーナー整理待ち）。
- **M3-C（実装中、`feature/universal-io`、2026-07-02 着手）**: パネル UI 刷新。
  デザイン原則 3.5 を全面適用する。フェーズ分割:
  - **C1 情報設計**: パネルを Spotlight/Raycast 型の縦 1 カラム（1 入力欄＋結果、
    空 → 原文 → 結果の 3 状態）に再構成。出力言語プルダウンをパネルから撤去し
    設定へ移動＋UserDefaults 永続化（「セッションごとに日本語へ戻る」既知課題も解消）。
    diff を結果表示の中心に昇格。右Shift 1回のフォーカス切替は上下（原文↔結果）として維持。
  - **C2 ストリーミング**: Gateway `/api/ai/review` に SSE を追加（`stream: true`）。
    revised_text の増分を `delta` イベント、最後に `result`（全体 JSON + quota）。
    macOS 側は `GatewayReviewClient` にストリーミング経路、結果エディタへトークン単位で反映。
    BYOK フォールバックは非ストリーミングのまま。
  - **C3 Liquid Glass / ビジュアル**: パネルをタイトルバーレスの浮遊ガラスに。
    `glassEffect`（macOS 26+、`#available` でフォールバック=現行 material。
    デプロイターゲットは 14.0 のまま）。メニューバーをモノクロ I//O グリフに。
    アニメーションはシステムスプリング/クロスフェードのみ。VoiceOver ラベル整備。
  - **C4 リブランド第 1 段**: 表示名・ウィンドウタイトルを Universal I/O 系へ。
    Bundle ID / URL scheme 変更は Supabase Redirect URL 設定と Keychain/権限の
    再許可を伴うため、変更内容をオーナーに提示して確認後に実施。
  - **C5 既知バグ**: アプリ起動直後に右Shift 2回が数回反応しない問題の切り分けと修正
    （M1 の「既知の不具合」参照）。
  実施順: C1 → C2 → C3 → C5 → C4。
  進捗（2026-07-02）: C1・C2・C3・C5 実装済み・**実機確認済み**（同日、レイアウト3状態・
  SSE ストリーミング・Liquid Glass・起動直後ジェスチャをすべて確認）。
  C4 は表示層（CFBundleDisplayName・ウィンドウタイトル・メニューバーグリフ）に続き、
  **Bundle ID / URL scheme も変更済み**（2026-07-03 オーナー決定: ドメイン
  `universal-io.com` の逆引きで `com.universal-io.mac` ／ scheme `universal-io://`。
  Keychain は legacyServices フォールバックで旧キーを引き継ぎ）。初回起動時に
  アクセシビリティ／マイク／画面収録の再許可と再ログインが必要。Supabase の
  Redirect URLs に `universal-io://auth/callback` の追加が必要（オーナー作業）。
  関連決定（同日）: Stripe はテストモードで実装先行、価格は Standard ¥1,980 /
  Pro ¥4,980。**Gateway デプロイ構成（2026-07-03 決定）**: 製品サイトは
  `universal-io.com`（既存 Vercel プロジェクト、web-product リポジトリ）で稼働中。
  Gateway は**別 Vercel プロジェクト**に分離し `api.universal-io.com` サブドメインへ
  （GitHub 連携 = app-mac リポジトリ、Root Directory=`web`）。apex を 2 プロジェクトに
  当てられないためサブドメイン分離が必須。クライアントの本番向き先デフォルトは
  Info.plist に `https://api.universal-io.com` を設定済み（開発は local.plist の
  localhost が優先。`GatewayAPI.endpoint` が `/api` 有無を吸収）。メールは
  Cloudflare + Resend 予定。

**目的**: ビジネス成立の土台。API キーのクライアント撤去、メータリング、Stripe サブスク、
デバイス間メモリ同期。**リブランドに伴う Bundle ID 変更もここで同時に行う**
（Keychain / 権限再許可の痛みを 1 回で済ませる）。

**スコープ**:

1. **Gateway（Next.js Route Handlers。既存 [auth-billing-infra-plan.md](auth-billing-infra-plan.md) と整合させて更新）**
   - エンドポイント（Pydantic スキーマ必須、[api-contract.md](api-contract.md) を正本として更新）:
     - `POST /v1/transform` — 送信レビュー／受信変換／Vision 解釈を統合した変換 API
       （`mode`, `input`, `situational_context`, `output_language`, ストリーミング=SSE）
     - `POST /v1/transcribe` — ASR プロキシ
     - `GET/PUT/DELETE /v1/memory/cards` — メモリ同期
     - `POST /v1/memory/distill` — 蒸留ジョブ
     - `GET /v1/me` — プラン・使用量
   - 認証: Supabase JWT 検証。使用量は `bs_usage_events` に記録（tokens, model, feature）。
   - モデルルーティング: プラン × 機能 × レイテンシ要件でサーバー側設定から決定。
     クライアントからモデル指定は受け取らない（開発者フラグ除く）。
   - Anthropic 連携の実装詳細（モデル ID・ストリーミング・Tool Use）は実装時に
     最新の公式ドキュメントを確認すること。
2. **Stripe 課金**: Standard / Pro の 2 プラン＋トライアル
   （オンボーディング〜最初の数変換まで無料）。Webhook で `bs_subscriptions` を更新。
   `PricingView` を実装に置き換え、アプリ内からは Web の課金ページへ誘導
   （macOS 直販アプリなので IAP 不要）。
3. **クライアント移行**: `GatewayReviewProvider: ReviewProvider` / `GatewayVisionProvider` を
   実装し既定に。SSE ストリーミングをパネル UI に反映（結果がトークン単位で流れる）。
   Keychain BYOK は隠し開発者設定に格下げ。`MemoryStore` を Supabase 同期対応にする
   （ローカルキャッシュ＋起動時/変更時同期。競合は updated_at 勝ち）。
4. **パネル UI の切り詰め（デザイン原則 3.5 の適用)**: モデル・言語プルダウンをパネルから
   管理ウィンドウへ移動。ストリーミング表示と diff を中心に再構成。
   Liquid Glass 採用（デプロイターゲット判断含む）。
5. **リブランド第 1 段**: Bundle ID / Keychain service / 表示名を Universal I/O 系に変更
   （コード名前空間のリネームは任意。表示層だけでもよい）。

**受け入れ基準**:
- [ ] クライアントバイナリに LLM プロバイダのキーが存在しない
- [ ] 未課金ユーザーはトライアル分だけ変換でき、超過で課金導線に誘導される
- [ ] 使用量が `bs_usage_events` に記録され、`/v1/me` とマイページで見える
- [ ] レビュー結果がストリーミング表示される（最初のトークンまで体感 1 秒以内）
- [ ] メモリカードが 2 台の Mac 間で同期される
- [ ] パネルにプルダウン類がなく、空→原文→結果の 3 状態だけで完結する

### M4: Vision の再定義 —「見る → わかる → 返す」

ステータス: スコープ 1〜3 完了・**実機確認済み**（`feature/universal-io-m4`、2026-07-03。
受け入れ基準 4 項目＋キャプチャ UX を実機で確認）。スコープ 4（受信変換の統合）は
別フェーズ（M4-B）として続行中。

進捗（2026-07-03）: スコープ 1〜3 実装・実機確認済み。実装メモ:
- キャプチャ（2026-07-03 オーナー仕様確定で改修）: 右Shift2回で
  `ScreenshotSelectionOverlay` が開き**全画面が選択済み**の状態で待機。Enter =全画面確定、
  ドラッグ=範囲選択（`captureRegion`）、esc =パネルへ戻る、右Shift2回=セッション破棄で
  待機モードへ。実撮影は `ScreenshotCaptureService`（SCScreenshotManager、カーソルの
  ディスプレイ。5K 級はアップロード上限対策で半分に縮小）。SCK 失敗時のみ
  `screencapture -i` にフォールバック。
- スキーマ: `VisionInterpretationResult` を situation / extracted / asks /
  suggested_actions[{title, kind, draft}] に刷新（旧 summary / visible_text 形も
  `decodeFlexible` で受容）。Gateway `/api/ai/vision` は review と同じ
  `input.context` / `input.memory` を受け取りプロンプトにのみ使用
  （[api-contract.md](api-contract.md) 更新済み）。BYOK `OpenAIVisionClient` も同等。
- UI: `VisionPanelView` 右ペインを状況→求められていること→提案アクション（カード）→
  読み取った内容に再構成。文案付きアクションは「承認して送信」（PasteDeployer で呼び出し元へ
  注入→パネル閉）と「編集する」（compose エディタへ引き継ぎ。パネルは 1 カラム幅へ復帰）。

**目的**: Vision を「スクショ → OCR → コピー」の素材撮影から、北極星体験
（画面を見せるだけで、やるべきことと文案が用意され、承認するだけ）の初期形へ引き上げる。

**スコープ**:

1. **キャプチャの刷新**（2026-07-03 オーナー仕様確定）: 空の原文欄で右Shift 2回 →
   **選択オーバーレイが全画面選択済みの状態で開く**。Enter でそのまま全画面を確定
   （ScreenCaptureKit、カーソルのあるディスプレイ。「今見ている画面」をそのまま渡す）、
   ドラッグで従来どおり範囲選択、esc でパネルへ戻る、右Shift 2回でセッション破棄
   （パネルが出る前の待機モードへ）。ユーザー操作は「呼び出す→ Enter」の 2 手に収める。
2. **解釈スキーマの拡張**（`VisionInterpretationResult` を拡張）:
   ```json
   {
     "situation": "この画面で何が起きているかの要約（1-2文）",
     "extracted": "画面から読み取った本文（構造化 Markdown）",
     "asks": ["あなたに求められていること（依頼・期限・事実）"],
     "suggested_actions": [
       {
         "title": "田中さんへ返信する",
         "kind": "reply | fill_form | task | info_only",
         "draft": "kind=reply の場合、Persona/Relationship を反映した返信文案"
       }
     ]
   }
   ```
   - 生成には Persona Card / Relationship Card / L1 を注入する（M1・M2 の成果を接続）。
3. **Vision パネル UI**: 左=スクリーンショット、右=「状況 → 求められていること →
   提案アクション（カード形式）」。reply 系アクションは
   **「承認して送信」＝そのまま Deploy** と **「編集する」＝compose モードへ文案を引き継ぎ**
   の 2 ボタン。ここで Vision → Voice/テキストのループが閉じる。
4. **受信変換の統合（M4-B。2026-07-03 実装済み・実機確認済み）**: transform モード
   （選択テキスト取り込み）を Vision 解釈の特殊ケースとしてスキーマ・UI を共通化。
   実装メモ:
   - Gateway `/api/ai/vision` が `input.text`（受信メッセージ、最大16,000字）を
     `image_base64` と排他で受ける（[api-contract.md](api-contract.md) 更新済み）。
     text の場合、`extracted` は「攻撃性・感情・皮肉を除いた中立な整理版」。
     BYOK `OpenAIVisionClient` も同等実装。
   - macOS: transform の変換は `runReview()` 内で解釈経路へ分岐
     （`runTransformInterpretation`、SSE レビュー経路は compose 専用に）。右ペインは
     Vision と同じ「状況→求められていること→提案アクション→整理した内容」。
   - **出口原則は不変（書き戻さない）**: transform の提案アクションは
     「承認してコピー」＝クリップボードのみ。「編集する」（compose への引き継ぎ）は
     デプロイヤ／プロンプトの整合が必要なため transform では非表示（次段候補）。
   - UI 切り詰め（同日オーナー指示）: 受信側はペインタイトル・文字数・説明バナー・
     レビュー/コピー/カメラ/ヘルプボタンを撤去し、受信メッセージは**読み取り専用**。
     残る操作は右ペインの「コピー」と「承認してコピー」のみ。あわせて compose の
     青フォーカスリングは「原文 vs 結果の二者択一になった時だけ」表示に変更。
   - 返信文案の役割取り違え（相手の行動を自分の行動として書く）を役割固定
     プロンプトで修正（受信者視点の明示＋依頼ゼロのメッセージへは短い承知で返す）。
   - 旧 transform 表示（IssueCard の受信ラベル・transformSystem プロンプト）は
     未使用化。掃除は M5 リブランド時にまとめて行う。

**非スコープ**: 画面の常時監視、複数アクションの自動実行、reply 以外のアクションの実行
（fill_form / task は表示と文案・手順の提示まで）。

**受け入れ基準**（2026-07-03 実機確認済み）:
- [x] メール画面を開いて右Shift 2回（空欄）→ Enter で「状況・求められていること・返信文案」が出る
- [x] 「承認して送信」でメールの返信欄に文案が注入される（ユーザーの追加入力ゼロ）
- [x] 文案にユーザーの文体（Persona）と相手との関係性（Relationship）が反映されている
- [x] info_only の画面（エラー・外国語 UI 等）では「わかる」まで（要約と次の一手の提示）が機能する

### M4 の先（ピン留め、2026-07-03 オーナー確認）: Vision 完成形と波の観測

**完成形（プロダクトのゴール）**: 「理解の代理」と「操作の代理」の合成レイヤー＝**認知の義肢**。
スクリーンショット（既定は全画面）を撮るだけで、今見ている画面を解釈・整理し、
アクションに落とし込み、ユーザーは AI の提案するアクションを**承認していくだけ**。
役所の申請・病院の Web 問診・各種手続き・会計ソフト・アクセス解析などを、
認知的・能力的ギャップがある人でも最低限こなせるようにする。秘書ではなく**本人の代理**。
自動実行はせず承認駆動（1.2 の北極星と同一原則）。

**方針**: 実装は常に「現在の技術で実際に機能する一番近い形」に留める。精度の低い段階の
技術（汎用 GUI grounding 等）には手を出さず、壁が崩れた瞬間に打ち出せるよう仕込みを先行させる。

**完成形までの階段**（各段は前段が実機で機能してから）:
1. **M4（実装済み・検証待ち）**: 全画面 1 ショット → 状況・asks・文案付きアクション → 承認で ⌘V 注入
2. **Vision × AX の fill_form**: 「何を書くか」= Vision、「どこに書くか」= AX API。
   モデルの座標 grounding を待たずに今日の技術で成立する中間解
3. **タスクセッション**: 複数画面にまたがる手続きの計画・進行状態・ステップごとの再キャプチャと検証
4. **パーソナルデータボールト**: 氏名・住所等の構造化本人データ＋利用ごとの承認 UI（役所・問診の解錠鍵）
5. **汎用エグゼキュータ**: computer use 系 API への実行部差し替え（スキーマ・UX は不変のまま）

**波の観測（2026-07-03 時点の読み）**:
- **GUI エージェント能力**: OSWorld-Verified で Claude Opus 4.8 = 83.4%、Fable/Mythos 5 ≈ 85% と
  **人間ベースライン（≈72%）を既に超えた**。能力の壁は崩れつつあり、残る壁は主にコストと統合。
  Anthropic の computer use ツール（`computer_20251124`、beta）が標準インターフェース候補。
- **コスト**: 単発 Vision 解釈は 1 円未満〜数円で既に問題なし。エージェント型手続き 1 件は
  Sonnet 5 級で概算 ¥50〜150（プロンプトキャッシュ込み）。「1 手続き ¥10 台」がマス展開の合図。
- **トリガー**: 私設ベンチ（下記）で「初見フォーム記入のステップ精度 ≈95%」を新モデルが超えた時点で
  階段 5 に着手。
- **仕込み（優先）**: ①私設ベンチ＝波検知器（役所・問診・会計・解析の実画面＋期待アクションの
  ゴールデンセット）を早期に作る、②アクションスキーマをエグゼキュータ非依存に保つ、
  ③Persona/Relationship/本人データのボールト、④承認 UX の文法。

**モデル選定（2026-07-03 リサーチ。適用はオーナー判断）**:
- Vision 解釈＋文案生成の品質本命: **Claude Sonnet 5**（$3/$15、2026-08 まで導入価格 $2/$10。
  高解像度ビジョン 2576px・指示追従・日本語品質。Gateway に Anthropic エンジン追加が必要）。
  現行の OpenAI `gpt-5.4-mini`（$0.75/$4.5）は速度・コストの現実解として妥当。
  フォールバック `gpt-4.1-mini` は旧世代のため `gpt-5.4-nano` 等へ更新推奨。
- ASR: Groq `whisper-large-v3` は現役。より高速な `whisper-large-v3-turbo` が Groq 推奨の移行先。
- ローカル VLM（Qwen3-VL 等）はサーバー級では商用に肉薄。コンシューマ Mac での文案品質は
  まだ先＝プライバシー切り札は引き続き観測。

### M5: マルチデバイス展開・リブランド完了

**目的**: iOS カスタムキーボードの GA と Universal I/O 正式リブランド。

**スコープ（概要。着手時にこのセクションを詳細化すること）**:
- iOS: `app-ios/BombSquadKeyboard` を Gateway 接続に対応。キーボードがモバイルの
  I//O レイヤーの物理的正位置。共有シート＋ショートカット対応。
  キーボード拡張のメモリ・ネットワーク制約（Full Access）に注意。
- macOS: Accessibility API による実フィールド直接注入（`Deployer` 差し替え、
  クリップボード退避の廃止）。
- リブランド完了: 名称・ロゴ（I//O）・Web・ストア表記の統一。
- Windows / Android は調査から。

---

## 6. マイルストーン間の依存関係

```
M1 (L1 コンテクスト) ──┬──> M2 (メモリ/マイページ) ──> M3 (Gateway/課金) ──> M5 (マルチデバイス)
                        └──────────────────────────────> M4 (Vision 再定義)
```

- M4 は M1・M2 の成果（コンテクスト・ペルソナ注入)を文案生成に使うため、M2 完了後が望ましい。
  M3 と M4 は並行可能だが、M4 の Vision 呼び出しコストが大きいため課金（M3）を先行させる。

## 7. このドキュメントの運用

- マイルストーン開始時: 対象セクションに `ステータス: 実装中（ブランチ名）` を追記する。
- 完了時: 受け入れ基準のチェックボックスを埋め、`ステータス: 完了（マージコミット）` にする。
- 方針変更時: 該当セクションを書き換え、冒頭の「最終更新」を更新する。旧記述は残さない
  （経緯は git 履歴が持つ）。
