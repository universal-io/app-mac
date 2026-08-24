# セッション引き継ぎ

**この1本だけを、常に次のセッションのためだけに保つ。** 役目を終えた記述は消し、増やさない・
分けない・積み上げない。現在の設計は [README](README.md) と
[docs/universal-io-master-plan.md](docs/universal-io-master-plan.md) が正本で、ここはその上に乗る
「いま何をすべきか」だけ。

最終更新: 2026-08-24

---

## いまどこにいるか

**R14（実画面の上で指して聞くVision）が実機で動いている。** 右Shift 2回で実画面に覆いが乗り、
入った瞬間に解説が始まり、クリックするとその場所についての解説がバブルに出る。質問も打てる。
102 unit testが通り、`main`に入っている（未タグ、`0.2.3`）。

**動いた証拠**: アクティビティモニタの「プロセス名」列見出しをクリックし、その列見出しについて
正確に答えた。座標変換とマークの焼き込みは成立している。

---

## 🔴 最大の課題: 指したものが一度も解説されない

**実機で複数回試して、選んだものが解説されたことが一度も無い。** 必ず「その周辺の何か」に移る。
ときどき隣に落ちるのは許容範囲だが、**一度も成功しないのは精度の問題**である。

### まずこれを作る: 送信したバイトを見る道具

**app-iosが同じ問題を1枚で決着させた道具が、macOSには無い**（app-web README「座標の検証の道具が
無い」）。`../app-ios/docs/investigation-highlight-offset.md` を**読んでから**着手すること
（読まずに独自の対処を作って、解決済みの問題を解き直した記録がある）。

作るもの: **Gatewayへ送った画像そのものをファイルへ書き出す**。`encodeForWire`が返す base64 を
デコードして保存するだけでよい。それを見れば、次の2つが1回で分かれる。

| 送信画像のマークの位置 | 意味 |
|---|---|
| クリックした場所に**ある** | 座標は正しい。プロンプトかモデルの問題（下記） |
| クリックした場所に**ない** | こちら側の座標バグ。以下の疑い順で追う |

### 座標が疑わしい場合の順序

1. **`captureMatchingScope(of:)` が覆っている画面と別のディスプレイを撮っていないか。**
   あれは*元の*attachmentの`captureRect`からディスプレイを決める。2画面環境で
   `ActiveDisplay.screen()`と食い違うと全部ずれる。`capture.display`の記録にディスプレイIDを
   足して確認する。
2. `screenFrame`（`NSScreen.frame`、Cocoa）と`captureRect`（`CGDisplayBounds`、CG）の対応。
   変換は`VisionPointerResolver`の2関数だけにあり、単体テスト12件で固定してある。
   **新しい式を書かないこと** — 過去に二次ディスプレイのオフセットで2回刺されている。

### プロンプト・モデル側が疑わしい場合

- **🔴 焼き込むリングが大きすぎる可能性が高い。** 半径は`unit * 0.022`（`unit`＝送信画像の長辺）で、
  1512pt幅なら**半径33pt・直径66pt**。アクティビティモニタの行高は20pt前後なので、**リング1つが
  3行を囲む**。モデルには「リングが乗っているコントロール」と指示しているが、囲まれた物が複数ある。
  十字は`半径×0.4`＝13ptしかなく、視覚的にリングが勝っている。
  試す価値がある順: ①リングを小さくする ②中心に不透明な小さな点を足す ③リングをやめて十字だけにする。
  **Web版は長辺1536の画像で調整した値なので、そのまま移植した比率が正しいとは限らない。**
- **プロンプトが隣へ逃げることを許している。** `api-gateway/lib/server/vision-prompt.ts` の
  pointerブロックに「If the exact spot is empty, use the nearest meaningful element」とある。
  これは*licence*であって、精度を上げたいなら弱める判断がある。
- **AXが測った要素の名前をモデルへ渡していない。** クライアントは`AXUIElementCopyElementAtPosition`
  を使っていない（未着手）が、`VisionPointerResolver.candidate(at:in:)`で「点を含む最小の候補」は
  すでに得ている。その`role`と`label`をpointerブロックへ入れれば、モデルは推測せず固定できる
  （**Gateway側の変更が要る**。api-gatewayはmainへのpushが本番デプロイ）。
- Gatewayは候補の矩形をモデルへ渡さない（`app/api/ai/vision/route.ts:175-182`）。
  だから**モデルにとっての「ここ」は焼き込んだマークだけ**である。この前提を忘れないこと。

---

## 🔴 フリーハンドで囲む線が失われている

**過去にあり、Web版にもある**（`app-web/docs/pointing.md`「なぞって囲む」、
`app-web/lib/marker.ts`の`loop()`）。R14で覆いを入れたときに、**ドラッグを実装しなかった**ため
消えた。現状の覆いは`mouseDown`だけを見ている（`VisionPointingOverlay.swift`の`PointingCanvas`）。

受け皿はすでに全部ある:

- `VisionPointer.Kind.region` と `stroke`（描いた軌跡そのもの。wireには載せず焼き込みにだけ使う）
- `VisionPointerMark.burn` は `stroke` があれば軌跡を閉じて描き、無ければ矩形を描く
- Gateway契約の`pointer`は`region`を受ける

やること: `PointingCanvas`に`mouseDragged`/`mouseUp`を足し、8pt以上動いたらドラッグとして扱い、
軌跡を覆いへ描きつつ`VisionPointer(kind: .region(bounds), stroke: path)`を作る。
**直線かどうかで意図を判別しない**（文字列を横になぞる操作は「この行」を指す正当なジェスチャー。
Web版 solo-mode.md §1）。

---

## バブルの表示品質（実機で見た残り）

1. **文字が行の途中で切れる。** 4行目が半分で切れる。スクロールはできるようになったので読めるが、
   **文字の途中で切るのは品質が低い。行の切れ目で切ること。** 高さを行高の整数倍へ丸める
   （`maxAnswerHeight`を行高で割って切り捨てる）のが素直。
2. **表示エリアが今の3倍必要。** `VisionBubbleView.maxAnswerHeight`は現在360pt。画面高の半分程度を
   上限にする案がある。
3. **本文表示エリアと入力フォームが背景に同化して分からない。** 薄いグレーの地を敷いて、
   「読む場所」と「打つ場所」が面として分かれて見えるようにする。

---

## 未確認のまま残っていること

- **覆いを出したまま撮った画像に、覆いが写り込んでいないか**（`capture.display`の`excluded`が0なら
  写り込んでいる。コードでは自アプリ除外済み）
- **日本語IMEのエラー行**（`IMKCFRunLoopWakeUpReliable`）が本体でも出るか。probeは.appバンドルでは
  なかったので条件が違う
- **撮影1回の所要ms**（`capture.display`の`ms`）。毎クリック撮り直しが体感に耐えるか、
  「変わっていなければ再利用」の最適化が要るかを決める数字
- **ネイティブメニューが開いた画面で覆いを出すとメニューは閉じるか**（`capture.display`の
  `menu=true/false`が普段の利用で溜まる）
- 覆いがフルスクリーンアプリ・Mission Control・Stage Managerでどう振る舞うか
- スポットライトの`reach = 672pt`はWeb版の値をそのまま持ってきたもので、実画面での見え方は未調整

---

## 別セッションで扱うと決めたもの

- **未ログイン初回起動の第一印象。** 現在は「画面の読み取りを開始できませんでした。」だけが出る。
  起動の合図・初回の挨拶・その場でのサインインを設計する。正本はマスタープランの
  「次期改善候補 › 未ログイン初回起動の第一印象」
- Copilotは今も従来のパネル／ストリップを使っている（覆いへは載せていない）。R14の範囲外

---

## 手を出す前に知っておくべきこと

| 事実 | なぜ重要か |
|---|---|
| **キーチェーンのプロンプトは原因が分かって直した** | 診断手順は [AGENTS.md](AGENTS.md)。**新規ユーザーは1回も聞かれない**（作成者はACLに載るので無音。実測済み） |
| **CLI検証ビルド（`CODE_SIGNING_ALLOWED=NO`）の`.app`を起動しない** | 署名が無くTCC許可もキーチェーンACLも成立しない。実機確認はXcodeから |
| **CLIビルドは必ず`-derivedDataPath`で隔離する** | 既定のDerivedDataを汚すとTCCが毎ビルド死ぬ |
| **座標の変換は`VisionPointerResolver`の2関数だけ** | 3つ目の式を書くと二次ディスプレイでずれる。12件のテストで固定してある |
| **Gatewayは候補の矩形をモデルへ渡さない** | AXは「バブルの置き場所と枠」の実測。モデルの根拠は焼き込んだマーク |
| **AX候補は操作系13ロールだけ** | 本文・画像・グラフ・canvasには当たらない。候補ゼロは正常な結果 |
| **枠が来たら自分の印は引っ込む** | だから印の位置を測る検証はクリック直後に行う。回答後には印が無い |
| **指し直しは新しい主題**（`turns`を捨てる） | Web版は捨てなかった版でタップのたびに最初の回答が返った |
| **`.nonactivatingPanel`＋`makeKey()`は同期的にキーを取る** | `NSApp.activate`は非同期で、出した直後はまだキーでない（実測） |
| **覆いに描いた印は撮影に写らない** | 自アプリ除外はアプリ単位。だから焼き込みは選択肢ではなく必然 |
| **`api-gateway`はmainへのpushが本番デプロイ** | プロンプトを触ると公開中のmacOSクライアントの挙動も変わる |
| **gitは必ず`git -C <絶対パス>`** | シェルは毎回app-macへ戻る。過去に2回、別リポジトリのコミットが混入した |

---

## 検証

```bash
xcodegen generate
xcodebuild -project BombSquad.xcodeproj -scheme BombSquad -configuration Debug \
  -derivedDataPath /tmp/universal-io-derived -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

実機は**Xcodeから Run**する。動作記録は「管理画面 › 設定 › 動作記録」。R14で足した記録は
`capture.display`（ms・画素数・除外数・メニューの有無）と`vision.point`（候補数・AXヒットの有無）、
`auth.keychain`（restored / absent / refused）。
