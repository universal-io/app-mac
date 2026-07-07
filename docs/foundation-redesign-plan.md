# 基礎固め（Foundation Redesign）— 全機能を貫く再設計

作成: 2026-07-07 ／ 最終更新: 2026-07-07（外部アーキテクチャレビューの反映）
ステータス: ドラフト（オーナーレビュー待ち）

機能追加の波（レビュー → Vision → 受信変換 → ナビゲーター → コパイロット）が一段落し、
「機能はこれ以上大きく増えない」フェーズに入った。本書は、なりゆきで積み上がった構造を
一度で立て直すための正本である。個別機能の正本（universal-io-master-plan.md /
navigator-copilot-plan.md / admin-dashboard-plan.md）は生きたまま、それらを載せる
**土台の設計**だけをここで定義する。

---

## 1. 製品の全体像（何を支えるための基礎か）

I//O は「アプリケーションより上のレイヤー」で人間の I/O を支える。機能は突き詰めると
**5つのモード**に収束しており、今後の拡張（ツール対応・個社パック・プラン制限・管理画面）も
この5つの上に載る:

| モード | 方向 | 入口 | 出口 |
|---|---|---|---|
| **Compose**（入力レビュー） | 人間 → 機械 | 手入力・ペースト・音声 | 呼び出し元フィールドへ注入 |
| **Transform**（受信整理） | 機械 → 人間 | 選択テキスト | クリップボードのみ |
| **Navigator**（画面Q&A） | 機械 → 人間 | スクリーンショット | 理解・ハイライト・文案・承認アクション |
| **Copilot**（ガイド実行） | 双方向 | Navigator からの遷移 | ステップ誘導 → 目的の答え |
| **Capturing**（選択オーバーレイ） | — | Navigator/再撮影の途中状態 | 撮影 or 破棄 |

音声入力（hold-to-talk）はモードではなく**横断的な入力手段**。L1/L2/L3 コンテクストと
履歴・蒸留も横断サービス。

---

## 2. 診断: なぜコンフリクトが起きるのか

### 2-a. モードが4つの直交しない軸に分散している（最重要）

現在、上記5モードは単一の状態としてどこにも存在せず、次の組み合わせで暗黙に表現されている:

- `ReviewMode`（compose / transform）— VM 生成時に固定
- `InputSessionKind`（text / vision）— VM の `@Published`
- `navigatorSessionActive` — wire turns の有無から導出される計算プロパティ
- `navigatorActiveTask != nil` — コパイロット中かどうか
- `isCopilotActive` — **同じ事実の複製**が AppDelegate 側にもある
- `isCapturingScreenshot` — AppDelegate と VM の**両方**にある

「今どのモードか」を知るには複数オブジェクトの複数フラグを正しい順序で読む必要があり、
新しい挙動を足すたびに全分岐（`advance()`、`handleResignActive`、dictation ルーティング、
パネルサイズ変更…）へ手作業で整合を取っている。既知バグはすべてこの構造の症状:

- 外クリックで閉じる vs コパイロット（`handleResignActive` 問題 → isCopilotActive ガードで対症療法済み）
- 合成クリック後のパネル復帰不能（1セッション1アクション制約の原因）
- 管理ウィンドウがパネル操作のたびに前面へ引っ張られる（`NSApp.activate` の散在）
- transform への暗黙突入（「送信したのにコピーされる」）

navigator-copilot-plan §1 の結論「**モードと計画はデータ、LLM は目と口**」はナビゲーターだけの
話ではなく、**アプリ全体に適用すべき原則**である。モードはデータ（単一の状態機械）で持つ。

### 2-b. 神クラスと文字列配線

- `ReviewViewModel`（1,261行）に 5 モード全部＋音声＋履歴＋蒸留＋デプロイが同居。
- `AppDelegate`（648行）がジェスチャ解釈・パネル生成・サイズ・位置・モーダル性・録音・撮影を保持。
- 両者は **NotificationCenter 11 チャンネル**（showPanel / closePanel / captureScreenshot /
  hidePanelForAction / showPanelAfterAction / visionSessionEnded / copilotModeChanged …）で
  双方向に結合。状態は VM に、その状態が要求する窓の形は AppDelegate にあり、同期は通知任せ。

### 2-c. クライアント/サーバーの機能別サイロ

- Gateway クライアントが機能ごとに別クラス（Review / Vision / Navigate / Transcriber / Account）で、
  認証・SSE・エラー処理・`make()` によるフォールバック判定を各自が重複実装。
- サーバー側も `review-engine` / `vision-engine` / `navigate-engine` が別立てだが、
  vision と navigate と transform は実質同じ「画面/文章を理解して行動可能にする」ジョブで、
  スキーマ（状況 → 求められていること → アクション）も既にほぼ共有している。
- ハーネスは `harness.ts` にハードコード。個社パック・ツール追加のたびにデプロイが要る。

### 2-d. 将来要件の置き場がない

- **プラン別機能制限**: `bs_entitlements` は存在するがクォータ数値のみ。機能単位のゲートがない。
- **個社（テナント）パック**: `bs_tenants` はあるが、ハーネスにテナント概念がない。
- **管理者権限・管理画面**: 設計のみ（admin-dashboard-plan.md）。

---

## 3. 方針判断: ゼロベースで作り直すか？

**しない。「コアの再構築＋周辺の移植」を推奨する。**

- 資産と負債の分布がはっきりしている。**負債は「状態と配線」**（ReviewViewModel・AppDelegate・
  通知網・ReviewPanelView の分岐）に集中し、**資産は Services 層**（クリップボード退避・⌘V/⌘C 合成・
  ScreenCaptureKit・OCR・AX 解決の段階マッチ・ジェスチャ判定・署名/TCC/配布パイプライン）と
  Gateway のエンジン群に蓄積している。Services 層は数ヶ月の実機知見（重いアプリでの取りこぼし、
  Electron の AX、activate の作法…）の結晶であり、書き直せば同じ穴に落ち直すだけ。
- ゼロベースは「軽快さ・堅牢さ最優先」の原則にも反する（動いて検証済みのものを壊して長期間
  不安定な状態を作る）。
- したがって: **状態機械とオーナーシップだけを新設**し、既存の Services / Views / エンジンを
  その下に**移植**する。挙動を変えないリファクタと、構造が可能にする挙動修正を厳密に分ける。

---

## 4. 新アーキテクチャ（クライアント）

### 4-a. 3層構造

```
┌──────────────── UI layer ────────────────┐
│ 共通コンポーネントキット（PanelChrome・エディタ・   │
│ 結果ペイン・アクションカード・ストリップ・トースト）  │
│ ＋ モードごとの薄い画面（ComposeView 等）          │
├────────────── Session layer（新設・本丸） ──┤
│ SessionCoordinator = AppMode の唯一のオーナー      │
│ 遷移表・ジェスチャ解決・PanelSpec 導出              │
│ ComposeSession / TransformSession /               │
│ NavigatorSession / CopilotSession（小さな VM）     │
│ SessionServices（横断: 音声・L1/メモリ・履歴・蒸留） │
├────────── Capabilities layer（既存を維持） ──┤
│ Deployer / SelectionGrabber / ScreenshotCapture / │
│ ScreenTextRecognizer / AXActionService /          │
│ ShiftGestureMonitor / AudioRecorder / Keychain /  │
│ HighlightOverlayPresenter / Stores（SQLite）       │
└──────────────────────────────────────────┘
```

### 4-b. AppMode: モードの単一の正本

```swift
// The ONE source of truth for "what is the app doing right now".
enum AppMode {
    case idle                                  // panel closed, standby
    case compose(ComposeSession)               // outgoing review
    case transform(TransformSession)           // incoming readability
    case navigator(NavigatorSession)           // screen Q&A conversation
    case copilot(CopilotSession)               // guided step-by-step run
    case capturing(CaptureContext)             // selection overlay is up
}
```

- `ReviewMode` / `InputSessionKind` / `navigatorSessionActive` / `isCopilotActive` /
  重複した `isCapturingScreenshot` は**全廃**し、この enum に置き換える。
- 各 `*Session` は自分のモードに必要な状態だけを持つ小さな `@MainActor` **参照型クラス
  （ObservableObject）**（目安: Compose ≈ 250行、Transform ≈ 100行、Navigator ≈ 400行、
  Copilot ≈ 250行）。参照型なので、ビュー側は `if case .compose(let session)` で取り出して
  `@ObservedObject` として受けるだけでよく、enum の連想値へのバインディング問題は生じない。
- Navigator → Copilot の遷移は `CopilotSession(from: navigatorSession, task:)` のように
  **前のセッションを引数に取る明示的な構築**で行う（会話履歴・OCR 断片の引き継ぎが型で見える）。
- **ライフサイクル契約**: 全セッションは `SessionLifecycle` に準拠し、`willEnd()` で
  進行中の非同期タスク（LLM ストリーム・再キャプチャ）・グローバルモニタ・ハイライトリングを
  必ず畳む。呼び出しは各所に散らさず、**Coordinator の遷移処理そのものに組み込む**
  （旧セッションの `willEnd()` → mode 差し替え → 新セッション開始、の順を1箇所で保証）。
  現行の `panelWillClose()` の「呼び忘れたら事故」構造を仕組みで潰す。
- **排他は enum、継続性は永続化**: モード遷移で下書き等のユーザー入力を失わないことは要件
  （ゴールデンパス表に含める）だが、その実現手段はセッションを温存する Registry ではなく、
  既存の `ComposeDraftStore`（UserDefaults 永続化＋復元）方式とする（§8-b 却下案参照）。

### 4-c. SessionCoordinator: 遷移とジェスチャの決定論化

```swift
@MainActor final class SessionCoordinator: ObservableObject {
    @Published private(set) var mode: AppMode = .idle

    // Gestures arrive as intents; the transition table resolves them
    // against the current mode. No scattered branching.
    func handle(_ intent: GestureIntent)   // .doubleTap, .singleTap,
                                           // .holdBegan, .holdEnded,
                                           // .escape, .panelToggle
    func handle(_ event: SystemEvent)      // .appResignedActive,
                                           // .authCallback, .permissionChanged
}
```

- 右Shift 2回の「起動/レビュー/ビジョン/閉じる」多義性は、**mode × intent の遷移表**として
  1箇所に書く。README の操作仕様がそのままテーブルの行になる（＝仕様とコードが一対一）。
- `didResignActive` の扱いもモードが決める: compose/transform → close、copilot → 無視、
  capturing → 無視、navigator → 無視 or close（現仕様どおり）。個別ガードの継ぎ足しを廃止。
- 音声ディクテーションの着地先も `mode` から導出（compose.draft / compose.revision /
  navigator.input）。現在の `activeTranscriptionTarget` 判定の移植。

### 4-d. PanelController: 窓の形は mode の純関数

```swift
struct PanelSpec: Equatable {
    var size: NSSize            // text 680×660 / vision 960×640 / strip 460×240
    var placement: Placement    // .centered, .bottomTrailing
    var isModal: Bool           // close on resign-active?
    var activates: Bool         // may steal app focus? (copilot: never)
}
extension AppMode { var panelSpec: PanelSpec? { ... } }  // nil = no panel
```

- `PanelController` は Coordinator の `mode` を購読して NSPanel を追従させるだけの存在にする。
  パネルサイズ変更・中央/右下配置・`NSApp.activate` の呼び出しは**ここにしか書かない**。
- **適用順の規約（フリッカー対策）**: モード遷移時は PanelSpec（窓のサイズ・位置）を
  **SwiftUI がビューを切り替えるより先に**適用する。`switch mode` によるビュー差し替えは
  旧ビューの破棄＋新ビューの生成なので、窓の変形と同時に走ると視覚的なちらつきになる。
  遷移アニメーションはシステムのクロスフェードのみ（デザイン原則 §3.5 と同じ）。
- これで「管理ウィンドウが前面に引っ張られる」問題は構造的に潰せる（activate が必要なモードか
  どうかを spec が宣言し、管理ウィンドウは `activates: false` の操作では動かない）。
- **NotificationCenter のアプリ内配線は全廃**。Coordinator → PanelController は直接参照
  （どちらも AppDelegate が生成する 2 オブジェクト）。メニューバー・管理ウィンドウからの操作も
  Coordinator のメソッド呼び出しに統一。

### 4-e. GatewayClient の一本化

```
GatewayClient（認証ヘッダ・SSE パーサ・エラー変換・リトライ/フォールバックを1実装）
  ├─ .review(...)      → POST /api/ai/review     (SSE)
  ├─ .interpret(...)   → POST /api/ai/vision     （画像 or テキスト）
  ├─ .navigate(...)    → POST /api/ai/navigate   (SSE, task 同送)
  ├─ .transcribe(...)  → POST /api/ai/transcribe
  ├─ .memory / .account / .entitlements
```

- BYOK 直叩き（開発者フォールバック）は `ReviewProvider` / `VisionProvider` プロトコルの
  実装として現状維持。ただし判定（Gateway が使えるか）は**1箇所**（`EngineResolver`）に集約し、
  各 `make()` の重複を廃止。

---

## 5. 新アーキテクチャ（サーバー / Gateway）

### 5-a. エンジンの統合: 「理解系」を1本に

- `vision-engine` / `navigate-engine` / transform（review-engine 内の分岐）を
  **interpret エンジン 1 本**に統合する。入力は `{ image | text }` × `{ oneShot | conversation }` ×
  `{ task? }` の直積で、出力スキーマは共通（状況 / asks / suggested_actions / マーカー）。
  ナビゲーターの会話・プランナー・補追コール・ハーネス選択はこのエンジンの機能になる。
- **統合の境界線（重要）**: 統合するのは**エンドポイント・認証・SSE・使用量記録・スキーマ・
  ハーネス選択**まで。**プロンプトテンプレートとモデル設定は intent 別
  （`transform` / `vision` / `navigate`）に分離したまま**、エンジン内部でルーティングする。
  1 本の巨大プロンプトに全 intent を担わせると、片方のチューニングが他方を退行させる
  （ナビゲーター計画 §0 で学んだ「5判断を1コールに任せない」と同じ原則）。intent ごとの
  プロンプトは独立して差し替え・計測できること。
- `review-engine`（diff 型の成果物）と `transcribe` / `memory` は独立のまま。
- モデルルーティング（操作 × プラン × レイテンシ）は admin-dashboard-plan v1 の
  `bs_app_config`（DB 設定 → env → コード既定）へ寄せる。

### 5-b. ハーネス → パック（データ化・テナント対応）

ユーザー明示の今後の計画（GA4・freee・Salesforce・Slack・Gmail・Google カレンダー…の標準対応と、
B2B 個社の基幹システム/ERP 向け追加パッケージ）の器をここで定義する。

```sql
CREATE TABLE bs_harness_packs (
    id          uuid PRIMARY KEY,
    tool_id     text NOT NULL,          -- 'ga4' | 'freee' | 'salesforce' | ...
    scope       text NOT NULL,          -- 'global' | 'tenant'
    tenant_id   uuid REFERENCES bs_tenants(id),  -- scope='tenant' のとき必須
    match_hints jsonb NOT NULL,         -- URL・ウィンドウタイトル・アプリ名のマッチ規則
    ui_map      text,                   -- 画面構造の知識（プロース）
    recipes     jsonb,                  -- Task.steps の正解データ（＝ゴールデンセット兼用）
    prompt      text,                   -- 追加システムプロンプト
    min_plan    text NOT NULL DEFAULT 'standard',  -- このパックが使える最低プラン
    enabled     boolean NOT NULL DEFAULT true,
    updated_at  timestamptz NOT NULL
);
```

- 現 `harness.ts` は**シードデータに降格**（DB 未設定時のフォールバック兼、初期データ投入元）。
- 選択ロジックは現行どおりサーバー側 `selectHarness`: クライアントはヒント（アプリ名・タイトル・URL）を
  送るだけで**非可視のまま**（ゼロ・インテグレーション思想は不変。navigator-copilot-plan §9-a）。
  テナントスコープのパックは JWT のテナント解決結果で自動的に候補へ入る。
- **ツール追加＝レシピ/パックの行追加**であり、アプリのリリースもサーバーのデプロイも不要になる。
  Salesforce 級の深い個別最適も「global パックの厚み」で表現し、個社 ERP は tenant パックで隔離。
  Chrome 拡張（DOM 直読み）による個社対応が必要になった場合も「tenant パックの実装手段の一つ」
  として同じ器に収まる（標準体験は拡張に依存しない）。

### 5-c. プラン制限（Entitlements）

- **強制は必ずサーバー**。Gateway の `authenticate` 済みコンテキストに
  `entitlements: { plan, features: string[], quotas: {...} }` を載せ、各エンジンが operation 単位で
  検査する（既存の月次クォータ機構の拡張）。
- プラン × 機能マトリクス（初期案。**数値・割当はオーナー決定事項**）:

| 機能 | Free/Trial | Standard ¥1,980 | Pro ¥4,980 | Team/Enterprise（B2B） |
|---|---|---|---|---|
| Compose / Transform | 回数制限 | ○ | ○ | ○ |
| Navigator（画面Q&A） | 回数制限 | ○ | ○ | ○ |
| Copilot（ガイド実行） | × | 回数制限 | ○ | ○ |
| 標準パック（GA4/freee/Slack…） | — | ○ | ○ | ○ |
| 個社パック（tenant） | — | — | — | ○（アップセル） |
| 上位モデルルーティング | — | — | ○ | 契約による |
| 管理コンソール（テナント管理者） | — | — | — | ○ |

- クライアントは `GET /api/account`（既存）に features を追加してもらい、**表示のゲートだけ**行う
  （ボタンを隠す/ロック表示。判定ロジックは持たない）。
- 超過・未権限のエラーは Gateway が構造化エラー（`code: 'PLAN_REQUIRED'` 等）で返し、
  クライアントは課金導線へ誘導する。

### 5-d. 権限モデルと管理画面

- **ロールは3層**: 一般ユーザー / テナント管理者（B2B 導入企業の管理者。自社の利用状況と
  個社パックを見る）/ システム管理者（事業者＝オーナー）。
- v0 は admin-dashboard-plan.md のとおり `ADMIN_EMAILS`（システム管理者のみ）で開始。
  v1 で `bs_profiles.role`（'user' | 'tenant_admin' | 'admin'）へ昇格し、`/admin` は
  ロールでセクションを出し分ける（テナント管理者には自テナントの集計とパックのみ）。
- admin コンソールのロードマップに **「パック管理」（5-b の CRUD）と「プラン設定」**を v1 として
  追加する。置き場所は既存決定どおり `web/app/admin`。

---

## 6. UI コンポーネントの統一

「UI は統一、ロジックはモード最適」の要件をキットとして固定する:

- **PanelChrome**（ガラス・角丸・警告バー）— 既存を昇格。全モードの外殻。
- **EditorPane** — draft/revision/navigator input を1実装で（フォーカスリング・placeholder・
  Enter/Shift+Enter の規約込み）。
- **ResultPane** — 「状況 → 求められていること → アクション → 内容」の interpret 共通表示
  （Transform と Navigator が共有）。Compose だけ DiffView。
- **ActionCard** — 承認して送信/コピー・編集する、の2ボタン規約。
- **CopilotStrip** — 右下帯（既存 `CopilotStripView` を移植）。
- **StatusBadge / Toast** — モデルID・処理時間・deploy 完了・モードバッジ。

`ReviewPanelView`（1,058行）はモードごとのファイルに分割し、`RootPanelView` は
`switch coordinator.mode` だけの薄いルーターにする。

---

## 7. 移行計画（strangler 方式・実機検証駆動）

原則: 1フェーズ = 1ブランチ = 実機確認。**挙動を変えるフェーズと変えないフェーズを混ぜない**。
`BombSquad` 名前空間のリネームは引き続きやらない（M5 方針のまま）。

### R0: セーフティネット（半日）

ステータス: 完了（2026-07-07、`feature/foundation-redesign`。[manual-golden-paths.md](manual-golden-paths.md)）

- 5モード × 主要ジェスチャ × 出口の**手動ゴールデンパス表**を
  `docs/manual-golden-paths.md` として作る（20〜30項目。README の操作仕様から機械的に
  起こせる。「モード遷移で下書きを失わない」も項目に含める）。以後の各フェーズは
  この表の全項目を実機確認して閉じる。
- `ReviewViewModel` の状態遷移に関わる既知バグ・対症療法（isCopilotActive ガード等)の一覧化。

### R1: 状態機械の導入（挙動不変のリファクタ・2段階）

ステータス: R1-a 実装済み・ビルド成功（2026-07-07、`feature/foundation-redesign`）。
**ゴールデンパス表 A〜D（+ E の入口/出口）の実機確認待ち**。実装メモ:
- `Session/` に AppMode / SessionSupport（SessionLifecycle・DictationTarget・SessionMemory）/
  ComposeSession / TransformSession / SessionCoordinator を新設。
- Vision/Navigator/Copilot は `AppMode.legacyVision(ReviewViewModel)` ブリッジで旧実装のまま
  動く（compose との往復は `onExitVisionToCompose` ハンドオフ + パネル寿命の `PanelContext`
  （deployer / L1 タスク）共有で実現）。R1-b でセッション化して ReviewViewModel を削除する。
- ビューは RootPanelView（ルーター）/ ComposeContentView / TransformContentView に分割。
  ContentView.swift は削除、VisionPanelView / VisionInterpretationView は独自ファイルへ移動。
- AppDelegate はライフサイクル・ウィンドウ機構・キャプチャオーバーレイ（R1-b で移す）のみ。
- 意図的変更は 2 点のみ: transform 中の音声入力を無効化（golden-paths C5）、
  キャプチャキャンセル後のレビュー結果保持は `.capturing(resume:)` が担う。
- project.yml に共有スキームを追加（xcodegen 再生成で CLI ビルドのスキームが消える問題）。

- `AppMode` / `SessionCoordinator` / `SessionLifecycle` を新設し、`ReviewViewModel` を解体・移植。
  4 セッション一斉ではなく**理解の深い順に 2 段で移す**:
  - **R1-a**: Compose / Transform（挙動が最も枯れている2つ）。Coordinator ↔ PanelController の
    ループをここで確立する。Navigator/Copilot は旧経路のまま並走。
  - **R1-b**: Navigator / Capturing / Copilot。遷移引き継ぎ（Navigator → Copilot）と
    `willEnd()` によるモニタ・ストリーム後始末もここで移植。
- `AppDelegate` はライフサイクル＋オブジェクト生成だけに縮小（目標 150 行以下）。
- ジェスチャ遷移表を README の仕様どおりに実装。**この段階では意図的にバグも移植する**
  （挙動が変わらないことが検証条件）。

### R2: 配線の刷新（構造が可能にする修正）
- NotificationCenter 全廃 → PanelController + PanelSpec。
- ここで初めて既知バグを直す: 管理ウィンドウ前面化、transform 暗黙突入の可視化強化、
  そして**1セッション1アクション制約の解除**（パネル復帰問題は activate 作法の一元化で
  再挑戦できる。だめでも copilot 経路が既に迂回路）。

### R3: API 層の統合
- クライアント `GatewayClient` 一本化・`EngineResolver` 集約。
- サーバー interpret エンジン統合（vision/navigate/transform）。api-contract.md 更新。
- 挙動互換を保つため、旧エンドポイントは互換レイヤとして残して段階削除。

### R4: 事業要件の実装
- `bs_harness_packs`（シード= 現 harness.ts）＋ Gateway の DB 読み込み。
- Entitlements の operation ゲート＋ `/api/account` へ features 追加＋クライアント表示ゲート。
- Admin v0（既存設計のまま）→ v1 でパック管理・プラン設定・ロール昇格。
- Stripe 課金（M3 残タスク）はこのフェーズの entitlements と同時に接続するのが最小工数。

### 見積もりの目安
R0+R1 が本丸で全体の半分。R2 以降は独立性が高く、事業都合（ベータフィードバック・営業）で
順序を入れ替えられる。R1 完了時点で「機能追加のたびに全分岐を手当てする」状態は終わる。

---

## 8. 検討して却下した代替案

- **8-a. TCA（The Composable Architecture）等の状態管理ライブラリ**: 状態機械駆動のアプリには
  定番だが、重い外部依存・ボイラープレート・実行時オーバーヘッドが軽快さ最優先の原則に反する。
  素の Swift enum + ObservableObject で同じ排他性が得られる。
- **8-b. Session Registry（セッションを破棄せず温存する）**: 「Compose → 撮影 → Compose で
  下書きを失わない」ための案だが、非アクティブなセッションが生きたままタスク・モニタ・状態を
  持ち続ける構造は、今回排除する病理（複数箇所に分散した生きた状態）の再導入になる。
  enum の排他性（同時に1つしか存在しない）はコンパイラ保証の要であり崩さない。
  下書きの継続性は既存の `ComposeDraftStore`（永続化＋復元）で既に満たされている——
  排他は enum、継続性は永続化、で分離して解く（§4-b）。
- **8-c. サーバー側プロンプトまで含めた完全統合**: §5-a の境界線のとおり、輸送・スキーマ・
  ハーネス選択は統合するが、intent 別プロンプトの分離は維持する。1コールに複数の仕事を
  同時に任せない（ナビゲーター計画 §0 の教訓）。

## 9. 設計原則（判断に迷ったらここへ戻る）

1. **モードと計画はデータ、LLM は目と口**（navigator-copilot-plan §1 の全体適用）。
2. **クライアントはセンサー&アクチュエータ**。知能・プロンプト・パック・プラン判定はサーバー。
3. **軽快さ・堅牢さが最大プライオリティ**。常駐監視・往復増・重い抽象化は入れない。
4. **承認駆動**。自動実行はしない（北極星 §1.2）。
5. **ゼロ・インテグレーション**。ハーネス/パックは非可視の自動アドオン。ユーザーにモードを選ばせない。
6. **強制はサーバー、表示はクライアント**（プラン制限・クォータ）。
7. **仕様＝遷移表**。ジェスチャの多義性は表で1箇所に書き、README と一対一を保つ。
