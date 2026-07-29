# Focused Vision 計画

最終更新: 2026-07-30 ／ ステータス: A6 clipboard復元撤去完了

本書は、TransformをVisionへ統合し、Universal I/Oがユーザーに見えない場所で
システムクリップボードを退避・復元する構造を廃止するプロジェクトの仕様書である。
進捗は[マスタープラン R9](universal-io-master-plan.md)、現行実装のAPI契約は
[api-contract.md](api-contract.md)を正とする。独立Transform契約はA5で撤去済み。

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

Focused Visionは4つ目のsurfaceではない。Vision sessionを開始する際の任意の
`focus target`である。Transform、受信変換、選択変換という製品名は廃止する。

```text
VisionSession
  capture: 必須
  focusTarget: 任意
    ├─ selectedText
    ├─ accessibilityElement
    └─ region
```

## 4. 起動と状態遷移

### 4.1 右Shift 2回

パネルを前面化する前に、呼び出し元アプリのAccessibility treeを読み始める。合成⌘Cは送らない。
選択取得、編集可能判定、画面captureは並行して進め、固定の2秒待機をユーザーへ課さない。

```text
右Shift 2回
  ├─ 意味のある選択対象をAXで取得できた
  │    → Focused Vision
  │
  ├─ focused elementが編集可能
  │    → Compose
  │
  └─ それ以外
       → 通常のVision
```

選択検出と編集可能判定は同じ`AXFocusSnapshot`から導く。別々のAX walkで時点や対象をずらさない。
選択対象がある場合は、編集可能な入力欄内の選択であってもFocused Visionを優先する。現行Transformの
意味を維持し、ユーザーが選択によって「この部分を見てほしい」と明示したものとして扱う。

Chromium / ElectronはAX treeを遅延構築する。アプリ要素へ`AXEnhancedUserInterface`と
`AXManualAccessibility`の両方を設定し、focused elementから祖先（通常`AXWebArea`）まで調べる。
treeが成長している間だけ、画面captureと並行してbounded retryする。既存の
`VisionObservationCaptureService`と異なる待機・有効化方式を新設しない。

### 4.2 AXで選択を取得できない場合

合成⌘Cへfallbackしない。編集可能なfocused elementならCompose、それ以外なら通常Visionへ
安全に退化する。クリップボードを触ってまで自動判定の網羅率を上げない。

Safari、Apple Mail、AX treeが冷えたChromium等では、公開・文書化されたAX属性から本文選択を
取得できない場合がある。この場合はcaptureに選択ハイライトが見えている可能性をVision promptへ
伝え、画像から対象を特定するbest-effort経路を使う。特定できなければ通常Visionとして答える。
未文書のtext marker属性、AppleScript、ページ内JavaScriptは初期実装のfallbackにしない。

### 4.3 他の起動操作

- メニューバー「パネルを表示」: 現行どおりCompose。選択検出を行わない。
- 右Shift長押し: 現行どおり音声入力を開始する。選択検出を行わない。
- Composeから右Shift 2回: 先読みcaptureを再利用して通常Visionへ進む。
- Vision / Focused Visionから右Shift 2回またはEsc: 閉じる。

## 5. Focus target

focus targetは、取得できた情報だけを持つセッション内データで、永続化しない。

```swift
struct VisionFocusTarget {
    let kind: Kind
    let text: String?
    let role: String?
    let label: String?
    let frame: CGRect?
    let source: Source
}
```

- `kind`: `selectedText` / `accessibilityElement` / `region`
- `text`: AXから取得した選択文字列。空白だけならnil
- `role`: AX role。診断・モデル解釈用
- `label`: title / description / label等から得た短い識別子
- `frame`: グローバル座標。capture座標へ変換してハイライトに使う
- `source`: `axSelectedText` / `axElement` / `userRegion`

制約:

- テキストはGatewayの入力上限内へ切り詰める。途中省略をメタデータで明示する。
- password等のsecure fieldは対象にもCompose入力先にも含めない。
- AX値、アプリ名、ウインドウタイトル、矩形はusageへ保存しない。
- focus targetと画像はVision session終了時に破棄する。
- AX要素参照そのものをGatewayへ送らない。送るのは必要な値だけ。

### 5.1 取得優先順位

1. focused elementから祖先へwalkし、`AXSelectedText`が非空な最も近い意味のある要素を探す。
2. 文字列と選択rangeが取れれば、公開parameterized attributeから矩形を取得する。
3. 文字列だけ取得できたら、位置なしのselectedTextとして使う。
4. 選択文字列は無いが、明示的に選択・フォーカスされた意味のあるUI要素を取得できたら、
   role、label、frameを使う。
5. AX対象が無くcaptureに視覚的な選択があり得る場合は、対象未確定のヒントだけをVisionへ渡す。
6. いずれも無ければfocus targetなしの通常Visionとする。

画面上の任意領域をマウスで囲う既存のcapture操作は`region`として同じ型へ合流できるが、
このプロジェクトの最初の完成条件はAX選択と通常Visionの統合までとする。

## 6. 画面体験

### 6.1 同じVisionパネルを使う

Focused Vision専用ウインドウやTransformパネルを作らない。既存Visionのレイアウト、質問欄、
Enter送信、Esc終了、Skill表示、fallback notice、Copilot開始を共有する。

### 6.2 対象の表示

対象がある時だけ、左側のcapture上にハイライトを表示し、対象カードを添える。

対象カードに表示するもの:

- 「選択中のテキスト」またはroleに基づく中立な名称
- 選択文字列（長文は折りたたみ、全文はスクロール可能）
- 取得元（選択テキスト／画面上の要素）
- 位置が取得できなかった場合は、その事実

ブラウザ名やウインドウタイトルを対象名として代用しない。適用中のSkillは既存Visionと同じ場所に
表示する。ハイライトはシステムのアクセントカラーを基本とし、ライト／ダーク、
Increase Contrast、Reduce Transparencyに対応する。色だけで対象を伝えず、枠とラベルを併用する。

### 6.3 初期応答

通常Visionは画面全体の重要点から説明を始める。Focused Visionは選択対象への回答を先に返し、
必要な範囲で画面全体との関係を補足する。

初期質問はクライアントが固定文字列として付け足すのではなく、Gatewayへfocus targetを構造化して渡し、
Vision promptが「対象を最優先で説明する」と解釈する。画面に根拠が無い情報を対象文字列だけから
断定しない。

### 6.4 継続

- 同じcapture、focus target、turnsを保ったまま追加質問できる。
- 質問が対象外へ広がっても、Visionは画面全体を参照できる。
- 操作意図があれば既存の「案内を開始」からCopilotへ進む。
- Copilot開始後は目的を引き継ぐ。古いfocus targetの枠を新captureへ機械的に再利用しない。
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

実装完了後、独立した`POST /api/ai/transform`を削除し、`POST /api/ai/vision`へ統合する。
移行中に二重の本番経路を常設しない。Gatewayを旧クライアント互換にする必要がある期間は、
削除順と公開版の最低バージョンを実装開始時に決める。

Vision requestへ任意のfocus targetを追加する。

```json
{
  "operation": "vision",
  "input": {
    "capture_id": "uuid",
    "image_base64": "...",
    "question": null,
    "turns": [],
    "candidates": [],
    "focus_target": {
      "kind": "selected_text",
      "text": "選択された文字列",
      "role": "AXStaticText",
      "label": null,
      "frame": { "x": 120, "y": 240, "width": 360, "height": 42 },
      "source": "ax_selected_text",
      "truncated": false
    },
    "context": {}
  }
}
```

契約規則:

- `focus_target`は任意。無ければ現行Visionと同一。
- `frame`はcapture画像座標へ正規化して送る。AXのグローバル座標をそのまま送らない。
- `text`、`role`、`label`は長さと制御文字を検証する。
- focus targetはモデル入力にだけ使い、usageや運用ログへ保存しない。
- 応答形式、model routing、fallback notice、Skill、candidate ID、Copilot guidanceは現行Visionと共通。
- Focused Vision専用モデル、endpoint、fallback、feature flagを作らない。
- Transformのusage dimensionは移行後`vision`へ統合し、必要なら内容を保存しない
  `focus_target_present: boolean`だけを運用指標として持つ。

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

- `AXFocusSnapshot` — focused element、祖先選択、編集可能性、選択対象を同時取得
- `VisionFocusTarget` — Visionへ渡すセッション内対象
- `VisionSession` / `GatewayVisionClient` — 任意focus target
- `VisionSessionView` — 対象カードとハイライト
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
  関係で説明する」ための意識的な交換である。初期実装では画像を省かず、実測後にcrop、低detail、
  オンデバイスOCR＋縮小画像を検討する。
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
プロジェクトBはAと分離したprobe・製品判断として扱う。

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
残さず、必要な復帰は開始tagまたはGit履歴から行う。Focused Visionの実機確認項目は
[manual-golden-paths.md](manual-golden-paths.md)に維持し、A7の統合検証で実施する。

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
リッチテキスト、画像、ファイル、複数item、送信直後のユーザー⌘Cとの競合は
[manual-golden-paths.md](manual-golden-paths.md)へ固定し、A7の署名付き実機検証で実施する。

### A7 — 統合検証と完了記録

- macOS unit test、署名なしDebug build、Web lint／TypeScript／production buildを通す。
- §14の実機検証を行う。
- README、API契約、golden paths、マスタープランを完了状態へ更新する。
- 変更全体を開始タグと比較し、無関係な実験物が無いことを確認する。

コミット境界: プロジェクトAの完了記録。main統合判断が可能な状態。

### B0 — AX入力probe（Aと独立）

- リポジトリ外に固定bundle IDの短命.appを作る。
- TextEdit、ローカルHTML、Chrome、Slack、Safariの順に、read／write／read-backを検証する。
- Undo、selection、複数行、日本語、絵文字、IME compositionを記録する。
- Unicode eventは製品実装ではなく、制約確認だけ行う。
- probe本体は削除し、再現手順、OS／アプリversion、結果表だけを本書へ残す。

### B1 — 入力方式の製品判断

B0の結果から§7.3の3案のどれかを選ぶ。採用方式、対象範囲、成功判定、失敗UX、履歴境界を
仕様化してから、別の短命branchで実装する。Bの失敗や不採用はAをrollbackする理由にしない。

## 14. 検証

### 自動検証

- 選択あり／空選択／編集可能／非編集／secure fieldの起動判定
- focused element／祖先／AXWebAreaの選択探索
- coldなChromium treeのbounded retryと期限終了
- AX selected textだけ、frameだけ、両方、どちらも無いfocus target
- focus targetのrequest encoding、上限、制御文字、座標変換
- 通常Vision requestがfocus target追加後も変わらないこと
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
- 未文書のtext marker属性やブラウザJavaScriptを初期fallbackにすること
- Focused Vision専用モデルや長期feature flagを作ること
- Transformの旧レイアウトをVision内へそのまま移植すること
- 選択対象や会話を永続化すること
- すべてのWeb editorへアプリ名ごとの特例を追加すること

## 17. 決定事項

- Transformは廃止し、Focused Visionへ統合する。
- Focused Visionは独立surfaceではなくVisionの任意focus targetである。
- 選択取得はAccessibility APIだけを使い、合成⌘Cへfallbackしない。
- Chromium／Electronでは両AX属性、祖先walk、captureと並行するbounded retryを使う。
- AXで対象を取れない場合、画像上の選択をbest-effortで読み、失敗時は通常Visionへ退化する。
- Focused Visionは画面画像を使い、画面全体の文脈内で対象を説明する。
- 編集可能欄内でも、非collapsed選択があればFocused Visionを優先する。
- プロジェクトAではComposeのclipboard＋⌘Vを維持するが、退避・復元は全廃する。
- AX直接入力はプロジェクトBのprobe結果が出るまで未採用とする。
- Unicode keyboard eventは製品fallbackにしない。
- Focused Visionの画像利用によるコストと送信範囲の増加を意識的に受け入れ、実測後に最適化する。
- 実装完了まで現行API契約を正とし、目標契約は本書で管理する。
