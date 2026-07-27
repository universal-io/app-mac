# Universal I/O マスタープラン

最終更新: 2026-07-25 ／ ステータス: `v0.2.0` 正式公開済み

## 製品

Universal I/O は、人が情報を送る・受け取る・画面上で行動する間に入り、意図と表現を
整える中間レイヤーである。自律操作ではなく、最終判断と操作はユーザーが行う。

製品surfaceは4つだけとする。

1. Compose: 自分の文章を作り、必要ならレビューして送信する。
2. Transform: 受信文章を理解し、返信や次の行動を準備する。
3. Vision: 現在の画面を読み、質問へ答える。
4. Copilot: 画面上の次の一手を示し、ユーザー操作後に再評価する。

## 現行アーキテクチャ

```text
macOS UI
  └─ SessionCoordinator
       ├─ ComposeSession  ── /api/ai/review
       ├─ TransformSession ─ /api/ai/transform
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
- 下書きとCompose送信履歴はMacローカル。履歴上限は100件。Transformは一切履歴化しない。
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
- Compose、Transform、Transcribe、Memoryを本番Gateway専用に統一。
- 実験資料とアーカイブをGit履歴へ戻し、作業ツリーから削除。

### R2 — 機械検証（完了、2026-07-22）

- XcodeGen生成が成功する。
- macOS Debugを署名なしでビルドできる。
- Web lint、TypeScript、production buildが成功する。
- 本番route一覧とクライアントendpointが一対一で一致する。
- リポジトリ内に旧経路の参照が残っていない。

### R3 — 本番E2E（進行中）

- ログイン、レビュー、音声入力、受信変換、Vision、Copilot、履歴を実機確認。
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
- **セットアップウィザード（未実装・案）** 画面検出とは別の取得経路として、対話形式で精度に効く
  項目を決め打ちで埋める。初回起動には置かず、マイページ常設＋ある程度使った段階での導線とし、
  1問も答えなくても全機能が動くオプショナル層に留める。設計は[v3-tool-fit-plan.md](v3-tool-fit-plan.md) §4。

共通の受け入れ条件: Skillが無い画面で汎用品質が落ちないこと。汎用理解が限界までチューニング
されていることが前提で、Skillsはその上の加算に限る。

## リリース判定

以下をすべて満たした時だけ公開する。

- R2〜R4が完了している。
- 主要5 AI endpointに旧・代替endpointが存在せず、各routeのモデル指定が共通SSOTだけにある。
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

### Transformのパネル内スペース配分

- 画面内テキストを選択してTransformを開いた時、選択元テキストの入力欄が縦に広すぎて
  解説・変換結果の表示領域を圧縮している。
- 選択元テキストは確認に必要な高さへ抑え、解説・変換結果へ優先的に縦方向のスペースを割く。
- 長文時のスクロール、最小・最大高、ウインドウサイズ変更時の配分を含めてUIを調整する。

### provider ZDRのリリース運用

- usage保持期間と退会機能は実装済み。provider ZDRはコードでは確認不能な外部設定なので、
  管理画面で有効化・記録するリリース運用を完了させる。

### 次期開発: アカウント、課金、テスター運用

- 現在、新規ユーザーは全員`free`・月500件で作成される。`standard` / `pro` / `team` /
  `enterprise`のplan catalogは存在するが、購入・自動割当・Stripe連携は未実装である。
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
- 詳細設計と実装順序の正本は[admin-dashboard-plan.md](admin-dashboard-plan.md)に置く。

## 変更ルール

新しい方式を試す時は、この本番構造を変更する前に短命ブランチを作る。採用時は現行方式を
同じ変更で置換し、不採用時はブランチを閉じる。二方式の常設並走は禁止する。
