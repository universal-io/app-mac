# Universal I/O for macOS

Universal I/O は、入力・受信・画面理解をひとつの操作体系にまとめる macOS アプリです。

> **設計思想の正本**（北極星＝ユーザー起点の世界モデル、作る順序）は
> [docs/design-philosophy.md](docs/design-philosophy.md)。本書が「現在どう動くか」、
> あちらが「どういう思想でどの順に作るか」を扱います。

## 重要: 本番AIモデルとfallback

全AIモデルの一次・二次ルートは
[`web/lib/server/ai-routing.ts`](web/lib/server/ai-routing.ts) が唯一の正本です。
個別のengine、macOSクライアント、環境変数へモデル名を分散させません。

**どのモデルを使うかは流動的です。** 新モデルの精度・遅延・単価を実画面で比較するため、
機能ごとの一次モデルはセッション単位で入れ替わることがあります（トライアル中の差し替えを含む）。
下の表はあくまで現時点のスナップショットで、食い違った場合は常に`ai-routing.ts`が正しく、
READMEの方を直します。モデル名を判断材料にする作業では、この表ではなくコードを読んでください。

現時点（2026-08-02）の構成:

| 機能 | 一次モデル | 二次モデル |
|---|---|---|
| Composeレビュー | OpenAI `gpt-5.6-luna` | Groq `openai/gpt-oss-120b` |
| Vision / Copilot | Cerebras `gemma-4-31b`（トライアル中） | OpenAI `gpt-5.4-mini` |
| 先回り文案 | OpenAI `gpt-5.6-luna` | OpenAI `gpt-5.4-mini` |
| 音声入力 | Groq `whisper-large-v3-turbo` | OpenAI `whisper-1` |

Vision / Copilotの一次は`gpt-5.6-luna`からCerebras `gemma-4-31b`へ試験的に差し替えています。
画面理解の精度が不足する場合はOpenAIへ戻す前提で、二次モデルは変更していません
（`CEREBRAS_API_KEY`が未設定でも二次へ落ちて動作します）。

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
- Compose上部はブラウザ名やウインドウタイトルではなく、適用ツールを右側に表示する。
  画面画像／AX周辺テキストの使用状況、実際の参照元、取得テキスト、保存範囲は
  情報ボタン内で確認・コピーでき、AX周辺テキストだけをそのセッションから除外できる。
  ComposeからVision撮影を直接起動するボタンは置かない。
- Vision: スクリーンショットを読み、質問への回答や次の操作位置を提示。選択テキストが
  ある時は、同じVisionパネルで対象を優先して説明。スクリーンショットは画像上を
  直接ドラッグして表示位置を動かし、トラックパッド操作で拡大・縮小できる。モデル、Gateway、
  AX収集、captureの開発情報はツール名横の情報ボタンへ畳み、まとめてコピーできる。
  Copilotはモデルへ渡す画面が確定した瞬間だけ撮影範囲を短く暗転し、画面を見た順序を示す
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
数百・数千製品へ増やすカタログ基盤はR8の**M7（未着手）**として管理する。製品内を画面moduleへ
分け、該当する1〜3 moduleだけを遅延ロードし、製品追加でmacOSクライアントを更新しない構成を目指す。

### Focused Vision（現行`v0.2.1`）

R9では当時のTransformを独立した製品surfaceとして残さず、選択テキスト・選択要素・位置を開始時点から
持つVisionへ統合した。通常Visionが画面全体から質問で対象を絞るのに対し、Focused Visionは
画面全体に加えて「この部分」を最初から指定した同じVision sessionで、初期解説、追加質問、
Copilotへの移行を行う。

この統合と同じプロジェクトAで、起動判定の合成⌘Cと標準クリップボードの退避・復元を廃止した。
選択取得はAccessibility APIだけを使い、取得失敗時は通常Vision／Composeへ安全に退化する。
Compose送信は主要アプリとの互換性を維持するため当面clipboard＋合成⌘Vを使うが、送信後に古い内容を
復元しない。送信本文がclipboardへ残る、明示操作に限った予測可能な副作用とする。

Composeのclipboard非依存化はプロジェクトBとして分離する。AX直接入力は戻り値だけでは成功を
判定できず、汎用`AXValue`挿入やUnicode keyboard eventは安全なfallbackにならないため、
リポジトリ外の短命probeでread-back、Undo、IME、改行を実測してから採否を決める。

意図、目標構造、移行順、受け入れ条件は
[focused-vision-plan.md](docs/focused-vision-plan.md)、進捗は
[マスタープラン R9](docs/universal-io-master-plan.md)を正本とする。右Shiftの本番起動は
Focused Visionへ切り替わり、独立Transformと`/api/ai/transform`は撤去済み。

R9プロジェクトAは完了し、右Shift起動は同じAX focus snapshotから、選択対象ありならFocused Vision、
選択なし＋編集可能ならCompose、それ以外なら通常Visionへ分岐する。snapshotと画面captureは
パネル前面化前に並行し、起動時の合成⌘C、clipboard読取・復元、0.12秒固定待機は廃止済み。
製品surfaceはCompose / Vision / Copilotの3つで、選択対象の理解もVisionの同一sessionとrouteを使う。
Compose送信は本文をclipboardへ書いて合成⌘Vを1回送るが、過去内容は復元しない。Accessibilityを
利用できない場合は本文を残し、手動⌘Vまたは設定を開く選択肢を明示する。
macOSのunit test／署名なしDebug buildとWebのlint／型検査／production build、開始tagからの
差分監査に加え、署名付きアプリの機能確認を通過した。R9はmainの`6bc471a`へ統合し、本番Gatewayへ
deploy済み。現行4 AI routeの応答と旧`/api/ai/transform`の404を確認した。`0.2.1` build `5`の
Developer ID署名、notarization、staple、Gatekeeper評価を完了し、検証した同一byte列を正式公開した。
公開URLからの再取得でも署名、version/build、Universal binary、SHA-256
`637cd6cc029452db349f87e0a1cae4e6ecf214a3d458ba9ce0ad87ea6344cd69`の一致を確認済みである。

### 開発中: Vision Selection Extension

現行`v0.2.1`は同じVisionパネル、Gateway、モデル、スクリーンショットを使う一方、選択取得が
focused elementに近い最初の非空AX祖先で止まり、初期promptも通常Visionへ情報を加えるのではなく
selection専用taskへ置き換える。このため、Gmail等で複数の画面構造にまたがって選択した全文が
先頭断片へ縮約され、画像・AX・Skillを使えるのにタイトルだけを説明する結果になり得る。
Chrome Gmailの実測では選択全文757 UTF-16 units自体は取得できたが、最初の非空`AXGroup`の
role／label／frameを全文と同じ単一`focus_target`へ格納するため、件名labelが選択全体の代表値として
モデルへ伝わる経路も確認した。取得文字列の欠落だけでなく、全文と局所構造を同一対象へ潰すことが
件名だけを説明する直接原因である。

次期R10では次を不変条件として修正する。

```text
Focused Vision = Vision Core + Selection Extension
Focused Vision - Selection Extension = 通常Vision
```

選択全文はユーザーが明示した回答対象として保持する。最初の非空祖先では止めずdocument rootまで
全候補を調べる。ただしrangeはAX要素ごとのローカル値なので、外側という理由だけで採用せず、
direct `AXSelectedText`の候補間／pass間の一致、非collapsed range、selection coverageを検証して
最も完全なdocument selectionを採用する。`AXStringForRange`との完全一致は補強証拠に留め、
Chrome Gmailで実測した表現差を理由に安定したdirect textを捨てない。複数segment集約は、
実機probeで公開document selectionが
成立せず、公開断片の集約で情報量が増えると分かった製品だけのfallbackとする。

通常Visionのスクリーンショット、現行のAX候補方針、画面identity、Skill、会話、Copilotを減らさず、
選択取得時にすでに得た構造だけを追加する。初回応答の全画面AX候補は通常／Focusedとも現行どおり空とし、
cold browser treeを待つ性能劣化を持ち込まない。初回Focused Visionでは、ユーザーの選択操作が
回答scopeを決め、選択全文が必ず扱う対象そのものになる。AX／画面構造、スクリーンショット、Skillは
意味・関係・操作可能性・見た目・配置を説明する重要情報だが、件名、label、目立つ要素で選択本文を
置換・縮約・無視する権限は持たない。

modeはguidance、最新質問、初回selection、初回observationの優先順で単一resolverが決め、
矛盾する`observation`／`answer`命令を連結しない。長文は先頭だけへ切らず頭尾を均等に残し、
selection本文中の命令には従わないが、文字列全体がユーザーの指定対象であることは信頼する。
新しいsurface、endpoint、model route、別promptは
作らない。公開済み旧fieldは恒久入力adapterから同じ内部型へ正規化する。要件、
マイルストーン、受け入れ条件、復帰点は
[focused-vision-plan.md](docs/focused-vision-plan.md)のプロジェクトCと
[マスタープラン R10](docs/universal-io-master-plan.md)を正本とする。C1の公開AX能力probe、C2の
Selection resolver／データモデル、C3の後方互換Gateway契約／単一promptに続き、C4で右Shiftの
本番入口を`VisionSession(selection:)`へ切り替えた。AX取得は最初の非空祖先で止まらず、documentまでの
候補から選択全文を決め、同時に得た短い部分候補は本文の代替ではなく補助構造として保持する。
macOSクライアントは旧`focus_target`／`visual_selection_hint`を送らず、通常Visionと同じ画像、identity、
Skill、会話、model routeへ任意`selection`だけを加える。旧fieldの受理は公開済みクライアント向けGateway
adapterだけに残る。C5では同じVisionパネルへ選択全文カードを追加し、captureと交差する全frameを別々に
表示する。短いAX labelをテキスト選択の見出しへ使わない。
acquisition、frame数、capture visibility、wire truncationは内容を含めず既存の処理情報へ置く。
C6のローカル自動検証では、通常Visionとの差分が`selection`だけであるrequest比較、単一intent、
全文scope、prompt injection、legacy adapter、secure descendant、capture外、旧経路・privacy監査を固定し、
macOS 41件、Gateway 14件、Web lint／TypeScript／production build、署名なしDebug buildが成功した。
R10の後方互換Gateway契約は2026-08-01にmacOS候補版より先に`main`へ配備した。公開中の
`v0.2.1`クライアントは旧fieldから同じ内部型へ合流するため互換性を維持する。

同日のC6実機テストで**リリースブロッカー**を確認した。何も選択していない画面にも選択カードと
選択用promptが常に付き、モデルが選択の不在報告から回答を始める。原因は`visualOnly`／
`accessibilityElement`という観測主体を持たない推測状態で、R10.5として撤回した。修正計画・
判定記録は[vision-selection-evidence-fix.md](docs/vision-selection-evidence-fix.md)を正とする。

R10.5の正本はこの一文である。

> **ユーザーが指定した選択内容が回答対象である。AX・DOM・スクリーンショット・OCRは、その内容を
> 取得または理解するための情報源であり、いずれの取得成否もユーザーの意図を上書きしない。**

まずGatewayを「拒否ではなく受理して無視」へ変更して本番へ配備し、クライアントからも推測経路を
削除して`kind`単一case・`text`必須へ型を収縮させ、`AXSelected`という概念自体を無くした。
bounded retryも「選択の証拠がまだ現れ得る積極的な兆候がある間だけ待つ」へ再設計し、何も選択して
いないブラウザ画面が起動のたびに2秒の予算を使い切っていた挙動を解消した。

ただしこの時点では、**AXが選択文字列を返さないとユーザーの選択操作ごと無かったことにしていた**。
実機でVS Codeの選択が回答対象にならず、これが誤りだと確定した。AXは取得経路の一つにすぎず、
その失敗はユーザー意図の不在を意味しない。そこで通常Visionのpromptへ「画像上に明確なテキスト
選択が見えるならそれを主対象として読む。ただし選択の有無・不在・不確実性はユーザーへ述べない」を
加え、**唯一画像を観測できるモデルへ判定を移した**。クライアントは見ていないものを報告せず、
モデルが自分の観測から判断するため、これは`visualOnly`の復活ではない。構造化された
`selection`が届いた時はそちらが確定した回答scopeになり、画像判定は行わない。

署名付き候補版での実機確認と性能比較は未実施である。

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

### アイデア: 音声入力のリアルタイム化（未着手）

現行の音声入力は右Shift長押しを離した時点で録音済みWAV1本をまとめて送信する方式（バッチ）。
将来案として、streaming ASR（OpenAIの`gpt-live-transcribe`等、WebSocketの
`v1/realtime/transcription_sessions`系エンドポイント）へ切り替え、右Shiftを押している最中から
部分認識結果（interim transcript）を継続表示することが考えられる。ただし現行のバッチ用モデルとの
単純な差し替えでは実現できず、Gateway側にWebSocket中継層を新設し、interim結果の書き換わりに
耐えるUIと、完了後の音声全体を検査する前提のハルシネーション除去ロジック（`no_speech_prob`等）の
作り直しを要する別プロジェクトになる。優先度・着手時期は未定。

## データ保存

- 入力履歴はComposeで実際に送信した原文と最終文だけを、ログイン中のユーザー専用領域へ
  最新100件保存する。
  Focused Visionの選択内容、画面画像、解説、会話は履歴へ保存しない。
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
| Vision / Copilot | `VisionSession` / `GatewayVisionClient` | `POST /api/ai/vision` |
| 先回り文案 | `ComposeSession` / `GatewaySuggestClient` | `POST /api/ai/suggest` |

ローカルGateway、BYOK、旧Navigator endpoint、shadow、runtime feature flag、macOS側の
代替経路は存在しません。モデルfallbackは本番Gateway内の共通ルーターだけが行います。
別方式を試す場合は短命ブランチで行い、終了時に削除します。

## 課金

macOSはStripeも直接呼びません。Gatewayがホスト型CheckoutまたはStripe顧客ポータルのURLを返し、
クライアントはそれをブラウザで開くだけです。publishable keyは持たず、price idもクライアントへ
渡しません。解約・支払い方法変更・請求書はStripeの画面をそのまま使い、アプリ側に再実装しません。

- **購入の入口はWeb、購入後の管理はアプリ**です。管理画面「料金プラン」のボタンが顧客ポータルを
  開き、解約はそこで行います。ボタンはStripeのcustomerが存在するアカウントにだけ表示します
  （`/api/account`の`has_billing_account`）。買う経路だけがあって止める経路が無い状態を作らない、
  というのがこの導線の理由です。
- **ボタンは画面の名前ではなく、ユーザーの用事で呼びます。** 有料プランなら
  「サブスクリプションを解約…」です。「お支払い管理」では、解約したい本人が解約経路だと気づけません
  （実測で失敗しました）。ポータルは支払い方法と請求書も扱いますが、推測できない用事は解約だけなので、
  それがラベルを取り、残りは説明文に置きます。末尾の`…`は「押すとさらに操作が必要」というmacOSの
  慣習で、押した時点では何も解約されないことを示します。
- **解約は期間終了時に効きます。** 支払った月は使えるという扱いで、即時停止も日割り返金もしません。
  その間プランは`standard`／`active`のままなので、契約状態そのものを
  「解約手続き完了（◯年◯月◯日まで有効）」と表示します（`cancel_at`）。これが無いと、解約した人には
  「有効」としか見えず、手続きが通ったのか分かりません。解約の取り消しも同じポータルで行い、
  取り消せば表示も消えます。
- **契約状態はブラウザから戻った時に照合します。** 購入も解約もブラウザで完了し、アプリからは
  観測できません。したがってアプリが握っている値はユーザーが離れた瞬間から古く、しかも古い値の方が
  危険です — 支払った直後に戻って「フリー」と出れば、ユーザーは入金が消えたと判断します。
  引き金は2つで、**「アカウント」「料金プラン」を開いている状態でアプリが前面化した時**（購入経路が
  Webでもアプリでも効きます）と、**アプリからポータルを開いた時**（戻ってから別画面へ移動しても
  追いつくため）です。起動のたびには取得しません（ホットキーで何度も前面化するので、通常利用の前に
  通信を挟みません）。webhookの適用に1〜2秒かかり、すぐ戻ったユーザーはその競争に勝ててしまうため、
  戻った直後と数秒後の2回読みます。
- **クライアントはプランの一覧を持ちません。** `/api/account`が返した`plan`のidをそのまま表示し、
  表示名を知らないidは生の文字列で見せます。未知のプランを既定値へ丸める実装は、`bs_plans`へ
  `standard`を足した時点で有料契約者に「フリー」と表示していました。

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
- 右 Shift 2回: 起動 / Vision開始 / 閉じる。起動時は、AXで選択テキストを取得できればFocused Vision、
  選択なしで編集可能な入力欄ならCompose、それ以外は通常Vision。
  AX snapshotと画面captureはパネル前面化前に並行し、clipboardへ触れない。Composeからさらに
  右 Shift 2回で先読みcaptureを使ってVisionへ進む
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

現行の正式版は `v0.2.1`（build `5`、バイナリソース `893c92a`）です。Focused Visionと
clipboard安全化を正式採用し、配布DMGは
`https://dl.universal-io.com/releases/0.2.1/build-5/Universal-IO.dmg`、公開ダウンロードは
`https://dl.universal-io.com/Universal-IO.dmg`、SHA-256は
`637cd6cc029452db349f87e0a1cae4e6ecf214a3d458ba9ce0ad87ea6344cd69`です。

前版の `v0.2.0`（build `4`、バイナリソース `ce74d12`）は
`https://dl.universal-io.com/releases/0.2.0/build-4/Universal-IO.dmg`、SHA-256
`98f14799181b45933d5e77df0a55aebbf7f65d9be3a0d87748e0b97551e093c7`として不変保存されています。

さらに前の `v0.1.1`（build `3`、ソース `7171d35`）は
`https://dl.universal-io.com/releases/0.1.1/build-3/Universal-IO.dmg`、SHA-256
`9b46618325f296bd78a7e48b75e383454f58ccb457d8617037dfacd887c2afca`として不変保存されています。

公開版は長期ブランチではなく、Gitタグと変更しないバージョン／build別DMGで保存します。
`main`は次のリリースへ進め、公開済みコードへ緊急修正が必要な場合だけタグからfixブランチを
作成します。versionは公開単位で更新し、build番号は署名・配布ビルドごとに増加させます。

```bash
# Developer ID署名、notarization、staple、Gatekeeper検証、候補DMG作成まで
bash tools/release.sh

# Golden Pathsで確認した同じ候補DMGを不変URLとversion aliasへアップロード
# 再ビルドは行わず、公開URLも変えない
bash tools/release.sh --publish

# 検証後、公開URL（Universal-IO.dmg）を選んだビルドへ向ける＝公開確定
bash tools/release.sh --promote 0.2.1 5
```

**ビルドの公開と「公開ダウンロードにする」を分離する。** `--publish` は
`releases/<version>/build-<build>/Universal-IO.dmg`（不変）と `Universal-IO-<version>.dmg` だけを
書き、**公開URL `Universal-IO.dmg` は触らない**。候補を検証したら `--promote <version> <build>` で
公開URLをそのビルドへ server-side copy する。これにより **WebサイトのCTAは版を持たない
`https://dl.universal-io.com/Universal-IO.dmg` に固定でき、二度と編集不要**（公開の切替は promote で
行う）。問題時は旧ビルドへ `--promote` し直せば公開を戻せる。公開成功後、そのソースコミットへ
`v<version>` タグを付ける。

永続的な候補成果物は`dist/Universal-IO-<version>-build<build>.dmg`の1つだけとする。archive、
Developer ID export後の`.app`、DMG stagingはOSの一時ディレクトリで作り、成功・失敗にかかわらず
スクリプト終了時に削除する。同じversion/buildの候補DMGがすでにある場合は上書きせず停止する。
`--publish`はこの既存DMGの署名、staple、Gatekeeper評価を再確認して同じbyte列をuploadするため、
Golden Pathsで確認したものと公開物が取り違わされない。

### 残タスク（`v0.2.1`公開後）

R9プロジェクトAに残作業はない。Composeをclipboard非依存にできるかを調べるAX直接入力probeと
製品判断は、R9から分離した
[プロジェクトB](docs/focused-vision-plan.md)（B0/B1）として将来実施する。現行の
clipboard＋合成⌘Vは、probeでread-back、Undo、IME、改行まで安全性を証明するまでは正式仕様として
維持する。

リリース全体の運用確認には、providerのZDR確認、本番課金、退会、権限拒否、offline復帰など
[manual-golden-paths.md](docs/manual-golden-paths.md)に未チェック項目がある。これらはR9を
未完了へ戻すものではないが、該当機能や運用を変更する次回リリースで重点確認する。

ここでいう「旧DMGを上書きしない」は配布サーバー上の履歴管理を指す。ユーザーが新しいDMGから
Applicationsへコピーし、既存の `Universal IO.app` を置き換えるのは通常のアップデートである。
XcodeのRunで使うDebugアプリは通常DerivedData内にあり、Applications版とは別のファイルである。
インストーラー確認時は両方を同時起動せず、Xcode版を終了してApplications版だけを起動する。

## 設定

`BOMB_SQUAD_API_BASE_URL` は `project.yml` の Info.plist 定義が唯一の正本です。
`BombSquad.local.plist` は Supabase の公開クライアント設定だけに使用し、Gateway URLは読みません。

詳細は [ドキュメント索引](docs/README.md) を参照してください。
