# Universal I/O マスタープラン

最終更新: 2026-08-23 ／ ステータス: `v0.2.2`（build `8`）を公開ダウンロードへ切替済み（D7通過）。`main`は`0.2.3`を開いている。R12はE1（測定）進行中、R14（実画面の上で指して聞くVision）は要件確定・実装未着手

## 製品

Universal I/O は、人が情報を送る・受け取る・画面上で行動する間に入り、意図と表現を
整える中間レイヤーである。自律操作ではなく、最終判断と操作はユーザーが行う。

製品surfaceは3つだけとする。

1. Compose: 自分の文章を作り、必要ならレビューして送信する。
2. Vision: 現在の画面または選択対象を読み、質問へ答える。
3. Copilot: 画面上の次の一手を示し、ユーザー操作後に再評価する。

## 現行アーキテクチャ

```text
macOS UI
  └─ SessionCoordinator
       ├─ ComposeSession  ── /api/ai/review
       ├─ VisionSession ──── /api/ai/vision
       └─ GatewayTranscriber /api/ai/transcribe
                              │
                       Production Gateway
                              │
                       AI providers + Supabase
```

設計原則:

- 状態遷移は `SessionCoordinator` に集約する。
- 各surfaceはSessionとViewを1組だけ持つ。
- AIは本番Gateway経由だけ。macOSからプロバイダーを直接呼ばない。
- ローカルGateway、BYOK、旧endpoint、shadow実行、macOS側のfallbackを持たない。
- 全AI機能はGatewayの単一モデルルーターで一次・二次モデルを指定する。一次失敗時だけ二次を
  1回実行し、切替時はユーザーへ共通noticeを表示する。両方失敗時は共通エラーを返す。
- 音声入力はGroq Whisper Large V3 Turboと16 kHz mono WAVを本番経路とする。
- 全AI機能は共通`GatewayAIWarmup`から、アプリ起動時と各機能へ入る直前に同一routeの
  認証・quota前処理をウォームする。Gateway instance内で5分キャッシュし、providerは呼ばないため
  ウォームアップ自体は課金・usage記録しない。
- 全AI routeのusage記録は共通処理で応答後に実行する。SSEも最終結果をクライアントへ返してから
  記録し、運用上のDB書き込みをユーザーの待ち時間から外す。
- Visionは画像、同一captureの候補、会話を1回のVLM呼び出しへ渡す。
- Focused Visionは別taskではなく`Vision Core + Selection Extension`とする。selectionは
  ユーザーが明示した回答scopeである。初回は選択操作が対象を決め、選択全文を必ず扱う。画像、
  現行の通常AX candidate policy、identity、Skill、会話、
  Copilotを減らさず、選択全文、取得済みの関連AX構造、複数frameを加える。selectionを除いた入力と
  実行経路は通常Visionと同一でなければならない。周辺観測はselectionを説明する材料であり、
  scopeを別のlabelや要素へ変更する権限を持たない。segmentは実機で必要性を証明した場合だけ加える。
- Composeの先回り文案は共通判断、ユーザーが確認したファクト、任意のアプリ文脈を独立した添付として
  渡す。ファクトはglobalと画面に効いているツールのscopeだけを注入し、固定Personaは持たない。
  最新メッセージの話者・宛先・行為主体を確定してから、現在のユーザー視点で文案を作る。
  アプリ文脈はbundle ID、アプリ名、ウインドウタイトルから選び、現行はSlackとGmailを補足する。
  検出条件と指示は製品単位の既定パッケージとして分離し、複数製品を持つ提供元名では束ねない。
  文案より先に話者、宛先、ユーザーの立場、添付所有者、依頼、返信意図を構造化出力させる。
  Gateway応答にはprompt versionと適用context packageを含め、実行時の適用有無を観測可能にする。
- モデル結果が選んだcandidate IDだけを、コードが保持する矩形へ変換する。
- Visionの`guide`回答はcandidate矩形の有無にかかわらずCopilotを開始できる。矩形は
  ハイライトにのみ使い、取得できないWeb/Electron画面でも文章案内とクリック後の再評価を続ける。
- 「どこから」「どうやって」「取得」「設定」等の操作意図はローカルでも判定し、モデルが
  `answer`へ分類しても任意のCopilot開始導線を出す。Gateway側も同種の質問を`guide`へ寄せる。
- Composeの自動返信モード見出しとオン／オフスイッチは常設し、切替は開いているセッションへ
  即時反映する。オフ時は説明用プレースホルダーを出さず、見出しより下を畳む。ただし完成済みの
  文案は現セッション中だけ保持・編集・送信でき、設定は次回のComposeから自動生成を止める。
- Composeのコンテクスト表示は「適用ツール・画面画像・AX周辺テキスト・検出元・保存範囲」を
  情報源として開示する。コンテナのブラウザ名とウインドウタイトルを主表示には使わず、
  除外操作はAX周辺テキストだけが対象であることを明記する。
- 入力履歴の閲覧は管理画面だけに置く。Composeパネルでは履歴を先読み・再読込・復元しない。
- 実験は短命ブランチで完結し、本番ツリーへ残さない。

モデルルーティングの正本は `web/lib/server/ai-routing.ts` だけとする。個別engine、route、
macOS、環境変数にモデル名やfallback順序を重複させない。Admin Consoleはこの正本を読み、
各機能の一次・二次、vendor、model ID、API方式をそのまま表示する。

## データ境界

- 認証、entitlement、usageはSupabaseを正とする。
- 下書きとCompose送信履歴はMacローカル。履歴上限は100件。Visionの対象・画像・会話は履歴化しない。
- スクリーンショット、音声、周辺コンテクストは処理用で、Gatewayへ恒久保存しない。一時画像は
  セッション終了時、異常終了で残った画像は次回起動時に削除する。
- ローカル履歴・下書きはSupabase user ID単位で物理分離し、ログアウト時にDBを閉じる。
- Supabase認証セッションはUniversal I/O専用のmacOS Keychain service/keyへ保存する。旧SDK共通
  keyは一度だけ移行し、unit testのhost起動ではKeychainへアクセスしない。
- usageと運用ログには入力本文、画像・音声、画像パス、アプリ名、ウインドウタイトルを保存しない。
- request単位usageは90日で月次rollupへ集約して削除する。退会時はユーザーおよび個人tenantに
  cascadeするデータと、Mac内のユーザー専用領域を削除する。
- APIキーはGateway環境だけに置く。macOSのKeychainへAI APIキーを保存しない。
- OpenAIへの保存対応endpointは`store: false`を必須とし、OpenAI/GroqのZDR有効状態は
  provider管理画面のリリースチェック対象とする。

## リリースまでのマイルストーン

### R1 — 経路一本化（完了、2026-07-18）

- 現行Visionを正式な `VisionSession` と `/api/ai/vision` に昇格。
- 旧Vision、Navigator v3/v4、Run、shadow、harness、fixture、local Gateway、BYOKを削除。
- Compose、Transcribe、Memoryを本番Gateway専用に統一。
- 実験資料とアーカイブをGit履歴へ戻し、作業ツリーから削除。

### R2 — 機械検証（完了、2026-07-22）

- XcodeGen生成が成功する。
- macOS Debugを署名なしでビルドできる。
- Web lint、TypeScript、production buildが成功する。
- 本番route一覧とクライアントendpointが一対一で一致する。
- リポジトリ内に旧経路の参照が残っていない。

### R3 — 本番E2E（進行中）

- ログイン、レビュー、音声入力、Focused Vision、通常Vision、Copilot、履歴を実機確認。
- 本番Gatewayで全routeがJSON/SSE契約を返し、404 HTMLを返さない。
- 全AI機能で実モデルと `fallback_used` をクライアントとusageで確認する。
- 一次失敗時は二次で成功して共通noticeが表示され、両方失敗時は共通エラーになる。
- 権限再起動、ネットワーク障害、期限切れsessionで明示的エラーになる。

### R4 — リリース品質

- [manual-golden-paths.md](manual-golden-paths.md) を全項目実施。
- UI文言、フォーカス、キーボード操作、VoiceOverラベルを確認。
- クラッシュ、秘密情報、ログへの入力本文・画像パス漏洩を点検。
- 署名、Hardened Runtime、notarization、DMG、更新導線を確認。

### R5 — 公開（`v0.1.0` 完了、2026-07-22）

- 正式版は `0.1.0`（build `2`）、Gitタグは `v0.1.0`、ソースは `700f607`。
- main、本番Gateway、Webサイトをdeploy済み。
- Developer ID署名、notarization、staple、Gatekeeper評価済みDMGを配布。
- 公開DMGはversion／build別の不変URLへ保存し、Webサイトは不変URLを直接参照する。
  version aliasとlatest aliasも互換用に更新する。
- 公式DMGのSHA-256は
  `e0b08385d11cb591019490a93a5bfc2aa3b0f510ef577f116ab768c3f90f2f90`。
- 初期usage、エラー率、レイテンシを監視する。

### R6 — データ境界修正版（`v0.1.1` 完了）

実装・機械検証・main統合・本番公開を完了した。

- Compose履歴、下書き、メモリをSupabase user ID単位で分離した。
- メモリ同期をdirty差分・server cursor・競合解決方式へ変更した。
- アカウント退会と、サーバー・Mac双方の関連データ削除を実装した。
- Supabase認証をアプリ専用Keychainへ移し、unit test起動時の不要なKeychainアクセスを止めた。
- request単位usageを90日後に月次rollupへ移すmigrationと日次cronを本番適用・記録した。
- 削除済みメモリから本文・相手名を消すtriggerは本番適用済み。migration台帳との整合確認を
  `v0.1.1`公開前に完了する。
- `0.1.1` build `3`として署名・notarization・DMG公開を完了し、旧版もrollback可能な履歴として保持する。

### R7 — Vision / Copilot・自動返信正式版（`v0.2.0`）

- Vision / Copilotを単一の本番経路へ統合し、画面上の質問から案内へ入りやすくした。
- Slack / Gmail等のアプリ文脈、Persona、話者・宛先の構造化認識を自動返信へ導入した。
- Composeの送信UI、可変パネル、ドラッグ移動、自動返信トグルを製品UXとして統一した。
- 全AI経路の認証・quotaウォームアップと応答後usage記録を共通化した。
- `0.2.0` build `4`を正式採用し、Developer ID署名、notarization、DMG公開を完了した。
- バイナリソースは`ce74d12`、公式DMGのSHA-256は
  `98f14799181b45933d5e77df0a55aebbf7f65d9be3a0d87748e0b97551e093c7`。

### R8 — v3: ツール適合（`v3`ブランチ、進行中）

事業上の核心は「あらゆるツールを使いこなせるアプリへ育てること」であり、ツール個別の適合が
エンタープライズ導入とFDEモデルの商材になる。精度レイヤーの正式名称は **Skills**（データであり
制御フローに触れない／ベース < ツール < 業務 < 個社の階層合成／有効なSkillは常に可視）。設計根拠は[v3-tool-fit-plan.md](v3-tool-fit-plan.md)。

- **M0（完了）** 文体・関係性メモリを全層から削除。macOSストア・同期・抽出、Gatewayの
  `/ai/memory/distill`と`/memory/cards`、`ai-routing`の`memory`route、`bs_memory_cards`table、
  ローカル`memory.sqlite`の消去まで。送信ごとの抽出呼び出しが1回分消える。
- **M0.5（完了）** 共通コアに「呼ばれた理由」を定義。ホットキーで呼ばれた時点でユーザーは
  助けを求めており、入力欄の手前はユーザー宛の依頼である可能性が高い、を既定の姿勢とする。
  認識フィールドへ「依頼を実行するのは誰か」を追加し、ユーザーが実行者の依頼を相手への指示として
  返す失敗を塞ぐ。文脈不足を理由に生成を控えない。この前提は各Skillを書くときも共有する。
- **M0.6（未着手・実機で再現）話者と実行者の取り違え。** 2026-08-03、AIチャット画面で先回り
  文案が「承知しました。これから本番デプロイをプッシュします。完了したらデプロイ状況を
  共有します。」を出した。実際にはデプロイは**相手**がすでに実行済みで、画面にはその完了報告が
  出ていた。2つの誤りが同時に起きている。
  1. **返信対象の取り違え。** 相手の最新メッセージではなく、ユーザー自身の1つ前の発言
     （相手への依頼）に返信している。
  2. **実行者の反転。** 相手が実行した行為を、ユーザー自身がこれから行う行為として書いている。
     M0.5で塞いだ向き（ユーザーが実行者の依頼を相手への指示にする）の**逆向き**であり、
     READMEが明記している禁止事項でもある。

  規則も構造化認識フィールドも既にあるのに実画面で効いていない。したがって次の作業は規則の
  追加ではなく、**なぜ既存の規則が適用されないかの特定**である。仮説は、長い相手メッセージが
  画面を占めると発言の境界と話者の帰属が読み取りにくくなること、およびチャットUIでは自分の
  発言と相手の発言が同じ列に並ぶこと。まずGatewayが受け取った構造化認識の出力を実際に見て、
  話者・実行者をどう判定したかを確認してから直す。R11とは独立で、`0.2.2`公開の前提には含めない。
- **M1（完了）** Skills基盤（`web/lib/server/skills/`、1ツール1ファイル、registry、階層合成、
  有効Skillの可視化）とSlack / Gmailの移植。各Skillはreading / conventions / affordances /
  attentionと、そのツールで学ぶ価値のあるfactキー語彙を宣言する。用途ごとに渡すセクションを
  変え、suggestはreading + conventions、Visionはreading + affordances + attentionを受け取る。
  適用中のSkill名はsuggest応答に含めてパネルへ表示する。
- **M2（完了）** SkillsをVision / Copilotへ供給する。attentionは「列挙禁止・確実な1件だけ」の
  抑制ルールとして渡し、適用中のSkill名はVisionパネルとCopilotストリップの両方に出す。
  当初「アプリ識別子は`candidate_diagnostics`で既に届いており契約変更は不要」と書いたが誤りで、
  同fieldはusageへ渡る運用情報のためクライアントがアプリ名もホストも送っていなかった。
  Visionにもsuggestと同じ`input.context`（`host`が一次シグナル）を追加し、識別子は
  プロンプト参照のみで保存しない。ホスト取得は`BrowserHostLookup`へ共通化する。
  **初回ターンで必ずSkillが効くこと**を受け入れ条件とし、製品判定はVision要求と同時（撮影と並行）に
  開始する。Compose経由ならsummon時のSituationalContextをそのまま使う。Chromiumはweb AXツリーを
  遅延構築するため、ツリーが成長している間だけ追加パスを回し、ネイティブ窓と確定したら即終了する。
- **M3（完了）** ファクトストア。`bs_user_facts`（`user_id`/`scope`/`key`/`value`のupsert、
  RLSは本人のみ）、`/api/facts`のGET/PUT/DELETE、管理画面「覚えていること」で一覧・編集・削除。
  語彙外キーは書き込み時に拒否し、これを唯一のガードレールとする（削除は語彙検査なし＝Skill廃止後の
  残骸をユーザーが消せる）。表示名（label）はSkill定義側が持ち、ツール追加でクライアントは変わらない。
  全件でも数十行のため差分同期もtombstoneも持たない。**検出と注入はまだ無い**（M4／M5）。
- **M4（完了）** 検出時にその場で確認するUI。専用呼び出しは作らず、suggestの構造化出力へ
  `fact_candidate`を1つ足した。モデルはGatewayが渡したaskableスロットのenumからidを選ぶだけで、
  キーを創作できない。askable＝有効Skill＋globalの語彙から保存済み・拒否済み・打ち切り済みを
  除いたもので、空ならスキーマからもプロンプトからも消えて従来と同一の呼び出しになる。
  抑制状態は`bs_fact_prompts`（`ask_count` / `declined_at`）に持ち、質問を返した時点で応答後に
  加算する（答えずに閉じても1回、通算3回で打ち切り）。「いいえ」は`POST /api/facts`で恒久記録し、
  「はい」は`PUT`だけで足りる。値はGatewayが正規化し、確認文もGatewayが組み立てて値を引用符へ
  入れる。usageには`fact_question_asked`の真偽だけを残す。
- **M5（完了）** ファクト注入（global＋現在ツールのscopeのみ）と固定Personaの撤去。注入と質問は
  同じ1回のルックアップ（`loadFactContext`）から出す。埋まっているスロットは注入対象、埋まって
  いないスロットが質問対象で、両者は補集合の関係にあるため2つ目のクエリを持たない。既定Personaは
  削除し、確認済みファクトが無い時は添付を送らない（借り物の人物像より無仮定の汎用が正確）。
  usageには注入した件数だけを残し、キーも値も記録しない。
  出力言語の初期値をOSの言語設定から読み、管理画面「設定 › 言語」の表記を出力言語だと分かる形へ
  改めた（UI自体の多言語化は別フェーズ）。
- **M6（進行中）** Salesforce / HubSpot / freee / SmartHR / GA4等を追加し、1ツールあたりの追加コストが
  定数に収まっているかで設計の合否を判定する。1本目はGA4（`analytics.google.com`）。会話系ではなく
  操作系の初例で、`conventions`を持たず`affordances`／`attention`が厚い——用途別にセクションを
  出し分ける設計の実地検証になる。
- **M7（未着手）** Skillsカタログを数百・数千製品へ拡張できる基盤へ移行する。製品識別子、製品内の
  画面モジュール、Skill本文を分離し、宣言的な定義からhost／bundle IDの索引を生成する。検出後は
  該当製品と必要な1〜3モジュールだけを遅延ロードし、追加のたびにmacOSクライアントの更新を要求しない。
  重複識別子・曖昧な一致・必須項目・トークン上限をビルド時に検証し、golden case、段階公開、
  バージョン管理、即時ロールバックを運用に含める。詳細は
  [v3-tool-fit-plan.md](v3-tool-fit-plan.md)「数百・数千ツールへの拡張」に従う。
- **セットアップウィザード（未実装・案）** 画面検出とは別の取得経路として、対話形式で精度に効く
  項目を決め打ちで埋める。初回起動には置かず、マイページ常設＋ある程度使った段階での導線とし、
  1問も答えなくても全機能が動くオプショナル層に留める。設計は[v3-tool-fit-plan.md](v3-tool-fit-plan.md) §4。

共通の受け入れ条件: Skillが無い画面で汎用品質が落ちないこと。汎用理解が限界までチューニング
されていることが前提で、Skillsはその上の加算に限る。

### R9 — Focused Visionとclipboard安全化（`v0.2.1`完了）

現行Transformを独立surfaceとして廃止し、画面全体に加えて選択テキスト・選択要素・位置を
開始時点から持つFocused Visionへ統合する。通常Visionと同じSession、View、Gateway route、
Skill、継続質問、Copilot経路を使い、Transform専用の状態・パネル・routeを削除する。

プロジェクトAでは、右Shift起動時の合成⌘Cと標準クリップボードの退避・復元を廃止する。
選択取得はAXだけを使い、失敗時は通常VisionまたはComposeへ安全に退化する。Compose送信は当面
clipboard＋合成⌘Vを維持するが、過去内容を復元せず、送信本文が残る予測可能な動作へ変える。

プロジェクトBではAX直接入力のread-back、Undo、IME、改行を実機probeし、実証できた対象だけ
clipboard非依存化するか、clipboard＋⌘Vを維持するかを別途決める。未証明のAXValue汎用挿入と
Unicode keyboard eventを製品fallbackにしない。

完了時の製品surfaceはCompose / Vision / Copilotの3つ。プロジェクトAの受け入れ条件は
`TransformSession`、`/api/ai/transform`、`SelectionGrabber`、`ClipboardBackup`、合成⌘C、
clipboard restoreが本番ツリーに存在しないこと。実装前の復帰点はtag
`pre-focused-vision-r9-20260730`（`1aea597`）。設計、マイルストーン、commit境界、検証の正本は
[focused-vision-plan.md](focused-vision-plan.md)。

- **A0（完了）** 復帰点、改訂設計、プロジェクトA/Bの境界を確定した。
- **A1（完了）** focused elementと祖先選択を1つの値snapshotへ固定するAX取得層を追加した。
  Chromium/Electronの両AX属性、captureと並行可能なbounded retry、secure field除外、
  timeout・失効要素の安全な退化、純粋な起動判定をunit testで固定した。現行の右Shift起動、
  Transform、SelectionGrabber、本番Gateway経路にはまだ接続していない。
- **A2（完了）** 任意のVision focus targetをSession、macOS request、Gateway validation、
  Vision promptへ後方互換で追加した。選択テキスト、AX要素、領域とcapture内ピクセルframeを扱い、
  AX対象未確定時は画像上の選択をbest-effortで探す。対象情報はusage／運用ログへ保存せず、
  通常Visionの未指定requestと現行本番入口は変えていない。
- **A3（完了）** 既存Visionパネルへ対象カードとcapture内ハイライトを追加した。選択テキスト、
  role由来の中立名、AX label、取得元、位置不明状態を表示し、長文は折りたたみと全文スクロールを
  両立する。同じ会話、Skill、fallback notice、Copilot経路を維持し、VoiceOver順序、
  Full Keyboard Access、Increase Contrast、Reduce Transparency、Reduce Motionへ対応した。
  右ShiftとTransformの本番入口はまだ切り替えていない。
- **A4（完了）** 右Shift起動を単一の`AXFocusSnapshot`判定へ切り替え、選択対象ありは
  Focused Vision、選択なし＋編集可能はCompose、それ以外は通常Visionへ分岐する。AXのbounded retry、
  画面capture、製品identity取得はパネル前面化前に並行し、Composeへ進む場合は同じcaptureを
  先読みに転用する。`SelectionGrabber`、合成⌘C、起動時のclipboard読取・復元、0.12秒固定待機を
  削除した。旧TransformコードとrouteはA5まで残るが、本番入口からは到達しない。
- **A5（完了）** `.transform`状態、Session、View、model、client、prompt、Gateway route、
  model routing、entitlement feature、ウォームアップを削除した。`review`はComposeだけを受理し、
  選択対象の理解は`VisionSession`と`/api/ai/vision`へ一本化した。ロールバック用・念のための
  旧実装は保持せず、必要な復帰はGit tag／履歴から行う。
- **A6（完了）** `ClipboardBackup`と遅延restoreを削除した。Compose送信は本文だけをclipboardへ
  書いて合成⌘Vを1回送り、本文を残す。Accessibility拒否またはevent生成失敗時は手動⌘Vを明示し、
  拒否時は設定を開く選択肢も出す。未実証のTransientTypeは付けず、送信後のユーザー⌘Cを時間差で
  上書きする経路を構造上なくした。
- **A7（完了）** XcodeGen、macOS署名なしDebug build、28 unit test、
  Web lint／TypeScript／production buildが成功した。旧Transform、起動時のclipboard／合成⌘C、
  遅延restoreが本番ツリーに無いことと、開始tagから恒久的な実験物が増えていないことを確認した。
  署名付きアプリの機能確認も問題なしと報告され、プロジェクトAの受け入れ条件を満たした。
- **正式公開（完了）** `0.2.1` build `5`をDeveloper ID署名、notarization、staple、
  Gatekeeper評価後に公開した。R9をmain `6bc471a`へ統合して本番Gatewayへdeployし、現行4 AI routeと
  旧`transform`の404を確認した。検証済みDMGを不変URLとversion aliasへpublishし、公開URLへpromote
  した後、公開URLから再取得して署名、version/build、Universal binary、SHA-256一致を再確認した。
  不変URLは`https://dl.universal-io.com/releases/0.2.1/build-5/Universal-IO.dmg`、SHA-256は
  `637cd6cc029452db349f87e0a1cae4e6ecf214a3d458ba9ce0ad87ea6344cd69`。
- **成果物境界** 永続的な候補はversion/build別DMG 1つだけとする。archive、export app、
  DMG stagingは一時領域で作って自動削除し、publishはGolden Paths済みDMGを再ビルドせずuploadする。

R9プロジェクトAに残作業はない。AX直接入力probeとclipboard非依存化の採否は独立した
プロジェクトB（B0/B1）で将来判断する。provider ZDR、本番課金、退会、権限拒否、offline復帰などの
横断的な運用確認は[manual-golden-paths.md](manual-golden-paths.md)に残し、該当領域を変更する
次回リリースで重点確認する。

### R10 — Vision Selection Extension（C6ブロッカー発見・R10.5修正中）

`v0.2.1`はFocused Visionを同じSession、View、Gateway route、モデルへ統合したが、選択取得は
focused elementに近い最初の非空AX祖先で終了し、Gatewayはselectionがあると通常Visionの初期taskを
selection専用taskへ置換する。このため、複数nodeにまたがる選択全文、スクリーンショット、
画面構造、Skillを共同で使うという製品要件を満たさない。初回turnの通常AX候補が空なのは
cold browser treeを待たないための意図的な性能設計であり、R10でも維持する。

2026-07-31のChrome Gmail実測では、複数DOM選択のdirect `AXSelectedText` 757 UTF-16 unitsは
取得できた。それでも現行経路は最初の非空`AXGroup`のrole／label／frameを全文と同じ
`VisionFocusTarget`へ格納し、Gatewayも単一の「focus target」として説明させる。件名のような
局所labelが選択全文の名前として扱われるため、本文を取得済みでも件名だけを説明し得る。
R10では選択全文とselection-related structureを別field・別provenanceで保持し、局所labelが
全文のscopeを置換しないことをtestで固定する。

R10では次を不変条件とする。

```text
Focused Vision = Vision Core + Selection Extension
Focused Vision - Selection Extension = 通常Vision
```

selection全文はユーザーが明示した回答scopeとして保持する。screenshot、AX／画面構造、identity、
Skillは引き続き第一級の観測であり、selectionの意味、関係、操作可能性、見た目、配置を共同で理解する。
ここで第一級とは情報を捨てないという意味であり、回答scopeを決める権限が同格という意味ではない。
初回のscopeは選択操作と選択全文が決め、周辺観測はそれを置換・縮約・無視できない。
主対策はdocument rootまで全候補を調べ、direct selected textの候補間／pass間の一致、
非collapsed range、selection coverageを検証して最も完全なdocument selectionを採用することである。
rangeはAX要素ごとのローカル値であり、外側という理由だけでは採用しない。
`AXStringForRange`との完全一致は補強証拠であり、Chrome Gmailで実測した表現差だけで安定した
direct textを棄却しない。複数segment集約は実機probeで必要性を証明した製品だけのfallbackとする。
構造化された`selection` wireは積極的に取得できた選択テキストからのみ作る。`visualOnly`
（画像上の推測ハイライト）と`AXSelected`要素による成立はR10.5で撤回した — どちらも観測主体を
持たない推測であり、選択していない画面に選択カードを常時表示する不具合の原因だった。
**ただしAXが返さないことはユーザーが選択していないことを意味しない。** 画像上に選択が見えるかを
観測できるのはモデルだけなので、通常Vision promptが「見えればそれを主対象として読む、見えなければ
通常の画面説明、どちらでも選択の有無を口にしない」と指示し、判定をモデルへ委ねる。選択内容は
回答対象を決めるsemantic authorityであり、AXはそれを運ぶacquisition channelにすぎない。

復帰点はtag `pre-vision-selection-extension-20260731`、commit `dcac535`。作業branchは
`feat/vision-selection-extension`。同じ`VisionSession`、`/api/ai/vision`、model route、
fallback、Skill、Copilotを維持し、別surface、別endpoint、別prompt、長期feature flagは作らない。
現行`v0.2.1`との旧fieldは恒久入力adapterとして受理するが、同じ内部型へ正規化して意味経路を
二重化しない。mode命令は単一request intent resolverで決定し、通常taskとselection taskを連結しない。

- **C0（完了）** 要件、目標契約、復帰点、C1〜C6のcommit境界と受け入れ条件を正本へ固定した。
- **C1（完了）** リポジトリ外のread-only AX probeでChrome Gmail、controlled Safari／Chrome、
  TextEdit、VS Codeを計測した。Chrome Gmailは単一document selectionで全文757 UTF-16 unitsを返し、
  Safariは公開AX本文を返さないため`visualOnly`へ退化する。segment fallbackを採用せず、短命probeは
  結果記録後に削除する。Safari Gmail、Slack、Apple Mailの製品固有golden pathはC6で確認する。
- **C2（完了）** `VisionSelectionContext`、`VisionSelectionStructure`、複数frame、acquisition状態、
  capture visibilityと純粋`VisionSelectionResolver`を追加した。document全文優先、native consensus、
  短いlabelによる本文置換禁止、range不一致、visualOnly、secure拒否、frame重複除去をunit testで固定し、
  36件が成功した。未使用`VisionFocusTarget.region`は削除した。現行本番入口はまだ切り替えていない。
- **C3（完了）** Gatewayへ後方互換な`selection`契約、恒久legacy adapter、共通内部型を追加した。
  promptを単一intent、selected text、screen evidence、selection structureへ分け、画像、Skill、turns、
  candidates、identity、model route、responseを共通のまま維持した。12,000 UTF-16 units内の頭尾保持、
  capture外、prompt injection、短い局所labelが長い選択全文を置換しないことを固定した。Gateway 8件、
  macOS 39件、型検査、対象lintが成功し、本番入口はまだ切り替えていない。
- **C4（完了）** 右Shiftの本番入口をresolverから`VisionSession(selection:)`へ切り替えた。AXは
  documentまでのdirect selected text候補を収集し、選択全文と部分的に重なる複数構造を別provenanceで
  保持する。macOSの単一`VisionFocusTarget`、旧field encoding、selection専用task、単一対象カードを
  削除し、画像上だけの選択も`visualOnly` extensionとして同じVision Coreへ渡す。追加質問は同じsessionの
  最新質問を優先し、Copilotの新captureへ古いselection payloadを渡さない。macOS unit test 35件が
  成功した。
- **C5（完了）** 同じVisionパネルへ選択全文カードと全visible frameの個別枠を追加した。テキスト選択を
  短いstructure labelで置換せず、`visualOnly`だけを表面の取得状態として示す。位置不明／capture外は
  その事実を表示し、acquisition、segment／structure／frame数、completeness、capture visibility、
  wire truncationは内容なしで既存の処理情報へ追加した。ネイティブButton、VoiceOver順序、Increase
  Contrast、Reduce Transparency、Reduce Motionへ対応し、presentationを含むmacOS unit test 39件が
  成功した。
- **C6（進行中）** ローカル自動検証と差分監査を実施した。通常／Selection Extension requestの
  selection以外の同一性、単一intent、全文scope、prompt injection、legacy adapter、secure descendant、
  capture外を回帰testへ追加し、起動先を同じVisionへ一本化した。macOS 41件、Gateway 14件、Web lint、
  TypeScript、production build、署名なしDebug buildが成功し、別endpoint、別model route、長期flag、
  probe残骸、起動時clipboard／合成⌘Cの再混入が無いことを確認した。後方互換Gatewayは2026-08-01に
  macOS候補版より先に`main`／本番へ配備した。署名付き候補版の実機golden pathと、同一端末でのwarm
  p50／p95比較を残す。coldの2秒deadlineはコード・unit test上で維持している。
- **R10.5（実装済み・実機検証待ち）** C6実機テストで、何も選択していない画面にも選択カードと
  選択用promptが常に付き、モデルが選択の不在報告から回答を始める不具合を確認した。原因は
  `visualOnly`／`accessibilityElement`という観測主体を持たない状態で、正本が実装不能な条件を
  書いていたことに起因する。修正計画・判定記録・受け入れ条件は
  `api-gateway/docs/vision-selection-evidence-fix.md`を正とする。
  順序は正本修正（済）→ Gateway「受理して無視」ホットフィックス → 本番デプロイ
  （この時点で`v0.2.1`ユーザーの症状も消える）→ クライアント削除＋retry再設計 → 計測後にwire撤去。
  正本修正・Gatewayホットフィックス・本番デプロイ（`349bb9c`）・クライアント削除・retry再設計まで
  完了した。selectionは`VisionSelectionResolver`が確定した非空textからのみ成立し、内部型は
  `kind`単一case・`text`必須へ収縮した。`AXSelected`はクライアントから概念ごと消え、bounded retryは
  証拠の兆候がある間だけ継続する。Gateway 17件、macOS 40件、Web lint／production build、署名なし
  Debug buildが成功。残るのは移行計測後のwire撤去である。
- **R10.5後半（完了）** 実機で「AXが選択を返しているのに製品が捨てている」ことが確定した。
  祖先walkが`AXWebArea`をスキップし（Chromeはdocument自身をfocused elementにする）、それを拾う
  はずのdocument走査は「window全体を256要素以内で走査完了」を要求して決して成立しなかった
  （Chrome Gmail 1,540要素超、VS Code 5,824要素）。web areaをroleでdocument scopeと判定して読み、
  走査上限を4,000へ上げ、完走必須条件を外した。secure保護は焦点チェーンの検査が担う。
  実機でChrome Gmailが`ax_document_selection` / `complete`となり、probe計測では取得1ms
  （修正前は候補0件でAX収集に1,500ms）。選択なし画面・VS Code webview・長い選択もすべて確認済み。
  R10とR10.5をmainへ統合し、`0.2.2` build `6`として公開する。

受け入れ条件と詳細なcommit境界は[focused-vision-plan.md](focused-vision-plan.md)の
プロジェクトCを正とする。R10はR9のclipboard安全化やTransform撤去を巻き戻さず、選択理解の
データモデルとprompt合成だけを正す。

### R11 — 起動確実性と公開品質（`0.2.2`公開の前提、実装・機械検証完了／長時間稼働試験のみ未了）

2026-08-03、約38時間連続稼働したアプリでVisionが「スピナーも出ない・画面画像も出ない・
エラーも出ない」空のパネルになり、再起動で回復した。同一プロセス・同一ビルド・同一画面で
24分前は正常に完走しており、実測ログではリクエストが1件も発行されていない。プロバイダ側は
同時刻に実画面サイズで一次985ms／二次3006msで応答しており、Gateway・モデル・ネットワークは
原因ではない。

原因は、Visionの初回リクエスト（`VisionSessionView.swift:34`の`.task`）と画面画像の読み込み
（`ZoomableScreenshotView.swift:87`の`.onAppear`）がSwiftUIのappearance callback 1点だけを
引き金にしていることである。パネルのヘッダーとキャレットは描画されていたので、body評価は
生きており、壊れたのはappearance通知だけだった。Composeは同じ形をしておらず、AI処理は
コーディネーターが所有している。**正しい形はすでにリポジトリの中にある。**

障害の召喚は`from=idle`であり、直前の`resignActive`で`PanelController.close()`まで到達して
いるため、**新品のNSWindowと新品のNSHostingControllerで失敗している**。当初「劣化源として
最有力」としたホスティングコントローラーの差し替え蓄積は、この実測で否定された。劣化は
ウインドウ単位ではなくプロセス単位で起きており、パネルを作り直す自動復旧も期待できない。

R11では次を不変条件とする。

```text
セッションが開始したかどうかは、UIの描画都合に依存してはならない。
どの操作も無音で終わらない — 有限時間で結果か原因を述べるエラーへ到達する。
```

**「再起動してください」を顧客へ案内する状態を公開品質と認めない。** `0.2.2` build `6`は
versionを上げただけで未公開のため、R10／R10.5の成果を先に出すのではなく、R11の完了を
`0.2.2`公開の前提条件とする。

実施順は D1 → D2 → D3 → D6 → D5 → D8 → D9 → D7。復帰点はタグ`r11-start`、作業ブランチは
`r11-reliability`。

- **D0（完了）** 原因分析、目標構造、受け入れ条件、技術的負債15項目の棚卸しを
  `api-gateway/docs/reliability-hardening-plan.md`へ固定した。実測により
  旧D4の前提を反証し、実施順と範囲を改訂した。
- **D1（完了）** 診断を`#if DEBUG`のNSLogから`os_log`へ移し、release buildでも開始・発行・
  完了・失敗を記録する。本文・回答・画像・タイトル・ホスト名は載せない。同じ記録を
  リングバッファへ持ち、管理画面からコピーできるようにする（顧客のログはsysdiagnoseなしでは
  届かないため）。
- **D2（完了）** Visionの開始をコーディネーターが所有する。`.task`を外しても初回リクエストが
  出ることをunit testで固定する。
- **D3（完了）** 画面画像の読み込みをappearance callbackから切り離す。sessionが表示用画像を
  値として持ち、ビュー側の読み込みという概念を無くす。
- **D5（完了）** ユーザーに見える操作を、期限・トレース・終端状態を必ず伴う単一のランナー
  経由でしか実行できない形にする（現状`timeoutInterval`／`maxDuration`ともに0件）。
  `accessToken()`の無期限await、Gateway側`fetch`、リクエスト未発行のウォッチドッグを含む。
  一次ハング時のfallbackはtimeoutが例外へ変換することで成立し、fallback機構は改造しない。
- **D6（完了）** 無音失敗の撤去。`CancellationError`の一括無音returnと、遷移拒否時にも走る
  `close()`のteardownを分離する。`transition`の`@discardableResult`を外し、戻り値を捨てている
  箇所をコンパイラに列挙させる。
- **D8（完了）** 最後の回復手段をメニューバーへ置く（「Universal I/Oを再起動」）。パネルが
  応答しない状況の回復手段をパネル内に置かない。自動再起動はしない。
- **D9（完了）** リポジトリ全体の`.task`／`.onAppear`を監査し、フォーカス・アニメーション・
  表示状態以外の副作用が0件であることを確認する。
- **D7（項目追加は完了、実施は未了。1回目の試行が未達で終了）** 24時間以上連続稼働後のgolden
  pathを[manual-golden-paths.md](manual-golden-paths.md)へ追加し、リリース前チェックとして実施する。
  1回目の試行（PID 20271、2026-08-03 21:53:01 → 2026-08-04 22:15:12、**24時間22分**）は、
  稼働時間は満たしたが**最後の操作が14:53（17時間時点）で、24時間到達後は無操作のまま
  正常終了した**。求めているのは稼働時間ではなく「24時間を超えたプロセスで各操作が通ること」
  なので、通過にはならない。次回は24時間到達の直後に実施する。

macOS unit testは41件から61件へ増えた。webのlint／型検査／production buildも成功している。
残るのは実機検証で、D7の長時間稼働試験、署名付き候補版でのGolden Paths、Gateway側変更の
本番デプロイ（`main`へのpush）が未了である。

旧D4（パネル表示の作り直し）は`0.2.2`のゲートから外す。障害は新品のウインドウで起きており、
ホスティングコントローラーの寿命を延ばしても防げない。衛生改善として公開後に扱う。

詳細と技術的負債の一覧は`api-gateway/docs/reliability-hardening-plan.md`を正とする。

### R12 — 案内の正確さ（未着手）

R11が「無音で止まらない」を扱ったのに対し、R12は**動いているのに内容が正しくない**を扱う。
2026-08-03の実機使用で次を確認した。

- Copilotが、開いたプルダウンが画面に出ているのに「画面に変化は見えませんでした」と述べた。
  実測ではクライアントのピクセル差分が`blockMax = 0.0088`（しきい値0.05）を返しており、
  **モデルにもAXにも関係しない**クライアント内の判定である。一次モデルを戻しても変わらない。
- Copilotの進捗ターンは前の画面画像を渡しておらず（`turns: []`、`question: nil`）、
  **構造上、変化を知覚できない**。それでもUIは変化の有無を断定している。
- 同一画面の連続ターンでAX候補が136件→136件→0件（`node_limit`）と不安定で、候補ゼロが
  成功と同じ経路を流れる。ハイライトが的外れになる材料がここにある。
- 先回り文案が相手ではなくユーザー自身の発言へ返信し、実行者を反転させた（M0.6）。

不変条件は2つ。

```text
アプリは、自分が観測していないことをユーザーへ述べない。
モデルには、その判断に必要なものを渡す。
```

E1（実機probeで測定）→ E2（観測できないことを述べない）→ E3（Copilotに前後を渡す）→
E4（候補ゼロを失敗として扱う）→ E5（話者と実行者＝M0.6）→ E6（固定材料でのモデル比較）。
**入力を直してからモデルを測る。** 壊れた入力での比較は、モデルの差ではなく入力の壊れ方を測る。

詳細は`api-gateway/docs/guidance-accuracy-plan.md`を正とする。

### R13 — 速さ（L1・L2実機確認済み、L3〜L5計測・改善中）

R11が「無音で止まらない」、R12が「正しくない」を扱うのに対し、R13は**正しいが遅い**を扱う。
ホットキーで呼ばれるアプリなので、待たされるほど「自分でやった方が早い」に近づく。

計測が単一起点になっていなかった。AX走査・identity解決・Gateway往復は並行して走るため
足し算に意味が無く、ユーザーが体感する「ジェスチャからパネルまで」「Gatewayが返ってから
画面に出るまで」はどちらも測っていなかった。`SummonClock`で起点を1つにし、
`vision.firstContent`（最初に読めるものが出た瞬間）を記録した。Copilot進捗ターンは
本番ビルドで1行も残っていなかったので、同じ梯子を追加した。

**「ストリーミング」は配管だけで、逐次ではなかった。** reviewのSSE封筒はクライアントまで
通っていたが、どのプロバイダ呼び出しも`stream: true`を送っていなかった。Visionには封筒すら
無く、モデルがJSONで答えるため閉じ括弧まで1文字も出せなかった。Visionを逐次化し、
未完成のJSONから`message`だけを取り出して送る。増分は読ませるためだけに使い、
mode・ハイライト対象・不確実性は最後の検証済みオブジェクトから読む。

実測で分かった最大の数字は**画像トークン4,927**（2560×1600、Retina実寸）である。同じ画面を
1280×800にすると1,327まで落ちる。一方ストリーミングが取り戻すのは生成の尾（約1秒）で、
prefillはそれより大きい。**ただし縮小の可否は「開いたメニューの文字が読めるか」を測るまで
決めない**（R12 E6の合格条件と同一）。

**AX走査は「どこから諦めるか」ではなく「1ノードいくらか」の問題だった。** 本番は1ノードごとに
7回の個別属性読みを行っていた。`AXUIElementCopyMultipleAttributeValues`で1往復にまとめると、
**候補が1件も変わらないまま2.3〜5.7倍**速くなる（実機5アプリ、role・label・矩形の
フィンガープリントで突合）。その結果`maxNodes = 2_000`は保護から欠落の原因へ変わっていたので
（VS Codeの3,300ノードが61%、6,885ノードが29%で切られていた）、**期限1.0秒は動かさずノード上限だけ
8,000へ**上げた。待ち時間の上限は同じまま、同じ1秒でツリーの数倍を見る。
撮影範囲外サブツリーの刈り取りは測定の上で却下した（Xcodeで812→2ノードに壊滅）。

冷えた初回の実測では、モデルの前に`getUser=1,099ms`、tenant取得`665ms`、entitlement取得
`639ms`、月次COUNT`273ms`を使い、以後のターンでもCOUNTが642〜942msだった。FKを確認した上で
profile・tenant・entitlementをPostgRESTのembedded relation 1リクエストへ統合し、月次利用数は
5分の値キャッシュへ変えた。成功usageは既知の値をその場で進めるため、同一Gateway instanceでは
次ターンのCOUNTが消える。DB変更は無い。`getUser`を署名のローカル検証へ変える案は約1.1秒の余地が
あるが、失効がJWT期限まで反映されない可能性を伴うため、この段階では製品判断まで保留した。

1-qの本番再計測ではpreflightが2,676→1,210ms、後続は0msになった。ユーザー判断を受け、
AI routeだけ`getClaims()`によるES256署名・期限のローカル検証へ変更する。アカウント・課金・
ファクト・管理routeは`getUser()`を維持する。両方式のcache keyも分離し、AIで得たcontextが
敏感なrouteのAuth server確認を迂回しない。

本番実機では起動時warmが同じinstanceへ届き、初回・質問とも`verifyJWT`、tenant+entitlement、
plan、COUNTがすべて0msになった。JWT高速化は受け入れ完了。残る観測値はidentity 1,470ms、
回線等1,695〜3,077ms、AX focus 1,153ms／候補収集1,758ms（ともに2パス）である。

L1（単一起点で測る）→ L2（分かった順に出す）→ L3（画像コスト＝R12 E6と合流）→
L4（AXをどこまで取るか）→ L5（Copilot撮影予算＝R12 E2と合流）→ L6（review/suggest逐次化）→
L7（モデル選定＝R12 E6）。**速くするために正しさを削らない。**

詳細は`api-gateway/docs/latency-plan.md`を正とする。

### R14 — 実画面の上で指して聞くVision（未着手・要件確定）

Web版（`app-web`）が「**指した場所の隣に答えが出る**」を実装し、実利用の評価が現行macOS Visionを
上回った。新機能を足したのではなく、**答えの置き場所を変えただけ**である（指した場所と答えの場所が
離れていると目が往復する）。Web版の`docs/pointing.md` §7は、この形をネイティブ版の目標として明示的に
申し送りしている。Webは画像の中でしかこれをできないが、macOSはAXの実測座標を持ち実画面の上に直接
描けるため、**同じ体験をより高い精度で、画面共有という前準備なしに**成立させられる。

R14では次を不変条件とする。

```text
Visionは「パネルを出す」ではなく「モードに入る」。
表示は実画面の上に出す。撮影は理解のための手段であって、見せるためのものではない。
指すこと自体が質問である。確認のためのボタンを挟まない。
製品が喋る場所は1つだけ。
```

目標の体験は、右Shift 2回でVisionモードへ入ると実画面の上に覆いが乗り、**入った瞬間に現在の画面の
解説が始まる**（質問は要らない）。解説は右下のバブルへ1文字ずつ書き出される。実画面のどこかを
クリックするとバブルがその場所の隣へ移り、そこについての解説が始まる。バブルの中で続けて質問を
打てる。Escで抜ける。Composeから右Shift 2回で入る経路も同じ形で、**範囲選択の確認待ちは入口から
外す**。

#### 確定した製品判断（2026-08-23）

1. **実画面優位。** 静止画パネルは目標形ではない。撮影は理解のための手段にすぎない。
2. **`pointer`と`candidates`は両方送る。** 併用のダウンサイドが分かっていないため、まず両方送って測る。
3. **指した印は送信画像のバイト列へ焼き込む。** 覆いに描いた印は撮影から除外されるため（下記）、
   これは選択肢ではなく必然である。幾何はWeb版`lib/marker.ts`の移植とし、焼き込みの位置
   （縮小前／縮小後）と数値併記の効き方は実測で決める。
4. **ホバーでは呼ばない。タップした時だけ。** 1リクエスト＝1ユニットで、free 200/月・全体5,000/月の
   枠をWeb版と共有しているため、カーソルが通過するたびの呼び出しは成立しない。ホバーで費用ゼロの
   情報（既に得た`annotations`のlabel等）を出すことは将来の加算として残す。
5. **Copilotへの導線は現行を維持する。** 指差しは通常Visionの入口を置き換えるが、`guidance`ターンと
   Copilotストリップの構造は変えない。

#### 実装で確認した事実（推測ではない）

- **撮影は自アプリを除外している**（`ScreenshotCaptureService.swift:126-134`の
  `SCContentFilter(display:excludingApplications:)`）。したがって覆いとバブルを乗せたまま撮っても
  下の実画面だけが撮れ、Web版が費やした合わせ鏡の検出（自己共有プローブ）は**丸ごと不要**である。
  同時に、**除外はアプリ単位なので覆いに描いた印も写らない**。モデルへ「ここ」を見せる手段は
  焼き込みか座標かの二択になる。
- **クリックを飲む全画面キーウインドウは実働している**（`ScreenshotSelectionOverlay.swift:29-42`の
  `KeyableOverlayWindow(clickThrough: false)`）。新規の危険なAPIは要らない。`CGEventTap`も使わない。
- **Gatewayは`input.pointer`を本番で受ける**（`vision-prompt.ts:55-73`）。intent resolverは
  `guidance > question > pointer > selection > 初期説明`で、質問なしのpointerには専用の指示がある。
  **Gateway側の変更は不要**である。
- **Gatewayはcandidateの矩形をモデルへ渡さない**（`app/api/ai/vision/route.ts:175-182`が
  `id/source/role/label/parent_label/states`だけを取り出す）。したがってAXは「バブルの置き場所と
  枠」の実測であり、**モデルにとっての根拠は焼き込んだ印**である。
- **AX候補は操作系13ロールだけ**（`VisionObservationCaptureService.swift:145-149`）。本文テキスト・
  画像・グラフ・canvasには当たらない。指した場所の要素をロールを問わず取るには
  `AXUIElementCopyElementAtPosition`が要る（リポジトリ内0件）。
- **候補の座標は既に`normalized_top_left`の0-1**（`VisionObservation.swift:88`）で、`pointer`と同じ
  空間である。変換を新しく書く必要はない。
- **ペン（`ScreenshotPreviewTool.annotate`）は実装済みだが本番から到達不能**で、描いた矩形は
  Gatewayへ送られない（`VisionSessionView.swift:101`が`tool: .pan`固定、`annotations`は`@State`のみ）。
  指差しの受け皿が半分だけ既にある。
- **候補の送信は`question != nil`で門番されている**（`VisionSession.swift:406`）。冷えたブラウザの
  AXツリーを待たないための意図的な性能設計で、開幕解説ではこれを維持する。ただし指差しターンは
  質問が無いまま候補を要る唯一のターンなので、条件を質問の有無からターンの種類へ切り替える。

#### 設計の芯

**入場時の1枚を、指差しの間ずっと使い回す。** 覆いがクリックを飲んでいる間ユーザーは下のアプリを
操作できないので、画面は動かない。これ1点で毎クリックの再撮影・AX再走査（最大5.0秒）・
`capture_id`の再発行が消え、**クリック1回の待ちはGateway 1往復だけ**になる。画面が実際に動く場面
（動画・時計）での使い回しの破れは、既存の`StableScreenCaptureService`の差分で測って判断する。

#### 先に外す落とし穴（これを外さないと作れない）

- `PanelSpec`の`closesOnResignActive`（`PanelController.swift:31-36`）。外さないと覆いを出した時点で
  セッションが閉じる。
- `activateTargetApp()`（`VisionSession.swift:906`）をCopilot限定にする。覆いが自アプリをactiveに
  保つ前提と正面衝突する。
- **指し直しは新主題として`turns`を捨てる。** Web版は捨てなかった版で「タップのたびに最初の回答が
  返る」不具合を出した。現行macOS Visionは`turns`を積み続けるので、同じ条件が揃っている。

#### マイルストーン

各段階が単独で検証可能であること（実機が要るものと要らないものを混ぜない）。

- **F1** 落とし穴を外す。他アプリを前面化してもVisionセッションが残ることを確認する。
- **F2** 覆いだけを出す（バブルなし・撮影なし・通信なし）。**最小コストで2つの未確認を確定させる** —
  非活性のままクリックを取れるか、覆いの上で日本語IMEが確定するか。ここでバブルを別ウインドウに
  するかが決まる。
- **F3** 覆いを出したまま1枚撮り、出力を目視して覆いが写らないことを確認する。撮影単体のms記録を
  足す（現在この経路に`Diagnostics`は0件）。
- **F4（完了）** `VisionPointer`と`VisionPointerResolver`を純粋な値と関数として追加した。Cocoa
  グローバル→CGグローバルは`HighlightOverlayPresenter`の反転の鏡として書き、4つ目の式を作っていない。
  撮影範囲外のクリックはclampせずnilを返す（撮影の縁はユーザーが指した場所ではない）。ヒットテストは
  点を含む最小の候補を採る。候補ゼロは正常な結果として固定した。
- **F5** 覆いに印とヒット枠を描く（通信なし）。二次ディスプレイでもズレないことを確認する。
- **F6（完了）** 焼き込みを`VisionPointerMark`として実装し、送信経路（`encodeForWire`）の
  downscale後へ入れた。幾何はWeb版`lib/marker.ts`の移植で、リング＋十字、矩形、手描きの軌跡その
  ものを描く。ピクセルを読む単体テストで、指した位置、上下反転、リング（塗り潰しでない）、
  範囲外の無傷、送信base64に印が残ること、pointerが無い場合に元バイトが素通りすることを固定した。
  縮小前に焼く案との比較は実機で測る。
- **F7** `pointer`をリクエストへ、指差しターンをSessionへ追加する。pointer以外のフィールドが通常
  Visionと同一であることを契約テストで固定する。
- **F8** 実機で1本通す。答えは既存パネルで読む。**UIを作る前に契約が効くことを確定させる。**
- **F9** バブルを覆いの上に出し、Visionを`.overlay`提示へ切り替える。入場で開幕解説、クリックで移動、
  質問が打てる。
- **F10** 書き出し表示（本物のSSE deltaを使う。Web版の疑似タイプとは実装が違い、速さの見え方だけを
  揃える）。
- **F11** 静止画パネル系を撤去する（およそ850行。`ZoomableScreenshotView` 481行、
  `ScreenshotAnnotation` 136行、パネル内の画像・ハイライト・選択カード）。
- **F12** build番号を上げて署名ビルドし、D7相当を通す。入場ms・クリックms・AXヒット率を
  unified logから集計する。

#### 実機で測らないと決まらないこと

1. **非活性のままクリックを取れるか**（F2で確定）。取れない場合、対象アプリが非活性になり、撮った
   画面の見た目（フォーカスリング・開いたメニュー）が変わる可能性がある。
2. 覆いの上で日本語IMEが確定するか（F2）。
3. 入場から最初のdeltaまで、クリックからdeltaまでの実測ms。
4. 焼き込みを縮小の前後どちらでやるとモデルの正答が上がるか（同一画面・同一点で各10回）。
5. AXヒット率（ボタン／本文／画像／canvasの内訳）。missが多数派なら枠を出さずバブルだけにする。
6. `pointer`と`candidates`を同時に送った実挙動（Gateway側にこの組み合わせのテストが無い）。
7. 覆いがフルスクリーンアプリ・Mission Control・Stage Managerでどう振る舞うか。
8. マルチディスプレイで、覆っていない画面のクリックがどうなるか（`ActiveDisplay`はセッション中
   1画面にピン留めする設計で、「別画面を指差す」と衝突する）。

#### Web版から持ち込む体験規則

正本は`app-web/docs/pointing.md`。バブルは指した点の右下20px・はみ出したら反対側・最低12px余白、
**指した対象と回答の枠を隠さない**、バブルは1つだけ、**枠が返ったら自分の印を引っ込める**、
待っている間は印そのものが脈打つ、`prefers-reduced-motion`では静止。色は「ここ・これ・あなたが
触ったもの」を1色に統一し、状態（動いている・注意）には貸さない — 現行macOSは`systemRed`で、
Web版は`iris`。**同じ製品が2つの見た目を持たないよう、どちらかへ寄せる判断が要る。**

**Web版の数値のうち実機未検証のものを設計根拠にしない。** 初回説明が何行で何秒返るか、指した対象と
返ってくる枠が一致するか、待ち時間の典型値は、Web版でもまだ記録されていない。

R14は「正しいが遅い」（R13）と「動いているのに内容が正しくない」（R12）を巻き戻さない。速さのために
正しさを削らず、**指差しという新しい経路にもR11の不変条件（無音で終わらない）を通す**。

## リリース判定

**配布には2段ある。** 候補DMGを版付き不変URLへ置くこと（`--publish`）と、公開ダウンロード
`Universal-IO.dmg`をそこへ向けること（`--promote`）は別の判断である。テスターへ渡すのは前者で
足り、下の判定は後者にだけ適用する。2026-08-11に`0.2.2` build `8`がD7を通過し、公開ダウンロードは
このビルドへ切り替わっている。

以下をすべて満たした時だけ**公開ダウンロードへ向ける**。

- R2〜R4が完了している。
- R11が完了している（`0.2.2`以降）。長時間稼働後もセッションが確実に開始し、失敗が無音で
  終わらないこと。「再起動してください」を回避策として案内しない。
- 主要4 AI endpointに旧・代替endpointが存在せず、各routeのモデル指定が共通SSOTだけにある。
- 重大度Highの既知不具合が0件。
- Composeのレビュー後フォーカス、自動返信、音声入力、Vision初回応答が実機で再現可能。
- rollback先と本番Gatewayの互換性が確認されている。

## 次期改善候補（2026-07-22 実機テスト所見）

以下は現行リリースの阻害要因ではなく、別セッションで設計・実装する改善候補とする。

### Copilot完了時の終了・フィードバック導線

- 完了時の「目的の情報を確認しました」は、状態説明なのか案内終了なのか意図が曖昧。
- 「目的を達成したので閉じる」「案内を終了」など、ユーザーが完了を確認して閉じる明示的な
  操作に置き換える。この操作は目的達成のフィードバック信号としても扱えるようにする。
- 完了操作の横にGood / Badとコメント用の吹き出しを置き、任意で評価や具体的な意見を
  運営へ送れる導線を検討する。
- 収集項目、送信前の説明、本文・画像・画面情報を含めるかどうか、保存期間を実装前に定め、
  ユーザーの意図しない情報を送信しない。

### provider ZDRのリリース運用

- usage保持期間と退会機能は実装済み。provider ZDRはコードでは確認不能な外部設定なので、
  管理画面で有効化・記録するリリース運用を完了させる。

### 次期開発: アカウント、課金、テスター運用

- 新規ユーザーは全員`free`・月500件で作成される。`standard`はCheckout・顧客ポータル・webhook反映・
  解約導線まで実装済みで、**sandbox鍵での購入・即時解約・期間終了時解約・再購入をすべて実地検証済み
  （2026-07-29）**。残るのは本番鍵への差し替えと、その後の再検証である
  （[manual-golden-paths.md](manual-golden-paths.md)「課金」）。`pro` / `team` / `enterprise`は
  catalogだけが存在し、販売価格も上限（現在null＝無制限）も未定である。
- 販売する最初のプランは`standard`のみ、月額のみ、通貨はJPY（2026-07-27決定）。開始時点は
  ¥1,980／月2000回（1回あたり約¥1）。**この数字の正本はドキュメントではない** — 金額はStripeの
  price、枠は`bs_plans.monthly_usage_limit`が正本で、変更に本書の更新は要らない。ここに記録するのは
  水準を選んだ理由だけである。
- **意図的に原価を下回り得る水準である。** 実測で1回の入力は約11,500〜15,500トークン（大半が画面画像）、
  月2000回で約2,400万〜3,100万トークンを¥1,980で売る計算になる。それでも採る理由は3つ:
  コンシューマー課金は事業の最初の勝ち筋ではない、同じ精度がより安いモデルで出るようになる方向に
  技術が動いている、そして**有料でも使うユーザーがいるという事実自体がピッチの証拠になる**。
  完全無料では体力が持たないため、下限として置く。頻繁な変更を前提とする。
- 原価の主要因は画面画像なのでプロンプトキャッシュはほぼ効かない。効くレバーは画像解像度
  （`SUGGEST_IMAGE_DETAIL`、および4096px超のみ半減させる現在のキャプチャ設定）で、原価と
  小さな文字の読み取り精度が直接トレードオフになる。安価なモデルで同精度が出るまでの間の実弾として
  記録しておく。
- free=500に対しstandard=2000は4倍でしかない。有料が伸びなかった場合、原因が価格なのか無料枠が
  十分すぎたのかを切り分けられないため、free側を下げる選択肢も併せて持つ。
  JPYを選ぶ理由は、日本アカウントの決済通貨がJPYであり、USD請求は毎回の為替手数料と顧客側の
  海外取引手数料を生み、総額表示義務との整合も悪いため。グローバル展開時はStripeの多通貨価格で
  USDを追加し、商品は作り直さない。
- price idとplanの対応は`bs_plan_prices`が持つ（`supabase/migrations/20260727000000_plan_prices.sql`）。
  1プランに複数のprice idが付く（sandbox／live、価格は編集不可なので値上げごとに増える、間隔・通貨の
  追加）ため、列ではなく対応表とする。**planが何を与えるかは`bs_plans`だけが決める**という境界は動かさない。
- トライアルは付けない。`free`=500がすでに試用の役割を持つため、カード登録後の無料期間は二重になる。
- **解約は期間終了時に効かせる**（2026-07-29決定）。支払った月は使えるという扱いで、即時停止も
  日割り返金もしない。この間`status`は`active`のままなので、契約状態そのものを
  「解約手続き完了（◯年◯月◯日まで有効）」と表示する。表示しないと、解約した人には「有効」としか
  見えず手続きが通ったのか分からない。
- **課金状態はブラウザで変わり、アプリからは観測できない。** 購入も解約もStripeか製品サイトで完了する
  ため、アプリが握る値はユーザーが離れた瞬間から古く、しかも古い値の方が危険である
  （支払った直後に「フリー」と出れば入金が消えたと解釈される）。課金状態を映す画面を開いた状態での
  前面化を引き金に照合し、webhook適用の1〜2秒に人間が勝つ前提で2回読む。起動のたびには取得しない
  （ホットキーで何度も前面化するため）。
- 支払い失敗中（`past_due`）は有料プランを維持する猶予とする。Stripeの再試行は数週間続くので、
  初回失敗で止めるとカード更新中の顧客を実際の解約よりきつく扱うことになる。アクセスを失うのは
  Stripeが最終的に解約した時点で、そこで`free`へ落とす。`canceled`をentitlementへ書かない
  （無料枠まで消える）、契約IDを残さない（退会できなくなる）という2点は変えない。
- Stripeの鍵は`STRIPE_SECRET_KEY`と`STRIPE_WEBHOOK_SECRET`の2つだけをGateway環境に置く。
  ホスト型Checkoutを使うためpublishable keyは持たない。macOSクライアントはStripeを直接呼ばない。
  本番環境にサンドボックス鍵を置く期間があるため、Gatewayが鍵の接頭辞から現在のモードを判定し
  管理画面へ表示する（差し替え忘れの検出）。
- 管理画面へ入れる`ADMIN_EMAILS`と商用planは別概念である。管理者であることだけではquotaや
  billingを免除しない。次期設計では権限、契約、利用制限を独立した軸として扱う。
- Stripe課金の有無に加え、社内運用、招待テスター、無償提供など、請求や通常制限を適用しない
  account classを明示的に持たせる。個別ユーザーの場当たり的なquota変更で代用しない。
- Admin Consoleでplan・account class・契約状態を確認・変更し、変更者、変更時刻、理由を監査する。
- テスター別・cohort別の利用回数、機能別成功率、fallback、エラー率、レイテンシを監視する。
  入力本文、回答、画像、音声などの内容は管理画面へ保存・表示しない。
- モデル別token／音声秒数へ価格表を掛けたAPIコスト概算、ユーザー／機能／日別の推移、予算閾値を
  表示する。最終請求額はOpenAI、Groq等のprovider管理画面を正とする。
- 詳細設計と実装順序の正本は`api-gateway/docs/admin-dashboard-plan.md`に置く。

## 変更ルール

新しい方式を試す時は、この本番構造を変更する前に短命ブランチを作る。採用時は現行方式を
同じ変更で置換し、不採用時はブランチを閉じる。二方式の常設並走は禁止する。
