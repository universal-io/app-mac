# Foundation Rebuild Plan（シャーシ交換）

最終更新: 2026-07-13
ステータス: Phase 3 完了・Phase 4 進行中

このドキュメントは macOS アプリの基盤作り直しの**正本**である。
旧計画 `foundation-redesign-plan.md`（ビッグバン方式、`backup/foundation-bigbang-broken-bc1070e`
にのみ存在）はクローズ。web/Gateway 側の成果（R3/R4）は本番稼働中のためそのまま採用する。

## 1. 経緯と診断（なぜビッグバンが失敗したか）

- 2026-07 上旬、R0〜R4 のビッグバンリファクタリングを実施 → macOS アプリが壊れ、
  安定版 `580a211` へ巻き戻して安定化したのが現在の `feature/foundation-redesign`。
- 失敗したのは**設計ではなく移行戦略**:
  1. 生きているアプリの中枢（状態管理・パネル制御・VM）を一度に全部差し替えた。
  2. R0 の成果物（手動検証手順書）が実際には作られておらず、壊れた箇所を検知できなかった。
- このアプリの資産は**プラットフォーム知見が染み込んだ末端サービス群**
  （ShiftGestureMonitor / PasteDeployer + ClipboardBackup / SelectionGrabber /
  ScreenshotCaptureService / 署名・TCC / 認証 / 配布パイプライン）。これらは壊れていない。
  問題は中枢 3 ファイルに集中している:
  - `ReviewViewModel.swift` 約1,570行（compose/transform/vision/navigator/copilot/履歴/蒸留/deploy が同居）
  - `AppDelegate.swift` 約780行
  - `ReviewPanelView.swift` 約1,080行

## 2. 世代の整理（2026-07-12 時点の事実）

| レイヤー | 状態 |
|---|---|
| 本番 Gateway（Vercel、`origin/main` = ビッグバン先端 `bc1070e`） | **新世代**（plans.ts / entitlements / admin console / harness packs）で正常稼働 |
| 本番 Supabase | **新世代**（migration 0003/0004 適用済み。`bs_plans` が正本、`bs_entitlements.plan` は FK） |
| 本ブランチの `web/` `supabase/` | main から port 済み（`42c644e`）。**Gateway 側の作り直しは不要** |
| 本ブランチの macOS アプリ | 巻き戻し＋安定化世代。部分的な芽（`TextPanelSession` / `RootPanelView` / `AppCommandCenter` / `SessionTrace`）あり |

⚠️ `origin/main` にはビッグバンの**アプリ側の壊れたコード**も含まれる。main への次のマージは
本ブランチの完成後に行い、アプリ側は本ブランチが main を上書きする（web 側は同一になっている）。

## 3. 方針: シャーシ交換

> 中枢はゼロから新規に書く。実証済みの末端サービスは無傷で移植する。
> 旧アプリはパリティ達成まで起動可能なまま残し、最後にエントリポイントを切り替える。

原則:
- **新中枢のファイルは旧中枢（ReviewViewModel / 旧 AppDelegate 経路）を import しない**。
  末端サービス（Services/ の葉）への依存のみ許す。
- 1 フェーズ = 1 コミット列。フェーズ末に必ず `xcodebuild` 成功＋
  [manual-golden-paths.md](manual-golden-paths.md) の該当シナリオを実機で通す。
- 旧経路はパリティ切替（Phase 4）まで削除しない。切替はエントリポイント 1 箇所で戻せる形にする。
- スコープ外の機能追加はしない（品質チューニングは
  [navigator-stabilization-followups.md](navigator-stabilization-followups.md) を起点に再開）。

**移植規律（2026-07-13 追加。Phase 3-c で「Vision one-shot と Navigator 初期準備の並行起動」
という旧経路に無い挙動を発明した結果、スピナー残留・フォーカス喪失・空パネル残留の競合バグが
発生した教訓のルール化）:**
1. **忠実移植の原則**: Phase 3 の間は挙動の変更・最適化・先回り（プリウォーム等）を一切禁止。
   旧経路の挙動を 1:1 で写すだけ。改善のアイデアは
   [navigator-stabilization-followups.md](navigator-stabilization-followups.md) に書いて
   Phase 4 パリティ達成後に別トラックでやる。
2. **モード完了ゲート**: 1 モード = 実装 → フラグ OFF/ON の A/B 実機比較 → 差分ゼロ →
   **コミット** → 次のモードへ。検証とコミットの先送り禁止（未コミットの複数モード同時進行は
   ミニ・ビッグバン）。
3. **非同期の世代ガード**: セッション内の async 完了ハンドラは、状態を書く前に必ず
   「自分のセッション／世代がまだ現行か」を確認する（`captureGeneration` と同じパターンを
   全 async に義務付け）。1 つのペインに書けるオーナーは常に 1 つ。
4. **teardown の完全性**: close は進行中 Task のキャンセル・セッション破棄・世代無効化まで
   やり切る。「次の召喚で前セッションの残骸が見える」は teardown バグ（GP-27 で検証）。
5. **バグ修正の第一手は旧経路の読解**: 新経路の挙動差を直すときは、まず旧コードの該当制御を
   引用してから着手する。症状だけ消す修正は禁止。
6. **Phase 3 の仕様の正は「フラグ OFF の旧コードの挙動」ただ一つ**（2026-07-13 追加）。
   README・master-plan の Vision 記述は **M4 世代のまま**で、Navigator 有効時の現挙動と異なる
   （旧コードの正: [`ReviewViewModel.enterVisionMode`](../BombSquad/ViewModels/ReviewViewModel.swift) —
   キャプチャ直後、Navigator 利用可なら **Navigator セッションを即開始**（auto first turn は
   `AppSettings.isNavigatorAutoFirstTurnEnabled()` に従い「軽い現状認識」を返す）。
   `/api/ai/vision` のフル解釈（状況→求められていること→提案アクション）は
   **Navigator 利用不可時のフォールバックのみ**）。ドキュメントを仕様として移植した結果、
   M4 世代の挙動が「亡霊」として復活する事故が Phase 3-c で実際に起きた（下記）。

**2026-07-13 の回帰と修正**: 新経路は一時、キャプチャ直後に常に one-shot vision 解釈を実行し、
Navigator は質問時にのみ起動する実装になっていた。これは旧挙動と逆
（旧: Navigator 優先・vision はフォールバック）で、(a) 初回解析が「軽い現状認識」でなく
フル解釈＋提案アクションになる、(b) 初回ターンのハイライト/ズームが出ない（vision 解釈には
grounding が無い）、(c) 案内の正確性低下（存在しない「国」ディメンションを案内する等）の原因になった。
修正方針は **キャプチャ後のエントリを旧と同じ分岐に戻す** こと
（Navigator 利用可 → `prepareNavigatorCapture(autoRun: isNavigatorAutoFirstTurnEnabled())`
相当を即実行、one-shot vision は Navigator 不可時のみ）。以前の「同時起動」不安定化は両方を
走らせたのが原因であり、正しい解消は「vision 側を残す」でなく「Navigator 側だけを残す」だった。

補強ルール（2026-07-12 追加）:
- **モード移植は「画面1枚」単位ではなく「挙動契約」単位で完了判定する**。
  例: Vision/Navigator は「説明表示」「初回質問」「panel highlight」「live highlight」
  「approve action」「Copilot 移行」「hold-to-talk」までを 1 契約として扱う。
- 各 Phase 3 サブ段は、実装前に **旧経路の所有挙動を列挙**し、実装後に
  **新経路の所有先へ 1:1 で対応付ける**。移植中に意図的に落とす挙動がある場合は、
  「未実装」ではなく **明示的な deferred 項目**としてこの文書に残す。
- `xcodebuild` 成功は「配線が通った」ことしか意味しない。**ビルド成功だけでは段完了にしない**。
  Phase 3 の「実装・ビルド済み」は「構造移植完了」の意味に限定し、
  体験パリティの完了は golden paths と実機差分確認でのみ宣言する。
- cross-cutting な挙動（focus / dictation / highlight / target-app capture / panel close など）は
  モードごとのローカル実装に閉じず、**移植時に横断チェック項目として毎回照合**する。

## 4. フェーズ

### Phase 0: 検証ハーネス（完了 2026-07-12）
- [x] `docs/manual-golden-paths.md` — 全機能の手動検証シナリオ（GP-01〜26）。
      **これが無い状態で中枢に触れることを禁止**（前回の失敗の直接原因）。
- [x] 現行アプリでシナリオを実施し、ベースラインを確認（2026-07-12 オーナー実機確認: 問題なし）。

### Phase 1: 新中枢の骨格
ステータス: **完了**（2026-07-12 実装・ビルド成功・オーナー実機確認済み:
フラグ ON でシェルパネルの召喚・遷移・クローズが動作、フラグ OFF で従来動作に変化なし）
- [x] `AppMode` 単一状態機械 — [`Core/AppMode.swift`](../BombSquad/Core/AppMode.swift)
      （遷移表 `canTransition(to:)` ＋ `AppStateMachine`。全遷移が `transition(to:reason:)` を通る。
      不正遷移は DEBUG で assert。旧コードの散在フラグには触れていない＝新経路のみ）。
- [x] `SessionCoordinator` — [`Core/SessionCoordinator.swift`](../BombSquad/Core/SessionCoordinator.swift)
      （`AppEvent` → 遷移の唯一の場所。singleTap / 長押し（ASR）は Phase 3 でセッションと共に実装。
      summon の選択分岐は Phase 3-b で新経路へ移植済み）。
- [x] `PanelController` + `PanelSpec` — [`Core/PanelController.swift`](../BombSquad/Core/PanelController.swift)
      （サイズ・配置・activate を mode の純関数 `PanelSpec.forMode` に集約。
      resignActive で閉じるか＝copilot 例外も spec の `closesOnResignActive` に一元化）。
- [x] 起動フラグ — UserDefaults `core.foundation.enabled`（既定 OFF）。
      `defaults write com.universal-io.mac core.foundation.enabled -bool YES` で新経路、
      AppDelegate の分岐は入力配線1箇所のみで旧経路コードは不変。
- 付随修正: `project.yml` に shared scheme 生成を追加（`xcodegen generate` 直後の
  `xcodebuild -scheme` が SPM 解決込みで通るように。従来はユーザースキーム依存だった）。

### Phase 2: GatewayClient 統一
ステータス: **完了**（2026-07-12 実装・ビルド成功、オーナー実機確認済み。
Gateway を通る golden paths = GP-03/04・GP-10・GP-14〜19・GP-22/23 に問題なし）
- [x] `GatewayClient` コア 1 実装 — [`Core/GatewayClient.swift`](../BombSquad/Core/GatewayClient.swift)
      （可用性ゲート・エンベロープ・JSON/multipart 送信・transport/status/エラー契約の変換・
      SSE フレーミング・context/memory ペイロードを一元化）。
- [x] 8 消費者を薄いラッパー化: Review / Vision / Transcribe / Account / Navigate ＋
      MemoryDistiller / MemorySyncService（計画時の 6 に加えメモリ系 2 つも同パターンだったため含めた）。
      公開 API は不変＝呼び出し側の変更ゼロ。正味 -200 行、SSE 解析の重複 2 → 1。
- 意図的な軽微変更: MemoryDistiller / MemorySyncService の transport エラーが他クライアントと
  同じ `ProviderError.http(-1)` 形式に統一された（従来は生 URLError。ログ文言のみの差）。

### Phase 3: モード移植（1 モードずつ、各段で golden paths）
ステータス: **完了**（2026-07-13 オーナー確認ベースで compose / transform / vision / navigator /
copilot の主要導線を新経路へ移植し、実機で見つかった回帰も順次修正済み。Phase 4 で
GP-03〜19 を新経路の正式パリティ確認として通す）

順序: 依存が少なく検証しやすい順。各モードは「小さなセッション VM ＋薄い View」として新規に書き、
末端サービスはそのまま挿す。
- [x] 3-a compose（レビュー・SSE・deploy・履歴・ASR 挿入）— 完了。
      [`Core/ComposeSession.swift`](../BombSquad/Core/ComposeSession.swift) が compose 状態と操作を所有し、
      [`Core/ComposeSessionView.swift`](../BombSquad/Core/ComposeSessionView.swift) はその状態を描画する薄い View。
      旧 `ReviewViewModel` / `PanelSession` への依存なし。旧経路と同じ draft 永続化キー・末端サービス
      （GatewayReviewClient / PasteDeployer / LocalHistoryStore / AudioRecorder / Transcriber）を再利用。
      オーナー実機確認は 3-b と束ねて GP-03〜10 を後段で確認する。
- [x] 3-b transform（受信整理。出口はコピーのみ）— 完了。
      [`Core/TransformSession.swift`](../BombSquad/Core/TransformSession.swift) が選択テキスト→解釈→コピーの
      receiving-side state を所有し、[`Core/TransformSessionView.swift`](../BombSquad/Core/TransformSessionView.swift)
      が read-only source + interpretation result を描画する薄い View。
      `SessionCoordinator` の summon 分岐も新経路へ移植済み（右Shift 2回のみ selection-aware。
      `⌘J` と hold-to-talk 起動は従来どおり compose 固定）。オーナー実機確認は GP-11/12 を後段で確認する。
- [x] 3-c vision（選択オーバーレイ→解釈→提案アクション）— 完了。
      [`Core/VisionSession.swift`](../BombSquad/Core/VisionSession.swift) が screenshot attachment →
      interpretation → action hand-off を所有し、[`Core/VisionSessionView.swift`](../BombSquad/Core/VisionSessionView.swift)
      が screenshot preview + interpretation result の 2-pane UI を描画する薄い View。
      `SessionCoordinator` は compose の空 draft から `capturing(returnTo: .compose)` へ遷移し、
      [`Views/ScreenshotSelectionOverlay.swift`](../BombSquad/Views/ScreenshotSelectionOverlay.swift) と
      [`Services/ScreenshotCaptureService.swift`](../BombSquad/Services/ScreenshotCaptureService.swift) を使って
      full-screen / region capture を実行、Esc で compose に戻り、右Shift 2回でセッション破棄。
- [x] 3-d navigator / copilot（マルチターン・ハイライト・タスクプラン・コーナーストリップ）— 完了。
      `VisionSession` が one-shot vision に加えて Navigator/Copilot の transcript・highlight・task proposal・
      progress recapture・approved AX action を所有し、`FoundationVisionRootView` は mode に応じて
      full panel / corner strip を描画する。最初の質問で `.vision -> .navigator`、案内開始で
      `.navigator -> .copilot`、完了で `.copilot -> .navigator` を `SessionCoordinator` 経由で遷移する。
      hold-to-talk は `.vision` / `.navigator` / `.copilot` の質問欄に接続済み。2026-07-12 の実機確認で見つかった
      回帰（質問開始で one-shot 説明が消える / vision 質問欄で音声入力できない / 実行時の対象 app 解決が
      L1 context 欠落に弱い）は同日フォローアップで修正済み。live highlight はスクロールやクリック後に
      stale な位置へ残らないよう、ユーザー操作で自動 dismiss する。2026-07-13 の回帰修正として、
      Foundation 経路の入口分岐を旧経路に合わせ、Navigator 利用可なら capture 直後に
      `prepareNavigatorCapture(autoRun: isNavigatorAutoFirstTurnEnabled())` 相当を即実行し、
      one-shot vision は Navigator 不可時のフォールバックに戻した。オーナー実機確認は
      GP-17〜19 を後段で確認する。
- [x] 3-e 横断: L1 コンテクストチップ、出力言語、メモリ注入・蒸留、管理ウィンドウ連携
      L1 コンテクストチップ / 出力言語 / メモリ注入・蒸留は新セッション群へ移植済み。
      2026-07-13 時点で Compose / Transform / Vision / Copilot strip から account / settings /
      history / memory / pricing を開く管理メニューを追加。Phase 4 では残る横断差分が無いことを
      golden paths と実機差分確認で最終確認する。

### Phase 4: パリティ切替と旧中枢の削除
ステータス: **進行中**（2026-07-13 静的パリティ監査を開始）
- [x] 旧 compose の明示的なカメラボタン経路を新中枢へ移植。
      `AppCommandCenter.onScreenshotCaptureRequested` がフラグ ON でも旧
      `AppDelegate.startScreenshotCapture()` へ直結され、新 Compose UI にボタン自体が
      無かった差分を修正。ボタンからも `SessionCoordinator` の同じ capture 経路へ入る。
- [ ] golden paths 全シナリオを新経路で通す（ベースラインと比較）
- [ ] エントリポイントを新経路に固定、旧 `ReviewViewModel` / 旧パネル経路 / 移行フラグを削除
- [ ] `ReviewPanelView.swift` の残骸整理（コンポーネント分割の仕上げ）
- [ ] 旧 transform 表示・`transformSystem` プロンプト等の未使用コード掃除（M4-B の積み残し）

### Phase 5: クローズ
- [ ] README を新アーキテクチャに合わせて書き直す
- [ ] このドキュメントのチェックボックスを全て埋め、ステータスを完了にする
- [x] `foundation-recovery-handoff.md` をアーカイブ扱いにする（2026-07-12 `docs/old/` へ移動済み）
- [ ] main へマージ（web は同一なので本番 Gateway に影響なし）

## 5. 旧計画からの引き継ぎ対応表

| 旧計画 | 本計画での扱い |
|---|---|
| R0 golden paths | Phase 0（今度こそ最初に作る） |
| R1 AppMode / セッション分割 | Phase 1 + 3（新規実装） |
| R2 PanelSpec + PanelController | Phase 1（新規実装） |
| R3 GatewayClient 統一 + EngineResolver | Phase 2（クライアント側）。サーバー側エンジン統合はスコープ外のまま |
| R4 harness packs / plans / admin console | **完了**（本番稼働中、web port 済み） |
| 1セッション1アクション制約の解除 | Phase 4 後の再挑戦候補（PanelController の activate 一元化が前提） |

## 6. このドキュメントの運用

- フェーズ開始時にステータスを追記、完了時にチェックボックスを埋める。
- 方針変更は該当セクションを書き換える（経緯は git 履歴が持つ）。
- 旧計画 `foundation-redesign-plan.md` は参照が必要な場合
  `git show backup/foundation-bigbang-broken-bc1070e:docs/foundation-redesign-plan.md` で読む。
