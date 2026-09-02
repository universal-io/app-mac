# Universal I/O マスタープラン

最終更新: 2026-09-02 ／ ステータス: `v0.2.2`（build `8`）を公開ダウンロードへ切替済み（D7通過）。`main`は`0.2.3`を開いている。R14・R15は実機で動作中（指した対象の認知精度100%、2026-08-24／案内が成立、2026-08-25）。R14のバブル配置は1ターン1配置の状態機械へ改修し、印とカードを独立させた挙動まで実機確認済み（2026-09-02）。R14の残りはF12（署名ビルドとD7相当）。R12はE1（測定）進行中。**R16（道具が押す＝操作）は2026-08-30に設計を確定し、未着手。**

## 製品

Universal I/O は、人が情報を送る・受け取る・画面上で行動する間に入り、意図と表現を
整える中間レイヤーである。**最終判断は常にユーザーが行う。道具が手を動かす段でも、一手ごとに
ユーザーが確定し、確定のない手は1つも進まない。無人で進む運転席は作らない。**

「自律操作ではなく、最終判断と操作はユーザーが行う」と書いていたのを2026-08-30に改めた。
**「操作はユーザーが行う」は、道具が押す段（R16）を嘘にする。** かといって「最終判断はユーザー」
だけに削ると、無人実行まで同じ一文で通ってしまい、ここで引いている線が消える。
線は「自律かどうか」ではなく**「一手ごとの確定かどうか」**にある。この粒度だけが 「操作」 を許し、
「連続」「無人」 を許さない。同じ主張は `docs/pitch/layer-value-thesis.md` の「エージェント時代の人間の
座席（approval seat）を作る会社」と、`api-gateway/docs/design-philosophy.md` の「実行は常に
人間承認」に既にあり、この一文はそれと同じことを言っている。

製品surfaceは3つだけとする。

1. Compose: 自分の文章を作り、必要ならレビューして送信する。
2. Vision: 現在の画面または選択対象を読み、質問へ答える。**解説**と**案内**の2状態を持つ。
3. 案内（Copilot）: Visionの2つ目の状態。画面上の次の一手を枠で示し、ユーザー操作後に再評価する。
   別surfaceではない — 同じセッション・同じ覆い・同じバブルで、幕の有無だけが違う。

surfaceの数と、そこで**誰が確定するか**は別の軸である。後者は5段あり、現行は 「案内」 まで実装済み。
**この段は新しいsurfaceを増やさない** — 「操作」 は案内状態の中の振る舞いであり、モードでも画面でもない。

| 段 | 名前 | 何が起きるか | 誰が確定するか | 誰のためか | 状態 |
|---|---|---|---|---|---|
| 1 | 解説 | 読む | — | 個人 | R14で完成 |
| 2 | 案内 | 次に押す対象を枠で示す | 人が押す | 個人 | R15で完成 |
| 3 | **操作** | 道具が押す・打つ | **一手ごとに人** | 個人 | R16（設計のみ） |
| 4 | 連続 | **1つの用事が終わるまで進む** | 人がゲートで | **個人**（普通の使い方） | 未設計 |
| 5 | 無人 | 人がいない | ポリシー | **法人。別製品** | 未設計 |

**4段目までは、同じ1人のユーザーが普通に使う道具である。** 「連続」は自律化ではなく、
用事の単位が1手から1件へ変わるだけである——SNSのプロフィールを設定し終える、
GA4で目的の数字にたどり着く。ユーザーは画面の前にいて、要所で確定する。

**線は5段目にある。** 人が画面の前にいない実行、つまり **Universal I/O を作業者として使う**（RPAの用途）
のが「無人」で、そこだけが法人向けの別製品になる。

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
- **Visionは「解説」と「案内」の2状態で、幕がその違いを言う。** 解説では幕が乗りクリックは質問、
  案内では幕が無くクリックは対象アプリへの操作になる。この2つを同時に成立させない。
  状態はバブル左上のチップが常に名乗る（不在はラベルにしない）。
- **案内へは、打ち込んだ質問の回答が`guide`だった時に自動で入る**
  （`VisionSession.opensGuidance(turn:mode:)`）。指示と行動の間にボタンを挟まない。
  指差しターンでは入らない — そのターンの本文「ここについて」が目的になってしまう。
  回答が`answer`の時だけ「案内を開始」を出し、押した時はその場で最初の一手を取りに行く。
- 案内は`candidate`矩形の有無にかかわらず続く。矩形は枠にのみ使い、取得できないWeb/Electron画面でも
  文章案内とクリック後の再評価を続ける。
- 案内の×で解説へ戻る（会話は残る）。目的に到達しても幕は戻さない。
- 案内中の進捗ターンは、目的・直前の指示・会話（最新20ターン、`VisionSession.maxWireTurns`）を渡す。
- **バブルの上のクリックは操作に数えない**（`VisionSession.advancesGuidance(clickAt:bubble:)`）。
  案内中は対象アプリが前面でこちらが非活性なので、グローバル監視には自分のバブルへのクリックも届く。
  数えると、バブルを動かすたびに枠が消え、暗転して撮影し、1ユニット払って「変化なし」を確認することになる。
- バブルは入力欄以外のどこを掴んでも動かせ、動かした位置は次に指すまで勝つ（上端基準）。
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

原因は、Visionの初回リクエスト（当時の`VisionSessionView.swift:34`の`.task`）と画面画像の読み込み
（当時の`ZoomableScreenshotView.swift:87`の`.onAppear`）がSwiftUIのappearance callback 1点だけを
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

### R14 — 実画面の上で指して聞くVision（F1〜F11実装済み・実機で動作中、残りF12）

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
   Copilotストリップの構造は変えない。**→ R15で撤回した**（2026-08-25の実機で、覆いの上では案内が
   成立しないことが分かった。ストリップは撤去し、案内は同じセッションの2つ目の状態になった）。

#### バブル配置の確定判断（2026-09-02）

**実装・実機確認完了。残タスクなし。** 以下を現行仕様とする。

1. **1回の指差しは自動配置を1回だけ持つ。** 状態は
   `gestureAccepted/resolving → placementCommitted → contentVisible`。リング、カード高、reflow timer、
   `streamingMessage`の有無を配置状態の代用にしない。
2. **印とカードは別の状態機械。** 印はリング → AX枠 → 最終検証済み回答の枠と、最新の対象解決へ
   必ず更新する。AX枠または囲みでカードを配置済みなら、後着の回答枠は印だけを更新してカードを
   動かさない。クリック点はカードの配置根拠にしない。
3. **AXヒット無しのクリックだけ、本文を配置確定までバッファする。** 回答枠を同期反映してから全文を
   表示し、枠が無ければ現在位置のまま表示する。実測では初文字が約3.5秒から約5.5秒へ遅くなるが、
   「位置→文章」を守るため正式に受ける。AX実測・囲み・通常質問は従来どおりストリーミングする。
4. **Gatewayはこの段階で変えない。** `targetCandidateId`は候補リストのidで、候補0件の配置には使えない。
   将来早期配置を送るなら矩形の`subjectPlacement`を、新クライアントが明示要求した時だけ返す別契約とする。
5. **`AXUIElementCopyElementAtPosition`は本実装へ直行しない。** 短命probeで入力座標に応じて結果が変わるか、
   画面大の`AXGroup`/`AXWebArea`を返さないかを測り、面積上限を含めて採否を決める。
6. `vision.point`は`collectorEmpty / pointMiss / measured`を記録し、訪問node数、収集起点、pass数、
   WebArea有無、打切り理由も併記する。本文・画像・graphでのmissと収集失敗の0件を同一視しない。

#### 実装で確認した事実（推測ではない）

- **撮影は自アプリを除外している**（`ScreenshotCaptureService.swift:126-134`の
  `SCContentFilter(display:excludingApplications:)`）。したがって覆いとバブルを乗せたまま撮っても
  下の実画面だけが撮れ、Web版が費やした合わせ鏡の検出（自己共有プローブ）は**丸ごと不要**である。
  同時に、**除外はアプリ単位なので覆いに描いた印も写らない**。モデルへ「ここ」を見せる手段は
  焼き込みか座標かの二択になる。
- **クリックを飲む全画面キーウインドウは実働している**（`ScreenshotSelectionOverlay.swift:29-42`の
  `KeyableOverlayWindow(clickThrough: false)`）。新規の危険なAPIは要らない。`CGEventTap`も使わない。
- **Gatewayは`input.pointer`を本番で受ける**（`vision-prompt.ts`）。intent resolverは
  `guidance > question > pointer > selection > 初期説明`で、質問なしのpointerには専用の指示がある。
  当初は「Gateway側の変更は不要」と判断したが、**実機で印だけではモデルが取り違えたため
  `pointer.hit_candidate_id`を追加した**（`08e570e`）。旧クライアントはこのフィールドを送らないので
  プロンプトはbyte一致で不変である。
- **Gatewayはcandidateの矩形をモデルへ渡さない**（`app/api/ai/vision/route.ts:175-182`が
  `id/source/role/label/parent_label/states`だけを取り出す）。したがってAXは「バブルの置き場所と
  枠」の実測であり、**モデルにとっての根拠は焼き込んだ印**である。
- **AX候補は操作系13ロールだけ**（`VisionObservationCaptureService.swift:145-149`）。本文テキスト・
  画像・グラフ・canvasには当たらない。指した場所の要素をロールを問わず取るには
  `AXUIElementCopyElementAtPosition`が要る（リポジトリ内0件）。
- **候補の座標は既に`normalized_top_left`の0-1**（`VisionObservation.swift:88`）で、`pointer`と同じ
  空間である。変換を新しく書く必要はない。
- **ペン（`ScreenshotPreviewTool.annotate`）は実装済みだが本番から到達不能**で、描いた矩形は
  Gatewayへ送られなかった。指差しの受け皿が半分だけ既にあった、という当時の記録である。
  **F11でパネルごと削除済み** — 指すことは覆いの上のジェスチャーになったので、静止画に描く道具は
  受け皿ではなくなった。
- **候補の送信は`question != nil`で門番されている**（`VisionSession.swift:406`）。冷えたブラウザの
  AXツリーを待たないための意図的な性能設計で、開幕解説ではこれを維持する。ただし指差しターンは
  質問が無いまま候補を要る唯一のターンなので、条件を質問の有無からターンの種類へ切り替える。

#### 設計の芯

**指を置いた瞬間に撮る。** 入場時の1枚を指差しの間ずっと使い回す案は棄却する。理由は
「覆いがクリックを飲むから画面は動かない」が**成り立たないこと**で、これは前面を奪うかどうかに
依存しない — 入場からクリックまでには秒単位の時間があり、その間に通知、アニメーション、受信、
別ディスプレイでの操作で画面は変わる（覆いは1画面だけを覆う）。加えて、対象アプリが非活性に
なるなら見た目そのものも変わる（F2ではここが未決着）。

使い回すと、ユーザーは変わった後の画面の位置Pをクリックし、こちらは変わる前の画像の位置Pへ
マークを焼く — **別のものについての回答が返る**。撮影1回を節約する代わりに対象を間違える取引は
成立しない。Web版の規則（`solo-mode.md` §1「ジェスチャーが始まった瞬間、そこにあったものが
対象」）がそのまま正しい。

したがって入場時に1枚撮って開幕解説を出し、**クリック時にはその瞬間の1枚を撮り直す**。
「変わっていなければ撮り直さない」は、撮影コストを測った後の最適化として残す（判定は既存の
`StableScreenCaptureService`の48×48・12格子の差分が持っている）。撮影msの記録が現在どこにも
無いため、F3で足すまでこの最適化の要否は決められない。

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
- **F2（完了・リポジトリ外の短命probeで実測）** 確定したこと、まだ決着していないこと。
  - **覆いはクリックを確実に飲む。** 両構成とも、覆っているディスプレイ上のクリックは全て
    こちらへ届き、下のアプリへは通らない。
  - **覆いの上で日本語IMEは確定する。** バブルは覆いと同一ウインドウの subview に置ける（別窓の
    退路は不要で、EscとIMEの持ち主争いが構造的に起きない）。probeは.appバンドルではないため
    `IMKCFRunLoopWakeUpReliable`のエラー行が出た。本体で再発しないかはF9で見る。
  - **`.nonactivatingPanel`＋`makeKey()`は同期的にキーを取り、`NSApp.activate`＋
    `makeKeyAndOrderFront`は出した直後まだキーになっていない**（macOS 14の協調的アクティベーションが
    非同期）。最初のクリックが即座に効くべき製品なので構成は前者を採る。既存の
    `ScreenshotSelectionOverlay`は後者の形である。
  - **覆いは1画面だけを覆い、他のディスプレイは通常どおり動く。** 別ディスプレイのアプリを操作でき、
    そのアプリが前面を持っている間も、覆っている画面のクリックはこちらへ届き続けた。
  - **🔴 前面を奪うかどうかは、このprobeでは決着していない。** 起動0.145秒後に出した回は3秒後に
    自分が前面になったが、8秒待って出した回は他アプリが前面のままだった（1回目はプロセス起動の
    副作用である可能性が高い）。さらに`NSApp.isActive=true`と
    `NSWorkspace.frontmostApplication=別アプリ`が同時に成立する状態を実測しており、2つの指標が
    食い違う。**したがって「対象アプリが非活性になる」を確定した事実として使わない。**
- **F3（完了）** 撮影経路へ`capture.display`の記録を足した（ms、画素数、除外したアプリ数、
  ネイティブメニューが開いていたか）。この経路には`Diagnostics`が1件も無く、
  `coordinator.axFocusResolved`が撮影とAX待ちの合算しか持っていなかった。
  - **除外数を記録する理由**: 除外リストが空になると、こちらが描いた覆いが「写らないはずの画像」へ
    写り込む。その時に例外は出ないので、0という数字だけが手がかりになる。
  - **メニューの有無を記録する理由**: ネイティブメニューはポップアップメニュー階層の独立した
    ウインドウで、ブラウザ内のプルダウンはページの中なのでウインドウを持たない。この1つのフラグが
    両者を分ける。ウインドウ階層だけを読み、所有者名やタイトルは取らない
    （`DiagnosticValue`が構造として持てない）。
  - 覆いを出したまま撮って写り込まないことの目視確認は、覆いが本体に入るF9で行う。
- **F4（完了）** `VisionPointer`と`VisionPointerResolver`を純粋な値と関数として追加した。Cocoa
  グローバル→CGグローバルは`HighlightOverlayPresenter`の反転の鏡として書き、4つ目の式を作っていない。
  撮影範囲外のクリックはclampせずnilを返す（撮影の縁はユーザーが指した場所ではない）。ヒットテストは
  点を含む最小の候補を採る。候補配列が空ならnilを返すことを固定し、収集失敗か正当なpoint missかは
  上流の`collectorEmpty / pointMiss`で区別する。
- **F5・F7・F9（完了・実機確認済み）** 3段に分けず1つにした。F2で「バブルは覆いと同一
  ウインドウに置ける」と分かって分割の理由が消え、途中の段（紫の画面をクリックすると丸が出るだけ）は
  見ても判断材料にならないためである。入ったもの:
  - `VisionPointingOverlay` — 覆っている画面のクリックを飲み、印とヒット枠を実画面へ描き、
    バブルを同一ウインドウの subview として持つ。`NonactivatingOverlayPanel`（F2の測定に従い
    `.nonactivatingPanel`＋`makeKey()`）。まだ何も指していない間はカーソル周りだけ素のまま残し、
    指した時点でその穴を閉じる（芯に光は足さない）。
  - `VisionBubbleView` — この製品が喋る唯一の場所。Skill名、回答、待ちの言葉、エラー、質問欄。
    絵の上には何も置かない。
  - `VisionBubblePlacement` — 指した点の右下20px、はみ出したら反対側、最低12px余白、ヒット枠を
    覆わない、指していない時は右下。純関数で9件のテスト。
  - `VisionSession.point(...)` — 指差しターン。**新しい場所は新しい主題**なので`turns`を捨てる
    （Web版は捨てなかった版でタップのたびに最初の回答が返った）。候補送信の門番を
    `question != nil`から`question != nil || pointer != nil`へ変え、指差しは質問なしで候補を要る
    唯一のターンとした。
  - `SessionCoordinator.point(at:)` — クリックで**まず印を出し**（聞こえた最初の証拠は触った場所に
    出ていなければならない）、その瞬間に撮り直し、AX候補を集めてヒットテストし、
    `pointer`付きで送る。撮影範囲外のクリックはclampせず「対象外」と述べる。
  - Visionの`closesOnResignActive`を`false`にした。F2で「別アプリが前面のままクリックが届く」ことを
    実測しており、trueのままでは指している最中にセッションが自分で終わる。
  - **Compose→Visionの入口から範囲選択の待ちを撤去し、`ScreenshotSelectionOverlay`（213行）を
    削除した。** 確認を求められていない説明の前に置いた確認は、押されるだけの手順である。
    範囲指定は覆い上の「囲む」ジェスチャーとして戻す。
  実機で通した（2026-08-24）。覆いが撮影に写り込まないことは、送信バイトそのものを開いて確認済み
  （膜・格子・リングのいずれも写っていない）。IMEのエラー行の再発だけが未確認のまま残る。
- **F6（完了）** 焼き込みを`VisionPointerMark`として実装し、送信経路（`encodeForWire`）の
  downscale後へ入れた。幾何はWeb版`lib/marker.ts`の移植で、リング＋十字、矩形、手描きの軌跡その
  ものを描く。ピクセルを読む単体テストで、指した位置、上下反転、リング（塗り潰しでない）、
  範囲外の無傷、送信base64に印が残ること、pointerが無い場合に元バイトが素通りすることを固定した。
  **縮小後に焼く現行のままで実機の認知精度100%に達したため、縮小前に焼く案との比較は不要になった。**
- **F7・F8（完了）** `pointer`はリクエストへ入り、pointer以外のフィールドが通常Visionと同一である
  ことは契約テストで固定した。実機で通っている。
- **F10（完了）** 書き出し表示は本物のSSE deltaで動いている。
- **F11（完了）** 静止画パネル系を撤去した。実際の削減は約1,000行で、`ZoomableScreenshotView`
  481行、`ScreenshotAnnotation` 136行、`VisionSessionView`（パネル本体・画像・ハイライト・
  選択カード）、`VisionSelectionPresentation`、セッションが持っていた`ScreenshotImageState`と
  `screenshotHighlight`が対象。**残すものは2つあった**:
  - 処理情報の情報ボタン（モデル・route・AX走査・capture）は`VisionDiagnosticsReport`として
    バブルへ移した。文言は当時のまま。
  - Copilotの「案内を開始」もバブルへ移した。**パネルは案内が始まった後にしか出ないため、
    覆いがパネルを置き換えた時点でCopilotの唯一の入口へ到達できなくなっていた**（撤去で失われた
    のではなく、撤去の前から到達不能だった）。
- **F12（残り）** build番号を上げて署名ビルドし、D7相当を通す。入場ms・クリックms・AXヒット率を
  unified logから集計する。

##### F11の後に追加で実装したもの（実機の指摘から）

- **AX実測要素のidをpointerへ載せる**（`pointer.hit_candidate_id`、Gateway `08e570e`で本番配備）。
  印だけではモデルが画面内の似たコントロールを取り違えるため。これで認知精度100%。
- **印は常に1つだけ**（リング → AX枠 → 回答枠と入れ替わる）。バブルは配置未確定の場合だけ回答枠に
  追従し、AX枠または囲みで配置済みなら印だけを更新する。
- **囲みジェスチャー**（パスのバウンズで判定、真横のなぞりも囲みとして成立させる）。
- **バブルの表示品質**（高さを行の整数倍へ、読む面と打つ面を分離）。答えの面積は最初「画面高の半分」に
  したが足りず、2026-08-25に**「画面に残っている分だけ」**へ変えた（3分の2を上限に、収まらない画面では
  残りを渡す。バブルのそれ以外の部分の合計を`chromeHeight`として明示し、総高が可視画面高を超えない
  ことをテストで固定）。**ただし上限を上げてもユーザーの見た目は変わらなかった** — 箱が内容に密着する
  ので普通の答えは上限に届かず、見えていたのは2行半だった。**下限（10行）を入れて初めて変わった**
  （1行の答えでバブル総高131pt→269pt、長文で627pt→850pt。`VisionBubbleLayoutTests`が実バブルを
  NSHostingViewで測って固定）。同じ日に**入力欄を打った内容へ追従**させた — それまでの
  `minHeight: 34 / maxHeight: 72`は常に34ptに解決しており、`maxHeight`は一度も効いていなかった。
- **送信ボタンを撤去**（2026-08-25）。Enter送信・Shift+Enter改行は最初から実装されており、ボタンは
  キーボードが既にやることの2つ目の経路だった。`PanelSendButton`はComposeでは現役。
- **印を1つの型・1つの描画へ統一**（2026-08-25、`WashView.MarkShape`）。リング（丸）と枠（四角）が
  線幅2.5pt・暗いハロー6pt・外へ14pt広がる減衰ビートを共有する。**中央の十字は削除**（クリックは
  クロスヘアではなく場所で、十字は持っていない精度を主張する）。焼き込み側のマゼンタのリング＋十字は
  観客がモデルなので変えていない。

#### 実機で測らないと決まらないこと

**このうち2、4、5は答えが出た（2026-08-24）。** 撮影1回は29〜97msで、Gateway往復に対して無視できる
（「変わっていなければ再利用」の最適化は不要）。焼き込みは縮小後のままで認知精度100%に達した。
AXヒットは`vision.point`の`hit`で溜まっており、実機のGitLab画面では183〜200候補で`hit=true`が
多数派だった。以下は残っているもの。

1. **こちらが覆いを出すと、対象アプリの開いたネイティブメニューは閉じるか。** R12が扱う
   「開いたプルダウンを説明する」がこの条件そのものである。**段取りを人に合わせてもらう実験を
   2回やって2回失敗したので、普段の利用の記録で答える方式へ振り替えた** — F3の
   `capture.display` が `menu=true/false` を残すので、実際に人が指している画面にネイティブ
   メニューが開いていたかが溜まる。
   **probeでは半分しか分からないという理由もある**: 本番の入口は右Shift 2回のホットキーで、
   ネイティブメニューが event を掴んでいる間そのホットキーが発火するのか自体が未確認である。
   閉じるなら、メニューが開いている画面はクリック時撮影では救えず、入場時の撮影に頼るしかない
   領域として別に扱う。
2. **撮影1回の所要ms**（F3で記録済み。あとは実機で読む）。毎クリック撮り直しが体感に耐えるか、
   「変わっていなければ再利用」の最適化が必要かは、この数字が決める。
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
触ったもの」を1色に統一し、状態（動いている・注意）には貸さない。覆い・印・枠・軌跡はWeb版と同じ
`iris`へ寄せた。Copilotの枠（`HighlightOverlayPresenter`）も2026-08-25に同じ`MarkStyle`へ揃え、
R15でそのクラス自体を削除した — 案内中の枠も覆いと同じ`WashView`が描く。

**Web版の数値のうち実機未検証のものを設計根拠にしない。** 初回説明が何行で何秒返るか、指した対象と
返ってくる枠が一致するか、待ち時間の典型値は、Web版でもまだ記録されていない。

R14は「正しいが遅い」（R13）と「動いているのに内容が正しくない」（R12）を巻き戻さない。速さのために
正しさを削らず、**指差しという新しい経路にもR11の不変条件（無音で終わらない）を通す**。

### R15 — 実画面の上の案内（完了、2026-08-25。実機で案内が成立）

**2026-08-25の実機テストが設計の前提を与えた。** Copilotの入口を「打ち込んだ質問」に開けた直後
（`508635a`）、GA4で「どうすればデバイス別にアクセス解析が見れますか」と打ち、「テクノロジーの
プルダウンを開いてください」が枠付きで返った（unified log 17:56:38 `vision.result mode=guide
highlight=resolved`）。ユーザーは**「案内を開始」を押さず、そのままテクノロジーをクリックした**。
その9秒後から`vision.point`が2回あり、`state.transition mode=copilot`も`copilot.*`も1件も無い。
覆いがクリックを指差しとして飲み、テクノロジーの**解説**が始まった。

ここから確定すること:

1. **指示を読んだ人の次の動作は、指示された物を押すことである。** 指示と行動の間のボタンは押されない。
   R14が確認ステップを撤去した理由（「確認を求められていない説明の前に置いた確認は、押されるだけの
   手順」）と同じ構図で、今回は**押されもしなかった**。
2. **覆いは案内と両立しない。** 覆いは「この画面は操作するものではなく指すもの」と言う層で、クリックを
   質問に変えるために存在する。案内は「次にこれを押す」で、クリックは操作でなければならない。直前まで
   リングや軌跡を置いていた面の上で「ボタンが押せる」という認知は成立しない。
3. **案内はセッションである。** 単発の質問と違い、押した→画面が変わった→次の一手、が続く。違う物を
   押したら「それではなく、こちら」が返る。ユーザーが終えるまで続く。
4. **今のCopilotの機構はそのまま使える。** クリック監視（`installCopilotClickMonitor`）、変化待ち撮影
   （`StableScreenCaptureService`）、進捗ターン（`evaluateCopilotProgress`）、状態（`CopilotState`）は
   R7から実働している。変えるのは**置き場所**（ストリップ→バブル）と、**その間の画面**（覆い→素の
   実画面）である。

#### 不変条件

```text
案内は別のモードではなく、同じセッションの2つの状態のうちの1つである。
覆いがある間、クリックは質問。覆いが無い間、クリックは操作。この2つを同時に成立させない。
指示と行動の間にボタンを挟まない。
製品が喋る場所は1つだけ。パネル／ストリップは作らない。
いまどちらの状態かは常に名乗る。不在はラベルではない。
```

#### 2つの状態

| | **指す** | **案内** |
|---|---|---|
| 画面 | 幕・格子・スポットライトが乗る | **素の実画面**。幕は無い |
| クリック | 質問（その場所／囲んだ範囲について） | **操作**。対象アプリへ通す。こちらは`leftMouseUp`を見て、画面が落ち着いたら撮って評価する（既存の経路） |
| 印 | リング→AX枠→回答枠 | 次に押す対象の**枠（ビート付き）**。クリックで消え、評価後に次の対象へ |
| バブル | 印の隣 | 対象の枠の隣（無ければ右下）。**同じバブル** — ラベルが「案内」になり、×で案内を終える |
| 入力欄 | 質問 | 質問（同じ会話の通常ターン。回答が`guide`なら目的を更新） |
| キー | バブルがキー（Esc・入力が効く） | **最後にクリックした方**が持つ。案内に入った時点ではバブルが持ったままで、対象アプリをクリックすると移る |
| 出口 | 解説を閉じる／Esc／右Shift 2回 | 案内の×（→指す状態へ戻る）／解説を閉じる／右Shift 2回 |

#### 遷移

- **指す→案内: 打ち込んだ質問の回答が`guide`だった時、自動で。** 指示の文が完成した瞬間に幕が引き
  （0.2s、Reduce Motionでは即時）、対象の枠だけが残る。「画面はあなたのものになった」を幕の消え方が言う。
  ボタンは無い。**モデルの`guide`判定を使う**ので、Gatewayの変更は無い（HANDOFFの「道1」を新フィールド
  ではなく既存の`mode`で実現する形。`mode`は既に「その画面で可能なアクションをユーザーが必要としている」
  の判定である）。
  - **指差しターンの`guide`では入らない。** そのターンの本文「ここについて」が目的になる（今日のゲートと
    同じ理由）。
  - 打ち込んだ質問の回答が`answer`だった時は**「案内を開始」を残す**（出ないくらいなら出やすい方へ）。
    押したら案内状態に入り、**その場で進捗ターンを1回走らせて最初の一手を出す**（変化待ち無し）。
    今の`startCopilot()`は直前の回答をそのまま指示として見せてクリックを待つが、`answer`は指示ではない。
- **案内→指す: 案内の×。** 幕が戻る。会話は捨てない（回答はバブルに残り、続けて指せる）。
- **目的到達（進捗ターンが`answer`）: 案内状態のまま、幕は戻さない。** バブルが「目的に到達」と
  「解説を閉じる」を出す。達成した直後の画面に幕を落とすのは、終わった仕事の上に膜を張る行為である。
  `stepLimit`・`clarification`も同様に案内状態のまま（表示は現ストリップの`statusText`を移す）。
- **どこからでも閉じる: 解説を閉じる／右Shift 2回**（`handleDoubleTap`は`.copilot`でも既に閉じる）。
  **案内中のEscは、その時キーボードのフォーカスを持っている方へ行く**（実機で確認、2026-08-25）。
  案内へ入ってもバブルはフォーカスを持ったままなので、**Escは普通Universal I/Oに届き、セッションが
  閉じる**（ユーザーが期待するとおりの挙動）。ただし**案内された対象をクリックするとフォーカスは
  対象アプリへ移る**ので、それ以降のEscは対象アプリのものになり、Universal I/Oは閉じない。
  設計時に「案内中のEscは対象アプリのもの」と断定したのは誤りで、フォーカスを手放す処理は入れていない。
  **どの状況でも必ず効く出口は右Shift 2回**（`handleDoubleTap`）**と×**。だから「Esc」の表記は
  解説の時だけ出す。

#### 「違う物を押した」時

既存の進捗ターンがそのまま答える。クリック後700ms→変化を待って落ち着いた画面を撮る→`goal`と
`previousInstruction`を渡す→モデルは**今の画面から**次の一手を返す。プロンプト（`vision-prompt.ts`の
guidance分岐）は「目的でない画面でも、閉じろ・戻れと言わない」を既に固定しているので、返るのは
「戻ってください」ではなく「ここからはこちら」である。画面が変わらなかった時は`copilotSawNoChange`で
「操作は検知しましたが画面に変化は見えませんでした」を添えて同じ指示を繰り返す（既存）。

**バブル上のクリックは進捗ターンを起こさない** — ただし当初「`addGlobalMonitorForEvents`は自アプリの
イベントを受けない」と書いたのは**誤りで、実機が反証した**（2026-08-25）。案内中は対象アプリが前面で
こちらは非活性なので、自分のバブルへのクリックも監視に届く。バブルをドラッグすると枠が消え、暗転して
撮影し、1ユニット払って「変化なし」を確認していた。判定は`VisionSession.advancesGuidance(clickAt:bubble:)`
＝バブルのカード矩形の外側だけを操作と数える（再確認・×・マイクも同じ理由で外れる）。
影の分の窓の余白がクリックを飲む件は、**窓をカードと同じ大きさにして影をAppKitに描かせて**直した
（`hasShadow`）。最初は`BubbleHostView.hitTest`でnilを返したが実機で効かなかった — **窓は受け取ってから
捨てるだけで、下の窓へは渡らない**。
**`IMKCFRunLoopWakeUpReliable`のエラー行は本体では出ない**（実アプリのログ3時間分で0件、2026-08-25）。
probeが.appバンドルでなかったことが条件だった。

**キーボード操作（欄に打つ・Enter）は監視していない**（現状どおり）。「再確認」で手動確認する。
キー監視の追加は、案内が実機で使われ始めてから決める。

#### 機構 — 幕を上げる

同じ`NonactivatingOverlayPanel`・同じ`PointingCanvas`・同じ`WashView`・同じバブルを使い、窓を
作り直さない。案内状態では:

- **窓を`ignoresMouseEvents = true`にする**（覆っているが触れない窓）。幕・格子・スポットライトは描かず、
  印（対象の枠）だけを描く。`WashView`に「幕を描くか」の1フラグ。
- **バブルは覆い窓の子パネル**（`addChildWindow`）にする。子は自分の`ignoresMouseEvents=false`を持ち、
  親が透過でもクリックを受ける。**指す状態でも同じ構造にする** — 状態ごとに親を替えると、遷移のたびに
  `NSHostingView`を移し替えることになる。**窓はカードと同じ大きさにし、影はAppKitに描かせる**
  （`hasShadow`）。SwiftUIの`.shadow()`だと影の分だけ窓をカードより大きくする必要があり、その余白が
  クリックを飲む — 案内中はそこが「押しても何も起きない帯」になる。
- **案内に入る時にこちらはキーを手放す。** キーストロークは対象アプリのもの。入力欄をクリックした時だけ
  子パネルが`makeKey()`する（`.nonactivatingPanel`なので対象アプリはactiveのまま）。
- 対象の枠は`WashView.markShape = .frame(...)`のまま（同じ描画）。`HighlightOverlayPresenter`は
  不要になる → 削除候補（印のホストが1つになる）。
- 撮影の暗転（`CopilotCaptureCuePresenter`）は残す。「この画面を見た」の合図。

**これはR14 F2と同じ種類の未測定を含む**（子パネルでのIME確定・Escの経路・2つの自パネル間のキーの
受け渡し・枠越しのクリックが対象アプリへ届くか・表示中の`ignoresMouseEvents`切替）。F2は「バブルは
同一ウインドウのsubviewに置ける（EscとIMEの持ち主争いが構造的に起きない）」を測って現構造を選んだので、
**子パネル化はその測定を一部やり直す**。G1のprobeで決める。

**代替（G1で子パネルが駄目だった時）**: 案内状態では覆い窓を**バブルの大きさへ縮める**（窓そのものが
バブルになる。影の分の余白を持つ）。幕は窓が覆わないので消える。対象の枠は既存の
`HighlightOverlayPresenter`（click-through・`MarkStyle`・ビート）が描く。印のホストは2つ残るが描画は
1つ（`MarkStyle.layer(for:)`）で、新しい窓クラスは要らない。

#### バブル（案内状態）

- **状態ラベルを対で名乗る**: 指す状態「解説」／案内状態「案内」（語は下記。見た目は後で決める）。
  案内側のラベルに×（案内を終える）。「解説を閉じる」はそのまま別に残す（全部を閉じる）。2つの×が
  並ぶ問題は文字で区別する（「案内を終える」「解説を閉じる」）。
- 質問チップ＝目的（打った質問）。読む面＝最新の指示。その下に**状態行**（待っています／確認しています／
  目的に到達／判断が必要／回数上限）と**再確認**、`copilotSawNoChange`の注記 — 現ストリップの
  `statusText`・`statusIcon`・再確認ボタンを移す。
- 入力欄とマイクはそのまま。`startDictation`の`case .navigator, .copilot: return`を外し、案内中も
  visionSessionへ流す（今は案内中の音声入力が黙って無効）。
- Skill名・処理情報はそのまま。

#### 語

**「案内」を推す。** 製品内の既存語（「案内を開始」「案内中」「操作案内」）で、READMEの呼び名表へ状態名
として足す。**「ガイド」は使わない** — Web版（`app-web/docs/solo-mode.md` §1）で「ガイド」は**静止画を
見て解説している状態**（＝Macの「指す」に相当）の名で、対になる「ライブ」がある。同じ語をMacのCopilot
へ当てると、同じ製品の中で1つの語が逆のものを指す。

#### 状態機械

- `.copilot`は残す（resignActiveで閉じない・ダブルタップで閉じる・記録に状態が出る、を担う）。
  `.navigator`は退役（`vision→navigator→copilot`の中継と`PanelSpec`しか役目が無い）。
  `.vision ⇄ .copilot`を直結し、**`.copilot → .vision`（×で戻る）を新設**する。
- `PanelSpec.forMode(.copilot)`はパネルを返さない。`applyPanel(.copilot)`は
  `pointingOverlay.enterGuiding()`、`.copilot`からの`applyPanel(.vision)`は`enterPointing()`
  （`presentPointing`で作り直さない）。
- 記録: `guide.entered`（auto／button、sinceAsk）、`guide.left`（cross／complete／closed／stepLimit）を
  足す。`copilot.capture`／`request`／`turn`／`failed`はそのまま。

#### 撤去したもの（G3・G4）

- `CopilotPanelView.swift`（`VisionRootView`・`CopilotStripView`）、`HighlightOverlayPresenter.swift`、
  `CorePanelShellView`。
- `AppMode.navigator`、`TransitionReason.visionGuideReady`、`PanelSpec`の`.navigator`、`AppMode.hasPanel`。
- `offersGuidance`はそのまま（打った質問＋回答あり）で、`canStartCopilot`が案内中は`false`を返す。
  `guide`回答は自動で入るので、ボタンが見えるのは`answer`回答の時になる。

#### 進捗ターンに履歴を渡す

進捗ターンは`turns: []`・`question: nil`で送っている（R12 E3未着手）。案内中に打った質問を成立させる
には、少なくとも**打った質問と直前の回答**を`turns`で渡す。Gatewayの契約は`guidance`と`question`を
排他にするが`turns`は禁じていない。**プロンプトがそれをどう使うかはE3の問題で、Gatewayの変更（本番
デプロイ）を伴う**。R15では**クライアントが渡すところまで**を行い、効き方の評価はE3へ。同じくGateway
の進捗プロンプトにある「小さなストリップで表示され、ユーザーは返答できない」の一文はバブルでは偽に
なる — `api-gateway`側の後続項目として記録する（案内の成立は妨げない。文が質問形にならないだけ）。

#### マイルストーン

- **G1 probe（完了・2026-08-25）** リポジトリ外のprobe（`NonactivatingOverlayPanel`と同じ構成の覆い＋
  子パネルのバブル）で測った。**決定: 機構は子パネル案。** 代替（窓をバブルの大きさへ縮める）は不要。
  - **子パネルは、親が`ignoresMouseEvents=true`でもクリックを受ける**（合成クリックと実クリックの両方）。
  - **透過した覆いを抜けたクリックは別アプリへ届く**（ChromeとFinderが実際に前面化した）。
  - **子パネルで日本語IMEは確定する**（`setMarkedText`×9→Enter→`insertText '日本語'`。前面がChrome／
    Finderのまま、時間を空けて2回）。
  - **Escはバブルがキーの時だけこちらへ届く**（`keyDown 53`→text viewの`cancelOperation`）。別アプリで
    打った文字は1件も来ない。**ただし「だから案内中のEscは対象アプリのもの」は誤った推論だった** —
    案内へ入ってもキーは手放していないので、普通はバブルが持ったままである（上記）。
  - **キーの受け渡し**: 別アプリをクリック→バブル`resignKey`、バブルをクリック→`becomeKey`、**前面アプリは
    変わらない**（nonactivating）。`NSApp.isActive`はこちらの窓がキーになると`true`を返す（F2と同じ
    食い違い。前面判定には`frontmostApplication`を使う）。
  - **表示中の`ignoresMouseEvents`切替は両方向とも効く**（実クリック: 透過OFF→覆いが2クリック飲む、
    ONに戻す→バブルは操作できる）。**反映は同期ではない** — 切替3〜12ms後の合成クリックは前の設定で
    配送され、約1秒後の次の段では確実に効いていた。**合成クリックで遅延の数値を取る試みは失敗した**
    （4本のprobeで半数のクリックがどの窓にも届かず、非キー窓・`orderOut`／`orderFront`・flushの有無を
    変えても一貫しない。合成イベント×非活性アプリの組み合わせが疑わしいが未特定）。製品では
    **切替のたびに幕を再描画し**、G6で「幕が引いた直後に押す」を実クリックで確かめる。
    副作用: 計測中、透過を抜けた合成クリックが約40回、プライマリ表示の左下（x60〜420・y120〜360pt）
    にあったアプリへ落ちた可能性がある。
- **G2（完了・`97d66b1`）** バブルを覆いの子パネルへ（影の分の余白32ptを窓の中に持つ）。
  `enterGuiding()`は幕を0.2秒で引き（Reduce Motionは即時）、`ignoresMouseEvents=true`にして再描画する。
  `enterPointing()`は逆。`clearAnswerFrame()`は枠だけ下ろしてバブルを動かさない。スポットライトは
  `mouseMoved`のローカルモニタで追う（バブルが別窓になり、その上ではcanvasに届かないため）。
- **G3（完了）** `VisionSession.opensGuidance(turn:mode:)`＝打った質問×`guide`のみ。自動入場は
  `run()`の`apply`直後、`enterGuidance(reason:)`が`.copilot`へ遷移して対象アプリを前面化する。
  `answer`＋ボタンは`startCopilot()`→入場→即`requestCopilotProgressCheck()`。`leaveGuidance()`（×）は
  `.vision`へ戻り`turns`を保つ。到達（`.complete`）・上限は案内状態のまま。進捗ターンは`turns`（最新20）を
  運ぶ。**Gateway上限20ターンにクライアント側のcapが無かった**のを`VisionSession.wire`で足した。
  `AppMode.navigator`退役、`vision ⇄ copilot`直結、`.copilot`は`PanelSpec`にパネルを持たない。
  `applyPanel`はモードごとのswitchになり、Phase 1の`CorePanelShellView`を削除。案内中も音声入力が通る。
  記録: `guide.entered via=copilotStarted|copilotAutoStarted`、`guide.left via=cross|closed`、
  `guide.done state=complete|stepLimit`。
- **G4（完了）** バブル左上に状態チップ（「解説」／紫の「案内」＋×）。案内中は答えの下に状態行
  （待ち・確認中・到達・判断・上限）と再確認、無変化の注記。Escの表記は解説の時だけ。
  `chromeHeight` 352→422。`CopilotPanelView.swift`（ストリップ）と`HighlightOverlayPresenter.swift`を
  削除。`GuidanceStateTests`（6件）。140 unit test。**見た目は仮** — 「デザインは後で」の指示どおり、
  意味と位置だけを置いた。
- **G5（完了）** README（呼び名表に解説／案内、案内の節）、golden paths、HANDOFF。
- **G6（完了・2026-08-25 21:43〜21:51）** 実機で成立した。3セッションとも
  `guide.entered via=copilotAutoStarted`で自動入場し、クリックが対象アプリへ通り、
  `copilot.capture`→`copilot.request`→`copilot.turn`が続いた。うち1回は2手で
  `guide.done state=complete`。`guide.left via=cross`で解説へ復帰、`via=closed`で終了。
  **実測**: 質問→案内入場まで約4.6秒、1ステップ（クリック→次の一手）が約6〜10秒
  （撮影1.7〜4.4秒＋Gateway往復3.5〜4.3秒）。
- **G7（G6の実機指摘から・完了）** バブルを掴んで動かせるようにし（入力欄以外のどこでも、
  動かした位置は次に指すまで勝つ）、**バブルの上のクリックを操作に数えないようにした**。
  ドラッグのたびに枠が消え、暗転して撮影し、1ユニット払って「変化なし」を確認していた。
  影の分の窓の余白（32pt）がクリックを飲んでいた件も同時に直した。
  **実機でドラッグとクリック計上を確認済み**（2026-08-25）。
- **G8（2回目の実機指摘から・完了）** 3件。
  - **リングが出なくなっていた（G7で入れた回帰）。** `point(at:)`がリングを描いた直後に
    `beginPointing()`→`publishAnswerHighlight(nil)`→`clearAnswerFrame()`が消していた。
    `clearAnswerFrame`は**回答が出した枠だけ**を下ろす（`showsAnswerFrame`）。ユーザーのジェスチャーが
    出した印は、この呼び出しの持ち物ではない。
  - **バブルが1ジェスチャーで2回動いていた**（クリックの点の隣→約0.6秒後にAX枠の隣）。リングでは
    動かさない（`showRing(at:)`）。置き場所はAX走査の後に1回だけ決める（`setMark(point:frame:)`を
    ヒットの有無にかかわらず1回呼ぶ）。
  - **影の帯**は窓をカードと同じ大きさにして解決（上記）。

#### 決定した論点（2026-08-25）

| | 論点 | 決定 | 退けた案 |
|---|---|---|---|
| A | 案内への入口 | **`guide`回答で自動**（実機が「ボタンは押されない」を示した） | ボタン維持 |
| B | ×で案内を終えた後 | **指す状態へ戻る**（幕が戻る、会話は残る） | セッション終了 |
| C | 目的到達後 | **幕を戻さない**（閉じるを促す） | 指す状態へ戻す |
| D | 名前 | **「案内」**（既存語。Web版「ガイド」との衝突を避ける） | 「ガイド」 |
| E | 案内中に打った質問 | **同じ会話の通常ターン**、`guide`なら目的を更新 | 案内を終えて質問 |

#### 範囲外

- 自動コパイロット（settle駆動で自発的に喋る。Web版`auto-copilot.md`）— 別テーマ。
- スキルの不足（案内の質はモデルより注入文脈で決まる）— 別トラック。案内の評価と混同しない。
- ComposeをバブルのUXへ — 次期改善候補。


### R16 — 道具が押す（操作。設計のみ、未着手）

**これは方針転換ではない。製品の2つの正本が食い違っている状態を解消する仕事である。**
マスタープランの冒頭は「自律操作ではなく、最終判断と操作はユーザーが行う」と言い、
`api-gateway/docs/design-philosophy.md:42-47` の Palantir 写像表は「書き戻し＝⌘V注入・AXクリック（実装済み）」
「実行は常に人間承認（実装済み）」と言い、`docs/pitch/layer-value-thesis.md:26-32` は
「Universal I/O は、エージェント時代の人間の座席（approval seat）を作る会社」と言っている。
**3つのうち正しいのは3番目だけである。** 1番目は座席を作らない読み方を許し、2番目の「実装済み」は事実に反する
（後述のとおり作動層は到達不能）。R16 はこの3つを1つの線へ引き直し、その線をコードで成立させる。

事業の側からも同じ結論が出ている。目の前にあるB2B案件——不動産管理のISP、賃貸革命のようなレガシー基幹系——は
「APIもCSVも無く、人間しか入力できない」画面群で、相談の中身は一貫して**入力の代行**である。ただし本製品が
そこで売るのは無人化ではない。**その画面を知らない人が初日から入力できること**であり、経験者の代替ではなく
未経験者の底上げである。認知・言語・経験のギャップを埋めるという製品の理由とそのまま一致する。

#### 「操作」は個人ユーザー全員に出す

**段の定義は「## 製品」が正本で、ここでは繰り返さない。** R16 はその 「操作」 であり、
次の「連続」も同じ個人ユーザーのための段で、R16 の直接の続きになる。**別製品になるのは「無人」だけ**である。

**したがって「操作」に法人／個人の切り分けは要らない。** 作動層は数千回の実クリックを浴びる場所でしか
育たず、普通のユーザーの手元がその場所である。先例も同じ線を引いている——Dropbox・Slack・
GitHub Copilot はいずれも**行為そのものは全階層で同一**にし、法人には統制・規模・無人性で課金した。

#### 不変条件

```text
最終判断は常にユーザーが行う。道具が手を動かす段でも、一手ごとにユーザーが確定し、
確定のない手は1つも進まない。無人で進む運転席は、この段では作らない。

道具が押すことは、ユーザーが押すことを妨げない。確定は近道であって関門ではない。
押す前に、何を押すのかが実画面の上に見えている。見えないものは押さない。
「押した」と述べてよいのは、押下APIの戻り値ではなく、押した後の画面を観測した時だけ。
押さない理由は、整合性検査（今その要素が在るか／同じ画面か）だけが持てる。
確からしさや画素差分に拒否権を与えない。
押せない画面では、押さずに言葉の案内へ縮退する。2つの案内を並立させない。
```

3行目と4行目が R16 の芯である。**「押しますか」と問える状態は、押す対象が枠で見えている状態と同じ**なので、
確認は言葉ではなく画面が担う。5行目は `never-veto-user-action` の唯一の例外
（stale capture／存在しないIDの拒否）の中に押下前ゲートを収めるための線引きで、
これを外すと「確からしさが足りないので押しません」という拒否権が生まれる。

#### 「指示と行動の間にボタンを挟まない」との関係（R15不変条件との衝突の解消）

R15 が禁じたのは、**ユーザーが次にやること（＝対象を押す）の手前に置かれたボタン**である。実機で2度実証された
——R14 は範囲選択の確認待ちを撤去し（「確認を求められていない説明の前に置いた確認は、押されるだけの手順」）、
R15 は「案内を開始」が**押されもしなかった**ことを観測した。

「操作」 の確定はこれに当たらない。**確定はボタンではなく行動そのものである。** 指示を読んでから対象を探して
マウスを運ぶ代わりに、その場で1操作するだけで同じことが起きる。指示と行動の間に何も挟まっていない——
行動の場所が対象アプリからバブルへ移っただけである。

ただし R15 の実測は別のことも言っている。**確認を出しても、人は確認ではなく対象を直接押しに行く可能性が高い。**
これは失敗ではない。ユーザーが自分で押せば 「案内」 として正しく動き、案内はそのまま次の一手へ進む。
だから 「操作」 の設計要件は「確定させること」ではなく、**確定を待っている間もユーザーが自分で押す道が
壊れていないこと**である。ここを閉じると、R15 が作った動く案内を R16 が壊すことになる。

#### 状態は増やさない

**`AppMode` に新しいケースを足さない。** 理由は3つある。

1. 2状態モデルの説明（**幕の有無＝クリックの持ち主**）が壊れる。幕が無い＝画面はユーザーのもの、で成立している
   ところへ第3の持ち主が入ると、クリックの意味が3通りになる。
2. `AppMode` へケースを足すと、コンパイラが止めてくれるのは幕とパネルの2箇所だけで、**音声入力は黙って死ぬ**
   （`case .vision, .copilot:` で列挙している箇所がある）。静かな網羅漏れを作る改修である。
3. 「二方式の常設並走は禁止」。押す案内と見せる案内を2つのモードにすると、ユーザーには2つの製品に見える。

**操作は案内状態の中の一時的な振る舞いとする。** チップは「案内」のまま。いま何を待っているかは
**バブルの状態行**が名乗る（R15 が状態行をそこへ置いたのと同じ形）。「不在はラベルではない」は状態行が満たす。

#### 印も増やさない

「これから押す」と「いま押した」を同時に描きたくなるが、**印は常に1つ**であり、紫は「ここ・これ」専用で
状態には貸せない。新しい色を作れば幕と印の横に3つ目の視覚言語が立つ（R14 が暗転を捨てた理由と同じ）。

**新しい視覚言語は要らない。既にある2つがそのまま時制を持つ。**

- **これから押す** ＝ 回答が出した**枠**。案内は既にこれを出している。押す前に見えているものは、これで足りる。
- **押した瞬間** ＝ 撮り直しのキュー（撮影範囲の幕が走査線1本分だけ戻る）。案内は既にこれを出している。

#### 作動層 — 既にあるものと、その扱い

`BombSquad/Services/AXActionService.swift` は**完成しているが呼び出し元がゼロの死んだコード**である。
Navigator時代の `821f6cb` で入り、`5e42145`「Remove experimental paths and keep production only」
（2026-07-18、R1の経路一本化）で呼び出し元だけが消えた。**作動が失敗したから捨てられたのではない。**
`git show 5e42145` に当時の体験がそのまま残っている——承認 → パネルを退ける → 150ms → 押す →
押した矩形を0.5秒光らせる → 失敗ならパネルを戻して説明。`.press` と `.fill(text)` の2動作。

**到達不能なコードを置き続けている現状自体が規則違反である**（`docs/README.md`「失敗した方式を作業ツリーに
アーカイブしない」）。R16 の着手は、このファイルを**復活させるのではなく、要件に合わせて書き直す**ことから
始める。そのまま持ち込めない点が3つある。

- **モデルが言った矩形へ盲打ちする第3経路がある**（要素が見つからなくても、モデルの推定矩形が画面上にあれば
  中心を押す）。「操作」 は「押す対象が見えている時だけ押す」段なので、この経路は成立しない。
- **成功判定が戻り値だけ**である。合成クリックに至っては `CGEvent` を生成できたかしか見ていない。
- **対象をラベル文字列で引き当てる**。これは 2026-07-06 の実バグ（素の「ユーザー」が
  「ユーザーの環境の詳細」に勝ち、メニューを閉じる方を押した）の温床そのもので、
  現行アーキテクチャが `candidate_id` で解決済みの問題を持ち戻すことになる。

**逆に、そのまま受け継ぐべき判断が2つある。**

- **要素ハンドルをキャッシュしない。** 「AIが対象を名指し、確定時に木を引き直し、**いま在るもの**に対して
  実行する。回答と確定の間に画面が変わっても、古い要素を撃つことはあり得ない」。これは never-veto の
  唯一の例外（stale の拒否）の実装形そのものである。
- **可視要素には AXPress より合成クリックを優先する。** 理由が実測として残っている——
  「web SPA（GA4等）は AXPress を受理しながら router が待っている DOM イベントを出さないことがあり、
  **成功を報告しながら何も起きない**」。この観察には射程の広い副産物がある:
  **AXPress の戻り値は成功判定に使えない。**

#### 対象の同一性 — R16 の中心的な制約

候補id は `ax:<DFS走査順>` で、**キャプチャ1回限りの使い捨て**である。`Candidate` は `AXUIElement` を保持しない。
つまり「モデルが `ax:37` と言った → それを押す」は、そのままでは成立しない。

**押す直前に AX を引き直し、収集時に測ったものと同じ要素であることを確かめてから押す。** 一致の条件は
role の一致と、label の一致と、矩形が当時と重なること。**どれか1つでも合わなければ押さず、撮り直して
言い直す。** これは拒否権ではなく整合性検査である（「今その要素は在るか」）。

矩形を第一情報にしてはならない。実測で**候補の18%が高さ1pxの矩形として公開され**、Gmailでは同じ14要素の
矩形が読み取りごとに「y=266・高さ1」から正しい位置へ変わった（`api-gateway/docs/guidance-accuracy-plan.md`）。
矩形中心へ素朴に合成クリックすると、スクロール領域の上端を押す事故が一定率で起きる。
**矩形は同名候補の絞り込みと枠の描画に使い、対象の同定には使わない。**

#### 押せるものと押せないもの

- **候補13ロールと作動可能な13ロールは完全に一致している。** モデルが名指せる候補は、構造上すべて
  押せる9ロールか打てる4ロールのどちらかである。**行動の種類をモデルに聞く必要がない——ロールが決める。**
- **パスワード欄は構造上到達不能。** secure field は label を nil にされ、label の無い要素は候補にならない。
  新しい防御を書く必要はなく、この不変条件を壊さないことだけを守る。
- **`states` に肯定形の `enabled` は無い。** 「読めなかった」と「有効」が同じ「disabled が無い」で表現される。
  押す直前に `kAXEnabled` を積極的に読み、true が取れた時だけ押す（不在と不明を混ぜない）。

#### 不可逆なものをどう扱うか — 「操作」では判定器を作らない

本番の案内プロンプトは**押してはいけないものの境界を既に持っている**:
「サインイン・アカウント作成・支払い・権限付与・規約同意——ユーザーにしかできない決定が要る時は
clarification へ落とし、**黙って通過させない**」。

**「操作」 はこの上に判定器を足さない。** 一手ごとにユーザーが確定する段では、不可逆性の判定は確定そのものが
兼ねているからである。「不可逆かどうか」をモデルに言わせる語彙も、クライアントの固定ルートも、「操作」では要らない。

**この判定器が必要になるのは 「連続」 である。** 人がゲートでしか確定しない段で初めて、「どの手は止まって聞くか」を
機械が決める必要が生まれる。「操作」 で作らないという判断は、「連続」 の設計を先送りするためではなく、
**「操作」 の範囲を正しく小さくするため**である。

#### 機構 — 挿入点は1点、押した後の経路は人が押した時と同一

```text
現行:  evaluateCopilotProgress → mode=.guide → installCopilotClickMonitor()
       → （ユーザーのクリックを待つ）→ scheduleCopilotProgressCheck(700ms, waitForChange)
       → StableScreenCapture → 進捗ターン → 次の一手

R16:   evaluateCopilotProgress → mode=.guide → 確定待ちへ入る（枠は出たまま）
       → ユーザーが確定 → 対象を引き直して同一性を確認 → 押す
       → scheduleCopilotProgressCheck(waitForChange) → 以降は現行と完全に同じ
```

**新設するのは「クリックを待つ」を「クリックする」に替える1点だけ。** 変化待ち撮影、進捗ターン、
`maxGuideSteps = 15` の止め弁、診断イベント（`copilot.capture` / `copilot.request` / `copilot.turn` が
同じ原点から積み上がる構造）は、すべて無改造で通る。

**先に外す落とし穴**（すべてコードに根拠がある）:

1. **自分のクリックを自分で拾う。** 案内中の監視は `NSEvent.addGlobalMonitorForEvents(.leftMouseUp)` で、
   除外条件は「バブル矩形の内側か」の2行だけ。**クリックの出所を見ていない。** 合成クリックは
   `.cghidEventTap` へ投函するので、自分の監視へ戻ってくる可能性が高い。戻れば1手で二重に撮影し、
   二重に課金する（R15 G7 が直したのと同型の欠陥）。**押す前に監視を明示的に外し、撮り直しの開始が
   確定するまで再設置しない**を不変条件とする。「自アプリのイベントは届かない」という思い込みは
   この製品で既に一度実機に反証されている。
2. **対象アプリの前面化がキーの持ち主を動かす。** `press()` は無条件に `NSRunningApplication.activate()` を
   呼ぶ。案内中はバブルがキーを持ったままなので、押下のたびに持ち主が動くと、**Escの行き先が押下ごとに
   変わる**という説明不能な挙動になる。確定の入口はキーボードとクリックの両方から届く1つの関数にし、
   キーを失っても確定できる道を残す。
3. **`copilotSawNoChange` の意味が変わる。** 現在は「操作は検知しましたが、画面に変化は見えませんでした」
   という、ユーザーの行為を前提にした注記である。道具が押して変化が無いのは**押下が失敗した積極的な証拠**
   なので、同じフラグを流用すると不在と不明を混ぜることになる。別の理由コードを立てる。
4. **進捗チェック中のユーザークリックが黙って捨てられている。** `scheduleCopilotProgressCheck` の
   先頭ガードが `!isCopilotChecking` を要求し、キューイングも通知もしない。6〜10秒のステップ中、
   ユーザーの操作は無視され続ける。道具が押す段では「道具が押している最中にユーザーも押した」が
   起きるので、この黙殺を明示的な状態へ格上げする。
5. **座標変換の式が3つある。** `VisionPointerResolver` の2関数に加え、未コミットの作業ツリーに
   `SessionCoordinator.cocoaFrame(fromAXFrame:primaryTop:)` が入っており、主ディスプレイ高さの取り方が
   2通りになっている（`NSScreen.screens.first?.frame.maxY` と `CGDisplayBounds(CGMainDisplayID()).height`）。
   実用上は同値だが、**HANDOFF が「二次ディスプレイでずれる」と名指した種類の重複がまさに増えた直後**である。
   R16 は AX frame → 実画面 の変換を必ず使うので、**着手前にここを1本へ戻す。**
6. **clarification が回数上限を増やさない**（`mode == .guide` の時だけ `stepCount` が増える）。
   毎手確定の 「操作」 では顕在化しにくいが、**「連続」 へ進む前に必ず塞ぐ**既知の穴。
7. **診断にラベルは載せられない。** `DiagnosticValue` は `.ms` / `.count` / `.flag` / `.literal(StaticString)` /
   `.code` の5種で、実行時文字列を入れる case が無い。「何を押したか」は
   **ロール**（13個の閉じた集合なのでコード型にできる）と **千分率座標**と **候補id** で記録する。
   これは制約ではなく、README「データ保存」の約束が型で守られているということである。

#### Gateway は当面変えない

**押す段（G1〜G5）に Gateway の変更は要らない。** 理由:

- 行動の種類はロールが決めるので、モデルに新しい語彙を出させる必要がない。
- `mode=guide` ＋ `targetCandidateId` は、すでに「次にこの要素へ作用せよ」という行動指示である。
- 案内プロンプトの「The user has acted since the previous capture」は、**毎手ユーザーが確定する 「操作」 では
  真のままである。**

**打つ段（G6以降）で初めて必要になる**——打つ文字列を返す口が無いため。応答側へキーを足すのは安全である
（公開済み `v0.2.2` のデコーダは辞書の添字読みで、未知キーを無視する）。ただし
`api-gateway` は main への push が本番デプロイなので、**公開中クライアントの挙動を同時に変える**ことを
前提に、入力側の恒久互換アダプタ（R10 の前例）と同じ作法で行う。

同じコミットで直すもの: 案内プロンプト末尾の
「Everything you return in this guided flow is shown in a small strip that has no text box, so the user
cannot reply to you」は R15 でバブルになった時点で偽であり、**R16 ではモデルが確認を求める文を書けることが
必要になる**ので、この一文が邪魔をする。

#### 打つ（テキスト入力）は押すの後、プロジェクトBを前提にする

**現行の「打つ」経路はクリップボード＋合成⌘Vだけ**で、送信本文をクリップボードに残す設計である。
README がこれを「明示操作に限った予測可能な副作用」として許容しているのは**送信1回の話**であり、
案内の各手で毎回上書きすることに同じ正当化は効かない。加えて:

- **AX へ直接書く経路が無い。** `focusTextInput` は欄にフォーカスを当てるまでしかやらない。
- **キーボード操作の進捗検知が存在しない。** 押す側はクリック監視があるが、打つ側は何も観測していない。
- **プロジェクトB（read-back / Undo / IME / 改行の実測）は未実施**で、実測値がリポジトリに1つも無い。
  合成⌘Vが実際に着弾したかを判定する手段も無い。

したがって **B0 probe は「いつかやる」から「打つの前提条件」へ格上げする。**

#### マイルストーン

各段に**実機で測ること**を必ず1つ以上置く。「実装より先に計測」は Web版 `auto-copilot.md` が
自動化機能の着手順として既に固定した規律である。

- **G0 — 借金を返す。** 座標変換を1本へ戻す（落とし穴5）。到達不能な `AXActionService` の去就を決める
  （書き直すなら残し、書き直さないなら削除する。置いたままにしない）。
  *実機で測る*: 無し（機械検証のみ）。
- **G1 — 自分のクリックが自分に返るか。** 短命 probe で、`CGEvent.post(.cghidEventTap)` の
  `leftMouseUp` が自分の `addGlobalMonitorForEvents` に届くかを確定させる。届くなら、押下の前後で
  監視を外す設計が必須になる。**この領域は実測が荒れる**前例がある（R15 G1 で4本の probe のうち
  半数のクリックがどの窓にも届かず、原因を特定できなかった）。
  *実機で測る*: 合成クリックが自分の監視に返る／返らない、と対象アプリに届く／届かない の4象限。
- **G2 — 押せるかどうかの実測。** 同じ probe で、ネイティブ／Chrome／Electron／Web SPA の代表4本に対し、
  「引き直し→同一性確認→合成クリック」がどれだけ当たるかを測る。AXPress との成功率の差も同時に。
  *実機で測る*: 対象別の成功率、引き直しにかかるms、`kAXEnabled` が積極的に読める率。
- **G3 — 押す（1手だけ）。** 案内の `.guide` 分岐を確定待ちへ替え、確定したら押して、既存の
  `scheduleCopilotProgressCheck` へ合流する。確定の入口は1つの関数で、キーボードとクリックの両方から届く。
  **確定を待っている間もユーザーが自分で押せることを壊さない。**
  *実機で測る*: 押下→次の一手の総時間（`copilot.turn` の `sinceAsk` 1本で読める）と、
  現行の「人が探して押す」との差。**軽快さが最大プライオリティである以上、ここが R16 の可否を決める。**
- **G4 — 無音で終わらせない。** 押せなかった（要素が見つからない／無効だった／同一性が合わなかった）を
  すべて言葉にし、言葉の案内へ縮退する。押下は期限とトレースを持つ単一のランナー経由でしか実行できない形にする。
  *実機で測る*: 意図的に外した3経路（対象を消す・画面を変える・無効なボタンを指す）で、
  それぞれ有限時間で理由に到達すること。
- **G5 — 既定はオフ。** 設定に1つトグルを置く（`isProactiveSuggestEnabled` が既定OFFオプトインの完成した前例）。
  オフの間は現行の案内と1ピクセルも違わない。アプリ別の許可は 「連続」 へ持ち越す。
  *実機で測る*: オフで押さないこと。オンで押すこと。24時間以上稼働したプロセスでも押せること（D7へ1項目追加）。
- **G6 — 打つ（プロジェクトB を前提）。** B0 probe（read-back / Undo / IME / 改行）を先に実施し、
  安全な書き込み経路が確定してから着手する。クリップボードを毎手上書きするなら、それを明示する。
  *実機で測る*: B0 の対象順（TextEdit → ローカルHTML → Chrome → Slack → Safari）で、
  書き込み後の read-back が成立する対象と成立しない対象。
- **G7 — 公開の門。** build番号を上げて署名ビルドし、golden paths へ R16 の項目を足して通す。

#### 実機で測らないと決まらないこと

- **押下1手あたりの原価と手数。** 1リクエスト＝1ユニット。押す段では手数が増えない（押下は
  モデル呼び出しを伴わない）が、失敗して押し直す分だけ増える。実測が無いまま枠の設計はできない。
- **確定をどの操作に載せるか。** R15 は「指示を読んだ人は確認ではなく対象を押しに行く」を実測した。
  Enter（入力欄が空の時）／クリック／その両方のどれを人が実際に選ぶかは、実機で見るしかない。
  **R14・R15 は2度とも実機の観察で設計を覆した領域である。**
- **押下後にバブルがキーを取り戻せるか。** 押すと対象アプリが前面になるので、2手目以降の Enter が
  どこへ行くかが変わる。`.nonactivatingPanel` ＋ `makeKey()` は同期的にキーを取れるが、
  押下直後に取り返すことが対象アプリの処理を壊さないかは未確認。
- **押した／押せなかったをどう述べるか。** R12 E2（`blockMax` の実値決定）が未着手で、現在の道具は
  「押したが変化なし」と「押せていない」を区別できない。R16 が先行できるのか、E2 を先に片付けるべきかの判断。
- **ネイティブメニューが開いている時に押せるか。** メニューは前面化で閉じることがあり、
  `activate()` → press の順序がメニュー内項目の押下を壊す可能性がある。
- **マルチディスプレイ。** 押す対象が覆っていない画面にある場合の扱いが未定
  （`capture.display` の `display` 値で不一致は検出できる）。
- **`AXActionService` の探索予算**（6000ノード／2.5秒）が実機で成立するか。R12 の実測では AX 収集が
  `node_limit` に当たった回があり、その時失われたのは案内対象そのものだった。

#### 範囲外

- **「連続」（1つの用事が終わるまで進む）。** 同じ個人ユーザーのための次の段で、R16 の直接の続きだが、
  R16 では扱わない。R16 は「連続」が乗る土台（行動の型、失敗の型、停止弁）を作る。
- **「無人」（人が画面の前にいない実行＝作業者としての利用）。** 法人向けの別製品。
- **不可逆性の判定器。** 上記のとおり 「操作」 では確定が兼ねる。「連続」 の課題。
- **自発的に押す。** 目的の宣言なしに道具から押しに行くことはしない。自動コパイロット
  （settle駆動で自発的に喋る）が R15 で範囲外とされたのと同じ線。
- **スキルの「手順」節。** 案内・操作の質はスキルが決めるが、**安全性をスキルに依存させられない**
  （Skillはデータであり制御フローに触れない）。手順節の設計は別トラックで、R16 の受け入れ条件に含めない。
- **Windows実装そのもの。** ただし**Windows版はこのアプリの参照ロジックを引き継ぐ**（オーナー方針、
  2026-08-30）。macOSのAXに相当するのはUI Automationで、古いWin32やIEはむしろツリーが豊かである。
  そのため R16 は、実装しながら**移植する単位を判別できる形にしておく**義務を負う:

  | 引き継ぐもの（OS非依存の判断） | OSに閉じるもの（書き直す） |
  |---|---|
  | 対象の同一性の確かめ方（引き直して role・label・矩形が一致するか） | AX / UI Automation のAPI呼び出し |
  | 成功を戻り値で判定しないという規則と、画面変化で判定する手順 | 合成イベントの投函方法 |
  | 押せない時に言葉の案内へ縮退する分岐 | ウインドウ・覆い・前面化の扱い |
  | 停止弁（回数上限）と、無音で終わらせない規則 | 座標系の変換 |
  | Gatewayとの契約（行動の種類はロールが決める、など） | 権限（TCC / UIAccess）の取得 |

  **判断を macOS の API 呼び出しと同じ関数に混ぜない。** 混ぜると、Windows版がロジックを読み取れず、
  同じ設計判断を2回することになる。


## リリース判定

**配布には2段ある。** 候補DMGを版付き不変URLへ置くこと（`--publish`）と、公開ダウンロード
`Universal-IO.dmg`をそこへ向けること（`--promote`）は別の判断である。テスターへ渡すのは前者で
足り、下の判定は後者にだけ適用する。2026-08-11に`0.2.2` build `8`がD7を通過し、公開ダウンロードは
このビルドへ切り替わっている。

以下をすべて満たした時だけ**公開ダウンロードへ向ける**。

- R2〜R4が完了している。
- R11が完了している（`0.2.2`以降）。長時間稼働後もセッションが確実に開始し、失敗が無音で
  終わらないこと。「再起動してください」を回避策として案内しない。**この不変条件は残るが、
  それを毎リリース長時間稼働で確かめることは要求しない**（D7は2026-08-31に必須ゲートから外した。
  実施条件は[manual-golden-paths.md](manual-golden-paths.md)）。
- **署名した候補そのものを実機で起動して見ている。** 実装済みでも一度も画面に出していないものを
  公開へ向けない。D7を毎回やらないぶん、この1項目は省けない。
- 主要4 AI endpointに旧・代替endpointが存在せず、各routeのモデル指定が共通SSOTだけにある。
- 重大度Highの既知不具合が0件。
- Composeのレビュー後フォーカス、自動返信、音声入力、Vision初回応答が実機で再現可能。
- rollback先と本番Gatewayの互換性が確認されている。

## 次期改善候補（2026-07-22 実機テスト所見）

### 未ログイン初回起動の第一印象（未着手・2026-08-24 実機で確認）

**ログアウト状態で右Shift 2回を押すと「画面の読み取りを開始できませんでした。もう一度お試し
ください。」だけが出る。** 何が足りないのかも、どうすればいいのかも言っていない。**再試行しても
永久に同じ結果になる案内**であり、無音ではないが行き先を示していないという意味でR11の不変条件を
満たしていない。初めて起動した人がここで離脱する。

やりたいこと（別セッションで設計する）:

- アプリを起動したことが分かる（ロゴなどの起動の合図）
- 初回起動なら挨拶と短い案内
- 未ログインならその場でサインインへ導く

**「利用できません」と述べる前に、何が必要かを述べる。**

以下は現行リリースの阻害要因ではなく、別セッションで設計・実装する改善候補とする。

### ComposeをバブルのUXへ（未着手・2026-08-25に方針決定）

Composeを、R14で作ったバブルと同じデザイン・同じ体験にする。同じサイズの同じバブル、送信ボタンなし
（Enter送信・Shift+Enter改行）。**核は機能の格付けである。**

```text
Composeの基本は入力補完。音声入力ができるだけでも便利。
通常は「ただ入力ができるだけ」でよい。
自動返信もレビューも、勝手に立ち上がってはいけない。
```

- **自動返信**は入力ボックスのすぐ下で簡単にオンオフできる。**オンの時だけ**、開いた瞬間に文案が
  入っていて採用するだけで返信が完了する。既定はオフ（そこまで求めていないユーザーが多い）
- **レビュー**はさらに格下げ。実際にレビューを使う場面は少ないので、必要な時に「いま入力されている
  情報」（自動返信の文案を含む）に対して走ればよい

現状は3つのエディタと3つの`PanelSendButton`を持つ`minWidth: 620`のパネルなので、統合ではなく
作り直しに近い。手順の正本はHANDOFFの「課題A」。

### Copilotの入口（2026-08-25: ゲートは開いた。続きはR15）

`canStartCopilot`のキーワード26語一致は削除し、打ち込んだ質問には常に「案内を開始」を出すようにした
（`VisionSession.offersGuidance`、`CopilotEntranceTests`）。指差しだけのターンには出さない。

同日の実機で、**ボタンは押されなかった** — 案内の答えを読んだユーザーはそのまま対象をクリックし、覆いが
それを指差しとして飲んだ。何が起きたかと次の設計は [R15](#r15--実画面の上の案内完了2026-08-25実機で案内が成立)。

### スキル（注入できる文脈）の不足（2026-08-25に記録）

**Copilotはスキルが無いとあまり機能しない。** 解説対象に対して用意できているスキルの数が圧倒的に
不足しており、**回路を開いた後に案内の質を決めるのはモデルではなくここになる**。設計の枠組みは
[v3-tool-fit-plan.md](v3-tool-fit-plan.md)。Copilotの評価とスキルの薄さを混同しないこと —
案内が下手なのか、渡す文脈が無いのかは別の問題である。

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
