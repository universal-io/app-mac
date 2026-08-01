# Vision Selection 証拠主義への修正計画（R10.5）

最終更新: 2026-08-01 ／ ステータス: §5-1〜§5-4実装済み・実機検証待ち（§5-5は移行計測後）

R10 C6の実機テストで、**何も選択していない画面でも常に選択カードが表示され、モデルが
「選択範囲を確認できません」と回答する**不具合を確認した。通常Visionが単独で成立しない状態であり、
製品として出せない。

本書は前セッションで計画を確定し、別セッションで§7〜§9の全判定をコード実物で裏取りした。
判定の過程で**計画自体の欠陥3件**（§7-2）を発見し、本版へ反映済みである。正本
（`focused-vision-plan.md`、`api-contract.md`、マスタープランR10、README）の矛盾修正は
本書と同じコミットで実施済み。残るのはGatewayホットフィックス以降の実装である。

## 0. 本来の意図（この機能の判断基準）

この製品がやりたいことは2つだけである。

1. **目の前の画面を正しく取得し、正しく理解する。**
2. **ユーザーが何かを選択している時は、その選択を回答対象として最優先する。**

選択は通常Visionへの純粋な加算であり、利用機会は選択していない時の方が圧倒的に多い。
「実装がこうなっているから」「直近こう作ったから」「wire契約に値があるから」は、この2点を
上書きする理由にならない。実装計画を評価する時は、新しい状態・enum値・fallbackの提案に対して
**「それを観測する主体は誰か」「それは上の2点のどちらに資するか」**を必ず問う。

## 1. 何が起きているか

4段の連鎖である（全段コード実物で確認済み）。

1. [`AXFocusSnapshotService.swift`](../BombSquad/Services/AXFocusSnapshotService.swift) の
   `shouldLookForVisualSelection`（L82-95）が、destinationが`.vision`で選択が無く、statusが
   `complete` / `noFocusedElement` / `timedOut` / `invalidatedElement`のときに`true`を返す。
   これは「何も選択していない普通の画面」そのものである。
2. `selectionExtension`（L74-76）がその`true`を`.visualOnly(captureVisibility: .visible)`へ
   昇格させる。`.visible`は観測結果ではなく定数で、画像を見た主体は存在しない。
   `resolvingCaptureVisibility`はframesが空のため素通しし、定数を訂正する機会も無い。
3. `VisionSelectionPresentation`（VisionFocusTarget.swift L224-227）が
   「選択範囲 / 選択範囲を画像から確認中」のカードを描く。
4. [`vision-prompt.ts`](../web/lib/server/vision-prompt.ts) の`resolveVisionIntent`（L78-81）が、
   初回taskを「画像から選択ハイライトを探して説明せよ」へ置換する。

モデルはこの指示に従い、選択の不在報告から回答を始める。

## 2. なぜ起きたか

**実装だけの逸脱ではない。**

正本§4.2は「capture上に選択ハイライトが**観測可能なら**`visualOnly`として加える」と条件付きで
書いていたが、**この条件を判定できる実装主体が現在の構成に存在しない**。クライアントは画像解析を
行わず、ハイライトを観測できるのはモデルだけで、その観測はselectionを組み立てた後に起きる。
実装者はこの充足不可能な条件を、条件を落とすことで解決した。本来は「実装できない」と止める箇所だった。

さらに、この推測的fallbackは**R10の発明ではなく`v0.2.1`に既に存在していた**。当時は
`visual_selection_hint`という真偽値で、カードが無くプロンプト行だけだったため目立たなかった。
R10はそれを一級の`selection`オブジェクトへ昇格させて可視化した。C1の判定ゲートと受け入れ条件が
「取得不能なら`visualOnly`へ安全に退化する」と明記して追認していたため、実装は仕様どおりに通った。

**したがってコードだけを直しても再発する。正本と受け入れ条件とテストを同時に直す**（正本側は
本コミットで実施済み）。

## 3. 不変条件

> **ユーザーが指定した選択内容が回答対象である。AX・DOM・スクリーンショット・OCRは、その内容を
> 取得または理解するための情報源であり、いずれの取得成否もユーザーの意図を上書きしない。**

この一文が正本である。以下は、そこから導かれる実装規則にすぎない。

- `Selection Extension`（構造化されたwire field）は、AXが実際に文字列を返したときだけ作る。
  クライアントは自分が観測していないものを報告しない。
- **AXが返さないことは「ユーザーが選択していない」ことを意味しない。** 言えるのは
  「AXという取得経路では文字列を回収できなかった」までである。
- 画面上に明確なテキスト選択が見えるかを観測できる主体は**モデルだけ**である。したがって
  その判定はモデルに委ね、クライアントは代わりに断定しない。
- 選択が見えたときはそれが主対象、見えないときは通常の画面説明。**どちらの場合も、選択検出の
  成否や不確実性をユーザーへ報告しない。**

再発防止のための補助原則:

> **「観測主体を問え」は、状態を消す方向にも、正しい主体へ委ねる方向にも使う。**
> クライアントが画像を見られないことは、クライアントにその状態を作らせない理由にはなるが、
> ユーザーの意図を無かったことにする理由にはならない。
> 観測主体を持たない状態を型・wire契約・UIへ持ち込まないことと、観測できる主体へ判断を渡すことは
> 同じ原則の表と裏である。

> 「選択の不在」と「選択の不明」を区別しない、はクライアントの**報告**についての規則である。
> ユーザーの**意図**については、不明を不在として扱ってはならない。

## 4. selection の成立条件

この表は**wire fieldを作るかどうか**の判定であって、ユーザーが選択したかどうかの判定ではない。
`nil`の行でも、画像上に選択が見えればモデルがそれを主対象として扱う（§4-b）。

| AXから得られたもの | `selection` wire | 起動先 |
|---|---|---|
| resolverが確定した非空の選択文字列 | `.text` | Vision（+ Selection Extension） |
| 選択文字列なし・編集可能 | `nil` | Compose |
| 選択文字列なし・非編集 | `nil` | Vision（画像上の選択はモデルが判定） |
| AX取得失敗 / timeout / focus要素なし | `nil` | Vision（同上） |
| `AXSelected == true`の現在項目 | `nil` | 編集可能ならCompose、他はVision |
| secure field | `nil` | Vision |

全行の判定主体はAX snapshotの読取そのものであり、判定不能な行は無い。

AX／DOMを軽視するのではない。選択文字列が取れたときの意味・構造・位置の補強、および通常Visionの
画面構造証拠としては引き続き第一級で使う。**AXの状態だけからユーザー意図を推測しない**という限定である。

`accessibility_element`を落とす理由: `AXSelected`はタブ、サイドバー、リスト、表で「現在表示中の項目」を
意味することがあり、「ユーザーがVisionへの説明対象として選んだ」証拠にならない。role除外リストの
追加では解けない（アプリ横断で意味が異なるため）。非テキスト要素を対象にしたいなら、専用の要素選択操作、
クリック直後という時間的証拠、明示的な領域指定など、意図を区別できる仕組みを別途設計する。

`visual_only`という**クライアント側の状態**を残さない理由:

1. クライアントに検出器が存在せず、導入計画も無い。残せば到達不能な状態のために型・契約・
   プロンプト・カード・テストを維持することになり、今回の不具合を起こした構造をそのまま休眠させる。
2. `visual_only`の誤りは「画像上の選択を扱おうとしたこと」ではなく、**画像を見ていない
   クライアントがその有無を断定したこと**である。同じ目的は、画像を見ているモデルへ判定を
   委ねることで、嘘の状態を作らずに達成できる（§4-b）。

### 4-b. AXが返さない選択の扱い（2026-08-01追加）

当初この節には「画面にハイライトが写っているので、ユーザーが質問すればモデルは画像から答えられる。
**質問が最後の選択拡張である**」と書いていた。**これは誤りだったので撤回する。**

- ユーザーは選択という明示的な操作をすでに行っている。そこへ質問という一手を追加で要求するのは、
  意図を尊重していない。
- 実機で否定された。selectionが無いとGatewayは通常観測を指示し、モデルにとってハイライトは
  画面上の多数の視覚情報の一つでしかない。「ユーザーが説明してほしい対象」だとは伝わらない。

正しい扱いは、**通常Visionのpromptが常にこう述べること**である。

```text
スクリーンショット上に明確なテキスト選択が見える場合:
    その選択内容をユーザーが指定した主対象として読み、説明する
明確なテキスト選択が見えない場合:
    通常どおり画面を説明する
どちらの場合も:
    選択検出の成否・不在・不確実性をユーザーへ報告しない
```

これは`visual_only`とは決定的に違う。`visual_only`は**クライアントが**「選択があるかもしれない」と
断定して「探せ」と命じ、選択の無い画面で不在報告を生ませた。この規則は**モデルが**自分の見ている
画像から判定し、見えなければ何も言わずに通常の観測を行う。観測主体が正しい位置にある。

限界も明記する。画面外へ続く長い選択、極小の文字、コントラストの低い選択色、スクロールで隠れた
部分は、画像だけでは全文を回収できない。そこはAX・DOM等の取得経路が優れている。**しかしこれは
取得精度の問題であり、AXをselectionの存在判定者にする理由にはならない。**

## 4-c. AX探索側の死角（2026-08-01、実測で確定・修正済み）

read-only probeとGmailの実機診断（`[selection] status: none`／`visited_nodes: 1540`）で、
**AXは選択を返していたのに製品が自分で捨てていた**ことが確定した。「webviewは公開AXに選択を
出さない」という当初の断定は誤りである。

真因は2つで、どちらも自前の探索条件だった。

- **祖先walkが`AXWebArea`をスキップしていた。** Chromeはdocument（`AXWebArea`）自身をfocused
  elementとして報告し、そこに選択全文を載せる。probe実測でfocused elementが679 unitsを公開して
  いたのに、「web areaの本文はsecure検査後に読む」という設計のため1歩目で捨て、candidateは0件に
  なっていた。
- **逃した分を拾うはずのdocument走査が構造的に動かなかった。** 「window全体を256要素以内で
  走査完了し、かつsecure descendantが無い」場合だけ読む条件だったが、Chrome Gmailは1,540要素超、
  VS Codeは5,824要素あるため`completedTraversal`は決して成立しない。AXWebAreaを見つけても
  選択文字列を一切読まなかった。

修正内容:

- 祖先walkでweb areaをスキップしない。secure保護は焦点チェーンの検査が担う（チェーン上に
  secure fieldがあればsnapshot全体を中止する）。選択は1箇所にしか存在しないので、チェーンが
  secureでなければ選択内容もsecureではない。
- `selectionScope(role:isFocusedElement:)`を追加し、web areaはチェーン上のどこにあっても
  document scopeとして扱う。位置ではなくroleで判定する。
- `shouldReadDocumentSelection`から「完走必須」を外し、走査上限を256→4,000へ。走査中にsecure
  fieldを見つけたら読まない規則は維持する。作業量を縛るのは1 pass 1秒のdeadlineであって、
  ノード数の定数ではない。
- 焦点チェーンでcandidateが取れたらdocument走査を丸ごと省く。

結果（Chrome Gmail、修正後probe）: `ancestor[0] role=AXWebArea -> candidate 227 units
scope=document`、**取得1ms、document走査スキップ**。修正前は同じ画面でcandidate 0件、AX収集に
1,500msを費やしていた。document scopeが立つため`hasAuthoritativeSelection`が即座に成立し、
bounded retryも1 passで止まる。

実機確認（2026-08-01、署名なしDebug build）: 同じChrome Gmailで
`acquisition: ax_document_selection` / `acquisition_completeness: complete` /
`structure_count: 1`を確認した。修正前の同一画面は`[selection] status: none`だった。
`frame_count: 0`はC1実測済みのChrome公開boundsの0サイズ問題で、選択位置の枠は描けない
（カードには選択全文が出るため内容は確認できる）。

残る死角（未修正・優先度低）:

- **focused elementが取れないとdocument探索を一切しない。** `captureAttempt`は
  `kAXFocusedUIElementAttribute`が無いとcandidateゼロで即returnする。ただし実測では、選択が
  存在する時のfocused elementは取得できていた（選択が無い時に`no focused element`になる）。
- **AXの挙動自体が不安定である。** 同じVS Codeウインドウで、選択中にfocused elementが49 unitsを
  返した観測と、180秒待って選択を1件も公開しなかった観測の両方が出た。**これはAXへ機能を依存
  させない根拠であり、§4-bのモデル判定を持つ理由でもある。**

## 5. 実装順序

### 0. C6をリリースブロッカーとして未完了へ戻す — 実施済み

### 1. 正本を先に直す（コードより先）— 実施済み（本コミット）

- `focused-vision-plan.md`: §4.1判定ツリー、§4.2、§5データモデル、§5.1取得優先順位、§6.2、§8、
  C1判定ゲート・結果表・結論、C4/C5仕様bullet、§14自動検証（不在検査の追加）、
  プロジェクトC受け入れ条件
- `api-contract.md`: R10契約の`selection.kind`有効値、旧fieldの扱い
- `universal-io-master-plan.md`: R10不変条件段落、C1/C4/C6記録、ブロッカーの明記
- `README.md`: 開発中セクションと操作セクション

C2〜C6の完了記録は当時の事実として残し、書き換えない。仕様と受け入れ条件だけを直す。

### 2. Gateway 後方互換ホットフィックス

**validationを先に削ってはならない。** [`route.ts`](../web/app/api/ai/vision/route.ts)では
`validateBody`（L117、内部でL372が`isValidVisionSelectionWire`を呼ぶ）が正規化（L170）より前に
走るため、`kinds`から`visual_only`を削ると現行の新クライアントは400を受け、通常Visionへ退化せず
**Visionセッションごと失敗する**（コード実物で確認済み）。

変更内容（1コミット）:

- `visual_selection_hint` → validationは現状のまま（booleanを受理し続けるので`v0.2.1`は無傷）、
  [`vision-selection.ts`](../web/lib/server/vision-selection.ts) `normalizeVisionSelection`の
  legacy分岐（L240-251）を削除し**正規化しない**
- 新wire `selection.kind === "visual_only"` **および `"accessibility_element"`** →
  wire validationは当面残したまま、`normalizeVisionSelection`で`undefined`として捨てる。
  注意: 新wireはL210でkindを見ずに素通しするため、そこにkind検査を入れる（§5-2に
  `visual_only`しか書いていなかったのは前版の欠落。候補ビルドは`accessibility_element`を送る）
- 旧`focus_target.kind === "accessibility_element"`と`"region"`も同じく正規化で捨てる
  （§7-1で「捨てる」に確定。`region`はどの公開クライアントも送らない死んだwire表面）
- `resolveVisionIntent`の`visual_only`分岐と`accessibility_element`分岐を削除
- **正規化前のraw wire種別をusage metadataへ記録する**（例: `selection_wire_kind`、
  legacy fieldの別）。前版の§5-5は正規化後の`selection_acquisition_completeness`で移行を
  計測する計画だったが、この値は正規化で捨てた瞬間に常に欠落し、**何も観測しない判定**になる
  （route.ts L194で確認済み）。raw種別は内容を含まない列挙値であり、データ保存方針と整合する

結果、旧・新クライアントとも通常Visionの観測プロンプトへ戻る。

実施済み（2026-08-01、`349bb9c`）: `normalizeVisionSelection`が唯一の成立判定になり、
`kind !== "text"`と空textを捨てる。legacy `accessibility_element` / `region` / `visual_selection_hint`は
正規化しない。`resolveVisionIntent`のvisual_only／element分岐を削除し、内部型`VisionSelection`の
`kind`を`"text"`、`text`を必須へ狭めた。選択が無いrequestでは証拠ブロックの見出しからも
"user-selected text"を外し、promptに選択の語が一切現れないようにした。usageへ
`selection_wire_kind`（正規化前のraw種別）を追加した。Gateway 17件、lint、production buildが成功。

### 3. Gateway を本番デプロイ

`origin/main`へのpushが本番デプロイである。R10のGateway契約は既に`main`にあるため、
ホットフィックスは**mainから短命ブランチを切って**mainへマージし、その後
`feat/vision-selection-extension`へmainを取り込む。この時点で**公開中の`v0.2.1`ユーザーの
症状が消える**。クライアント修正を待たない。

実施済み（2026-08-01）: `fix/vision-selection-evidence`をmainへfast-forwardし、`349bb9c`を
push。Vercelのproduction deployが同commitでREADYになったことを確認した。公開中の`v0.2.1`は
`visual_selection_hint`を送り続けるが、Gatewayが無視するため通常Visionの観測promptへ戻る。
ただし`focus_target.accessibility_element`のカードはクライアントローカル描画のため`v0.2.1`では
残り、回答だけが正される（§7-1）。

`v0.2.1`への効果の限定を正確に: `visual_selection_hint`にはカードが無いため症状は完全に消える。
`focus_target.accessibility_element`のカードは**クライアントローカル描画**のため残り、回答だけが
通常観察へ正される（§7-1）。

### 4. クライアントから削除

- `AXFocusLaunchDecision.shouldLookForVisualSelection`
- `selectionExtension`のvisual分岐とelement分岐
- `AXFocusLaunchDecision.isMeaningfulSelectedElement`（**3箇所すべて**: `selectionExtension`、
  `destination`の起動先判定、`capture()`内の`resolvedSelection`（AXFocusSnapshotService L227-235）、
  および`hasAuthoritativeSelection`（L258））
- `VisionSelectionContext.visualOnly` factory、`Kind.visualOnly`、
  `AcquisitionCompleteness.visualOnly`
- `VisionSelectionContext.accessibilityElement` factory、`Kind.accessibilityElement`
- `VisionSelectionResolver`の`allowVisualFallback`（本番からは`true`で呼ばれておらず削除は安全）
- `VisionSelectionPresentation`のvisualOnly／accessibilityElement分岐
- `visual_only`のwire生成

**波及1（起動先）**: `isMeaningfulSelectedElement`を外すと`AXSelected == true`の
**編集可能フィールド**が現在のVisionからComposeへ変わる。これは正本の「選択なし＋編集可能なら
Compose」に一致させる修正であり望ましいが、起動経路の挙動変更なので回帰テストの明示対象とする。

**波及2（retry停止＝summon遅延）**: `hasAuthoritativeSelection`は同関数を「選択あり＝bounded
retry停止」の条件にも使っている。単純に外すと、AXSelected要素があるweb画面（GA4サイドバー等）で
retryが早期停止しなくなり、`sawWebArea`だけでretryを許す現行規則
（`AXFocusSnapshotRetryPolicy` L124-125）により**2秒予算を使い切る**。しかも
`SessionCoordinator`はcaptureとsnapshotの両方を待ってからパネルを出す（L233）ため、これは
そのまま起動遅延になる。そこでretry規則を不変条件の精神に合わせて再設計する:

> retryを正当化するのは「選択の証拠がまだ現れ得る積極的な兆候」だけとする。すなわち
> (a) focused elementが未取得、(b) treeが成長中、(c) 断片候補は在るがdocument選択が未確定、
> のいずれか。`sawWebArea`単独では追加1passまでしか正当化しない。証拠の兆候ゼロの安定した
> 画面で予算を使い切らない。

これは「選択なしブラウザ画面」という**最頻の利用場面**のsummon遅延を直接短縮する。cold
Chromiumで選択が遅れて公開されるケースは(b)(c)が受け止める。効果と安全性はC6の同一端末
p50／p95比較で、**選択なしブラウザ画面と複数node Gmail選択の両方**を計測して確認する。

実施済み（2026-08-01）: 上記をすべて削除し、`selectionExtension`は`snapshot.selection`を
返すだけになった。`isMeaningfulSelectedElement`の消滅で`AXSelected`という概念自体が
クライアントから無くなったため、`AXFocusSnapshot.isElementSelected`とその`kAXSelectedAttribute`
読取も削除した（summonごとのAX readが1回減る）。`VisionSelectionContext`は`kind`を単一case、
`text`を非optionalへ狭め、型として「取得できた選択テキスト以外は存在しない」を表現する。
`VisionSelectionPresentation`の`statusText`と、それを描いていたVisionパネルのLabelも削除した。
retry規則は下記のとおり再設計した。macOS 40件、署名なしDebug buildが成功。

### 5. 移行完了を計測してから wire を撤去

「移行期間」は推測せず観測する。§5-2で追加した`selection_wire_kind`の記録で、`visual_only`／新wire
`accessibility_element`の受信がゼロで安定したことを確認してから、wire validationのenumと型を
別コミットで削除する。

このコミットへ回した残りの収縮（ブロッカー修正のdiffを不変条件の貫徹だけに保つため）:

- **Gateway内部型の非対称の解消。** `kind`はmacOS／Gatewayとも`text`単一へ収縮したが、Gatewayの
  `VisionSelection`は`acquisitionCompleteness`に`visual_only`、`acquisition`に`ax_element`／
  `visual_highlight`をwire由来のまま残している。macOS側は2値／2値へ収縮済みなので、wire撤去と
  同時に揃える。現行では実害が無い（wire validationが`kind: text`と`completeness: visual_only`の
  同居を拒否し、公開・現行クライアントとも矛盾する`acquisition`を送らない）が、`text`があるのに
  「画像から取得した」と申告するwireを内部型が表現できてしまう状態は残っている。
- `acquisition`の2値化（document / element-local）とモデルへの寄与の検証。
- `captureVisibility`は`frames`とcapture矩形から導出できる冗長fieldなので導出へ寄せる。
- `kind`フィールド自体の削除（定数を送る意味が無い）。

`visual_selection_hint`と`focus_target`はこの対象外で、受理を**恒久的に**維持する
（`v0.2.1`ユーザーは更新しないため）。段階撤去が必要なのは厳密なenumに入っている
`selection.kind`だけである。

## 6. 回帰テスト

**不在を断言する形**（`XCTAssertNil`）で書く。現在は逆を断言しているテストがあるため、まず反転する
（`AXFocusSnapshotTests`のL30-49・L74-82、`VisionFocusTargetTests`のvisualOnly生成・wire・
presentation期待）。

| ケース | 期待 |
|---|---|
| 選択なしの通常画面 | selection nil / カードなし / selectionプロンプトなし / selection wireなし |
| focus要素なし | 同上 |
| AX timeout | 同上 |
| サイドバーの現在項目（`AXSelected`） | 同上 |
| 選択中のタブ・行 | 同上 |
| `AXSelected`な編集可能フィールド | **Composeへ起動**（波及1の検証） |
| 兆候ゼロの安定web画面 | retryが早期停止する（波及2の検証） |
| 断片候補あり・document未確定のweb画面 | retryが継続する（cold tree保護の検証） |
| 非空の複数DOMテキスト選択 | `.text`成立、全文が回答scope |
| Gateway: 旧`visual_selection_hint: true` | 200、通常Visionプロンプト |
| Gateway: 旧`focus_target.kind: "accessibility_element"` | 200、通常Visionプロンプト |
| Gateway: 新`kind: "visual_only"` | **200**（400でないこと）、通常Visionプロンプト |
| Gateway: 新`kind: "accessibility_element"` | **200**、通常Visionプロンプト |
| Gateway: 上記の無視ケース | usageへraw wire種別が記録される（§5-5の観測可能性） |

実機では、GA4のようなサイドバー項目をクリックした直後の画面で右Shift×2を行い、カードが出ないことを
確認する。今回の不具合はこの操作で再現した。

## 7. 判定記録（2026-08-01、別セッションでコード実物により裏取り）

### 7-1. 旧クライアントの`accessibility_element`をGatewayで捨てるか → **捨てる（確定）**

- 理由: (a) サイドバーの現在項目を延々説明する回答より全画面観察が明確に有益、
  (b) `visual_selection_hint`の無視が既に同型のreleased挙動変更であり一貫する、
  (c) `accessibility_element`という状態・prompt分岐・adapter生成が系から完全に消え、
  休眠状態を残さない。
- 明示すべきトレードオフ: `v0.2.1`のカードはクライアントローカルなので**カードは残り**、
  回答だけが正される。「v0.2.1ユーザーも救われる」はプロンプトについてのみ正しい。

### 7-2. 前版計画の欠陥3件（本版で修正済み）

1. **§5-5の計測が機能しなかった**: 正規化後のmetadataで移行を測る計画は、正規化で捨てた瞬間に
   恒久ゼロになり無内容だった。→ raw wire種別の記録を§5-2へ追加。
2. **新wire `accessibility_element`の扱いが未規定だった**: 候補ビルドが送るのに§5-2は
   `visual_only`しか挙げていなかった。→ 同じ「受理して無視」へ追加。legacy `region`も同様。
3. **`hasAuthoritativeSelection`の波及が未記載だった**: retry停止条件の変更はsummon遅延に直結し、
   C6の性能受け入れ条件に響く。→ §5-4へretry再設計と計測ゲートを追加。

### 7-3. 前版§10の6問への回答

1. 不変条件は一意に実装可能か → 可。「selection＝resolverが返した`.text`のみ」を§3へ追記した。
   §4表は全行AX snapshotだけで判定でき、判定主体の無い行は無い。
2. Gateway段階撤去は400を出さないか → 出さない。`validateBody`→正規化の実行順を実コードで確認。
   「受理して無視」が唯一安全。
3. §5-4の波及 → 記載済みの起動先変更に加え、未記載のretry波及を発見（§7-2-3）。
4. §7の結論 → 7-1で確定。
5. `acquisition`／`captureVisibility`を畳むか → wire撤去コミット（§5-5）に同梱。
   `captureVisibility`はframes×captureRectの幾何計算という観測主体を持つため`visual_only`と
   同罪ではないが、framesから導出可能な冗長fieldではある。
6. 他の受け入れ条件の同じ穴 → あった。「capture外のselectionを画像で確認できたと装わない」は
   `.visible`決め打ちの時点で既に破られていたのに、検査がwire組合せテストだけだった。
   §14へ不在検査を追加済み。

## 8. C6の最重要受け入れ条件

> 何も選択せずに呼び出した通常Visionに、選択カード、選択用プロンプト、選択の不在・不確実性への
> 言及が一切現れない。

今回すり抜けた理由はここにある。既存の受け入れ条件は「選択がある時に何が起きるか」しか規定しておらず、
**圧倒的多数である「選択が無い時」を誰も検査していなかった。**

## 9. 修正後に残るデータモデル

この修正は機能の削減ではなく、**観測していない状態の削除**である。修正後、現行の
`VisionSelectionContext`は次のように収縮する（収縮の実施は§5-5）。

| フィールド | 現行 | 修正後 |
|---|---|---|
| `kind` | 3値 | **1値**（`text`）＝定数。フィールド自体が不要になる |
| `acquisitionCompleteness` | 3値 | resolverは元々`.complete`しか生成していない＝定数 |
| `acquisition` | 4値 | 2値（document / element-local）。モデルへの寄与は要検証 |
| `captureVisibility` | 4値 | `frames`から導出される値であり独立情報ではない |
| `text` | — | **必要** |
| `frames` | — | **必要** |
| `structures` | — | **必要**（意味・関係・操作可能性） |
| `wireTruncated` / `originalUTF16Units` | — | **必要**（切り詰めの明示） |

つまり本質的な形は「選択テキスト＋位置＋構造＋切り詰め」であり、残りは取得過程についての自己申告だった。
**この製品が難しいのは選択の合成ではなく、取得できたかどうかを正直に扱うことである。**
