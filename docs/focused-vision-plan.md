# Focused Vision 計画

最終更新: 2026-08-01 ／ ステータス: プロジェクトA完了・プロジェクトC C6でリリースブロッカー発見、R10.5修正中

本書は、TransformをVisionへ統合し、Universal I/Oがユーザーに見えない場所で
システムクリップボードを退避・復元する構造を廃止するプロジェクトの仕様書である。
進捗は[マスタープラン R9](universal-io-master-plan.md)、現行実装のAPI契約は
[api-contract.md](api-contract.md)を正とする。独立Transform契約はA5で撤去済み。

2026-07-31に、`v0.2.1`の選択取得がfocused elementに近い最初の非空AX祖先で停止し、
通常Visionの初期入力へ情報を加えるのではなく別taskへ置き換えていたことを確認した。
プロジェクトCではFocused Visionを次の式どおりの**純粋な加算**へ改修する。

```text
Focused Vision = Vision Core + Selection Extension
Focused Vision - Selection Extension = 通常Vision
```

選択操作はユーザーが明示した対象指定であり、選択全文が初回回答のscopeを決める。
スクリーンショット、AX／画面構造、Skillはその全文を理解・説明する重要な材料だが、対象を別の
件名、label、目立つ要素へ変更する権限は持たない。選択本文だけでVision Coreを置換せず、逆に
周辺観測で選択全文を縮約・無視しない。プロジェクトAの完了記録は当時の実装履歴として残すが、
§3〜§6の目標仕様と§18以降のプロジェクトCが今後の実装判断に優先する。

2026-08-01のC6実機テストで、選択していない画面にも選択カードと選択用promptが常に付く不具合を
確認した。原因判定と修正は[vision-selection-evidence-fix.md](vision-selection-evidence-fix.md)
（R10.5）を正とする。本書の`visualOnly`／選択要素（`AXSelected`）による選択成立の記述は同日
撤回し、**selectionは`VisionSelectionResolver`が確定した非空の選択テキストからのみ成立する**。
C2〜C6の完了記録中の`visualOnly`等の記述は当時の実装履歴である。

## 0. 復帰点と変更管理

実装前の復帰点は次で固定する。

```text
tag:    pre-focused-vision-r9-20260730
commit: 1aea597c4c9bad6088a69d67ad689c01c45aaade
branch: feat/focused-vision-r9
```

このタグは、Focused Visionのコード変更を1行も含まない当時の`main`を指す。プロジェクトA全体が
不採用になった場合は、このタグから新しい復旧ブランチを作る。公開済み履歴を破壊するresetや
force pushは使わない。

```bash
git switch -c recover/pre-focused-vision pre-focused-vision-r9-20260730
```

変更は§13のマイルストーンごとに、機械検証が通った地点でコミットする。各コミットは次のどちらかを
満たす単独で理解可能な境界にする。

- 内部構造だけを追加し、現行本番経路の挙動を変えない。
- 新経路を完成させると同時に、置換された旧経路を削除する。

長期feature flag、二重の本番route、失敗したprobeやfixtureを完成後のツリーへ残さない。
プロジェクトBの実験物はリポジトリ外に置き、結果だけを本書へ記録する。

プロジェクトCの復帰点は次で固定する。

```text
tag:    pre-vision-selection-extension-20260731
commit: dcac535
branch: feat/vision-selection-extension
```

このcommitは`v0.2.1`公開後のpanel直接操作・情報表示改善を含み、selection extensionの設計・実装を
含まない。Cの変更は短命ブランチでマイルストーンごとにコミットし、失敗したprobe、二重prompt、
長期flagを本番ツリーへ残さない。

## 1. なぜやるか

現行Transformは、他アプリで選択した文章を取り込み、状況・依頼・返信案へ整理する独立surfaceである。
しかしユーザーの意図は「文章を変換したい」ではなく、**画面上のこの部分について知りたい**である。
これは独立したTransformではなく、対象を最初から指定したVisionとして扱う方が正確である。

通常のVisionは画面全体を把握してから質問で対象を絞る。Focused Visionは、画面全体に加えて
選択テキスト、選択要素、位置のいずれかを開始時点から持つ。

```text
通常のVision
  画面全体を把握する → 質問で対象を絞る → 必要ならCopilot

Focused Vision
  画面全体を把握する
  ＋ 選択対象を最初から指定する
  → 対象を文脈内で説明する → 追加質問 → 必要ならCopilot
```

この再定義には5つの目的がある。

1. Transformという実態に合わない名前と独立パネルを廃止する。
2. 選択箇所の説明を、画面全体・Skill・継続質問・Copilotと同じ理解経路へ載せる。
3. VisionとTransformに重複しているSession、View、Gateway route、プロンプトを統合する。
4. 起動時の合成⌘Cと全てのクリップボード退避・復元を廃止し、時間差でユーザーのコピーを
   上書きする構造をなくす。
5. Compose入力のclipboard非依存化は、主要アプリでの実測を終えてから別プロジェクトとして
   採否を決める。未証明の入力方式をFocused Visionの出荷条件にしない。

## 2. A4改修前の構造的問題

### 2.1 右Shift起動が必ずクリップボードへ触っていた

A4改修前の右Shift 2回は、Compose、Transform、Visionのどれを開くか決める前に
`SelectionGrabber`が合成⌘Cを送る。

```text
クリップボードを退避
  → 対象アプリへ合成⌘C
  → 0.12秒後に標準クリップボードを読む
  → 選択があればTransform
  → 退避内容を標準クリップボードへ書き戻す
```

このため、ユーザーがTransformもコピー操作も使わず、ComposeやVisionを開くだけでも
グローバルな標準クリップボードが変更される。

### 2.2 Compose送信もクリップボードを借用する

`PasteDeployer`は送信文を標準クリップボードへ書き、対象アプリを前面化して合成⌘Vを送り、
合計約0.42秒後に退避内容を書き戻す。この間にユーザーや別アプリがコピーすると競合する。

### 2.3 退避・復元は安全なトランザクションにならない

- 遅延提供のpasteboard flavorを完全に複製できない。
- 0バイトのflavorを有効な値として再登録できる。
- 空snapshotの復元が現在値を消去できる。
- `changeCount`は変更回数だけで、誰がどの順序で書いたかを示さない。
- 合成イベントとユーザー操作の到着順を、復元時点の値だけから完全には判別できない。

これは個別条件の不足だけでなく、複数アプリが共有する可変状態をタイマー付きで借りる設計の問題である。

### 2.4 TransformがVisionの先に進めない

現行Transformは選択文と単発の整理結果を表示し、出口はコピーだけである。同じ対象について
質問を重ねたり、画面上の意味を確認したり、操作案内へ進むにはVisionを開き直す必要がある。

## 3. 製品モデル

実装完了後の製品surfaceは3つとする。

1. **Compose** — 対象入力欄へ入れる文章を作成・レビューし、ユーザーの確定で入力する。
2. **Vision** — 現在の画面または選択対象を理解し、質問へ答える。
3. **Copilot** — Visionの理解を引き継ぎ、ユーザー操作後に画面を再評価して次の一手を示す。

Focused Visionは4つ目のsurfaceでも別taskでもない。通常Visionが必ず使うcapture、画面全体の
視覚理解、AX候補、identity、Skill、会話、Copilotを一切減らさず、ユーザーが明示した選択情報を
任意の`Selection Extension`として追加した同じVision sessionである。
Transform、受信変換、選択変換という製品名は廃止する。

```text
VisionSession
  Vision Core（常に同じ）
    ├─ capture
    ├─ visual understanding
    ├─ AX screen structure / action candidates
    ├─ product identity
    ├─ Skill
    ├─ turns
    └─ Copilot
  Selection Extension（任意）
    ├─ selected text
    ├─ selection-related AX structure
    ├─ multiple frames
    └─ acquisition completeness / capture visibility
```

通常VisionとFocused Visionを証拠・安全規則の三項分岐で作り分けない。共通のVision evidenceと
safetyを先に構築し、単一request intent resolverがmode命令を1つだけ決め、selectionがある場合だけ
同じuser inputへ参照データと意味指示を追記する。VLM呼び出しは1回のままで、通常Visionを
別呼び出ししてからFocused Visionを実行する二段構成にはしない。

## 4. 起動と状態遷移

### 4.1 右Shift 2回

パネルを前面化する前に、呼び出し元アプリのAccessibility treeを読み始める。合成⌘Cは送らない。
選択取得、編集可能判定、画面captureは並行して進め、固定の2秒待機をユーザーへ課さない。

```text
右Shift 2回
  ├─ resolverが非空の選択テキストを確定できた
  │    → Vision(selection: Selection Extension)
  │
  ├─ focused elementが編集可能
  │    → Compose
  │
  └─ それ以外
       → Vision(selection: nil)
```

起動結果のsurfaceはComposeまたはVisionだけとし、Visionへ任意のselectionを渡す。選択検出と
編集可能判定は同じsummon時点の値snapshotから導き、別々のAX walkで時点をずらさない。
編集可能な入力欄内でも非collapsed選択があればVisionへ進む。ユーザーが選択によって
「この範囲を見てほしい」と明示したためであり、単一のfocused AX要素を選んだという意味ではない。

Chromium / ElectronはAX treeを遅延構築する。アプリ要素へ`AXEnhancedUserInterface`と
`AXManualAccessibility`の両方を設定し、focused elementの祖先だけでなくfocused window内の
document rootと選択を公開するtext containerを調べる。treeまたはselection coverageが成長している
間だけ、画面captureと並行してbounded retryする。最初の非空断片を成功条件にしない。
既存の`VisionObservationCaptureService`と同じdeadline／cancel規律を使い、選択用に無制限walkを作らない。

### 4.2 AXで選択を取得できない場合

合成⌘Cへfallbackしない。選択文字列を取得できなければselectionは成立せず、編集可能な
focused elementならCompose、それ以外ならselectionなしの**完全な通常Vision**へ進む。劣化状態では
ない。「capture上に選択ハイライトが観測可能なら`visualOnly`」という当初の条件は撤回した —
クライアントは画像解析を行わず、この条件を判定できる主体が存在しないため、実装は必ず推測になる
（R10.5）。

Safari、Apple Mail、AX treeが冷えたChromium等では、公開・文書化されたAX属性から本文選択を
取得できない場合がある。その場合も通常Visionとする。画面にはハイライトが写っており、ユーザーが
質問すればモデルは画像から答えられる。**質問が最後の選択拡張である。**
公開AX rangeで複数DOM相当の選択全文を取得できない製品は、リポジトリ外probeで公開属性、実際に
列挙されるattribute、OS／アプリversionを記録して採用可否を決める。
未検証の属性、AppleScript、ページ内JavaScriptを黙った汎用fallbackにはしない。

### 4.3 他の起動操作

- メニューバー「パネルを表示」: 現行どおりCompose。選択検出を行わない。
- 右Shift長押し: 現行どおり音声入力を開始する。選択検出を行わない。
- Composeから右Shift 2回: 先読みcaptureを再利用して通常Visionへ進む。
- Vision / Focused Visionから右Shift 2回またはEsc: 閉じる。

## 5. Selection Extension

Selection Extensionは、取得できた情報だけを持つセッション内データで、永続化しない。

```swift
struct VisionSelectionContext {
    let text: String?
    let structures: [SelectionStructure]
    let frames: [CGRect]
    let acquisitionCompleteness: AcquisitionCompleteness
    let acquisition: Acquisition
    let captureVisibility: CaptureVisibility
}

struct SelectionStructure {
    let source: StructureSource
    let role: String?
    let label: String?
    let parentLabel: String?
    let relationship: SelectionRelationship
    let states: [String]
    let actions: [String]
    let frame: CGRect?
    let coverage: StructureCoverage
}
```

- `text`: ユーザーが選択した論理的な全文。先頭segmentの別名にしない
- `structures`: selection取得中にすでに得たAX／DOM相当のrole、label、relation、state、action、frame。
  text segmentとは独立させ、各項目にselectionとのrelationshipと
  `whole` / `partial` / `context` / `unknown`のcoverageを持つ
- `frames`: 選択範囲を表す0個以上のグローバル矩形。単一unionへ潰さない
- `acquisitionCompleteness`: `complete` / `partial`。AX取得の状態であり、
  Gateway送信用の切り詰めとは別。`visualOnly`はR10.5で撤回した（観測主体が無い）
- `acquisition`: 公開AX range、複数AX fragment、画像上の選択等の取得方法
- `captureVisibility`: `visible` / `partial` / `offCapture` / `unknown`
- structureの`role` / `label` / `parentLabel`は本文の名前や要約ではない。coverageはcontainerと
  selection rangeの重なりだけを示し、`whole`でも選択全体を命名するmetadataとして扱わない

制約:

- ローカルsessionは取得した全文を保持できるが、Gateway送信時は§8の規則でbounded representationを
  作る。先頭だけを残す切り詰めは禁止する。
- `complete`は「採用した公開AX APIがselection全体として返した値をローカルで切らずに取得した」
  ことを意味し、画像との完全一致を証明したという意味にはしない。
- password等のsecure fieldは対象にもCompose入力先にも含めない。focused ancestor、document root、
  text containerの全経路で、値・label・frameを読む前にsecure判定を再適用する。
- AX値、アプリ名、ウインドウタイトル、矩形はusageへ保存しない。
- selectionと画像はVision session終了時に破棄する。
- AX要素参照そのものをGatewayへ送らない。送るのは必要な値だけ。

### 5.1 取得優先順位

**主対策は、focused elementに近い最初の非空値で止まらず、document rootまで全候補を調べ、
direct selected textの候補間／pass間の一致、非collapsed range、selection coverageを検証して、
最も完全なdocument selectionを採用することである。外側という理由だけでは採用しない。
`AXStringForRange`との完全一致は補強証拠であり、Chrome Gmailで実測した表現差だけで安定した
direct textを棄却しない。複数segment集約は、この方式が成立しない製品でだけ使う受け皿であり、
最初から必須のデータモデルやwire契約にしない。**

1. focused elementからdocument rootまでの祖先を調べ、selectionを返す各containerを記録する。
   最初の非空`AXSelectedText`では終了しない。
2. 外側のdocument／text containerが公開する`AXSelectedTextRanges`、`AXSelectedTextRange`、
   `AXSelectedText`と`AXStringForRange`／`AXBoundsForRange`を、実際に対応する範囲で読む。
3. rangeはそのAX要素の文字空間に属するローカル値として扱い、別の祖先・子孫へ流用しない。
   direct `AXSelectedText`の候補間／pass間の一致、非collapsed range、coverage、pass間の安定を
   検証する。`AXStringForRange`が一致すれば補強証拠とするが、不一致だけでdirect textを棄却しない。
4. 検証済みdocument containerがselection全体として値を返せば、それを`complete`なselection
   textとして内側の断片より優先する。外側候補のrange/textが不整合なら採用しない。
5. C1でdocument selectionが成立しないと確認した製品だけ、複数要素の断片を文書順で集約し、
   重複を除いて全文を構成する。近い要素、先頭要素、長い要素だけを採用しない。
6. retry品質は「選択が1文字あるか」ではなく、document root確認、range/text対応、候補のcoverage、
   pass間の安定で決める。最初の非空断片では終了しない。
7. document selectionの契約を確認できず断片だけを構成した場合は`partial`とし、モデル入力と
   開発情報で取得状態を区別する。
8. AX textを取得できなければselectionなしの通常Visionとする。画像上の選択の有無をクライアントは
   観測できないため、`visualOnly`という状態を作らない（R10.5）。
9. `AXSelected == true`の要素は「現在表示中の項目」でありユーザー意図の証拠にならないため、
   selectionを成立させない。編集可能ならCompose、それ以外は通常Visionとする（R10.5）。

画面上の任意領域をマウスで囲う現行操作は画像のcapture regionであり、Selection Extensionではない。
未使用の`VisionFocusTarget.region`は新modelへ移さずC2で削除する。ただし公開済みクライアント向けの
legacy wire入力は§8のadapterで安全に正規化できる範囲に限り受理する。

## 6. 画面体験

### 6.1 同じVisionパネルを使う

Focused Vision専用ウインドウやTransformパネルを作らない。既存Visionのレイアウト、質問欄、
Enter送信、Esc終了、Skill表示、fallback notice、Copilot開始を共有する。

### 6.2 対象の表示

selectionがある時だけ、左側のcaptureと交差する取得済みframeを全てハイライトし、selectionカードを添える。
selectionが無い時は、カード、選択用prompt、選択への言及が一切現れない（R10.5の最重要受け入れ条件）。

対象カードに表示するもの:

- 「選択した内容」またはUI要素に基づく中立な名称
- 選択全文（長文は折りたたみ、全文はスクロール可能）
- 複数segmentと複数位置を持つ場合も、単一roleや単一矩形へ偽装しない表示
- 位置が取得できなかった場合は、その事実

`complete` / `partial`や取得方式をカード表面へ常時表示しない。
acquisition、segment数、frame数、acquisition completeness、wire truncationは既存の情報ボタン内へ置く。
取得側の不安をユーザーへ常時読ませない。

ブラウザ名やウインドウタイトルを対象名として代用しない。適用中のSkillは既存Visionと同じ場所に
表示する。ハイライトはシステムのアクセントカラーを基本とし、ライト／ダーク、
Increase Contrast、Reduce Transparencyに対応する。色だけで対象を伝えず、枠とラベルを併用する。

### 6.3 初期応答

通常VisionとFocused Visionは同じVision Coreの証拠・安全規則、同じcapture、同じ通常AX候補方針、
同じidentity、同じSkillを使う。Focused VisionはそこへSelection Extensionを追記し、画面全体を理解した上で
ユーザーが選択した範囲へ回答を集中する。内部理解の入力を選択だけへ狭めることと、回答の焦点を
選択へ合わせることを混同しない。

処理を次の二段階に分け、混ぜない。

1. **取得**: ユーザーが実際に選んだ論理textを欠落なく確定する。AX候補比較は取得完全性だけを
   判定し、どの言葉が重要かを決めない。
2. **解釈**: 確定したselection text全体を初回回答の必須対象にする。画像、AX／DOM相当構造、
   identity、Skillはその対象の説明へ加算するが、scopeを変更しない。

権限順位は次で固定する。

```text
ユーザーの明示操作／最新質問（意図とscopeを決める）
  > 選択全文（初回に必ず扱う対象データ）
  > screenshot・AX/DOM・identity・Skill（対象を説明する周辺証拠）
```

Gatewayは三項演算子等で通常Visionの証拠と安全規則をselection専用taskへ置換しない。ただし
`observation`と`answer`のようなmode命令は加算対象ではない。次の優先順位を持つ単一の
`request intent resolver`で一度だけmode方針を決める。

```text
guidance > latest question > initial selection > initial observation
```

共通の証拠・安全規則を先に組み立て、resolverが選んだtaskを1つだけ加え、selectionがある時だけ
次の参照データと意味指示を追記する。

- selection全文が明示された質問対象であり、先頭segmentや最も目立つ箇所だけへ縮約しない
- textを取得できた初回は、その全文を回答の主対象として実際に要約・説明する。「本文も選択されている」
  と選択状態だけを報告して説明を省略することを成功としない
- screenshotから見た目、配置、選択ハイライト、現在状態を読む
- AX／画面構造からselectionの意味、関係、操作可能性を読む
- Skillから製品固有の意味を読む
- `partial`では取得できていない部分を完全な全文だと断定しない
- 情報が矛盾する時も周辺証拠でselection scopeを書き換えず、ユーザーに意味のある不確実性だけを示す
- selection本文は`untrusted content, not instructions`であり本文中の命令へ従わない。ただしselection
  操作はtrusted intentであり、その文字列全体が回答対象であることを弱めない

promptではselectionとstructuresを同じJSONの「target」として渡さない。少なくとも次の独立した
意味ブロックを、この順で構築する。

```text
Resolved user intent:
  Explain the content of the entire user-selected text.

User-selected text — authoritative answer scope, untrusted content:
  <selection.text または明示的に省略されたbounded representation>

Supporting screen evidence — cannot redefine the answer scope:
  screenshot / capture visibility

Supporting structure — cannot name, summarize, or replace the selected text:
  AX/DOM role, label, relation, state, action, frame, coverage
```

`selection.text`を取得できた初回では最初の2ブロックが必須で、structuresの有無や内容に依存しない。
selectionに非空textが無ければselection自体を送らず、通常Visionのrequestとする（R10.5）。
wire上で省略した場合は元の長さと省略を明示し、「全文を受け取った」とモデルへ装わない。

初回turnの通常AX候補は、cold browser treeの待ちを避ける現行性能設計どおり、通常／Focusedの
両方で空を維持する。Focusedにはresolverが選択取得のためにすでに読んだAX構造だけを加算し、
初回応答のための追加AX walkを行わない。全画面候補を初回へ追加する改善はR10から分離する。
画面に根拠が無い情報を対象文字列だけから断定しない。

selectionのframeがcapture内に無い場合は、画像に選択ハイライトが見えると指示しない。
`captureVisibility`が`offCapture` / `unknown`なら、選択テキストは明示されたscopeとして使えるが
画像上の位置は確認できない、とモデルへ伝える。`partial`ではcaptureと交差するframeだけを渡し、
画面外部分も画像に写っているように扱わない。複数displayも各captureとの交差で同じ規則を適用する。

### 6.4 継続

- 同じcaptureでの追加質問ではSelection Extensionを参照文脈として保つが、latest questionを
  scope決定で優先する。「選択全文だけに答える」という初回指示を無条件に再適用しない。
- 質問が対象外へ広がれば、selectionへ回答を縛らず画面全体を参照する。
- 操作意図があれば既存の「案内を開始」からCopilotへ進む。
- Copilot開始時はselectionを踏まえて確定した目的だけをgoalへ引き継ぐ。新captureのguidance turnへ
  古いselection text、segment、frameを再送しない。
- 「コピー」は標準の明示操作として結果テキストのcontext menuまたはボタンから実行できる。

## 7. クリップボード境界

### 7.1 不変条件

**起動・選択取得・モード判定では標準クリップボードを絶対に読み書きしない。標準クリップボードへ
書くのは、ユーザーが「コピー」またはComposeの「送信」を明示的に確定した時だけとする。**

禁止:

- 起動モード判定のための合成⌘C
- 選択テキスト取得のための合成⌘C
- 標準クリップボードの退避・復元
- AX失敗時の無言のclipboard fallback
- タイマー後に過去の内容を書き戻す処理

許可:

- ユーザーが「コピー」を押した時の通常の文字列書き込み
- ユーザーがComposeの「送信」を確定した時、対象欄へ合成⌘Vするために送信本文を書き込むこと
- ユーザーが通常の⌘CをUniversal I/O自身の選択可能テキスト上で実行すること

Compose送信では退避も復元もしない。送信本文が標準クリップボードへ残ることを予測可能な副作用とする。
これにより、遅延提供flavorの破損、空snapshot、changeCount競合、送信後の時間差上書きを構造上なくす。
`org.nspasteboard.TransientType`は履歴アプリ向けの未標準な慣習なので、対象アプリで文字列pasteと
履歴除外を実測できた場合だけbest-effortで付与し、保証にはしない。

名前付きpasteboardは他アプリの⌘C／⌘Vと接続しないため、隠れた受け渡しの代替には使わない。
テスト用の隔離pasteboardには使用できる。

### 7.2 Composeの当面の入力（プロジェクトA）

プロジェクトAでは、Compose送信の互換性を維持するためclipboard＋合成⌘Vを使う。ただし
`ClipboardBackup`による退避・復元は削除する。

1. ユーザーが送信を確定する。
2. 送信本文だけを標準クリップボードへ書く。
3. パネルを閉じて対象アプリを前面化する。
4. 合成⌘Vを1回送る。
5. clipboard内容を復元しない。

Accessibility権限が無い場合は、現行どおり本文をclipboardへ残して手動pasteを案内する。
送信履歴の成功境界は、合成⌘Vを送れたことと対象アプリ内で実際に反映されたことが同義ではないため、
プロジェクトBで再検討する。

### 7.3 Compose直接入力の研究（プロジェクトB）

AX直接入力は確定仕様にしない。リポジトリ外の固定bundle IDを持つ短命probeで実測し、次を全て
満たす対象だけ採用候補とする。

- 書き込み前の全体値を取得できる。
- 選択範囲またはカーソル位置を取得できる。
- 期待する変更後の全体値を決定できる。
- 書き込み後に同じ値をread-backできる。
- 既存内容、改行、日本語、絵文字、結合文字を壊さない。
- Undo、selection、IME compositionの挙動を実機で確認できる。
- APIの成功値だけで成功判定しない。

`AXValue`を汎用的なカーソル挿入に使わない。contenteditable等、read-back oracleを確立できない対象では
試験書き込み自体をしない。Unicode keyboard eventは改行と受信側フレームワークの解釈を保証できないため、
製品fallbackにしない。

probeの結果により、プロジェクトBは次のいずれかを選ぶ。

1. 実証済みのネイティブ対象だけAX直接入力し、それ以外はclipboard＋⌘V。
2. 信頼できる成功判定を作れなければ、全対象でclipboard＋⌘Vを維持する。
3. clipboard変更を許容しない製品判断なら、自動入力をやめて明示コピーへ変更する。

この決定はプロジェクトAの出荷を妨げない。

## 8. Gateway目標契約

`POST /api/ai/vision`、model route、response、fallback、Skill、Copilotは現行の1系統を維持する。
プロジェクトCでは、現行`focus_target` / `visual_selection_hint`を内部的なSelection Extensionへ
正規化し、任意の`selection`へ移行する。C1で必要性を確認できなかったsegment fallbackは追加しない。

```json
{
  "operation": "vision",
  "input": {
    "capture_id": "uuid",
    "image_base64": "...",
    "question": null,
    "turns": [],
    "candidates": [],
    "selection": {
      "kind": "text",
      "text": "選択全文の先頭…[省略: 4800 UTF-16 units]…選択全文の末尾",
      "acquisition_completeness": "complete",
      "acquisition": "ax_document_selection",
      "capture_visibility": "partial",
      "frames": [
        { "x": 120, "y": 240, "width": 360, "height": 42 }
      ],
      "structures": [
        {
          "source": "ax",
          "role": "AXHeading",
          "label": "件名",
          "relationship": "intersects_selection",
          "states": [],
          "actions": [],
          "coverage": "partial"
        }
      ],
      "wire_truncated": true,
      "original_utf16_units": 16800
    },
    "context": {}
  }
}
```

契約規則:

- `selection`は任意。無ければ通常Visionと同一で、requestからselectionを除いた結果も通常Visionと
  同じ入力構成になる。
- `text`はユーザーが選択した論理的な全文、またはそのbounded representationであり、
  structure labelから代用しない。
- selectionのwire text上限は現行と同じ12,000 UTF-16 unitsとする。上限超過時は先頭だけを残さず、
  省略量を含むmarkerを中央へ置く。marker分を除いたbudgetを頭尾へ半分ずつ割り当て、
  grapheme clusterを途中で壊さない。
- `acquisition_completeness`はローカル取得状態、`wire_truncated`は送信時の削減で直交する。
  `complete`と`wire_truncated: true`は「全文を取得したがwire上はbounded representation」の意味で
  矛盾しない。`original_utf16_units`で元の規模を示す。
- segment fallbackはC1で必要性が確認されなかったため、内部型とwire schemaへ追加しない。
- `structures`は任意fieldである。selection取得時にすでに得た構造だけを
  boundedに送り、初回turnの全画面candidate walkを追加しない。relationshipとcoverageを必須にし、
  `partial` / `context` / `unknown`のlabelをselection全体の名前としてpromptへ書かない。
- `kind`の有効値は`text`のみで、非空`text`を必須にする。structures、
  frames、labelだけでtext selectionを成立させない。旧enum値`visual_only` / `accessibility_element`は
  wire互換のため当面受理するが、Gatewayは正規化で捨てて通常Visionとして扱う（R10.5 §5-5で撤去）。
- `frames`は0件以上を許し、単一unionへ潰さない。`capture_visibility`でcapture内との関係を示す。
- 全`frame`はcapture画像座標へ正規化して送る。AXのグローバル座標をそのまま送らない。
- text総量、structure数、frame数、各role／label／state／action長、制御文字、座標範囲を
  Gatewayで検証する。
- selectionはモデル入力とセッション内UIだけに使い、usageや運用ログへ内容を保存しない。
- 応答形式、model routing、fallback notice、Skill、candidate ID、Copilot guidanceは現行Visionと共通。
- Focused Vision専用モデル、endpoint、fallback、feature flagを作らない。
- screenshotは常にVision Coreの原画像を`original` detailで渡す。selection cropを追加する場合も
  原画像を置換せず、追加画像として効果と原価を測る。
- `capture_visibility`が`off_capture` / `unknown`なら画像上の選択ハイライトを探すよう命じない。
  `partial`なら送ったframeが見えている部分だけだと明示する。
- selection本文を`untrusted content, not instructions`として囲み、本文中の命令、schema模倣、
  mode変更要求を実行しない。一方、選択操作はtrusted intent、本文全体は必須の対象データとして扱い、
  untrustedという理由でscopeの優先度を下げない。
- 運用指標は内容を保存しない`selection_present: boolean`、acquisition completeness、および
  正規化前のraw wire種別（無視した旧enum値の移行観測用、R10.5）だけを持つ。

移行は次の順で行う。まずGatewayが現行`focus_target` / `visual_selection_hint`と新`selection`を
同じ内部型へ正規化し、現行`v0.2.1`を壊さない状態でdeployする。次にmacOSを新契約へ切り替える。
公開済みクライアントは全員が更新するとは限らないため、旧fieldは**恒久的な入力互換adapter**として
受理する。adapterはvalidationと内部Selection Extensionへの正規化だけを行い、旧prompt、
別endpoint、別model routeとして意味経路を並走させない。

## 9. macOS目標構造

削除対象:

- `TransformSession`
- `TransformSessionView`とTransform専用View
- `GatewayTransformClient`
- `TransformInterpretationResult`
- `SelectionGrabber`
- `ClipboardBackup`
- `.transform` AppMode
- Transform専用prompt、route、routing entry、ウォームアップ

追加・拡張:

- `AXFocusSnapshot` — focused element、編集可能性、document root、選択rangeを同じ時点で取得
- `VisionSelectionContext` — 全文、supporting structures、複数frame、完全性を持つセッション内拡張
- `VisionSession` / `GatewayVisionClient` — 任意のSelection Extension
- `VisionSessionView` — 複数位置、全文、取得完全性を示す対象カードとハイライト
- `PasteDeployer` — プロジェクトAでは退避・復元をせず、明示送信時だけclipboard＋⌘V

`Deployer` protocolはテスト境界として維持できるが、「deploy＝clipboardへコピー」という
現行コメントは、明示送信と明示コピーの違いが分かる記述へ更新する。プロジェクトBで直接入力を
採用する場合だけ、実証済みのAX入力serviceを追加する。

## 10. 失敗時のUX

- 選択取得失敗: エラーを出さず通常VisionまたはComposeへ退化する。
- screen recording拒否: Focused Visionは画像なしの旧Transformへ戻さない。
  Visionを利用するため画面収録が必要だと説明し、許可導線を出す。
- Accessibility拒否: 選択検出を実行せず、通常Visionへ退化する。Compose送信本文はclipboardへ残し、
  手動pasteを案内する。
- 合成⌘Vを送れない: 本文をclipboardへ保持し、手動pasteを案内する。
- コピー成功: inlineで短く通知し、modal alertを出さない。
- モデル失敗: 現行Visionの共通fallback notice／共通エラーを使う。

失敗を理由に、ユーザーに知らせず別の入力欄へ送る、過去のclipboard内容を時間差で復元する、
送信履歴へ未確認の成功を記録することは禁止する。

## 11. データ・プライバシー

- Focused Visionは画面画像を本番Gatewayへ送る。対象テキストだけのTransformより送信範囲が広がるため、
  UIで「画面画像」と「選択対象」を参照元として明示する。
- text-onlyだったTransformより画像token、レイテンシ、原価が増える。これは「選択対象を画面全体との
  関係で説明する」ための意識的な交換である。原画像を省略・低detail画像で置換しない。
  実測後にselection cropを原画像へ追加する最適化は検討できるが、Vision Coreを失わせない。
- 選択全文も入力tokenと原価を増やす。wire上限、頭尾保持、省略markerを固定し、
  長文選択が無制限にpromptを膨らませない。usageへはtoken数だけを既存どおり記録し、選択内容、
  元文字数、segmentごとの長さを保存しない。
- 既存Visionと同じく画像と会話を永続化しない。一時画像は正常終了時、残骸は次回起動時に削除する。
- 選択テキスト、role、label、frame、画像、質問、回答をusageへ保存しない。
- 認証情報、銀行口座、本人確認書類等が写る画面では使わないという既存注意を維持する。
- AXから取得した選択内容を診断ログへ出さない。
- 画面収録許可はFocused Vision開始前に確認する。許可なしにcaptureを試行し続けない。

## 12. アクセシビリティとキーボード

- 既存の右Shift 2回、Enter、Escを維持する。
- 対象カード、ハイライト、質問欄、コピー、Copilot開始へVoiceOverラベルを付ける。
- VoiceOver順序は対象 → 初期解説 → 継続質問 → 操作の順にする。
- 対象の有無と取得失敗を色だけで表現しない。
- Full Keyboard Accessで全操作へ到達できる。
- ハイライトはIncrease ContrastとReduce Transparencyに対応する。
- animationはReduce Motion時に無効化または単純なopacity変化へ置換する。

## 13. 実装順序

本番ツリーに新旧方式を常設しない。プロジェクトAは安全化とFocused Visionを完成させ、
プロジェクトBはAと分離したCompose入力のprobe・製品判断として扱う。A0〜A7は`v0.2.1`を
作った時点の履歴であり、最初の非空祖先／単一focus targetに関する記述はプロジェクトCで置換する。
選択理解の現行計画はC0〜C6を正とする。

### A0 — 設計と復帰点（本コミット）

- 復帰タグ、開始commit、作業branchを§0へ記録する。
- レビューで撤回されたAXValue汎用挿入、Unicode fallback、clipboard完全不使用の完了条件を削除する。
- A／Bのマイルストーン、検証、commit境界を確定する。

完了条件: ドキュメントだけが変更され、`git diff --check`が通る。

### A1 — AX focus snapshot

- focused element、祖先selected text、role、label、frame、編集可能性を1つのsnapshotで取得する。
- `AXEnhancedUserInterface`と`AXManualAccessibility`を設定する。
- captureと並行するbounded retry、secure field除外、AX timeout、失効要素を扱う。
- 右Shift起動の判定を純粋関数としてテストする。
- この段階では本番の起動経路を切り替えない。

コミット境界: 新しいsnapshot層とunit testだけ。現行Transform／SelectionGrabberは維持。

完了（2026-07-30）: `AXFocusSnapshotService`がfocused elementと最も近い祖先の非空選択を
同じ値snapshotへ収める。Vision captureと同じ両AX属性、短いmessaging timeout、
成長中だけのbounded retryを使い、AX要素参照をtask外へ残さない。secure fieldは内容・label・frameを
読まず通常Visionへ退化し、timeoutと失効要素も値statusへ閉じ込める。純粋な起動判定とretry境界を
unit testで固定した。この段階ではSessionCoordinatorへ接続せず、現行本番経路は不変。

### A2 — Vision focus target

- focus targetをVision request、Gateway validation、prompt、Sessionへ通す。
- focus targetが無い通常Visionのrequest／responseを変えない。
- AX対象が無い時の視覚的選択ヒントをpromptへ追加する。
- focus targetをusageとログへ保存しない。

コミット境界: APIの後方互換な追加とテスト。まだUIと起動経路は切り替えない。

完了（2026-07-30）: `VisionFocusTarget`を`VisionSession`内の任意データとして追加し、
`GatewayVisionClient`から`POST /api/ai/vision`、Gateway validation、Vision promptまで通した。
AXグローバルframeは送信時にcapture左上原点のピクセル座標へ変換し、capture外を切り詰める。
text上限、role／label上限、禁止制御文字、kind／sourceの組み合わせ、frame範囲を検証する。
対象未確定時の`visual_selection_hint`は画像からbest-effortで選択を探し、見つからなければ通常Visionへ
退化する。focus targetとhintはusage／運用ログへ保存せず、Copilotの新captureへ古いframeを渡さない。
未指定時はrequest fieldもprompt追加も無く、現行通常Visionと同一。UIと起動経路はまだ不変。

### A3 — Focused Vision UI

- 既存Visionパネルへ対象カードとハイライトを追加する。
- 通常Visionと同じ会話、Skill、fallback notice、Copilot経路で初期解説を返す。
- VoiceOver、Full Keyboard Access、Increase Contrast、Reduce Motionを確認する。

コミット境界: focus targetを注入したVisionを開けば完成体験になるが、Transformはまだ本番入口。

完了（2026-07-30）: 既存`VisionSessionView`へfocus targetがある時だけ対象カードを追加した。
カードは選択テキスト、role由来の中立名、AX label、取得元、capture上の位置有無を示し、長文は
4行へ折りたたんだまま全文をスクロール表示できる。AXグローバルframeは同じcapture内の正規化座標へ
投影し、system accent色の枠と「選択対象」ラベルを併用する。capture位置が不明または範囲外なら
古い／推測位置を描かず、その状態を文字とアイコンで示す。通常Visionと同じ会話、Skill、
fallback notice、Copilot経路を維持し、Copilotが新captureを得た後は従来どおり新しい案内位置を優先する。
VoiceOverでは対象、解説、継続入力、操作の順序を指定し、全文表示はkeyboard操作可能。
Increase Contrastでは枠を太くし、Reduce Transparencyでは不透明背景、Reduce Motionでは
自動zoomと会話scrollのanimationを止める。右ShiftとTransformの本番入口はまだ不変。

### A4 — 起動経路切替と合成⌘C撤去

- 右Shift起動を`AXFocusSnapshot`判定へ一括置換する。
- 選択あり→Focused Vision、選択なし＋編集可能→Compose、それ以外→通常Visionとする。
- `SelectionGrabber`と合成⌘Cを同じ変更で削除する。
- 選択取得失敗時にclipboardへfallbackしない。
- 0.12秒固定待機が起動経路から消えたことを計測する。

コミット境界: 新入口への切替と旧読取経路の削除を同時に行う。ここから起動時clipboard不変。

完了（2026-07-30）: `SessionCoordinator`の右Shift idle起動を、単一の
`AXFocusSnapshot`による純粋判定へ切り替えた。snapshot task、full-screen capture、
Vision identity取得を呼び出し元アプリが前面の間に開始し、AXのbounded retryをcapture待ちへ重ねる。
選択テキストまたは意味のある選択要素は`VisionFocusTarget`としてFocused Visionへ渡し、
選択なし＋編集可能はCompose、それ以外は通常Visionへ進む。AXで対象を得られない非secure画面だけ
`visual_selection_hint`を渡し、Accessibility拒否とsecure fieldでは推測しない。Composeへ進む時は
並行取得済みcaptureを先読み画像へ所有権移譲し、別captureと別AX walkを増やさない。
`SelectionGrabber`を削除したため、起動経路には合成⌘C、clipboard読取・復元、0.12秒固定待機が
存在しない。A4ではコミット境界を起動切替に限定したため旧Transform実装が未参照で残ったが、
実行時互換やrollback用途ではない。A5でGit履歴以外に残さず削除する。

### A5 — Transform撤去

- `.transform`状態、Session、View、client、prompt、route、routing entry、ウォームアップを削除する。
- `/api/ai/transform`を削除し、旧クライアント用の互換routeを残さない。
- 現行Transformの利用意図がFocused Visionで満たされることを実機確認する。
- 製品surfaceの正本をCompose / Vision / Copilotへ更新する。

コミット境界: Focused Visionが旧Transformを完全に置換し、二重routeを残さない。

完了（2026-07-30）: macOSの`.transform`状態、Session、View、model、provider/client、
panel分岐、ウォームアップを削除した。Gatewayの`/api/ai/transform`、transform engine、
専用prompt、model routing、entitlement featureも削除し、`/api/ai/review`はComposeだけを
受理する。製品surfaceとAPI正本をCompose / Vision / Copilotへ更新した。旧実装はrollback用にも
残さず、必要な復帰は開始tagまたはGit履歴から行う。Focused Visionの実機確認結果は
[manual-golden-paths.md](manual-golden-paths.md)に記録した。

### A6 — clipboard復元撤去

- `ClipboardBackup`を削除する。
- `PasteDeployer`は明示送信時だけ本文を書き、合成⌘V後に復元しない。
- Accessibility拒否時は本文をclipboardへ残して手動pasteを案内する。
- TransientTypeは対象アプリでの実測に通った場合だけ付ける。
- クリップボード破壊の再現手順と、送信中にユーザーが⌘Cする競合試験を行う。

コミット境界: 退避・復元が本番ツリーから0件になり、今回の破壊原因が構造上消える。

完了（2026-07-30）: `ClipboardBackup`と未使用の`ClipboardDeployer`を削除した。
`PasteDeployer`は明示送信時に本文だけを標準clipboardへ書き、対象アプリを前面化して合成⌘Vを
1回送る。送信後の遅延restoreは行わないため、その間にユーザーが行った新しいコピーを時間差で
上書きする処理は存在しない。Accessibility拒否または⌘V event生成失敗時は、本文がclipboardへ
コピー済みであることと対象欄で手動⌘Vすることをmodal alertで明示する。拒否時はAccessibility設定を
開く選択肢も出す。未標準の`org.nspasteboard.TransientType`は実機証明が無いため付与していない。
リッチテキスト、画像、ファイル、複数item、送信直後のユーザー⌘Cとの競合を含む継続的な回帰項目は
[manual-golden-paths.md](manual-golden-paths.md)へ固定した。

### A7 — 統合検証と完了記録

- macOS unit test、署名なしDebug build、Web lint／TypeScript／production buildを通す。
- §14の実機検証を行う。
- README、API契約、golden paths、マスタープランを完了状態へ更新する。
- 変更全体を開始タグと比較し、無関係な実験物が無いことを確認する。

コミット境界: プロジェクトAの完了記録。main統合判断が可能な状態。

自動検証完了（2026-07-30）: XcodeGen生成、macOS署名なしDebug build、macOS unit test
28件、Web lint、TypeScript、production buildがすべて成功した。production buildのAI routeは
`review`、`suggest`、`transcribe`、`vision`の4つだけである。構造検査では本番ツリーの
`TransformSession`、`/api/ai/transform`、`SelectionGrabber`、`ClipboardBackup`、合成⌘C、
遅延clipboard restoreが0件で、clipboard writeと合成⌘Vは`PasteDeployer`の明示送信に限定された。
開始tag `pre-focused-vision-r9-20260730`からの追加ファイルはFocused Visionのmodel／AX取得層と
対応unit testの4件だけで、恒久的な実験物や無関係な追加物は無い。

完了記録（2026-07-30）: Developer ID署名したUniversal binaryのappとDMGがApple notarizationで
Acceptedとなり、staple、Gatekeeper評価に成功した。署名付きアプリの機能確認も問題なしと
ユーザーから報告された。DMGのSHA-256は
`637cd6cc029452db349f87e0a1cae4e6ecf214a3d458ba9ce0ad87ea6344cd69`。R9をmain
`6bc471a`へ統合してVercel productionへdeployし、現行4 AI routeのJSON応答と旧`transform`の
404を確認した。検証した同一DMGを不変URLとversion aliasへpublishし、公開URLへpromoteした。
公開URLから再取得したDMGでも署名、staple、Gatekeeper、`0.2.1` build `5`、Universal binary、
SHA-256一致を再確認した。これにより§15の受け入れ条件を満たし、プロジェクトAを完了とする。

残タスクはR9プロジェクトAにはない。B0/B1はComposeのclipboard非依存化を検討する独立した
将来プロジェクトであり、`v0.2.1`の完了条件でもrollback理由でもない。

### B0 — AX入力probe（Aと独立）

- リポジトリ外に固定bundle IDの短命.appを作る。
- TextEdit、ローカルHTML、Chrome、Slack、Safariの順に、read／write／read-backを検証する。
- Undo、selection、複数行、日本語、絵文字、IME compositionを記録する。
- Unicode eventは製品実装ではなく、制約確認だけ行う。
- probe本体は削除し、再現手順、OS／アプリversion、結果表だけを本書へ残す。

### B1 — 入力方式の製品判断

B0の結果から§7.3の3案のどれかを選ぶ。採用方式、対象範囲、成功判定、失敗UX、履歴境界を
仕様化してから、別の短命branchで実装する。Bの失敗や不採用はAをrollbackする理由にしない。

### C0 — Selection Extension設計と復帰点（本コミット）

- `Focused Vision = Vision Core + Selection Extension`を不変条件として正本へ固定する。
- 現行の最初の非空祖先で停止する探索、単一focus target、selection専用prompt置換を
  既知の修正対象として記録する。
- 復帰tag、開始commit、作業branch、C1〜C6のcommit境界を確定する。
- 現行APIと次期契約を混同せず、旧クライアントとの移行順を決める。

コミット境界: ドキュメントと作業branch情報だけ。製品挙動は変えない。

補正（2026-07-31）: 外部レビューとコード再照合により、外側document selectionを主対策、
segmentを実証後fallbackへ変更した。mode resolver、初回候補の性能境界、wire切り詰め、turn減衰、
capture外、prompt injection、secure再判定、恒久legacy adapterをC1前の要件として追加した。

### C1 — 公開AX能力probe

- リポジトリ外のread-only短命probeで、実際に公開されるattributeとrangeの対応を計測する。
- Chrome / Safari上のGmail、Electron版Slack、TextEdit、Apple Mailを対象にする。
- 単一node、複数node、逆方向drag、画面外を含む選択、編集可能／read-onlyを試す。
- `AXSelectedTextRanges`、`AXSelectedTextRange`、`AXSelectedText`、
  `AXStringForRange`、`AXBoundsForRange`とdocument rootの関係を記録する。
- 内側で止める現行結果と、document候補を全て調べて候補自身の整合性を検証した結果を
  同じ選択で比較する。
- WebKit等が列挙する`AXSelectedTextMarkerRange`、`AXStringForTextMarkerRange`等のtext marker系
  attributeも名前、値型、取得結果をread-onlyで観測する。ただし「観測できた」と
  「公開・文書化され製品が依存できる」を結果表で分け、未文書属性へ製品依存しない。
- private API、合成⌘C、ページ内JavaScriptは使わない。probe本体は完了後に削除する。

#### C1実測結果（2026-07-31）

macOS 26.5（25F71）で、リポジトリ外の短命Swift probeをAccessibility許可済みの実行hostから使った。
probeは選択本文、URL、title、labelを出力せず、文字数、改行数、SHA-256、range、frame、
列挙attribute名だけを記録する。Chromium／Electronでは本番と同じ
`AXManualAccessibility`／`AXEnhancedUserInterface`だけを設定した。合成⌘C、clipboard、
JavaScript、private APIは使っていない。

| 対象 | 条件 | 公開AXの結果 | 未文書attributeの観測 | 設計への意味 |
| --- | --- | --- | --- | --- |
| TextEdit 1.20 (415) | 編集可能、既知文字列20 UTF-16 units | focused `AXTextArea`の`AXSelectedText`、単一range、複数ranges、`AXStringForRange`が同じ値。boundsも有効 | 不要 | 同一要素内の公開range経路を`complete`にできる |
| Chrome 151.0.7922.72 | local read-only HTML、複数DOM、順方向／逆方向drag | `AXWebArea`が両方向とも選択全文106 unitsを返し、`AXSelectedText`と`AXStringForRange`が一致 | marker textも同値 | document candidateをfocusとは独立に探索すれば単一selectionで取得可能。公開boundsは0サイズでframe根拠には使えない |
| Chrome 151.0.7922.72上のGmail | 実メール、複数DOM選択、同一状態を2 pass | focused `AXHeading`は空だが、2階層上の`AXGroup`からdocument `AXWebArea`まで同じdirect `AXSelectedText` 757 unitsを安定して返した。rangeは非collapsedで同じ長さだが、`AXStringForRange`は別hash | marker textはdirect textと同値 | direct textの候補間／pass間consensusを主証拠にする。range string完全一致を必須にすると全文を誤って棄却する。segmentsは不要 |
| Safari 26.5 (21624.2.5.11.4) | 同じlocal HTML、複数DOM drag | 本文`AXWebArea`の公開`AXSelectedText*`は値を返さない。focusがアドレス欄に残る場合もある | 列挙されるmarker経路では129 unitsを観測 | focused ancestorだけではアドレス欄を誤採用し得る。未文書markerへ依存せず、本文は通常Visionとする（R10.5改訂） |
| VS Code 1.131.0 | Electron、編集可能、AX tree準備後 | 内側`AXTextArea`では`AXSelectedText`と`AXStringForRange`が一致。複数の外側ancestorでは同じ長さのrangeでも`AXStringForRange`が別値 | marker textは直接選択値と一致 | rangeは要素ローカル。最外側を無条件採用せず、候補自身でtext／range整合性を検証する |

Appleの公開契約では、[`AXSelectedText`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)、
[`AXSelectedTextRange`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute)、
[`AXSelectedTextRanges`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangesattribute)
は編集可能なtext element向けで、
[`AXStringForRange`](https://developer.apple.com/documentation/applicationservices/kaxstringforrangeparameterizedattribute)と
[`AXBoundsForRange`](https://developer.apple.com/documentation/applicationservices/kaxboundsforrangeparameterizedattribute)は
渡したrangeに対応する文字列と可視boundsを返す。実測どおり、ブラウザのread-only documentで
同じ属性が常に使える契約ではない。marker系は実際に列挙・取得できても公開契約とは分け、
製品依存しない。

C1結論:

- 「focused elementに近い最初の非空値」は廃止する。
- 「常に最外側」へ単純に反転もしない。focused window／applicationからdocument候補を独立に集め、
  direct selected textの候補間／pass間consensus、非collapsed range、coverage、安定性を検証して
  採用する。range string一致は補強証拠に留める。
- segment fallbackを採用しない。Chromeの既知複数DOM選択は単一document
  selectionで成立し、Safariは公開fragment集約へ進まず通常Visionとする（R10.5改訂）。
- Safari上のGmail、Slack、Apple Mailの製品固有画面は、既知内容を安全に用意するC6の手動golden
  pathで確認する。C1のアーキテクチャ判断はcontrolled WebKit／Chromium／AppKit／Electronと
  Chrome Gmail実測で確定し、製品固有画面のためにresolver実装を止めない。

#### Chrome Gmailの製品経路診断

同じ複数DOM選択で現行Focused Visionを起動すると、「件名は……です。本文も広範囲に選択されています」
という結果になり、選択本文そのものを説明しなかった。直前のprobeでは全文757 UTF-16 unitsを
取得できていたため、これはAX文字列取得だけの失敗ではない。コード上の因果は次のとおりである。

1. `AXFocusSnapshotService.captureAttempt`は最初の非空`AXSelectedText`で祖先walkを終了する。
2. その同じAX要素のrole、label、単一frameを`AXFocusSnapshot`へ格納する。Gmailでは選択全文を返す
   要素が局所的な`AXGroup`でもよく、そのlabelが件名等を表しても、選択全体へ適用できる根拠はない。
3. `VisionFocusTarget.from`は全文とそのrole／label／frameを単一のselection-wide targetへ潰し、
   `wirePayload`も区別せず送る。
4. GatewayはそのJSONを`Focus target reported by the client`として渡し、初回taskを
   `Explain the supplied focus target first`へ置換する。全文と局所labelのprovenance／coverageを
   モデルが区別できず、短く明瞭な件名labelを対象の代表値として説明し得る。
5. `VisionFocusTargetCard`もlabelを選択本文より前へ表示し、同じ誤った階層をUIで強化する。

必要変更:

- `VisionSelectionContext.text`をユーザーが明示した論理scopeとして独立保持する。
- role、label、relation、action、frameは重要な構造情報のまま保持するが、selection-wide metadataへ
  昇格させない。取得元要素とcoverageを持つselection-related structureとして本文へ加算する。
- labelが論理selection全体を表すと公開契約から確認できない限り、本文の名前・要約・置換として
  promptへ提示しない。
- promptは「選択全文を最初から最後まで対象として理解し、画像と構造で意味を補う」と明示する。
  通常Visionの画像・証拠・安全規則をselection専用taskで置換しない。
- UIは選択全文を先に示し、構造情報は対象の補助情報として関連付ける。局所labelを見出しにしない。
- 長い複数DOM本文と短い件名labelを同時に与え、回答scopeが件名へ縮約されないrequest／prompt testを
  C3へ追加する。

判定ゲート:

- document selectionが全文を返す製品では、検証済みdocument candidateの単一selectionを主経路とする。
- 公開断片の集約がdocument selectionより情報量を増やす結果は得られなかったため、
  segment fallbackを内部型とwireへ追加しない。
- WebKitで公開・文書化された経路から全文を取得できなければ通常Visionとし、観測した未文書属性へ
  依存しない（R10.5改訂。当初の「`visualOnly`を受け入れ可能な製品結果として記録」は、判定主体の
  無い状態を仕様が正当化した箇所として撤回）。

コミット境界: OS／アプリversion、再現手順、結果表、判定ゲートの結論だけを本書へ追記し、
製品コードは変えない。

### C2 — Selection Resolverとデータモデル

- `VisionSelectionContext`、複数frame、acquisition completeness、capture visibilityを追加する。
- selection本文と独立した`SelectionStructure`を追加し、role／label／relation／state／action／frameと
  coverageを保持する。局所構造をselection-wide metadataへ昇格させない。
- 最初の非空祖先では止めずdocument候補を集め、C1で実証したdirect textの候補間／pass間consensus、
  非collapsed range、coverage、安定性を満たすdocument selectionを優先する。
- 安定判定とbounded retryを純粋関数とunit testで固定する。
- secure判定をfocused ancestor、document root、text containerの全経路で
  値・label・frame読取より前に適用する。
- 未使用の新`region` variantは作らず、現行`VisionFocusTarget.region`を製品modelから削除する。
- この段階では右Shiftの本番入口とGateway requestを切り替えない。

コミット境界: resolver、値model、unit testだけ。現行`VisionFocusTarget`経路はまだ稼働する。

完了（2026-07-31）: `VisionSelectionContext`、`VisionSelectionStructure`、純粋
`VisionSelectionResolver`を現行`VisionFocusTarget`と並存する内部型として追加した。document全文、
native consensus、短いlabel不変、range不一致、visualOnly、secure拒否、複数frameを含む8件の
resolver testを追加し、macOS全36 unit testが成功した。未使用のlegacy `region` variantも削除した。
右Shift入口、Gateway request、UIは変更していない。

### C3 — Gateway契約とprompt加算

- §8の`selection`を後方互換に追加し、現行fieldと同じ内部型へ正規化する。
- 共通のVision Core evidence／安全規則、単一request intent resolver、任意Selection Extensionの
  3層へprompt builderを分ける。mode命令はresolverが1つだけ出し、observation／answerを連結しない。
- selectionの有無でimage、candidates、identity、Skill、turns、model routeが減らないことを
  request snapshot／prompt testで固定する。
- 長い複数DOM本文と短い局所labelを同時に入力し、labelが回答scopeやUI見出しを置換しないことを
  request snapshot／prompt testで固定する。
- 初回turnの通常AX candidatesは通常／Focusedとも現行どおり空とし、追加walkを行わない。
  Focusedにはresolverが選択取得時にすでに得た構造だけを加える。
- 12,000 UTF-16 units内の頭尾保持、省略marker、`acquisition_completeness`と
  `wire_truncated`の直交、
  capture外規則をvalidation／encoding testで固定する。
- legacy fieldは恒久入力adapterから同じ内部型へ正規化し、旧promptを残さない。
- selectionをuntrusted dataとして囲み、本文中の命令でmode、schema、安全規則が変わらないことを
  adversarial prompt testで固定する。
- 選択内容、segment、frameをusage／運用ログへ保存しない。

コミット境界: 後方互換なGatewayとmacOS client encoding、validation、testだけ。本番入口は未切替。

完了（2026-07-31）: 同じ`POST /api/ai/vision`へ任意`selection`を追加し、公開済み
`focus_target` / `visual_selection_hint`を恒久adapterから同じ`VisionSelection`へ正規化した。
promptは単一intent、user-selected text、supporting screen evidence、supporting selection structureの
独立ブロックへ分け、画像、通常candidate、identity、Skill、turns、model route、responseを共通のまま
維持した。macOS clientには12,000 UTF-16 units内の頭尾保持、複数frame／structure encodingを追加した。
Gatewayのadapter／validation／prompt 8件、macOS全39件、TypeScript型検査、対象lintが成功した。
右Shiftの本番入口はまだ現行`VisionFocusTarget`であり、C4でresolver結果へ切り替える。

### C4 — 本番入口のSelection Extension化

- `SessionCoordinator`からresolver結果を同じ`VisionSession(selection:)`へ渡す。
- `.focusedVision`相当の意味分岐、selection専用task、単一fragmentへの変換を削除する。
- AX textが無い時はselectionなしの同じ通常Visionとする（R10.5改訂。当初の`visualOnly` extensionは撤回）。
- 追加質問ではlatest questionをscope決定で優先し、Copilotの新captureには古いselection payloadを
  渡さず、selectionから確定したgoalだけを引き継ぐ。
- 通常Vision、継続質問、Copilot、fallbackの既存経路を維持する。

コミット境界: 新しい入口へ切り替えるのと同時に、置換された旧意味分岐を削除する。

完了（2026-08-01）: 右Shift起動のAX snapshotがdocumentまでのdirect selected text候補を収集し、
resolverで確定した選択全文、同時に得た部分候補の構造、複数frameを`VisionSession(selection:)`へ渡す
本番経路へ切り替えた。短い部分候補は`intersectsSelection`／`partial`として残るが、選択全文のscopeを
置換しない。captureとの照合後にvisibilityを確定し、画像だけで選択を探す場合も`visualOnly` extensionを
同じVision Coreへ渡す。macOSの単一`VisionFocusTarget`、旧field encoding、selection専用task、単一対象
カードは削除した。通常Visionの画像、通常candidate policy、identity、Skill、会話、model route、responseは
変更せず、追加質問ではlatest questionを優先し、Copilotの新captureへ旧selectionを渡さない。複数frameと
全文の正しいパネル表示はC5の境界に残す。Web画面では短い内側fragmentだけでretryを終了せず、既存2秒枠内で
document selectionを待つ。macOS unit test 35件が成功した。

### C5 — 複数範囲UIと診断表示

- capture上の全visible frameと全文を同じVisionパネルへ表示し、単一role／位置を偽装しない。
- カード表面へ取得状態を常時表示しない。`partial`等は開発情報に置く（R10.5改訂）。
- 開発情報にはselection acquisition、segment数、frame数、acquisition completeness、
  capture visibility、wire truncationを内容なしで追加する。
- VoiceOver、Full Keyboard Access、Increase Contrast、Reduce Transparency、Reduce Motionを確認する。

コミット境界: Selection ExtensionのUI表示とアクセシビリティtestだけ。

完了（2026-08-01）: 既存Visionパネルの右列へ「選択した内容」カードを追加し、選択全文を短いAX labelより
先に表示する。長文は5行から全文スクロールへ展開でき、UI要素選択だけはその要素自身のlabelを使う。
左の同一captureには交差する全frameをunionせず個別のアクセント色破線枠で描き、枠と「選択範囲（Nか所）」
labelを併用する。`visualOnly`だけは「選択範囲を画像から確認中」と表面へ示し、通常のcomplete／partialや
acquisitionは常時表示しない。位置不明とcapture外は事実として示す。既存の処理情報へ、selection内容を
含めずkind、acquisition、segment／structure／frame数、completeness、capture visibility、wire truncationを
追加した。操作はネイティブButtonでFull Keyboard Accessに乗り、VoiceOverの論理順序、Increase Contrast、
Reduce Transparency、Reduce Motionに応答する。全文優先、全visible frame、visualOnly、要素label、capture外の
presentationをunit testで固定し、macOS全39件が成功した。各支援設定を有効にした実機golden pathはC6で行う。

### C6 — 統合検証と完了記録

- §14の自動／実機検証を通し、複数node Gmailの全文理解をgolden pathへ固定する。
- 通常VisionとFocused Visionのrequest差分がselectionだけであることを検査する。
- 同一端末・同一対象の`v0.2.1`基準に対し、右ShiftからGateway dispatchまでの追加時間を
  warm時p50 +50ms以内、p95 +150ms以内とする。cold Chromiumでも既存2秒deadlineを延長しない。
- README、API契約、マスタープラン、golden pathsを実装済み状態へ同じcommitで更新する。
- 復帰tagからの差分に別endpoint、別prompt、長期flag、probe残骸が無いことを確認する。

コミット境界: Cの完了記録。main統合判断が可能な状態。

進行記録（2026-08-01）: ローカル自動検証と開始tag差分監査を実施した。通常Vision requestと
Selection Extension付きrequestの全fieldを比較し、`selection`を除けば画像、turns、candidates、
diagnostics、identityを含めて同一であることをmacOS testへ固定した。Gatewayでは単一intent、
全文scope、structure labelの非置換、structureなし全文、prompt injection、capture外、legacy adapterを
14件で固定した。監査で残っていた`.focusedVision`起動先を削除し、同じ`.vision`へ任意selectionを
加える構造へ一本化した。同時に文字を伴わない選択要素のextension欠落と、secure descendant確認前に
document textを読み得る順序を修正した。macOS 41件、Web lint／TypeScript／production build、
署名なしDebug buildが成功し、別endpoint、別model route、長期flag、短命probe、起動時clipboard／
合成⌘Cの再混入は無い。後方互換Gatewayは2026-08-01にmacOS候補版より先に`main`／本番へ配備した。
署名付き実機golden pathと、同一端末・同一対象でのwarm p50／p95比較は未実施であり、C6は未完了である。

ブロッカー記録（2026-08-01）: 実機テストで、何も選択していない画面にも選択カードと選択用promptが
常に付き、モデルが選択の不在報告から回答を始める不具合を確認した。C6をリリースブロッカーとして
未完了へ戻す。原因判定・修正計画・受け入れ条件は
[vision-selection-evidence-fix.md](vision-selection-evidence-fix.md)（R10.5）を正とし、
`visualOnly`／`accessibilityElement`の撤回、Gatewayの「受理して無視」ホットフィックス、
retry停止規則の再設計、不在検査の追加を含む。

R10.5実装記録（2026-08-01）: 正本修正のあとGatewayホットフィックスを`main`へ配備し（`349bb9c`、
production READY確認済み）、続けてクライアントから推測経路を削除した。`normalizeVisionSelection`が
唯一の成立判定になり、内部型は`kind`単一case・`text`必須へ収縮した。`AXSelected`はクライアントから
概念ごと消え、`kAXSelectedAttribute`の読取も無くなった。bounded retryは「選択の証拠がまだ現れ得る
積極的な兆候」（focus未取得／tree成長中／断片ありdocument未確定）でのみ継続し、web areaを見た
だけでは追加1passに留める。選択なしの安定した画面が2秒予算を使い切っていた挙動を、最頻の利用場面の
遅延として解消した。Gateway 17件、macOS 40件、Web lint／production build、署名なしDebug buildが
成功した。署名付き候補版での実機golden pathと性能比較は未実施であり、C6は引き続き未完了である。

## 14. 検証

### 自動検証

- 選択あり／空選択／編集可能／非編集／secure fieldの起動判定
- **不在検査**（R10.5）: 選択なし・focus要素なし・timeout・`AXSelected`現在項目の各snapshotで
  selectionがnilになり、カード、選択用prompt、selection wireが一切現れないこと
- `AXSelected`な編集可能フィールドがComposeへ起動すること（R10.5の波及検証）
- 兆候ゼロの安定web画面でretryが早期停止し、断片候補あり・document未確定なら継続すること（R10.5）
- Gatewayが旧`visual_selection_hint`／旧`focus_target.accessibility_element`／新wire
  `visual_only`・`accessibility_element`を**200で受理して無視**し、通常Visionのpromptになり、
  raw wire種別がusageへ記録されること（R10.5）
- document root／text container／AXWebAreaの選択探索
- 内側に短い断片、documentに全文がある時にcoverageとdirect text consensusから全文を選ぶこと
- coldなChromium treeのbounded retryと期限終了
- 単一range、逆方向選択、画面外を含むselection、複数frameの保持
- textだけ、複数frameだけ、両方、どちらも無いSelection Extension
- 12,000 UTF-16 units内の頭尾均等保持、省略marker、元UTF-16長、grapheme境界、制御文字、座標変換
- acquisition completenessとwire truncation、capture visibilityの全組み合わせ
- Focused Vision requestからselectionを除くと通常Vision requestと一致すること
- selectionがimage、通常candidate policy、identity、Skill、turnsを減らさないこと
- 初回の通常AX candidatesが通常／Focusedとも空で、Focused用の追加walkが無いこと
- request intent resolverがguidance／質問／初回selection／初回observationからmode命令を1つだけ出すこと
- 同じ長いselection textに異なる短いstructure labelを付けても、初回taskの対象がselection全文から
  変わらないmetamorphic prompt test
- structuresを全て除いてもselection全文を説明するtaskが残り、selection textを除いた時だけ
  通常initial observationへ戻ること
- 初回selection taskが「選択状態を報告」ではなく「選択本文の内容を要約・説明」する契約であること
- selection本文中のprompt injectionがmode、schema、安全規則を変更しないこと
- secure descendantをdocument root／segment経路から取得・送信しないこと
- capture外frameを画像上の可視selectionとしてpromptへ記述しないこと
- legacy inputが恒久adapterから新inputと同じ内部型・同じpromptへ合流すること
- 起動・選択取得からpasteboard APIと合成⌘Cへ到達しない構造検査
- `ClipboardBackup`と遅延restoreが存在しない構造検査
- Compose送信時だけclipboard writeと合成⌘Vへ到達すること
- Web lint、TypeScript、production build、macOS unit test、署名なしDebug build

### 実機検証

最低対象:

- AppKit: TextEdit、Apple Mail
- WebKit: Safari上のGmail
- Chromium: Chrome上のGmail、Slack
- Electron: SlackまたはVS Code
- 選択なし、単一要素選択、複数ノード選択、編集欄内選択
- 順方向／逆方向drag、viewport内／画面外をまたぐ選択
- 複数displayにまたがる選択と、capture対象display外にだけある選択
- AX selected textを返す画面／返さない画面
- selection本文に命令文、JSON、mode名、prompt模倣が含まれる画面
- secure fieldを含むdocument rootと通常textの混在
- Accessibility拒否／画面収録拒否
- cold／warmなChromium AX tree
- 画像上の選択ハイライトだけを使うbest-effort経路

クリップボード回帰:

1. リッチテキスト、画像、ファイル、複数itemを標準クリップボードへ入れる。
2. 通常Vision、Focused Vision、Copilotを実行し、changeCountと全flavorが変化しないことを確認する。
3. Compose送信を実行し、送信本文がclipboardへ残り、時間差で古い内容へ戻らないことを確認する。
4. Compose送信の直後に別アプリで⌘Cし、その新しい内容が上書きされないことを確認する。
5. Universal I/O終了後も最新内容を貼り付けられることを確認する。
6. HTML／UTF-8／UTF-16／空string flavorを含む元の再現手順でclipboardが壊れないことを確認する。

### プロジェクトCの受け入れ条件

- **何も選択せずに呼び出した通常Visionに、選択カード、選択用プロンプト、選択の不在・不確実性への
  言及が一切現れない（R10.5最重要受け入れ条件）。**
- Focused VisionからSelection Extensionを除いた入力と実行経路が通常Visionと同一である。
- selection全文は明示された質問対象として保持され、先頭AX／DOM相当fragmentへ縮約されない。
- direct text consensusとcoverageを検証したdocument selectionを内側fragmentより優先し、
  segment fallbackを内部型・wire・promptへ持たない。
- screenshot、現行の通常AX candidate policy、identity、Skill、turnsはselection追加時にも維持される。
- 初回turnは通常／Focusedとも全画面AX候補を待たず、selection取得済み情報だけを追加する。
- AXのrole、label、relation、actionは第一級の構造情報としてselection理解へ加算される。
- screenshotは原画像を常に使用し、任意cropが原画像を置換しない。
- 同じSession、View、endpoint、model route、fallback、Copilotを使い、専用promptや長期flagが無い。
- mode命令は単一request intent resolverだけが生成し、矛盾するmode指示を同居させない。
- 初回応答も通常Visionと同じVision Coreデータ方針を使う。
- Chrome／Safari上のGmailで複数node選択の全文を扱い、公開AXで取得不能なら通常Visionとする（R10.5改訂）。
- Chrome Gmailの「件名＋本文」選択で、件名と選択状態だけを述べず、取得した本文全体の内容を
  主回答として要約・説明する。
- Electron版Slack、TextEdit、Apple Mailでも選択の取得または安全な退化を確認する。
- `partial`等の内部取得状態は開発情報に置き、カード表面へ取得状態を常時表示しない（R10.5改訂）。
- 上限超過時も先頭だけを送らず、12,000 UTF-16 units内で頭尾を均等に保持して省略を明示する。
- 追加質問はlatest questionをscopeとして優先し、新captureへ古いselection payloadを送らない。
- capture外のselectionを画像で確認できたと装わない。可視性の主張はframesとcapture矩形の
  交差計算という観測主体を持つ場合に限る（R10.5）。
- selection本文中の命令はuntrusted dataとして扱うが、選択操作と本文全体が回答scopeであることは
  trusted intentとして維持し、mode、schema、安全規則も本文中の命令では変わらない。
- 起動と選択取得はclipboardを変更せず、全取得経路でsecure fieldの内容を取得・送信・記録しない。
- 選択内容、segment、frame、画像、質問、回答をusageと診断ログへ保存しない。
- 現行`v0.2.1`の恒久入力adapterも同じ内部型へ合流し、別endpoint、別prompt、別model routeを作らない。
- warm時のGateway dispatch追加時間がp50 +50ms以内、p95 +150ms以内で、cold時の2秒deadlineを延長しない。
  計測には**選択なしブラウザ画面**（最頻の利用場面）と複数node Gmail選択の両方を含める（R10.5）。

## 15. プロジェクトAの受け入れ条件

（`v0.2.1`公開時の記録。`visualOnly`等の選択推測はR10.5で撤回済みで、現行仕様は§4.2と
[vision-selection-evidence-fix.md](vision-selection-evidence-fix.md)を正とする。）

以下を全て満たした時だけ完了とする。

- 製品surfaceの正本がCompose / Vision / Copilotの3つになっている。
- 選択対象がある時、同じVisionパネルで対象を優先した初期解説が返る。
- 同じsessionで追加質問とCopilot開始ができる。
- 選択が取れない画面では、clipboardへfallbackせず通常VisionまたはComposeが動く。
- `TransformSession`、`/api/ai/transform`、`SelectionGrabber`、`ClipboardBackup`、合成⌘C、
  clipboard restoreが本番ツリーに存在しない。
- 起動、選択取得、通常Vision、Focused Vision、Copilotが標準クリップボードを変更しない。
- Compose送信時だけ送信本文がclipboardへ残り、その後に過去内容を書き戻さない。
- Compose送信中にユーザーが行った新しいコピーを時間差で上書きしない。
- 通常Vision、Skill、fallback notice、Copilot、Composeレビューの既存品質が落ちていない。
- 入力本文、選択内容、画像、画面情報がusageや診断ログへ保存されない。
- 開始タグ`pre-focused-vision-r9-20260730`からの差分に、常設の実験経路や無関係な変更が無い。

## 16. 非目標

- Universal I/Oが他アプリを自律操作すること
- プロジェクトAだけでComposeをclipboard非依存にすること
- AX writeの成功をAPI戻り値だけで判定すること
- `AXValue`を汎用カーソル挿入に使うこと
- Unicode keyboard eventを製品fallbackにすること
- 公開AX能力をprobeせず推測で未文書属性へ依存すること
- 汎用DOM取得が存在するように装うこと。実DOMが必要なら明示的なブラウザ統合として別途設計する
- ページ内JavaScriptを無言の汎用fallbackにすること
- Focused Vision専用モデルや長期feature flagを作ること
- Transformの旧レイアウトをVision内へそのまま移植すること
- 選択対象や会話を永続化すること
- すべてのWeb editorへアプリ名ごとの特例を追加すること

## 17. 決定事項

- Transformは廃止し、Focused Visionへ統合する。
- Focused Visionは独立surfaceではなく、Vision Coreへ任意のSelection Extensionを加えたものである。
- selectionはユーザーが明示した回答scopeであり、AX／画面構造、screenshot、Skillはその意味を
  説明する重要な観測である。scopeを決める権限はselection操作と本文にあり、周辺観測は本文を
  別のlabelや要素へ置換・縮約・無視しない。
- 通常Visionの証拠・安全規則をselection専用taskへ置換せず、selectionを参照データとして追記する。
  mode命令は単一request intent resolverで一度だけ決め、矛盾するtaskを連結しない。
- 選択取得はAccessibility APIだけを使い、合成⌘Cへfallbackしない。
- 主取得は最初の非空祖先で止まらずdocument候補を全て調べ、direct textの候補間／pass間consensus、
  非collapsed range、coverage、安定性を満たすselectionを優先する。range string一致は補強証拠とし、
  segment集約はC1で必要性を実証した製品だけのfallbackとする。
- Chromium／Electronでは両AX属性、document root／text container探索、captureと並行するbounded retryを使う。
- AXで対象を取れない場合、画像上の選択をbest-effortで読み、失敗時は通常Visionへ退化する。
- Focused Visionは画面画像を使い、画面全体の文脈内で対象を説明する。
- 初回turnの全画面AX候補は現行どおり空とし、Focused用の追加walkを行わない。
- `partial`等は開発情報へ置き、ユーザー表面で取得状態を示すのは`visualOnly`だけとする。
- legacy focus fieldは恒久入力adapterで同じ内部Selection Extensionへ正規化する。
- 新Selection Extensionへ`region` variantを持ち込まず、region captureはVision Coreの画像範囲として扱う。
- 編集可能欄内でも、非collapsed選択があればFocused Visionを優先する。
- プロジェクトAではComposeのclipboard＋⌘Vを維持するが、退避・復元は全廃する。
- AX直接入力はプロジェクトBのprobe結果が出るまで未採用とする。
- Unicode keyboard eventは製品fallbackにしない。
- Focused Visionの画像利用によるコストと送信範囲の増加を意識的に受け入れ、実測後に最適化する。
- 現行本番API契約は[api-contract.md](api-contract.md)を正とし、本書はR9の履歴とR10の要件・
  実装計画を記録する。
