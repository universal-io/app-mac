# Universal I/O for macOS

Universal I/O は、入力・受信・画面理解をひとつの操作体系にまとめる macOS アプリです。

> **設計思想の正本**（北極星＝ユーザー起点の世界モデル、作る順序）は
> [docs/design-philosophy.md](docs/design-philosophy.md)。本書が「現在どう動くか」、
> あちらが「どういう思想でどの順に作るか」を扱います。

## 重要: 本番AIモデルとfallback

全AIモデルの一次・二次ルートは
[`web/lib/server/ai-routing.ts`](web/lib/server/ai-routing.ts) が唯一の正本です。
個別のengine、macOSクライアント、環境変数へモデル名を分散させません。

| 機能 | 一次モデル | 二次モデル |
|---|---|---|
| Composeレビュー | OpenAI `gpt-5.6-luna` | Groq `openai/gpt-oss-120b` |
| Transform（選択テキストの解説） | OpenAI `gpt-5.6-luna` | OpenAI `gpt-5.4-mini` |
| Vision / Copilot | OpenAI `gpt-5.6-luna` | OpenAI `gpt-5.4-mini` |
| 先回り文案 | OpenAI `gpt-5.6-luna` | OpenAI `gpt-5.4-mini` |
| 音声入力 | Groq `whisper-large-v3-turbo` | OpenAI `whisper-1` |

共通規則:

- 一次モデルが失敗した時だけ二次モデルを1回実行する。三番目の経路は持たない。
- 二次モデルで成功した場合は、全routeが `fallback_used: true` と同じ形式のnoticeを返す。
  macOSは「一次へアクセスできなかったため、二次で処理した」と必ず表示する。
- 両方が失敗した場合は、全機能で同じ明示的エラーを返す。
- macOSはモデルを選ばず、認証済みの本番Gatewayだけを呼ぶ。
- 音声入力は16 kHz mono PCM WAVを使う。全AI routeは共通の認証・quota前処理を、モデル呼び出し
  なしでウォームできる。アプリ起動時は全route、各操作の開始時は次に使うrouteを先回りし、
  成功した前処理をGateway instance内で5分キャッシュする。
- usage記録は成功・モデルエラーとも応答後に行い、レビューのSSEも最終結果を閉じてから記録する。
  モデル推論後の運用記録をユーザーの待ち時間へ含めない。

v3で文体・関係性メモリ（persona / relationship カード）を廃止しました。実利用で注入に値する
学習が得られず、送信のたびに1回の抽出呼び出しを費やしていたためです。ユーザーに関する事実の
記憶はv3で別機構として設計します（[v3-tool-fit-plan.md](docs/v3-tool-fit-plan.md)）。

## 現行機能

- 入力パネル: 文章の作成、音声入力、レビュー、対象アプリへの送信
- 入力履歴は管理画面からだけ閲覧し、入力パネルでは読み込まない。自動返信モードがオフの時は
  見出しとスイッチだけを残して下段を畳む。ただし、そのセッションですでに完成した文案は
  オフにしても保持し、次回のComposeから自動生成を止める。
- Compose上部はブラウザ名やウインドウタイトルではなく、適用ツールと実際の参照元
  （画面画像／AX周辺テキスト）を表示する。詳細から取得テキストと保存範囲を確認でき、
  AX周辺テキストだけをそのセッションから除外できる。
- 受信変換: 選択中の文章を読み取り、要点と返信案を表示
- Vision: スクリーンショットを読み、質問への回答や次の操作位置を提示
- Copilot: ユーザーの操作後に画面を再取得し、目的に到達するまで次の一手を案内
- 履歴: 実際に送信した内容のローカル履歴

## 開発予定の新機能

### v3: ツール適合（Skills とユーザーファクト）

汎用理解を限界までチューニングした上に、ツール個別の理解を積み上げていく。精度レイヤーの
正式名称は **Skills** で、データであり制御フローには触れない（Skillが無くても汎用経路は無傷）。
階層はベース < ツール < 業務 < 個社で合成し、有効なSkillは常にUIで見える（サイレント注入禁止）。

1つのSkillは、そのツールの読み方（reading）、自然な書き方（conventions）、使える機能
（affordances）、注意すべき状態（attention）に加えて、そのツールで学ぶ価値のあるユーザー
ファクトのキー語彙を宣言する。ファクトは`scope`/`key`/`value`のupsertなので、同じ事実を何度
検出しても1行のままで、使い続けても膨らまない。検出はSkillが効いている画面から行い、保存前に
必ずユーザーへ確認する（1セッション1問、拒否したキーは再質問しない）。

確認は先回り文案と同じ1回の呼び出しで行い、検出専用の呼び出しは作らない。Gatewayは
「保存済み・拒否済み・通算3回で打ち切り済み」を除いたキーだけをモデルへ渡し、モデルはその
一覧からidを選ぶだけでキーを創作できない。

**画面上のどれが本人かを決める規則はSkill側に置く。** 基礎プロンプトは「画面上の名前は
たいてい他人なので、その名前を本人と断定できる根拠を示せ」までを中立に定義し、製品ごとの
根拠はSkillが宣言する。Slackは自分宛メンションだけを背景の付いた塊として描くため、色ではなく
描画の形で判定する（ライト／ダークで色は変わるが形は変わらない）。`@here`や
ユーザーグループも同じ強調が付くので、人名以外は除外する。たずねる候補が無い時は項目ごと消えるので、
学習は従来の呼び出しへの純粋な加算になる。確認文はGatewayが組み立て、画面から読み取った値は
必ず引用符の中に入れる。答えは「はい（覚える）」と「いいえ（覚えない）」だけで、値の訂正と
削除は管理画面「覚えていること」で行う。

設計根拠は[v3-tool-fit-plan.md](docs/v3-tool-fit-plan.md)、進捗と受け入れ条件は
[マスタープラン R8](docs/universal-io-master-plan.md)を正本とする。

### Focused Vision（Transform統合とclipboard非依存化）

現行Transformは独立した製品surfaceとして残さず、選択テキスト・選択要素・位置を開始時点から
持つVisionへ統合する。通常Visionが画面全体から質問で対象を絞るのに対し、Focused Visionは
画面全体に加えて「この部分」を最初から指定した同じVision sessionで、初期解説、追加質問、
Copilotへの移行を行う。

この統合と同じプロジェクトで、起動判定の合成⌘C、Compose送信の合成⌘V、標準クリップボードの
退避・復元を廃止する。選択取得とCompose入力はAccessibility APIを第一経路とし、選択取得失敗時は
通常Vision／Composeへ安全に退化する。ComposeのAX入力が使えない場合だけclipboardを使わない
Unicode入力を試し、それも失敗した時はユーザーが選べる明示コピーを提示する。バックグラウンドでは
標準クリップボードを読み書きしない。

意図、目標構造、移行順、受け入れ条件は
[focused-vision-plan.md](docs/focused-vision-plan.md)、進捗は
[マスタープラン R9](docs/universal-io-master-plan.md)を正本とする。実装完了までは現行Transformと
`/api/ai/transform`が本番経路であり、目標仕様と混同しない。

### ゲストプレビュー（ログイン前に試せる体験）

初回起動でいきなり「ログインが必要」とせず、**ログインなしで約20回まで試せる**プレビューを提供する。
デモを触る感覚で入力レビューや変換を体験でき、システム許可の設定を終えた直後にオンボーディングで
うんざりさせない。

- 実現方式: Supabase の**匿名サインイン**をゲストの正体とする（本アプリは全AIを認証済みGateway経由で
  呼ぶため、ゲストにも認証済みセッションが要る）。匿名ユーザーには free(500) ではなく **guest 枠（約20）**を
  provisioning で割り当てる。
- 枠を使い切った時に初めて「利用継続にはログインが必要です。月◯◯クレジット分無料でお使いいただけます。」を
  表示する。◯◯は `bs_plans` の free 上限（現在500）を**動的に**反映し、100や1000へ変えても文言が追従する。
- 継続は匿名アカウントを Google / メールへ**リンク**して昇格（guest→free）。ログイン画面は最初から登録として
  表示し、Google かメールをその場で選べる。
- 要検討: 20回を端末単位/匿名ユーザー単位のどちらで数えるか（再インストール悪用の許容度、`bs_app_devices`）、
  ゲストデータのZDR扱い、初期値「20」。

サーバー（Supabase 匿名認証・guest plan・provisioning 分岐）＋クライアント＋商品/セキュリティ判断に
またがる中規模機能。アカウント管理UI（`docs/admin-dashboard-plan.md` §9-b の権限/plan/account class 分離）と
同じライフサイクル上にあるため、そのプロジェクトと合わせて設計・実装する。

## データ保存

- 入力履歴はComposeで実際に送信した原文と最終文だけを、ログイン中のユーザー専用領域へ
  最新100件保存する。
  Transformの選択文、解説、返信案、コピー結果は履歴へ保存しない。
- 未送信のCompose下書きもユーザー単位でこのMacへ保存する。送信した下書きは消去する。
- 履歴・下書きはSupabase user IDごとに分離する。ログアウト時はローカルDBを閉じ、
  別アカウントへ内容を表示・注入・同期しない。旧版の未分離データは、起動時に復元できた既存
  セッションにだけ一度移行する。
- SupabaseのログインセッションはUniversal I/O専用のmacOS Keychain領域へ保存する。旧SDK共通
  キーは一度だけ移行し、テスト起動ではKeychainを開かない。
- 画面から読み取るホスト名は製品の判定にだけ使い、パス・クエリは取得しない。周辺コンテクストと
  同じくプロンプト用の参照情報で、Gatewayにもusageにも保存しない。
- スクリーンショットと音声は処理用の一時ファイルだけに置く。通常終了時に削除し、異常終了で
  残ったVision画像も次回起動時に削除する。Vision/Copilotの会話は永続化しない。
- Supabaseのusageには機能、モデル、token／秒数、成功・失敗、処理時間などの運用情報だけを
  記録し、入力本文、回答本文、画像、音声、アプリ名、ウインドウタイトルは保存しない。
  ファクトの確認質問も、たずねたかどうかの真偽だけを記録し、キーも画面から読み取った値も残さない。
- transcribe応答は`auth`、`quota`、`provider`、`usage`、`total`の所要時間を返す。
  `usage`は応答後実行のため0として明示し、体感遅延をprovider時間だけで判断しない。
- request単位のusageは90日保持し、期限後はユーザーID・request IDを持たないテナント月次集計へ
  加算して詳細行を自動削除する。月次利用枠は当月の成功行だけで計算する。
- Stripeのwebhookは、受け取ったイベントのIDと種別、livemode、対象subscription IDだけを記録する。
  payloadも金額も顧客情報も保存しない。金銭の正本はStripe Dashboardである。
- アカウント画面から退会できる。直近10分以内の再認証を要求し、Authユーザー、usage、profile、
  個人tenantと、このMacの履歴・下書きを削除する。有効な契約があれば先に解約する。

### AI事業者側の保持（ZDR）

- OpenAIのResponses / Chat Completionsにはすべて`store: false`を指定する。これはAPIの会話状態を
  保存しない指定であり、不正利用監視ログも除外するZDRとは別である。
- OpenAI ZDRは承認後にOrganization / ProjectのData controlsで有効化する。Groq ZDRはData
  Controlsで有効化する。コードから有効状態は取得できないため、リリース前チェックで両方の
  管理画面を確認する。
- 公式仕様: [OpenAI Data controls](https://developers.openai.com/api/docs/guides/your-data)、
  [Groq Your Data](https://console.groq.com/docs/your-data)。

## 本番アーキテクチャ

macOS アプリは AI プロバイダーを直接呼びません。認証済みの全 AI リクエストは
`https://api.universal-io.com` の本番 Gateway に送信します。

| 機能 | macOS | Gateway |
|---|---|---|
| 入力レビュー | `ComposeSession` / `GatewayReviewClient` | `POST /api/ai/review` |
| 音声入力 | `GatewayTranscriber` | `POST /api/ai/transcribe` |
| 受信変換 | `TransformSession` / `GatewayTransformClient` | `POST /api/ai/transform` |
| Vision / Copilot | `VisionSession` / `GatewayVisionClient` | `POST /api/ai/vision` |
| 先回り文案 | `ComposeSession` / `GatewaySuggestClient` | `POST /api/ai/suggest` |

ローカルGateway、BYOK、旧Navigator endpoint、shadow、runtime feature flag、macOS側の
代替経路は存在しません。モデルfallbackは本番Gateway内の共通ルーターだけが行います。
別方式を試す場合は短命ブランチで行い、終了時に削除します。

## 課金

macOSはStripeも直接呼びません。Gatewayがホスト型CheckoutまたはStripe顧客ポータルのURLを返し、
クライアントはそれをブラウザで開くだけです。publishable keyは持たず、price idもクライアントへ
渡しません。解約・支払い方法変更・請求書はStripeの画面をそのまま使い、アプリ側に再実装しません。

- **プランが何を与えるかは`bs_plans`だけが決めます。** Stripeは「どの価格が売れたか」と
  「その契約がどの状態か」しか言いません。枠の変更は`bs_plans`の1行UPDATEで完了します。
- price idからplanへの対応は`bs_plan_prices`が持ちます。クライアントが送ったprice idは使わず、
  planから対応表を引いて販売可能な価格を**サーバーが決めます**。価格は編集できないため値上げごとに
  IDが増え、旧契約者は旧価格のまま残ります。sandboxと本番のIDは同じ表に共存し、
  `STRIPE_SECRET_KEY`の接頭辞がどちら側を販売対象にするかを決めます。
- 反映経路はwebhookだけです。イベントのpayloadは信用せず、subscriptionをStripeから読み直して
  現在の状態を書きます（イベントは順序が保証されず、配送時のAPI versionも一定でないため）。
  同じイベントの再送は`bs_stripe_events`のevent IDで無視します。
- 支払い失敗（`past_due`）の間は有料プランを維持します。Stripeの再試行は数週間続くので、
  最初の失敗でカード更新中の顧客を止める方が、実際の解約よりきつい扱いになるためです。
  解約・未払い確定・未開始はすべて`free`へ落とし、契約IDを消します（`canceled`を書くと
  無料枠まで使えなくなり、契約IDが残ると退会できなくなります）。
- 管理画面「設定」に、鍵の接頭辞から判定した実効モード（本番／サンドボックス）と販売可能な価格を
  表示します。本番デプロイがサンドボックス鍵を握ったままの状態を見えるようにするためで、
  非本番Gatewayを向いている時の警告バーと同じ考え方です。

## 操作

- 右 Shift 1回: 入力パネル内のフォーカス切替（自分の下書き ⇄ 文案／レビュー結果）
- 右 Shift 2回: 起動 / Vision開始 / 閉じる。起動時は、選択テキストがあれば受信変換、編集可能な
  入力欄にフォーカスがあればコンポーズ、どちらも無ければ最初からVision（書き込む先が無いため）。
  コンポーズからさらに右 Shift 2回でVisionへ。フォーカス判定は前面化する前に同期で行う
- 右 Shift 長押し: 音声入力
- Esc: パネルを閉じる
- 入力パネルの「レビュー」ボタン: 自分の下書きをレビュー
- 入力パネルのカメラ: Vision用スクリーンショット取得（範囲選択あり）

レビュー結果は参考表示です。レビュー完了後も入力フォーカスは自分の下書きに残り、
Enter は下書きを送信します。レビュー案を使う場合だけ明示的にフォーカスを切り替えます。

入力パネルを開くと、フォーカス中のフォームに入れる文案を画面から先回りで生成し、レビュー結果と
同じ位置に自動表示します（設定でオフにでき、オフでもVisionの先読みは続きます）。候補はその場で
編集でき、「送信」1回で対象欄へ直接入力します。使わなければ保存されません。Shift×2でVisionへ
進むときは、パネル起動時に撮った画面をそのまま再利用します。

先回り文案のプロンプトは、まず「なぜ呼ばれたか」を定義します。ホットキーで呼び出された時点で
ユーザーは書くことについて助けを求めており、入力欄の手前にあるものはユーザーへ向けられた依頼や
質問である可能性が高い、という前提です。画面上の証拠が明確に否定しない限りユーザーを返す側と
みなし、会話の大半が画面外でも文脈不足を理由に生成を控えません。助けが必要な場面で何も出さない
ことを最悪の結果として扱います。

文案生成前に、最新の送信者、宛先、ユーザーの立場、添付所有者、依頼内容、**その依頼を実行するのは
誰か**、返信意図を構造化します。実行者がユーザーの場合、文案はユーザーが何をするかを述べ、同じ依頼を
相手への指示として返しません（「確認しますか」に「確認してください」と返すのは失敗です）。可否や
選択を問われた場合は立場を示します。逆向きも同じで、相手の送付や作成をユーザー自身の行為として
言い換えません。検証中はこの認知結果を文案下の説明に表示します。

共通の判断指示と、ユーザー本人に関する情報は別レイヤーで渡します。後者は**ユーザーが確認した
ファクトだけ**で、注入するのは`global`と画面に効いているツールのscopeに限ります（Slackのハンドルが
Gmailの文案へ入ることはありません）。確認済みのファクトが無ければ添付ごと送らず、汎用のまま動きます。

既定Personaは廃止しました。「事業開発とソフトウェア開発を横断するFounder／Engineer／Designer」
という記述は、書いた本人1人の説明を全ユーザーへ断定していたためです。借り物の人物像より、
何も仮定しない汎用の方が正確です。

出力言語（文案・要約・回答の言語）は管理画面の「設定 › 言語」で選び、初期値はこのMacの言語設定から
読み取ります。日本語と英語に対応します。アプリ自体の表示は現在日本語のみで、UIの多言語化は
別フェーズとして扱います。

画面上の製品はホスト名で判定します。業務ツールの多くはブラウザ内で動くため bundle ID は
ブラウザのものにしかならず、ウィンドウタイトルもページ次第です（Workspace の Gmail は
「件名 - アドレス - 組織名 Mail」で製品名を含みません）。ホスト名だけが製品を確実に指すので、
Accessibility からページのホスト名を読み、パスとクエリは取得しません。ネイティブアプリは
bundle ID で判定します。

製品を判定すると、その製品のSkillを添付します。Skillは1製品1ファイルで、画面の読み方
（reading）、その製品での自然な書き方（conventions）、使える機能（affordances）、注意すべき状態
（attention）、そこで学ぶ価値のあるユーザーファクトのキー語彙を持ちます。用途に応じて渡す
セクションを変え、文案生成にはreadingとconventions、Vision／Copilotにはreading・affordances・
attentionを渡します。現行はSlack、Gmail、Google アナリティクス（GA4）、Stripeです。Googleのような
提供元単位ではなく、Gmail、Docs、SheetsのようにUIの意味が異なる製品単位で追加します。

**認証情報が写る画面では画面送信を伴う機能を使わないでください。** Stripeのシークレットキー、
銀行口座、本人確認書類などは、スクリーンショットに写ればそのまま送信されます。Skill側にも
「その種の値は読み上げず、場所と扱い方だけを述べる」規則を入れていますが、これはモデルの
振る舞いの制約であり、送信そのものを止める仕組みではありません。

ツールによって厚いセクションが変わります。SlackやGmailは書き方（conventions）が厚く、GA4のような
操作系は逆にaffordancesとattentionが厚く、conventionsを持ちません。持たないセクションは
単に注入されないので、文案生成はGA4ではreadingだけを受け取ります。

**適用中のSkillは必ずパネルに表示します。** ユーザーが見えない知識は、疑うことも直すこともできない
ためです。Skillはデータであり制御フローに触れないので、該当するSkillが無い画面でも汎用の経路が
そのまま動きます。

明示的にパネルを閉じた時は呼び出し元アプリへフォーカスを戻し、
次回起動のCompose／Vision判定がUniversal I/O自身を前面アプリとして誤認しないようにします。

Composeは最初から自動返信モードの領域を表示し、見出し横のスイッチでセッション中にもオン／オフを
切り替えられます。オフでも領域は残り、オンにすると同じ先読み画像から生成を開始します。
画面分析中は領域内、レビュー中は操作列のスピナーで進行を示します。Compose原文、
AI文案、レビュー文案、Vision質問の送信操作は、同じ紙飛行機アイコン、Enter操作、VoiceOver上の
用途別ラベルに統一します。AI文案には破棄操作を置かず、使わない場合はそのまま無視できます。
パネルとスクリーンショットの対象画面は、**呼び出し元アプリのフォーカスウインドウがある画面**に
揃えます（`ActiveDisplay`）。カーソル位置は使いません。マルチディスプレイではポインタが別の画面に
置かれたままキーボードだけ手元の画面という状態が普通に起き、カーソルを追うと見ていない画面を撮って
そちらにパネルを出してしまうためです。判定はパネルが前面化する前に行い、セッション中は同じ画面へ
固定します。Accessibilityから位置が取れない場合だけカーソル位置へ戻します。パネルは対象画面の中央に
開き、表示後は背景や余白をドラッグして自由に移動できます。前回の位置は保存しません。

Visionの回答が`guide`の場合に加え、「どこから」「どうやって」「取得」「設定」等の明示的な
操作質問なら回答modeにかかわらず「案内を開始」からCopilotへ進めます。Chrome等がクリック対象の
Accessibility矩形を返さない場合も入口は表示し、矩形がある時だけ対象をハイライトします。
矩形が無い時は文章案内を継続してユーザーのクリック後に画面を再評価します。

## 開発

必要環境:

- macOS 14+
- Xcode 16+
- XcodeGen
- Node.js / npm

```bash
xcodegen generate
xcodebuild -project BombSquad.xcodeproj -scheme BombSquad -configuration Debug \
  -derivedDataPath /tmp/universal-io-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

cd web
npm install
npm run lint
npm run build
```

通常のCLI検証では署名を無効にします。署名付き実行はマイク・画面収録・Accessibility・
Keychain の許可状態に影響するため、明示的な実機確認時だけ行います。

### Gatewayのデプロイ

**`origin/main` へのpush＝本番Gatewayデプロイ**です（Vercelのgit連携。`vercel` CLIもCI workflowも
使いません）。Vercelが見るのはGitHub上の`main`なので、ローカルでコミットしただけでは何も起きません。
`web/` を触った変更は push するまで本番へ届かないので、実機検証の前に必ず `main` へマージして
pushします。過去に「クライアントは正しいのに文案が出ない」障害の唯一の原因が、routeが本番の`main`に
無かったことでした。macOSクライアントだけの変更はGatewayに影響しません。

`main` 以外のブランチをpushするとVercelのPreviewが生成されますが、Deployment Protection配下で
外部からは到達できず、固定エイリアスも持ちません。アプリは常に `api.universal-io.com`
（Production＝`main`）だけを見るため、実検証にはPreviewを使えません。

配布中のDMGはGatewayデプロイとは独立で、`tools/release.sh` を回さない限り変わりません。

## リリース運用

現行の正式版は `v0.2.0`（build `4`、バイナリソース `ce74d12`）です。配布DMGは
`https://dl.universal-io.com/releases/0.2.0/build-4/Universal-IO.dmg`、SHA-256は
`98f14799181b45933d5e77df0a55aebbf7f65d9be3a0d87748e0b97551e093c7`です。
Vision / Copilot、画面文脈に基づく自動返信、共通AIウォームアップ、統一したCompose UIを
製品機能として正式採用しました。

現行公開版の `v0.1.1`（build `3`、ソース `7171d35`）は
`https://dl.universal-io.com/releases/0.1.1/build-3/Universal-IO.dmg`、SHA-256
`9b46618325f296bd78a7e48b75e383454f58ccb457d8617037dfacd887c2afca`として不変保存されています。

公開版は長期ブランチではなく、Gitタグと変更しないバージョン／build別DMGで保存します。
`main`は次のリリースへ進め、公開済みコードへ緊急修正が必要な場合だけタグからfixブランチを
作成します。versionは公開単位で更新し、build番号は署名・配布ビルドごとに増加させます。

```bash
# Developer ID署名、notarization、staple、Gatekeeper検証、DMG作成まで
bash tools/release.sh

# 上記に加え、不変URLとversion aliasへアップロード（公開URLは変えない）
bash tools/release.sh --publish

# 検証後、公開URL（Universal-IO.dmg）を選んだビルドへ向ける＝公開確定
bash tools/release.sh --promote 0.2.0 4
```

**ビルドの公開と「公開ダウンロードにする」を分離する。** `--publish` は
`releases/<version>/build-<build>/Universal-IO.dmg`（不変）と `Universal-IO-<version>.dmg` だけを
書き、**公開URL `Universal-IO.dmg` は触らない**。候補を検証したら `--promote <version> <build>` で
公開URLをそのビルドへ server-side copy する。これにより **WebサイトのCTAは版を持たない
`https://dl.universal-io.com/Universal-IO.dmg` に固定でき、二度と編集不要**（公開の切替は promote で
行う）。問題時は旧ビルドへ `--promote` し直せば公開を戻せる。公開成功後、そのソースコミットへ
`v<version>` タグを付ける。

ここでいう「旧DMGを上書きしない」は配布サーバー上の履歴管理を指す。ユーザーが新しいDMGから
Applicationsへコピーし、既存の `Universal IO.app` を置き換えるのは通常のアップデートである。
XcodeのRunで使うDebugアプリは通常DerivedData内にあり、Applications版とは別のファイルである。
インストーラー確認時は両方を同時起動せず、Xcode版を終了してApplications版だけを起動する。

## 設定

`BOMB_SQUAD_API_BASE_URL` は `project.yml` の Info.plist 定義が唯一の正本です。
`BombSquad.local.plist` は Supabase の公開クライアント設定だけに使用し、Gateway URLは読みません。

詳細は [ドキュメント索引](docs/README.md) を参照してください。
