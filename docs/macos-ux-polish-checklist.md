# macOS アプリ UX 磨き込みチェックリスト

最終更新: 2026-07-23 ／ ステータス: 現行

Apple HIG は原則と規約を示すが自動チェッカーではなく、"最後の1マイル"（ウィンドウが最前面に
来るか、権限行が実状態を映すか、再署名で許可が生き残るか等）は明文化されない。公開チェック
リスト（Mario Guzman / usagimaru）もこの領域に穴がある。本書は**その穴を埋める内部チェック
リスト**であり、リリース前に上から照合する。各項目は「なぜ」を1行添える。

## 使い方

- リリース候補ビルドを**クリーンな実機**（過去の許可・登録が無い状態）で1回動かして照合する。
  開発機は残留TCC/登録があるため“通ってしまう”。[[dev-prod-app-identity]] 参照。
- 個別項目の Apple 正式指針が要るときは `sosumi` スキルで公式docsを、Mac らしさの一般規約は
  `macos-design-guidelines` スキルを参照する。
- 公開資料: [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/) ／
  [Macintosh Checklist（Guzman）](https://marioaguzman.github.io/design/macintoshchecklist/) ／
  [Settings Window Guidelines（usagimaru）](https://zenn.dev/usagimaru/articles/b2a328775124ef?locale=en)。

## 1. 権限（TCC）フロー

- [ ] 権限行の状態は**ライブなAPI**（`AXIsProcessTrusted` / `CGPreflightScreenCaptureAccess` /
  `AVCaptureDevice.authorizationStatus`）を短間隔ポーリングで反映する。ハードコードや一度きりの
  判定にしない。理由: 設定側でトグルされても追従するため。
- [ ] **「トグルON なのに未許可」を検知**して案内する（署名不一致・再署名でTCCが失効する）。
  許可押下後、数秒 false のままなら「トグルOFF→ON／再起動」を提示。→ [[signing-tcc-identity]]、
  本リポは `PermissionsCoordinator.stalled` ＋ `PermissionsSetupView`。
- [ ] 画面収録は**許可後にアプリ再起動が必要**な旨を明示する（`CGPreflightScreenCaptureAccess`
  は再起動まで false）。
- [ ] 許可要求は**フォーカスのあるキーウィンドウから1つずつ**。メニューバー常駐アプリが前面窓
  無しで要求するとダイアログが別ディスプレイに散る。
- [ ] `NSMicrophoneUsageDescription` 等の **Usage Description が Info.plist にある**（無いと
  クラッシュ）。
- [ ] 拒否済み（denied）は system prompt が出ないので**設定ディープリンク**へ誘導する。

## 2. ウィンドウと配置

- [ ] ウィンドウ位置・サイズを**ハードコードしない**。SwiftUI コンテンツには
  `contentViewController.view.fittingSize` でサイズを合わせてから中央配置する。理由: 文言変更で
  高さが変わると中央がずれる。
- [ ] オンボーディング/権限窓は**全アプリの最前面**に出す（`level = .floating` ＋
  `orderFrontRegardless()` ＋ `activate(ignoringOtherApps:)`）。既存のシステム設定等の後ろに
  隠れさせない。必要なら `collectionBehavior` に `.canJoinAllSpaces` を付ける。
- [ ] **マルチディスプレイ**でマウス/アクティブ画面側に出す（`NSScreen` を明示選択）。
- [ ] 通常ウィンドウに**最小サイズ**を設定（目安 幅480–600 / 高さ320–400、サイドバー幅225–275）。
- [ ] フルスクリーン/Stage Manager/複数 Space で破綻しない。

## 3. システム設定連携

- [ ] 各権限の**設定ペインへ正しくディープリンク**（`x-apple.systempreferences:` URL）し、開けない
  場合のフォールバックURLも持つ。
- [ ] 設定を開く前に**自前で設定を前面化しない**（OSダイアログと二重にフォーカスが飛び、
  ダイアログが別画面に残る）。OSのプロンプトのボタンに処理を委ねる。

## 4. 署名・配布・アプリの正体

- [ ] Debug と Release で**bundle id / アプリ名を分離**（開発ビルドが本番のLaunch Services正体を
  奪わない）。モジュール名は固定。→ [[dev-prod-app-identity]]。
- [ ] Release は**常に同一 Developer ID・同一 designated requirement** で署名（変えると既存
  ユーザーのTCC許可が失効する）。
- [ ] notarization / staple / `spctl -a -vv` 検証を通す。Hardened Runtime 有効。
- [ ] 迷子のLaunch Services登録を掃除する手段を持つ（`tools/ls-cleanup.sh`）。

## 5. オンボーディング / 初回起動

- [ ] 初回に必要なものだけを出し、**全許可済みなら出さない**（軽さ優先）。
- [ ] 文言は**ユーザー設定に依存しない汎用トーン**（キー・ジェスチャを決め打ちしない。設定変更で
  嘘になる）。内部用語（コードネーム等）をユーザーに見せない。
- [ ] 完了状態が UI に明確に反映される（ボタン文言・チェック表示）。

## 6. 一般的な Mac らしさ

- [ ] メニューバー（App/File/Edit/View/Window/Help）とキーボードショートカットが妥当。
- [ ] 設定ウィンドウは modeless・`NSToolbar .preference`・「一般」先頭/「詳細」末尾・肯定形の
  文言（usagimaru）。設定はUIを散らさず1箇所に集約。
- [ ] ダークモード／`prefers-reduced-motion`／Dynamic Type 相当に対応。
- [ ] Xcode **Accessibility Inspector** で a11y を監査。

## 7. リリース前の実機検証

- [ ] クリーンな実機（別ユーザー or TCCリセット後）で初回起動を通す。
- [ ] マルチディスプレイ・別Space・フルスクリーンで権限窓とパネルの前面/位置を確認。
- [ ] アップデート（旧版を置換）後も許可・設定・データが保持される。
