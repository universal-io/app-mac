# Foundation Rebuild Plan（シャーシ交換）

最終更新: 2026-07-12
ステータス: 承認済み（オーナー決定 2026-07-12）・Phase 0 から着手

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

## 4. フェーズ

### Phase 0: 検証ハーネス（着手済み）
- [ ] `docs/manual-golden-paths.md` — 全機能の手動検証シナリオ（15〜25件、ID 付き）。
      **これが無い状態で中枢に触れることを禁止**（前回の失敗の直接原因）。
- [ ] 現行アプリで全シナリオを一度実施し、ベースライン結果を記録する
      （既知バグはバグとして記録し、期待値に混ぜない）。

### Phase 1: 新中枢の骨格
新規ディレクトリ `BombSquad/Core/` に、旧計画の設計を継承して新規実装:
- [ ] `AppMode` 単一状態機械（idle / compose / transform / vision(capturing) / navigator / copilot）。
      遷移は明示メソッドのみ。`ReviewMode` / `InputSessionKind` / `navigatorSessionActive` /
      `isCopilotActive` の散在フラグをここに一元化する（旧コードは触らず、新経路のみ）。
- [ ] `SessionCoordinator` — ジェスチャイベント（右Shift 1回/2回/長押し・⌘J・Enter/esc）を
      AppMode 遷移に変換する唯一の場所。
- [ ] `PanelController` + `PanelSpec` — 窓の形（サイズ・位置・activate・キー扱い）を
      mode の純関数として 1 箇所に集約。`handleResignActive` の閉じ判定もここへ。
- [ ] 起動フラグ（開発者向け UserDefaults）で新旧エントリポイントを切替可能にする。

### Phase 2: GatewayClient 統一
- [ ] `GatewayClient` コア 1 実装（認証ヘッダ・SSE・エラー変換・フォールバック判定）。
      既存 6 クライアント（Review/Vision/Transcribe/Account/Navigate/API）を薄いラッパー化。
      これは新旧両経路から使えるため先行して差し替えてよい（挙動不変の置換）。

### Phase 3: モード移植（1 モードずつ、各段で golden paths）
順序: 依存が少なく検証しやすい順。各モードは「小さなセッション VM ＋薄い View」として新規に書き、
末端サービスはそのまま挿す。
- [ ] 3-a compose（レビュー・SSE・deploy・履歴・ASR 挿入）
- [ ] 3-b transform(受信整理。出口はコピーのみ)
- [ ] 3-c vision（選択オーバーレイ→解釈→提案アクション）
- [ ] 3-d navigator / copilot（マルチターン・ハイライト・タスクプラン・コーナーストリップ）
- [ ] 3-e 横断: L1 コンテクストチップ、出力言語、メモリ注入・蒸留、管理ウィンドウ連携

### Phase 4: パリティ切替と旧中枢の削除
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
