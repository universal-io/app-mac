# 起動確実性と公開品質（R11）

最終更新: 2026-08-03 ／ ステータス: 計画確定・未着手

進捗と受け入れ条件の正本は[マスタープラン R11](universal-io-master-plan.md)、
本書は原因分析・目標構造・マイルストーンの正本とする。

## 0. なぜ

2026-08-03、約38時間連続稼働したアプリでVisionが「スピナーも出ない・画面画像も出ない・
エラーも出ない」空のパネルになった。アプリを再起動すると回復した。

**「再起動してください」は回避策ではない。** 顧客一人ひとりに案内して回れないものは、
公開版の品質基準を満たさない。本プロジェクトはこの一件を単発の不具合として塞ぐのではなく、
同じ形の障害（無音で止まり、原因も分からない）を構造的に起こせなくすることを目的とする。

`0.2.2` build `6`はversionを上げただけで、署名・notarization・公開をまだ行っていない
（公開済みの最新は`v0.2.1` build `5`）。**R11の完了を`0.2.2`公開の前提条件とする。**
R10／R10.5の成果を先に出してから直すのではなく、この状態のまま公開しない。

## 1. 確定した事実

同一プロセス（PID 48311、稼働約38時間）・同一ビルド・同一画面（Chrome）で、24分違いの
2回が別物になった。unified logの実測。

**13:48（正常）**

```text
13:48:42.611 coordinator.event mode=idle event=doubleTap
13:48:43.567 state.transition mode=vision from=capturing reason=captureCompleted
13:48:45.4   POST https://api.universal-io.com/api/ai/vision   ← 発行された
13:48:51.651 [Vision] turn=first gatewayRoundTrip=7342ms      ← 完走
```

**14:12（障害）**

```text
14:12:21.768 state.transition mode=vision from=capturing reason=captureCompleted
14:12:21.908 Vision AX collection pass=1 visited=606 candidates=106 webArea=1
14:12:22.618 Vision AX collection pass=2
（30秒間、何も無い）
14:12:52.496 state.transition mode=idle from=vision reason=resignActive
```

14:12のセッションでは次を確認した。

- `api.universal-io.com`・`supabase.co`・CFNetworkタスクの記録が**1件も無い**
  （14:12:20〜14:12:55の全ログを対象に確認）。リクエストは発行されていない。
- `[Vision]` 完走トレースも失敗トレース（`failed after ...`）も無い。つまり例外でもない。
- AX収集は正常に完了している（`reason=complete`）。これはコーディネーター側が起動するため、
  パネルの描画とは独立に動く。
- 画面画像は表示されず、スピナーも表示されず、エラーバナーも出ていない。
- プロセスのRSSは44MBで、暴走的なメモリリークの兆候は無い。

同時刻のプロバイダ側は健全である。本番と同一のリクエスト形状（同じschema、
`reasoning_effort: none`、`max_tokens: 25000`）で実画面サイズ2560×1600の画像を直接投げ、
一次Cerebras `gemma-4-31b`が985ms／HTTP 200、二次OpenAI `gpt-5.4-mini`が3006ms／HTTP 200で
応答した。**Gateway・モデル・ネットワークはこの障害の原因ではない。**

## 2. 根本原因

Visionの初回リクエストとスクリーンショット表示は、どちらもSwiftUIの
appearance callback 1点だけを引き金にしている。

| 引き金 | 位置 | 発火しないと失われるもの |
|---|---|---|
| `.task { session.startIfNeeded() }` | `BombSquad/Core/VisionSessionView.swift:34` | 初回リクエスト（`isLoading`も立たないのでスピナーも出ない） |
| `.onAppear { loadImage() }` | `BombSquad/Views/ZoomableScreenshotView.swift:87` | 画面画像の読み込み |

観測された症状は、この2つがどちらも発火しなかった状態と正確に一致する。パネルの外枠、
ヘッダー、入力欄のキャレットは描画されていたので、描画そのものは生きていた。

`BombSquad/Core/PanelController.swift:69` は召喚のたびに
`panel.contentViewController = NSHostingController(rootView: content)` で
ホスティングコントローラーを差し替える。Visionの経路は必ず
`idle → capturing`（`panelController.hide()` = `orderOut`）`→ vision`（`present()`）を通るため、
**ウインドウが画面外に置かれた状態で新しいホスティングコントローラーを差し込み、その後に
再表示する**。この差し替えがappearance transitionを伴わない状態が、長時間稼働後に発生した。

差し替えが劣化する物理的な機序（AppKit側の状態、蓄積したホスティングビュー、
ウインドウサーバとの整合）はまだ特定していない。**特定を待たない。** 機序が何であれ、
UIフレームワークの描画都合がリクエスト発行の必要条件になっている構造そのものが欠陥である。

Composeは同じ形をしていない。`BombSquad/Core/ComposeSessionView.swift:62` の `.onAppear` は
フォーカスと展開状態だけを扱い、AI処理（先読みcapture、先回り文案）はコーディネーターが
所有している（`presentComposeSession`）。**正しい形の前例はすでにリポジトリの中にある。**
Visionだけが例外である。

## 3. 不変条件

R11では次を不変条件とする。

> **セッションが開始したかどうかは、UIの描画都合に依存してはならない。**
> パネルの表示はコーディネーターの決定の結果であり、リクエスト開始の条件ではない。

> **どの操作も無音で終わらない。** 有限時間で必ず、結果か、原因を述べるエラーのどちらかに
> 到達する。「押したのに何も起きない」を到達可能な状態として残さない。

## 4. マイルストーン

各マイルストーンはコミット境界とする。受け入れ条件を満たさないものは次へ進めない。

- **D0（計画）** 本書、[ドキュメント索引](README.md)、マスタープランR11を同じコミットで確定する。
  受け入れ条件: 原因分析が実測ログとコード位置で裏付けられ、D1〜D7の受け入れ条件が
  検証可能な文で書かれている。

- **D1（診断の常設化）** 現在の`CoreTrace`／`VisionTrace`は`#if DEBUG`のNSLogだけで、
  公開版では何も残らない。`os_log`のsubsystemへ移し、release buildでも
  「セッション開始・リクエスト発行直前・完了・失敗」を必ず記録する。
  記録するのは機能名、経過ミリ秒、成否、理由コードだけとし、本文・回答・画像・
  ウインドウタイトル・ホスト名は**載せない**（README「データ保存」の境界を動かさない）。
  受け入れ条件: 署名付きrelease buildで同じ障害が起きた時、ログだけで
  「開始しなかった」と「開始したが応答しなかった」を切り分けられる。

- **D2（開始をコーディネーターが所有）** `handleVisionCaptureCompletion`でセッションを
  生成した直後に開始する。`startIfNeeded()`は`hasStarted`で冪等なので、ビュー側の`.task`は
  残っていても二重送信にならない。
  受け入れ条件: `.task`を取り除いた状態でも初回リクエストが発行されることを、
  ビューを介さないunit testで固定する。

- **D3（画像読み込みの非依存化）** スクリーンショット表示を`.onAppear`から切り離す。
  受け入れ条件: appearance callbackを呼ばずに画像が解決されることをtestで固定する。
  Visionパネル内でユーザーが見る情報のうち、appearance callbackだけを引き金にするものを
  ゼロにする。

- **D4（パネル表示の作り直し）** 召喚ごとの`contentViewController`差し替えをやめ、
  パネルの寿命に対してホスティングコントローラーを1つとし、root viewが
  コーディネーターの状態（mode、現在のsession）を観測して切り替わる構成にする。
  受け入れ条件: 召喚と解放を連続で繰り返した後に、生存しているホスティング
  コントローラーとNSWindowの数が増えない。再現は短命ブランチの計測ハーネスで行い、
  終了時に削除する（常設の代替経路を作らない）。

- **D5（期限とウォッチドッグ）** 現状タイムアウトはクライアント・サーバのどちらにも存在しない
  （`timeoutInterval`／`maxDuration`ともに0件）。次を入れる。
  - Vision 1ターンの全体期限。超過で「画面の読み取りが時間内に完了しませんでした」を表示する。
  - `BombSquadAuthClient.accessToken()`（`client.auth.session`）の期限。ここは現在無期限に
    awaitし、失敗するとネットワークログさえ残らない唯一の箇所である。
  - Gateway側の`fetch`2箇所（`web/lib/server/vision-engine.ts:111`、`:165`）へ
    `AbortSignal.timeout`、routeへ`maxDuration`。
  - `mode=vision`へ遷移してから一定時間内にリクエストが発行されなければ、
    コーディネーターが開始を再試行し、それでも駄目なら可視エラーにする。
  受け入れ条件: 一次モデルが「エラーを返さず無応答」の場合に二次モデルへ落ちること。
  現在の`runWithModelFallback`は一次が**例外を投げた時だけ**二次へ進むため、
  READMEの二段構えはハング時に成立していない。

- **D6（無音失敗の撤去）** `BombSquad/Core/VisionSession.swift:340` の
  `catch is CancellationError { return }` は、ユーザーが閉じた場合と内部都合で
  取り消された場合を区別せず結果を捨てる。両者を分け、後者は理由を表示する。
  `SessionCoordinator.close()` は`stateMachine.transition(to: .idle)`の戻り値を捨てており、
  遷移が拒否されてもteardownが走る。拒否時はteardownしない
  （画像削除とリクエスト取消だけが実行され、パネルだけが残る＝今回見た抜け殻状態を作る経路）。
  受け入れ条件: 遷移拒否時にセッションが生存していることをtestで固定する。

- **D7（長時間稼働の受け入れ試験）** 24時間以上連続稼働させた後にCompose、Vision、Copilot、
  音声入力のgolden pathを通す項目を[manual-golden-paths.md](manual-golden-paths.md)へ追加する。
  受け入れ条件: リリース前チェックとして実施され、結果が記録される。これが
  「再起動してください」を顧客へ案内しないための最後の防波堤である。

## 5. 技術的負債の棚卸し

D0時点の実測に基づく。「扱い」がD番号のものは本プロジェクトで解消し、
それ以外は残す理由を明記する。

| # | 項目 | 位置 | 影響 | 扱い |
|---|---|---|---|---|
| 1 | セッション開始が`.task`単点依存 | `VisionSessionView.swift:34` | 今回の障害の直接原因 | D2 |
| 2 | 画像読み込みが`.onAppear`依存 | `ZoomableScreenshotView.swift:87` | 画面が空になる | D3 |
| 3 | タイムアウトが皆無 | クライアント全体・`vision-engine.ts` | 止まったのか遅いのか区別できない | D5 |
| 4 | `accessToken()`が無期限await | `BombSquadAuthClient.swift:197` | 痕跡ゼロで永久停止し得る | D5 |
| 5 | fallbackが例外時のみ | `ai-routing.ts:101` | 一次ハング時に二次へ落ちない | D5 |
| 6 | `maxDuration`未設定 | `web/app/api/ai/*` | 直列2コールに予算が無い | D5 |
| 7 | 診断がDEBUG限定 | `VisionSession.swift:603`、`CoreTrace` | 公開版で原因が分からない | D1 |
| 8 | `close()`が遷移結果を無視 | `SessionCoordinator.swift:374` | 抜け殻パネルを作り得る | D6 |
| 9 | CancellationErrorの無音return | `VisionSession.swift:340` | 完了した回答を黙って捨てる | D6 |
| 10 | ホスティングコントローラー毎回差し替え | `PanelController.swift:69` | 劣化源として最有力 | D4 |
| 11 | ライフサイクルのtestがゼロ | `BombSquadTests/`（41件） | パネル・セッション寿命が未検証 | D2〜D4で追加 |
| 12 | 3MB超画像のJPEG再圧縮が1回のみ | `GatewayVisionClient.swift:152` | 高解像度で4.5MB制限を超え得る | D5で実測して判断 |
| 13 | AX messaging timeoutの実効範囲が未検証 | `VisionObservationCaptureService.swift:285` | 子要素へ継承されるか未確認 | D5で実測 |

## 6. 検証

各マイルストーンで次を通す。

- macOS unit test（現行41件＋D2〜D4、D6の追加分）
- 署名なしDebug build（`-derivedDataPath`を隔離。既定DerivedDataを汚さない）
- `web`のlint、TypeScript型検査、production build（Gateway側を触る D5 のみ）
- 長時間稼働試験（D7）
- 署名付きアプリでの実機確認（公開前）

## 7. 対象外

- モデルの選定。Vision一次のCerebras `gemma-4-31b`トライアルの採否は別の判断であり、
  正本は`web/lib/server/ai-routing.ts`のまま動かさない。
- R8（v3ツール適合）とM7カタログ基盤。
- UIの多言語化。
- Composeのclipboard非依存化（プロジェクトB）。

## 8. 復帰点

着手時に現行`main`へタグを打ち、作業ブランチを切る。ブランチ名とタグはD0の実行時に
マスタープランR11へ記録する。
