# 起動確実性と公開品質（R11）

最終更新: 2026-08-03 ／ ステータス: 実装・機械検証完了。残るは長時間稼働試験（D7）のみ

進捗と受け入れ条件の正本は[マスタープラン R11](universal-io-master-plan.md)、
本書は原因分析・目標構造・マイルストーンの正本とする。

復帰点: タグ`r11-start`（`3ca936e`）、作業ブランチ`r11-reliability`。

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
13:48:42.786 state.transition mode=capturing from=idle reason=idleAXFocusSummon
13:48:43.567 state.transition mode=vision from=capturing reason=captureCompleted
13:48:45.4   POST https://api.universal-io.com/api/ai/vision   ← 発行された
13:48:51.651 [Vision] turn=first gatewayRoundTrip=7342ms      ← 完走
13:49:26.013 state.transition mode=idle from=vision reason=resignActive
```

**14:12（障害）**

```text
14:12:21.241 coordinator.event mode=idle event=doubleTap
14:12:21.251 state.transition mode=capturing from=idle reason=idleAXFocusSummon
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

### 1-b. 障害召喚は新品のウインドウだった（D4前提の反証）

計画初版は「召喚ごとの`contentViewController`差し替えの蓄積」を劣化源として最有力に置いた。
**実測はこれを否定する。**

障害の召喚は`from=idle reason=idleAXFocusSummon`である。直前の13:49:26に`resignActive`で
idleへ落ちており、`close(reason:)`は`applyPanel(.idle)`経由で`PanelController.close()`まで
到達するため、この時点でwindowは破棄され`panel`は`nil`になっている。したがって14:12の召喚は
`makePanel()`を通り、**新品のNSWindowと新品のNSHostingControllerで失敗した**。差し替えは
起きていない。回復後のプロセス（PID 91910）も同じコードパスを通って成功している。

結論として、**ホスティングコントローラーの寿命を延ばしても今回の障害は防げない**。むしろ
失敗したのは最も新しい状態だった。劣化はウインドウ単位ではなくプロセス単位で起きている。

同じ理由で、「壊れたらパネルを作り直して回復する」という自動復旧も期待できない。作り直した
ものが失敗した実績が、この14:12そのものである。**最終的な回復手段はプロセスの再起動しかない。**
ならばそれを口頭の案内ではなく、アプリ内の1操作として提供する（D8）。

## 2. 根本原因

Visionの初回リクエストとスクリーンショット表示は、どちらもSwiftUIの
appearance callback 1点だけを引き金にしている。

| 引き金 | 位置 | 発火しないと失われるもの |
|---|---|---|
| `.task { session.startIfNeeded() }` | `BombSquad/Core/VisionSessionView.swift:34` | 初回リクエスト（`isLoading`も立たないのでスピナーも出ない） |
| `.onAppear { loadImage() }` | `BombSquad/Views/ZoomableScreenshotView.swift:87` | 画面画像の読み込み |

観測された症状は、この2つがどちらも発火しなかった状態と正確に一致する。パネルの外枠、
ヘッダー、入力欄のキャレットは描画されていたので、**body評価そのものは生きていた**。
壊れたのは描画ではなく、appearanceという「いつ呼ばれるかをSwiftUIが決める」通知だけである。

body評価が生きているという事実には実装上の意味がある。`@Published`の変化でビューは更新される
ので、**リクエストさえ発行できれば結果は表示される見込みが高い**。D2は症状の隠蔽ではなく修正である。

劣化の物理的な機序（プロセス内のAppKit／SwiftUI状態、ウインドウサーバとの整合）は特定できて
いない。**特定を待たない。** 機序が何であれ、UIフレームワークの描画都合がリクエスト発行の
必要条件になっている構造そのものが欠陥である。

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

2つ目は個別の経路へタイムアウトを配って回ることでは達成できない。次にawaitを1つ足した人が
無音経路を復活させられる限り、不変条件ではなく努力目標である。**期限・トレース・終端状態を
持たない実行経路を書けないようにする**（D5）。

## 4. マイルストーン

各マイルストーンはコミット境界とする。受け入れ条件を満たさないものは次へ進めない。
実施順は D1 → D2 → D3 → D6 → D5 → D8 → D9 → D7 とし、最もリスクの高い変更を、
診断と期限が入った後に行う。

- **D0（計画）** 本書、[ドキュメント索引](README.md)、マスタープランR11を確定する。
  受け入れ条件: 原因分析が実測ログとコード位置で裏付けられ、各マイルストーンの受け入れ条件が
  検証可能な文で書かれている。**完了**（1-bの実測でD4の前提を反証し、順序と範囲を改訂した）。

- **D1（診断の常設化）完了。** 現在の`CoreTrace`／`VisionTrace`は`#if DEBUG`のNSLogだけで、
  公開版では何も残らない。`os_log`のsubsystemへ移し、release buildでも
  「セッション開始・リクエスト発行直前・完了・失敗」を必ず記録する。
  記録するのは機能名、経過ミリ秒、成否、理由コードだけとし、本文・回答・画像・
  ウインドウタイトル・ホスト名は**載せない**（README「データ保存」の境界を動かさない）。
  あわせて同じイベントをプロセス内のリングバッファ（直近200件）へ保持し、管理画面から
  コピーできるようにする。顧客のMacのunified logはsysdiagnoseなしでは回収できず、
  「ログだけで切り分けられる」の主語が開発者の実機に限られてしまうためである。
  受け入れ条件: 署名付きrelease buildで同じ障害が起きた時、ログだけで
  「開始しなかった」と「開始したが応答しなかった」を切り分けられる。ユーザーが管理画面から
  その記録をコピーして送れる。コピーされた文字列に本文・タイトル・ホスト名が含まれないことを
  testで固定する。

- **D2（開始をコーディネーターが所有）完了。** `handleVisionCaptureCompletion`でセッションを
  生成した直後に開始する。`startIfNeeded()`は`hasStarted`で冪等なので、ビュー側の`.task`は
  残っていても二重送信にならない。
  受け入れ条件: `.task`を取り除いた状態でも初回リクエストが発行されることを、
  ビューを介さないunit testで固定する。

- **D3（画像読み込みの非依存化）完了。** スクリーンショット表示を`.onAppear`から切り離す。
  `ZoomableScreenshotView`はURLを受け取って自分でディスクから読み直しているが、captureは
  すでに画像を持っている。表示用の画像をsessionが値として保持すれば、`loadImage()`という
  概念ごと無くなる。「appearance callbackから切り離す」のではなく「読み込みが存在しない」に
  する。一時ファイルはGatewayへの送信用にだけ残す。
  受け入れ条件: appearance callbackを呼ばずに画像が解決されることをtestで固定する。
  Visionパネル内でユーザーが見る情報のうち、appearance callbackだけを引き金にするものを
  ゼロにする。

- **D6（無音失敗の撤去）完了。** `BombSquad/Core/VisionSession.swift` の
  `catch is CancellationError { return }` は、ユーザーが閉じた場合と内部都合で
  取り消された場合を区別せず結果を捨てる。両者を分け、後者は理由を表示する。
  `SessionCoordinator.close()` は`stateMachine.transition(to: .idle)`の戻り値を捨てており、
  遷移が拒否されてもteardownが走る。拒否時はteardownしない
  （画像削除とリクエスト取消だけが実行され、パネルだけが残る＝今回見た抜け殻状態を作る経路）。
  戻り値を無視している箇所は目視で数えず、`transition`の`@discardableResult`を外して
  コンパイラに列挙させる。
  受け入れ条件: 遷移拒否時にセッションが生存していることをtestで固定する。
  `transition`の戻り値を暗黙に捨てているコードがビルド時に0件である。

- **D5（操作の一元実行機構）完了。** 現状タイムアウトはクライアント・サーバのどちらにも存在しない
  （`timeoutInterval`／`maxDuration`ともに0件）。個別に配って回るのではなく、ユーザーに
  見える操作（Visionの1ターン、レビュー、transcribe、suggest）は**期限・トレース・終端状態を
  必ず伴う単一のランナー経由でしか実行できない**形にする。sessionが素の`Task {}`を張って
  awaitする経路を残さない。含めるもの:
  - Vision 1ターンの全体期限。超過で「画面の読み取りが時間内に完了しませんでした」を表示する。
  - `BombSquadAuthClient.accessToken()`（`client.auth.session`）の期限。ここは現在無期限に
    awaitし、失敗するとネットワークログさえ残らない唯一の箇所である。
  - Gateway側のprovider呼び出しを`fetchProvider`へ集約して`AbortSignal.timeout`を必ず通す。
    実装時の再確認で、transcribeにだけ既に期限があった（vision／review／suggestには無い）。
    4 routeへ`maxDuration = 60`を入れ、whisperのfallbackを60秒から35秒へ下げて
    `15 + 35 < 60`が成り立つようにした。現行プランでだけ通る予算は、いちばん困る時に破れる。
  - `mode=vision`へ遷移してから一定時間内にリクエストが発行されなければ、
    コーディネーターが開始を再試行し、それでも駄目なら可視エラーにする。
  受け入れ条件: 一次モデルが「エラーを返さず無応答」の場合に二次モデルへ落ちること。
  `runWithModelFallback`は一次が例外を投げた時だけ二次へ進むが、`AbortSignal.timeout`は
  ハングを例外へ変換するため、fallback機構自体は改造せずに成立する。予算は
  `maxDuration ≧ 一次timeout + 二次timeout + overhead`を満たすこと。
  一次timeoutの値はD1で得た実測分布から決め、正常応答を切らない。

- **D8（最後の回復手段をアプリ内に持つ）完了。** 1-bのとおり、パネル再生成では回復しない。
  プロセスの再起動が唯一確実な手段である以上、それを口頭の案内ではなくメニューバーの
  1操作として提供する（「Universal I/Oを再起動」）。回復操作をパネル内に置かない。
  パネルの描画が壊れている状況を前提とした回復手段が、そのパネルの中にあっては意味がない。
  自動再起動はしない。ユーザーが押した時だけ再起動する。
  受け入れ条件: パネルが応答しない状態でも、メニューバーから再起動して回復できる。
  未送信のCompose下書きは再起動後も残る（すでにユーザー単位で永続化済み）。

- **D9（appearance依存の全体監査）** 不変条件はアプリ全体の主張であり、Vision限定ではない。
  リポジトリ全体の`.task`／`.onAppear`を列挙し、判定規則を1つ決めて各点を判定する。**完了**。

  規則: **appearance callbackは表示状態を設定してよく、その画面が見せている内容の更新を
  始めてもよい。ただしユーザーが頼んだ仕事の唯一の引き金になってはならない。**

  | 位置 | 内容 | 判定 |
  |---|---|---|
  | `VisionSessionView:71` | `focusedField = .navigator` | 表示状態。可 |
  | `ComposeSessionView:62` | フォーカスと展開サイズ | 表示状態。可 |
  | `ZoomableScreenshotView` | 画像読み込み | **D3で撤去** |
  | `VisionRootView` | セッション開始 | **D2で撤去** |
  | `PermissionsSetupView:51` | 権限ポーリング開始 | **撤去**。この窓の仕事はユーザーが権限を与えた瞬間を捉えることで、発火しなければ許可しても何も起きない。窓を開いた側（`AppDelegate`）が開始する |
  | `GeneralSettingsView` | 動作記録の再読み込み | メモリ上の配列を読むだけ。可 |
  | `AccountView:100`／`PricingView:108` | `/api/account`の再取得 | 見ている画面の更新。可。前面化時の再取得という独立した第2の引き金も持つ |
  | `FactsView:59`／`HistoryPlaceholderView:50` | 一覧の読み込み | 見ている画面の更新。可。失敗時は`errorMessage`と`isLoading`で必ず終端し、無音では終わらない |

  管理画面の再取得を残す理由: ユーザーが頼んだのは「その画面を見ること」であり、読み込みは
  画面そのものである。発火しなければ空の画面が見え、別セクションへ移って戻せば再取得される。
  課金状態のように古い値が危険なものには、前面化時の引き金がすでに別途ある。
  Visionの欠陥はこれと種類が違い、ユーザーが頼んだ操作そのものが失われていた。

- **D7（項目追加は完了、実施は未了）** 24時間以上連続稼働させた後にCompose、Vision、Copilot、
  音声入力のgolden pathを通す項目を[manual-golden-paths.md](manual-golden-paths.md)へ追加する。
  受け入れ条件: リリース前チェックとして実施され、結果が記録される。これが
  「再起動してください」を顧客へ案内しないための最後の防波堤である。

### D4（パネル表示の作り直し）を`0.2.2`のゲートから外す

初版のD4は「召喚ごとの`contentViewController`差し替えをやめ、パネル寿命に対して
ホスティングコントローラーを1つにする」だった。1-bの実測により、**この変更が今回の障害を
防いだとは言えない**。障害はまさに新品のウインドウ・新品のホスティングコントローラーで
発生している。

パネル構造の単純化そのものは価値があるが、それは衛生であって修正ではない。R11で最もリスクの
高い変更を、効果を証明できないまま公開の前提条件に置かない。`0.2.2`公開後、計測ハーネスで
「召喚と解放の反復でNSWindowとホスティングコントローラーが増えないこと」を確認した上で
別途扱う。

## 5. 技術的負債の棚卸し

D0時点の実測に基づく。「扱い」がD番号のものは本プロジェクトで解消し、
それ以外は残す理由を明記する。

| # | 項目 | 位置 | 影響 | 扱い |
|---|---|---|---|---|
| 1 | セッション開始が`.task`単点依存 | `VisionSessionView.swift:34` | 今回の障害の直接原因 | D2 |
| 2 | 画像読み込みが`.onAppear`依存 | `ZoomableScreenshotView.swift:87` | 画面が空になる | D3 |
| 3 | タイムアウトが皆無 | クライアント全体・vision／review／suggest engine | 止まったのか遅いのか区別できない | D5で解消 |
| 4 | `accessToken()`が無期限await | `GatewayAPI.authorizedRequest` | 痕跡ゼロで永久停止し得る | D5で解消（10秒） |
| 5 | fallbackが例外時のみ | `ai-routing.ts:101` | 一次ハング時に二次へ落ちない | D5のtimeoutが例外化して解消。機構は無改造 |
| 6 | `maxDuration`未設定 | `web/app/api/ai/*` | 直列2コールに予算が無い | D5で解消（60秒） |
| 7 | 診断がDEBUG限定 | `VisionTrace`／`CoreTrace` | 公開版で原因が分からない | D1で解消（`Diagnostics`へ統合） |
| 8 | `close()`が遷移結果を無視 | `SessionCoordinator.close()` | 抜け殻パネルを作り得る | D1で解消（`@discardableResult`除去） |
| 9 | CancellationErrorの無音return | `VisionSession` | 完了した回答を黙って捨てる | D6で解消 |
| 10 | ホスティングコントローラー毎回差し替え | `PanelController.swift:69` | 劣化源との推定は1-bで**反証**。衛生改善 | `0.2.2`後（旧D4） |
| 11 | ライフサイクルのtestがゼロ | `BombSquadTests/`（41件） | パネル・セッション寿命が未検証 | 61件へ。D1・D2・D3・D5・D6で追加 |
| 12 | 3MB超画像のJPEG再圧縮が1回のみ | `GatewayVisionClient.swift:152` | 高解像度で4.5MB制限を超え得る | **未対応**。D7の実機計測へ持ち越す |
| 13 | AX messaging timeoutの実効範囲が未検証 | `VisionObservationCaptureService.swift:285` | 子要素へ継承されるか未確認 | **未対応**。D7の実機計測へ持ち越す |
| 14 | 診断をユーザーが取り出せない | 管理画面 | 顧客のログはsysdiagnoseなしでは届かない | D1で解消 |
| 15 | 最終回復手段が口頭案内 | — | 「再起動してください」を案内するしかない | D8で解消 |

## 6. 検証

各マイルストーンで次を通す。

- macOS unit test（現行41件＋D2・D3・D6の追加分）
- 署名なしDebug build（`-derivedDataPath`を隔離。既定DerivedDataを汚さない）
- `web`のlint、TypeScript型検査、production build（Gateway側を触る D5 のみ）
- 長時間稼働試験（D7）
- 署名付きアプリでの実機確認（公開前）

## 7. 対象外

- モデルの選定。Vision一次のCerebras `gemma-4-31b`トライアルの採否は別の判断であり、
  正本は`web/lib/server/ai-routing.ts`のまま動かさない。
- パネル表示の作り直し（旧D4）。上記のとおり`0.2.2`後へ送る。
- R8（v3ツール適合）とM7カタログ基盤。
- UIの多言語化。
- Composeのclipboard非依存化（プロジェクトB）。

## 8. 復帰点

タグ`r11-start`（`3ca936e`）が着手直前の`main`である。作業ブランチは`r11-reliability`。

## 9. 現在の状態

D1〜D6、D8、D9をブランチ上で実装した。macOS unit test 61件（41→61）、署名なしDebug build、
webのlint／TypeScript型検査／production buildが成功している。

残っているのは**実機での確認**である。ここまでの検証はいずれも自動テストとビルドで、
署名付きアプリを長時間動かした確認は行っていない。具体的には次が未了である。

- D7の長時間稼働試験（24時間以上）。項目は[manual-golden-paths.md](manual-golden-paths.md)へ
  追加済みで、実施はこれから。
- 署名付き候補版でのGolden Paths全体（R10／R10.5分を含む）。
- 負債#12（3MB超画像の再圧縮）と#13（AX messaging timeoutの継承）の実測。
- Gateway側変更（`maxDuration`とprovider timeout）は`main`へpushするまで本番へ届かない。
  現在は作業ブランチ上にあり、**本番Gatewayはまだ期限を持っていない**。
