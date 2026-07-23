# 開発版と本番版のアプリ正体を分ける（macOS）

最終更新: 2026-07-23 ／ ステータス: 現行

macOS アプリを開発していると、開発ビルドと本番アプリの「正体」が同一のままになりがちで、
これが Launchpad にアプリが出ない・登録が無限に溜まる、といった問題を起こす。これは
Xcode/XcodeGen の既定では防げず、明示的に設定して初めてベストプラクティスが効く領域である。
本書はその原因と対処を、他プロジェクトでも再利用できる形で残す。

## 症状

- DMG からインストールし `/Applications` に置いたのに、Launchpad に出てこない。
- Finder の `/Applications` には存在し、そこからは起動できる。
- `open -b <bundle id>` が意図しない古いコピーを開く。

## 本質的な原因

macOS の Launch Services は、見つけたアプリ bundle を **パス単位** で登録する。そして
**ビルドのたびに自動登録される**（Xcode のビルド手順に `RegisterWithLaunchServices` =
`lsregister -f` が含まれる）。

問題は、開発ビルドも検証ビルドも本番アプリも **同じ正体**（同一 `CFBundleIdentifier` ＋
同一アプリ名）だった場合に起きる。

1. **正体の衝突**: 同じ bundle id を持つ複数のコピー（DerivedData / `/tmp` / マウント中の
   DMG / `/Applications`）を、macOS は「同一アプリ」として名寄せする。名寄せ先が
   `/Applications` 以外（`/tmp` や DMG）になると、Launchpad は正規の場所しか並べないため、
   本番アプリが表示から消える。
2. **登録の蓄積**: ビルド出力を毎回別パス（`/tmp/xxx-derived` 等）に吐いていると、同一正体の
   登録が何十件も溜まり、名寄せをさらに不安定にする。

つまり「インストールで増える」のではない。ドラッグでの `/Applications` 上書きは同じパスなので
増えない。**増えるのは、散らばった場所に吐かれた開発・検証ビルドの登録**である。

## ベストプラクティス

### 1. 開発版と本番版の正体を分ける

構成（Debug / Release）ごとに **bundle id とアプリ名を分ける**。開発ビルドが本番アプリの正体を
決して奪わないようにする。

- Debug: `com.example.app.dev` ／ 名前 `Example Dev`
- Release: `com.example.app` ／ 名前 `Example`

**署名は安定させたまま**にすること。TCC（画面収録・アクセシビリティ・マイク）と Keychain の
「常に許可」は「bundle id ＋ 署名」に紐づく。id を分けても署名が安定していれば許可は恒久化する
（許可先が「開発版」「本番版」に分かれ、それぞれ一度許可すれば以後保持される）。ad-hoc 署名は
ビルドごとに CDHash が変わり許可が毎回死ぬため使わない。

**Swift モジュール名は固定する**。`PRODUCT_NAME` は Swift のモジュール名も決めるため、Debug 名を
`Example Dev` にするとモジュールが `Example_Dev` になり、テストの `@testable import Example` が
壊れる。`PRODUCT_MODULE_NAME` を明示して固定する。

`TEST_HOST` は host アプリの構成別 `PRODUCT_NAME` に一致させる（テストは通常 Debug で走る）。

### 2. ビルド出力先を固定する

CLI 検証で毎回 `/tmp/foo-derived` のような新しいディレクトリを作らない。**固定した 1 つの
DerivedData パス**（例: プロジェクト外の scratchpad）に集約する。散らばり＝登録の蓄積を止める。

### 3. 掃除スクリプトを用意する

迷子登録を一括で忘れさせる手段を持つ。本リポジトリでは
[`tools/ls-cleanup.sh`](../tools/ls-cleanup.sh)。`/Applications` の本番アプリ以外の
「Universal IO」登録を `lsregister -u` で解除し、本番アプリを再登録する（ファイルは消さない。
開発ビルドは次回ビルドで自動再登録される）。

## このプロジェクトでの実装

- [`project.yml`](../project.yml) の `BombSquad` ターゲット:
  - base: `PRODUCT_BUNDLE_IDENTIFIER: com.universal-io.mac` / `PRODUCT_NAME: Universal IO` /
    `PRODUCT_MODULE_NAME: Universal_IO`（Release はこれを継承）
  - Debug 上書き: `PRODUCT_BUNDLE_IDENTIFIER: com.universal-io.mac.dev` /
    `PRODUCT_NAME: Universal IO Dev`
  - `BombSquadTests` の `TEST_HOST` は構成別（Debug=`Universal IO Dev.app`、
    Release=`Universal IO.app`）
- 掃除: [`tools/ls-cleanup.sh`](../tools/ls-cleanup.sh)（`--dry-run` 対応）

開発ビルドは `/Applications` に入れる必要はない。Xcode の Run も CLI ビルドも DerivedData から
起動できる（署名が安定していれば TCC も保持）。`/Applications` に入るのは DMG からの本番
インストールだけ。

## 派生症状: TCC トグルは ON なのにアプリは「未許可」

同じ正体（bundle id）を署名違いのビルドで許可すると、**システム設定のトグルは ON なのに
アプリの許可判定 API が false を返す**ことがある。TCC は許可エントリに「どの署名か
（code signing requirement）」も記録し、`AXIsProcessTrusted()` /
`CGPreflightScreenCaptureAccess()` は **実行中アプリの署名** が記録要件を満たすか検証するため。
トグルは bundle id/パスで表示されるので ON に見える。

- 典型: アクセシビリティ／画面収録を開発ビルド（Apple Development 署名）で許可した後、本番版
  （Developer ID 署名）を起動すると、トグル ON・API false → 許可ボタンが出続ける。マイクは
  AVFoundation で本番版自身が許可していれば署名一致で `.authorized` になる、という非対称も起きる。
- **本番でも起こる**: リリースを別証明書で再署名すると、既存ユーザーの許可が失効し同じ症状になる。
  Release は常に同一 Developer ID・同一 designated requirement で署名し続けること。
- **復旧（開発機の残留）**: `tccutil reset Accessibility|ScreenCapture|Microphone <bundle id>` →
  本番アプリを再起動して入れ直す。画面収録は許可後にアプリの一度きりの再起動が必要。
- **UX 保護**: 許可ボタン押下後、数秒しても API が false のままなら「一覧にある場合はトグルを
  OFF→ON、またはアプリ再起動」と行内で案内する。本リポジトリでは
  [`PermissionsCoordinator`](../BombSquad/Services/PermissionsCoordinator.swift) の `stalled` 判定と
  [`PermissionsSetupView`](../BombSquad/Views/PermissionsSetupView.swift) のヒント行で実装。クリーンな
  環境では許可が即座に通るので出ない。

## 他プロジェクトへの適用チェックリスト

- [ ] Debug に固有の `PRODUCT_BUNDLE_IDENTIFIER`（`.dev` 等）とアプリ名を設定した
- [ ] `PRODUCT_MODULE_NAME` を固定して `@testable import` を守った
- [ ] `TEST_HOST` を構成別 `PRODUCT_NAME` に一致させた
- [ ] 署名は安定した証明書（ad-hoc 不可）で TCC/Keychain 許可を恒久化した
- [ ] CLI/検証ビルドの出力先を固定 1 パスに集約した
- [ ] 迷子登録の掃除スクリプトを用意した

## 手動復旧手順（Launchpad に出ない時）

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# 1. マウント中の配布 DMG があれば取り出す
hdiutil detach "/Volumes/<Volume Name>"

# 2. 現在の登録を確認
"$LSREG" -dump | grep -oE "path: +.*<App>[^/]*\.app" | sed 's/path: *//' | sort -u

# 3. /Applications 以外を登録解除（tools/ls-cleanup.sh が自動化）
"$LSREG" -u "<迷子のパス>"

# 4. 本番アプリを再登録し Launchpad を更新
"$LSREG" -f "/Applications/<App>.app"
killall Dock
```

注: `lsregister -kill` は現行 macOS で廃止されている。全体リセットではなく、迷子登録を個別に
`-u` で解除するのが安全。Launchpad のアイコン配置ごと初期化する
`defaults write com.apple.dock ResetLaunchPad -bool true` は配置が失われるため最終手段。
