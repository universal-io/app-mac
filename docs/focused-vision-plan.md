# Focused Vision 計画

最終更新: 2026-07-29 ／ ステータス: 設計確定・実装前

本書は、TransformをVisionへ統合し、Universal I/Oがユーザーに見えない場所で
システムクリップボードを借用する構造を廃止するプロジェクトの仕様書である。
進捗は[マスタープラン R9](universal-io-master-plan.md)、現行実装のAPI契約は
[api-contract.md](api-contract.md)を正とする。実装が完了するまで、現行Transform契約と
本書の目標契約を混同しない。

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

この再定義には4つの目的がある。

1. Transformという実態に合わない名前と独立パネルを廃止する。
2. 選択箇所の説明を、画面全体・Skill・継続質問・Copilotと同じ理解経路へ載せる。
3. VisionとTransformに重複しているSession、View、Gateway route、プロンプトを統合する。
4. 合成⌘C／⌘Vとクリップボード退避・復元を廃止し、ユーザーのクリップボードを
   バックグラウンド処理から完全に隔離する。

## 2. 現行構造の問題

### 2.1 右Shift起動が必ずクリップボードへ触る

現行の右Shift 2回は、Compose、Transform、Visionのどれを開くか決める前に
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

1. **Compose** — 対象入力欄へ入れる文章を作成・レビューし、ユーザーの確定で直接入力する。
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

パネルを前面化する前に、呼び出し元アプリのfocused elementをAccessibility APIで同期取得する。
合成⌘Cは送らない。

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

選択検出と編集可能判定は同じfocused element snapshotから導く。別々のAX walkで時点や対象を
ずらさない。選択対象がある場合は、編集可能な入力欄内の選択であってもFocused Visionを優先する。
ユーザーは選択によって「この部分を見てほしい」と明示しているためである。

### 4.2 AXで選択を取得できない場合

合成⌘Cへfallbackしない。編集可能なfocused elementならCompose、それ以外なら通常Visionへ
安全に退化する。クリップボードを触ってまで自動判定の網羅率を上げない。

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

1. focused elementの`AXSelectedText`が非空なら、文字列と可能なら
   `AXBoundsForRange`相当の矩形を使う。
2. 文字列だけ取得できたら、位置なしのselectedTextとして使う。
3. 選択文字列は無いが、明示的に選択・フォーカスされた意味のあるUI要素を取得できたら、
   role、label、frameを使う。
4. いずれも無ければfocus targetなしの通常Visionとする。

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

**ユーザーが明示的にコピーを選んだ時以外、Universal I/Oは標準クリップボードを読み書きしない。**

禁止:

- 起動モード判定のための合成⌘C
- 選択テキスト取得のための合成⌘C
- Compose送信のための一時書き込み＋合成⌘V
- 標準クリップボードの退避・復元
- AX失敗時の無言のclipboard fallback

許可:

- ユーザーが「コピー」を押した時の通常の文字列書き込み
- ユーザーが通常の⌘CをUniversal I/O自身の選択可能テキスト上で実行すること

名前付きpasteboardは他アプリの⌘C／⌘Vと接続しないため、隠れた受け渡しの代替には使わない。
テスト用の隔離pasteboardには使用できる。

### 7.2 Composeの直接入力

Composeはfocused elementのidentityをパネル前面化前に取得し、ユーザー確定後に次の順で入力する。

1. 対象アプリを前面化する。
2. 保存したAX elementが有効で、`AXSelectedText`がsettableなら選択範囲を置換する。
3. `AXValue`と選択範囲を安全に扱える場合は、カーソル位置または選択範囲へ文字列を挿入する。
4. AX直接設定が使えない場合は、対象のfirst responderへUnicode keyboard eventで文字列を入力する。
5. いずれも成功を確認できなければ、パネルを閉じずに「この入力欄へ直接入力できません」と表示する。
   ユーザーが明示的に選べる「コピー」を提示する。

直接入力の要件:

- 既存内容を意図せず全置換しない。
- 選択範囲があれば置換し、無ければカーソル位置へ挿入する。
- 改行を含む複数行、日本語、絵文字、結合文字を壊さない。
- secure fieldへ入力しない。
- AX elementが失効・別要素へ変化した場合、別の入力欄へ推測で送らない。
- 成功が確認できない時に履歴へ「送信済み」と記録しない。
- 失敗時の明示コピーはユーザー操作が完了した時だけ履歴の扱いを決める。

Unicode eventは標準クリップボードを使わないが、すべてのアプリでの動作を保証しない。
AX直接入力とUnicode fallbackの対応表は実機検証から作り、アプリ名による本番分岐をハードコードしない。

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
- `PasteDeployer`
- `ClipboardBackup`
- `.transform` AppMode
- Transform専用prompt、route、routing entry、ウォームアップ

追加・拡張:

- `AXFocusSnapshot` — focused element、編集可能性、選択対象を同時取得
- `VisionFocusTarget` — Visionへ渡すセッション内対象
- `AXTextInputService` — 選択置換／カーソル挿入／成功判定
- `UnicodeTextInputService` — clipboardを使わない限定fallback
- `DirectInputDeployer` — Composeから上記入力戦略を実行
- `VisionSession` / `GatewayVisionClient` — 任意focus target
- `VisionSessionView` — 対象カードとハイライト

`Deployer` protocolはテスト境界として維持できるが、「deploy＝clipboardへコピー」という
現行コメントと実装は廃止する。

## 10. 失敗時のUX

- 選択取得失敗: エラーを出さず通常VisionまたはComposeへ退化する。
- screen recording拒否: Focused Visionは画像なしの旧Transformへ戻さない。
  Visionを利用するため画面収録が必要だと説明し、許可導線を出す。
- Accessibility拒否: 選択検出と直接入力を実行せず、通常Visionまたは明示コピーを案内する。
- 直接入力失敗: パネルを閉じず、本文を保持し、再試行と明示コピーを提示する。
- コピー成功: inlineで短く通知し、modal alertを出さない。
- モデル失敗: 現行Visionの共通fallback notice／共通エラーを使う。

失敗を理由に、ユーザーに知らせず別の入力欄へ送る、クリップボードを変更する、送信履歴へ成功として
記録することは禁止する。

## 11. データ・プライバシー

- Focused Visionは画面画像を本番Gatewayへ送る。対象テキストだけのTransformより送信範囲が広がるため、
  UIで「画面画像」と「選択対象」を参照元として明示する。
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

本番ツリーに二方式を常設しない。短命ブランチ内で以下を順に完成させ、採用時に現行方式を置換する。

### M1 — AX focus snapshot

- focused element、編集可能性、selected text、role、label、frameを1回のsnapshotで取得する。
- secure field除外、AX timeout、失効要素を扱う。
- 右Shift起動の判定を純粋関数としてテストする。

### M2 — Focused Vision

- focus targetをVision request、prompt、Session、Viewへ通す。
- 通常Visionと同じ会話・Skill・Copilot経路で初期解説を返す。
- 対象カードとハイライトを実装する。

### M3 — Transform撤去

- `.transform`状態、Session、View、client、route、model routingを削除する。
- 旧Transformの主要な利用意図がFocused Visionで満たされることを実機確認する。
- 現行公開クライアントとのGateway互換境界を確認してからendpointを削除する。

### M4 — Compose直接入力

- AXSelectedText／AXValueによる挿入・置換を実装する。
- Unicode keyboard event fallbackを実装する。
- 失敗時の明示コピーと送信履歴の成功境界を実装する。

### M5 — clipboard借用の完全削除

- `SelectionGrabber`、`PasteDeployer`、`ClipboardBackup`を削除する。
- 合成⌘C／⌘V、遅延復元、標準クリップボードの暗黙read/writeが0件であることを検索と実機で確認する。
- README、API契約、golden paths、マスタープランを完了状態へ更新する。

M2だけを本番採用してM4/M5を先送りしない。本プロジェクトの完了条件はTransform統合だけでなく、
隠れたクリップボード依存が全て消えることである。

## 14. 検証

### 自動検証

- 選択あり／空選択／編集可能／非編集／secure fieldの起動判定
- AX selected textだけ、frameだけ、両方、どちらも無いfocus target
- focus targetのrequest encoding、上限、制御文字、座標変換
- 通常Vision requestがfocus target追加後も変わらないこと
- Composeの挿入、選択置換、複数行、日本語、絵文字
- AX失敗時のUnicode fallbackと、両方失敗時に履歴を保存しないこと
- 明示コピー以外からpasteboard APIへ到達しない構造検査
- Web lint、TypeScript、production build、macOS unit test、署名なしDebug build

### 実機検証

最低対象:

- AppKit: TextEdit、Apple Mail
- WebKit: Safari上のGmail
- Chromium: Chrome上のGmail、Slack
- Electron: SlackまたはVS Code
- 複数行、選択置換、カーソル挿入、日本語、英語、絵文字
- AX selected textを返す画面／返さない画面
- Accessibility拒否／画面収録拒否
- 入力欄が消えた、別タブへ移動した、対象アプリを終了した場合

クリップボード回帰:

1. リッチテキスト、画像、ファイル、複数itemを標準クリップボードへ入れる。
2. 通常Vision、Focused Vision、Compose送信、Copilotを実行する。
3. 各操作後にchangeCountと全flavorが変化していないことを確認する。
4. 操作中に別アプリで⌘Cし、その新しい内容が保持されることを確認する。
5. Universal I/O終了後も同じ内容を貼り付けられることを確認する。
6. 明示的な「コピー」を押した時だけ、期待した文字列へ置き換わることを確認する。

## 15. 受け入れ条件

以下を全て満たした時だけ完了とする。

- 製品surfaceの正本がCompose / Vision / Copilotの3つになっている。
- 選択対象がある時、同じVisionパネルで対象を優先した初期解説が返る。
- 同じsessionで追加質問とCopilot開始ができる。
- 選択が取れない画面では、clipboardへfallbackせず通常VisionまたはComposeが動く。
- Composeが標準クリップボードを変更せず対象欄へ入力できる。
- 直接入力できない場合は本文を失わず、明示コピーをユーザーが選べる。
- `TransformSession`、`/api/ai/transform`、`SelectionGrabber`、`PasteDeployer`、
  `ClipboardBackup`、合成⌘C／⌘Vが本番ツリーに存在しない。
- ユーザーが明示的にコピーした時以外、標準クリップボードのchangeCountと内容が変わらない。
- 通常Vision、Skill、fallback notice、Copilot、Composeレビューの既存品質が落ちていない。
- 入力本文、選択内容、画像、画面情報がusageや診断ログへ保存されない。

## 16. 非目標

- Universal I/Oが他アプリを自律操作すること
- AX非対応アプリのためにclipboard借用を復活させること
- Focused Vision専用モデルや長期feature flagを作ること
- Transformの旧レイアウトをVision内へそのまま移植すること
- 選択対象や会話を永続化すること
- すべてのWeb editorへアプリ名ごとの特例を追加すること

## 17. 決定事項

- Transformは廃止し、Focused Visionへ統合する。
- Focused Visionは独立surfaceではなくVisionの任意focus targetである。
- 選択取得はAccessibility APIだけを使い、合成⌘Cへfallbackしない。
- Focused Visionは画面画像を使い、画面全体の文脈内で対象を説明する。
- ComposeはAX直接入力を第一経路、Unicode eventを限定fallbackとする。
- 自動入力に失敗した時だけ、ユーザーが選べる明示コピーを提示する。
- バックグラウンドの標準クリップボードread/writeと退避・復元を全廃する。
- 実装完了まで現行API契約を正とし、目標契約は本書で管理する。

