# Focused Vision 計画

最終更新: 2026-07-31 ／ ステータス: プロジェクトA完了・プロジェクトC設計確定／実装前

本書は、TransformをVisionへ統合し、Universal I/Oがユーザーに見えない場所で
システムクリップボードを退避・復元する構造を廃止するプロジェクトの仕様書である。
進捗は[マスタープラン R9](universal-io-master-plan.md)、現行実装のAPI契約は
[api-contract.md](api-contract.md)を正とする。独立Transform契約はA5で撤去済み。

2026-07-31に、`v0.2.1`の選択取得と初期理解が「最も近い単一AX要素」を事実上の対象とし、
通常Visionの初期入力へ情報を加えるのではなく別taskへ置き換えていたことを確認した。
プロジェクトCではFocused Visionを次の式どおりの**純粋な加算**へ改修する。

```text
Focused Vision = Vision Core + Selection Extension
Focused Vision - Selection Extension = 通常Vision
```

選択はユーザーが明示した対象範囲であり、スクリーンショット、AX／画面構造、Skillはその範囲を
共同で理解する第一級の観測である。選択だけで画面理解を置換せず、逆にAX要素や視覚的な目立ち方で
選択全文を先頭断片へ縮約しない。プロジェクトAの完了記録は当時の実装履歴として残すが、
§3〜§6の目標仕様と§18以降のプロジェクトCが今後の実装判断に優先する。

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
    ├─ ordered segments
    ├─ selection-related AX structure
    ├─ multiple frames
    └─ completeness / acquisition
```

通常VisionとFocused Visionをtaskの三項分岐で作り分けない。共通のVision taskを先に構築し、
selectionがある場合だけ同じuser inputへ追加指示と構造化データを追記する。VLM呼び出しは1回のままで、
通常Visionを別呼び出ししてからFocused Visionを実行する二段構成にはしない。

## 4. 起動と状態遷移

### 4.1 右Shift 2回

パネルを前面化する前に、呼び出し元アプリのAccessibility treeを読み始める。合成⌘Cは送らない。
選択取得、編集可能判定、画面captureは並行して進め、固定の2秒待機をユーザーへ課さない。

```text
右Shift 2回
  ├─ 選択を取得または視覚的に観測できた
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

合成⌘Cへfallbackしない。選択文字列を取れなくてもcapture上に選択ハイライトが観測可能なら、
`completeness: visualOnly`のSelection Extensionとして同じVision Coreへ加える。画像上でも
選択を根拠づけられず、編集可能なfocused elementならCompose、それ以外ならselectionなしのVisionへ進む。

Safari、Apple Mail、AX treeが冷えたChromium等では、公開・文書化されたAX属性から本文選択を
取得できない場合がある。この場合はcaptureに選択ハイライトが見えている可能性をVision promptへ
伝え、画像から**全ての連続した選択ハイライト**を1つの論理selectionとして読むbest-effort経路を使う。
最も目立つ件名や先頭断片だけを対象にしない。公開AX rangeで複数DOM相当の選択全文を取得できない製品は、
リポジトリ外probeで公開属性、実際に列挙されるattribute、OS／アプリversionを記録して採用可否を決める。
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
    let segments: [SelectionSegment]
    let frames: [CGRect]
    let completeness: Completeness
    let acquisition: Acquisition
}

struct SelectionSegment {
    let text: String?
    let role: String?
    let label: String?
    let frame: CGRect?
}
```

- `text`: ユーザーが選択した論理的な全文。先頭segmentの別名にしない
- `segments`: 複数AX／画面構造へ分かれた選択断片。文書順を保持する
- `frames`: 選択範囲を表す0個以上のグローバル矩形。単一unionへ潰さない
- `completeness`: `complete` / `partial` / `visualOnly`
- `acquisition`: 公開AX range、複数AX fragment、画像上の選択等の取得方法
- `role` / `label`: selection全体ではなくsegmentに属する構造情報

制約:

- テキストはGatewayの入力上限内へ切り詰める。途中省略をメタデータで明示する。
- password等のsecure fieldは対象にもCompose入力先にも含めない。
- AX値、アプリ名、ウインドウタイトル、矩形はusageへ保存しない。
- selectionと画像はVision session終了時に破棄する。
- AX要素参照そのものをGatewayへ送らない。送るのは必要な値だけ。

### 5.1 取得優先順位

1. focused window内のdocument rootとtext containerを特定する。focused elementの祖先だけに限定しない。
2. 公開されている`AXSelectedTextRanges`、`AXSelectedTextRange`、`AXSelectedText`と
   `AXStringForRange`／`AXBoundsForRange`を、対象が実際に対応する範囲で読む。
3. 1つのdocument rangeから全文が取れれば、それを`complete`なselection textとする。
4. document rangeが無く複数要素が選択断片を公開する場合は、文書順でsegmentを集約し、
   重複を除いて全文を構成する。近い要素、先頭要素、長い要素だけを採用しない。
5. retry品質は「選択が1文字あるか」ではなく、document root確認、range/text対応、segment coverage、
   pass間の安定で決める。最初の非空断片では終了しない。
6. textは取れたがcoverageを証明できなければ`partial`とし、完全な全文だとモデルにもUIにも断定しない。
7. AX textを取れず画像上に選択が見える場合は`visualOnly`とし、Visionが全ハイライトを読む。
8. テキスト選択は無いが意味のあるUI要素が明示選択されている場合は、従来どおりelement selectionを
   別種のSelection Extensionとして扱う。
9. いずれも無ければselectionなしの通常Visionとする。

画面上の任意領域をマウスで囲う既存のcapture操作は`region`として同じ型へ合流できるが、
テキスト選択、UI要素選択、user regionは同じoptional extensionのvariantとし、Vision Coreを分岐させない。

## 6. 画面体験

### 6.1 同じVisionパネルを使う

Focused Vision専用ウインドウやTransformパネルを作らない。既存Visionのレイアウト、質問欄、
Enter送信、Esc終了、Skill表示、fallback notice、Copilot開始を共有する。

### 6.2 対象の表示

selectionがある時だけ、左側のcapture上に取得できた全frameをハイライトし、selectionカードを添える。
`visualOnly`でもカード自体を消さず、「選択範囲を画像から確認中」と取得状態を明示する。

対象カードに表示するもの:

- 「選択した内容」またはUI要素／regionに基づく中立な名称
- 選択全文（長文は折りたたみ、全文はスクロール可能）
- `complete` / `partial` / `visualOnly`をユーザー向けに表した取得状態
- 取得元（公開AX range／複数AX断片／画像上の選択／画面上の要素）
- 複数segmentと複数位置を持つ場合も、単一roleや単一矩形へ偽装しない表示
- 位置が取得できなかった場合は、その事実

ブラウザ名やウインドウタイトルを対象名として代用しない。適用中のSkillは既存Visionと同じ場所に
表示する。ハイライトはシステムのアクセントカラーを基本とし、ライト／ダーク、
Increase Contrast、Reduce Transparencyに対応する。色だけで対象を伝えず、枠とラベルを併用する。

### 6.3 初期応答

通常VisionとFocused Visionは同じVision Core task、同じcapture、同じAX候補取得方針、同じidentity、
同じSkillを使う。Focused VisionはそこへSelection Extensionを追記し、画面全体を理解した上で
ユーザーが選択した範囲へ回答を集中する。内部理解の入力を選択だけへ狭めることと、回答の焦点を
選択へ合わせることを混同しない。

Gatewayは三項演算子等で通常Vision taskをselection専用taskへ置換しない。先に共通taskを組み立て、
selectionがある時だけ次を追記する。

- selection全文が明示された質問対象であり、先頭segmentや最も目立つ箇所だけへ縮約しない
- screenshotから見た目、配置、選択ハイライト、現在状態を読む
- AX／画面構造から各segmentの意味、関係、操作可能性を読む
- Skillから製品固有の意味を読む
- `partial` / `visualOnly`では取得できていない部分を完全な全文だと断定しない
- 情報が矛盾する時は一方を黙って捨てず、ユーザーに意味のある不確実性だけを示す

初回turnでも通常Visionの構成要素をselectionが置き換えてはならない。AX候補をVision Coreに含める
方針なら通常／Focusedの両方へ同じbounded policyで供給し、Focusedにはselection関連segmentを加算する。
画面に根拠が無い情報を対象文字列だけから断定しない。

### 6.4 継続

- 同じcapture、Selection Extension、turnsを保ったまま追加質問できる。
- 質問が対象外へ広がっても、Visionは画面全体を参照できる。
- 操作意図があれば既存の「案内を開始」からCopilotへ進む。
- Copilot開始後は目的を引き継ぐ。古いselectionの枠を新captureへ機械的に再利用しない。
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
正規化し、クライアントの複数segment対応に合わせて任意の`selection`へ移行する。

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
      "text": "複数の画面構造にまたがる選択全文",
      "completeness": "complete",
      "acquisition": "ax_document_range",
      "segments": [
        {
          "text": "選択断片",
          "role": "AXHeading",
          "label": "件名",
          "frames": [
            { "x": 120, "y": 240, "width": 360, "height": 42 }
          ]
        }
      ],
      "frames": [
        { "x": 120, "y": 240, "width": 360, "height": 42 }
      ],
      "truncated": false
    },
    "context": {}
  }
}
```

契約規則:

- `selection`は任意。無ければ通常Visionと同一で、requestからselectionを除いた結果も通常Visionと
  同じ入力構成になる。
- `text`はユーザーが選択した論理的な全文で、`segments[0].text`から代用しない。
- `segments`と`frames`は0件以上を許し、文書順を保持する。単一role、label、frameへ潰さない。
- 全`frame`はcapture画像座標へ正規化して送る。AXのグローバル座標をそのまま送らない。
- text総量、segment数、frame数、各role／label長、制御文字、座標範囲をGatewayで検証する。
- selectionはモデル入力とセッション内UIだけに使い、usageや運用ログへ内容を保存しない。
- 応答形式、model routing、fallback notice、Skill、candidate ID、Copilot guidanceは現行Visionと共通。
- Focused Vision専用モデル、endpoint、fallback、feature flagを作らない。
- screenshotは常にVision Coreの原画像を`original` detailで渡す。selection cropを追加する場合も
  原画像を置換せず、追加画像として効果と原価を測る。
- 必要なら内容を保存しない`selection_present: boolean`とcompletenessだけを運用指標として持つ。

移行は次の順で行う。まずGatewayが現行`focus_target` / `visual_selection_hint`と新`selection`を
同じ内部型へ正規化し、現行`v0.2.1`を壊さない状態でdeployする。次にmacOSを新契約へ切り替える。
旧fieldを除去できる最低クライアント版が確定するまでは互換adapterだけを残してよいが、旧prompt、
別endpoint、別model routeとして並走させない。削除時は別の検証済みcommitで行う。

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
- `VisionSelectionContext` — 全文、ordered segments、複数frame、完全性を持つセッション内拡張
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
作った時点の履歴であり、単一祖先／単一focus targetに関する記述はプロジェクトCで置換する。
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
- 現行の単一祖先探索、単一focus target、selection専用prompt置換を既知の修正対象として記録する。
- 復帰tag、開始commit、作業branch、C1〜C6のcommit境界を確定する。
- 現行APIと次期契約を混同せず、旧クライアントとの移行順を決める。

コミット境界: ドキュメントと作業branch情報だけ。製品挙動は変えない。

### C1 — 公開AX能力probe

- リポジトリ外のread-only短命probeで、実際に公開されるattributeとrangeの対応を計測する。
- Chrome / Safari上のGmail、Electron版Slack、TextEdit、Apple Mailを対象にする。
- 単一node、複数node、逆方向drag、画面外を含む選択、編集可能／read-onlyを試す。
- `AXSelectedTextRanges`、`AXSelectedTextRange`、`AXSelectedText`、
  `AXStringForRange`、`AXBoundsForRange`とdocument rootの関係を記録する。
- private API、合成⌘C、ページ内JavaScriptは使わない。probe本体は完了後に削除する。

コミット境界: OS／アプリversion、再現手順、結果表だけを本書へ追記し、製品コードは変えない。

### C2 — Selection Resolverとデータモデル

- `VisionSelectionContext`、ordered `SelectionSegment`、複数frame、completenessを追加する。
- focused ancestorだけでなくdocument root／text containerから範囲を解決する。
- 重複除去、文書順、全文組み立て、coverage、安定判定、bounded retryを純粋関数とunit testで固定する。
- 最初の非空断片では成功終了せず、secure fieldと取得不能は内容を漏らさず値状態へ閉じ込める。
- この段階では右Shiftの本番入口とGateway requestを切り替えない。

コミット境界: resolver、値model、unit testだけ。現行`VisionFocusTarget`経路はまだ稼働する。

### C3 — Gateway契約とprompt加算

- §8の`selection`を後方互換に追加し、現行fieldと同じ内部型へ正規化する。
- Vision Core promptを先に一度だけ組み立て、selection指示と構造化データを追記する。
- selectionの有無でimage、candidates、identity、Skill、turns、model routeが減らないことを
  request snapshot／prompt testで固定する。
- 初回turnにも通常Visionと同じbounded candidate policyを適用する。
- 選択内容、segment、frameをusage／運用ログへ保存しない。

コミット境界: 後方互換なGatewayとmacOS client encoding、validation、testだけ。本番入口は未切替。

### C4 — 本番入口のSelection Extension化

- `SessionCoordinator`からresolver結果を同じ`VisionSession(selection:)`へ渡す。
- `.focusedVision`相当の意味分岐、selection専用task、単一fragmentへの変換を削除する。
- AX textが無い時も`visualOnly` extensionとして同じVision Coreへ入り、別promptにしない。
- 通常Vision、継続質問、Copilot、fallbackの既存経路を維持する。

コミット境界: 新しい入口へ切り替えるのと同時に、置換された旧意味分岐を削除する。

### C5 — 複数範囲UIと診断表示

- capture上の全frameと、全文、複数segment、取得完全性を同じVisionパネルへ表示する。
- `partial` / `visualOnly`をユーザーへ分かる文言で示し、単一role／位置を偽装しない。
- 開発情報にはselection acquisition、segment数、frame数、completenessを内容なしで追加する。
- VoiceOver、Full Keyboard Access、Increase Contrast、Reduce Transparency、Reduce Motionを確認する。

コミット境界: Selection ExtensionのUI表示とアクセシビリティtestだけ。

### C6 — 統合検証と完了記録

- §14の自動／実機検証を通し、複数node Gmailの全文理解をgolden pathへ固定する。
- 通常VisionとFocused Visionのrequest差分がselectionだけであることを検査する。
- README、API契約、マスタープラン、golden pathsを実装済み状態へ同じcommitで更新する。
- 復帰tagからの差分に別endpoint、別prompt、長期flag、probe残骸が無いことを確認する。

コミット境界: Cの完了記録。main統合判断が可能な状態。

## 14. 検証

### 自動検証

- 選択あり／空選択／編集可能／非編集／secure fieldの起動判定
- document root／text container／AXWebAreaの選択探索
- coldなChromium treeのbounded retryと期限終了
- 単一range、複数segment、重複segment、逆方向選択、画面外を含む選択の全文構成
- textだけ、複数frameだけ、両方、どちらも無いSelection Extension
- selectionのrequest encoding、総量上限、件数上限、制御文字、座標変換
- Focused Vision requestからselectionを除くと通常Vision requestと一致すること
- selectionがimage、candidates、identity、Skill、turnsを減らさないこと
- selection有無で共通Vision Core promptが同一で、追加部分だけが変わること
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
- AX selected textを返す画面／返さない画面
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

- Focused VisionからSelection Extensionを除いた入力と実行経路が通常Visionと同一である。
- selection全文は明示された質問対象として保持され、先頭AX／DOM相当fragmentへ縮約されない。
- screenshot、通常のAX候補、identity、Skill、turnsはselection追加時にも全て使われる。
- AXのrole、label、relation、actionは第一級の構造情報としてselection理解へ加算される。
- screenshotは原画像を常に使用し、任意cropが原画像を置換しない。
- 同じSession、View、endpoint、model route、fallback、Copilotを使い、専用taskや長期flagが無い。
- 初回応答も通常Visionと同じVision Coreデータ方針を使う。
- Chrome／Safari上のGmailで複数node選択の全文を扱い、取得不能時は`partial` / `visualOnly`を明示する。
- Electron版Slack、TextEdit、Apple Mailでも選択の取得または安全な退化を確認する。
- 起動と選択取得はclipboardを変更せず、secure fieldの内容を取得・送信・記録しない。
- 選択内容、segment、frame、画像、質問、回答をusageと診断ログへ保存しない。
- 現行`v0.2.1`からのAPI移行中も別endpoint、別prompt、別model routeを作らない。

## 15. プロジェクトAの受け入れ条件

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
  共同で理解する第一級の観測である。どれか一つを残りの代替物として扱わない。
- 通常Vision taskをselection専用taskへ置換せず、共通taskへselectionを追記する。
- 選択取得はAccessibility APIだけを使い、合成⌘Cへfallbackしない。
- Chromium／Electronでは両AX属性、document root／text container探索、captureと並行する
  bounded retryを使う。
- AXで対象を取れない場合、画像上の選択をbest-effortで読み、失敗時は通常Visionへ退化する。
- Focused Visionは画面画像を使い、画面全体の文脈内で対象を説明する。
- 編集可能欄内でも、非collapsed選択があればFocused Visionを優先する。
- プロジェクトAではComposeのclipboard＋⌘Vを維持するが、退避・復元は全廃する。
- AX直接入力はプロジェクトBのprobe結果が出るまで未採用とする。
- Unicode keyboard eventは製品fallbackにしない。
- Focused Visionの画像利用によるコストと送信範囲の増加を意識的に受け入れ、実測後に最適化する。
- 現行本番API契約は[api-contract.md](api-contract.md)を正とし、本書はR9の履歴とR10の要件・
  実装計画を記録する。
