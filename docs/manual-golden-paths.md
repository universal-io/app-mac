# リリース前 手動Golden Paths

最終更新: 2026-08-01 ／ ステータス: `0.2.1` build `5`正式公開済み／R10 C6検証中

署名付きアプリでのみ実施する。CLIの通常ビルドでは権限やKeychainを刺激しない。
R9 A7は自動検証とユーザーによる署名付き機能確認を完了し、`0.2.1` build `5`を正式公開した。
検証対象の`dist/Universal-IO-0.2.1-build5.dmg`と公開物は同一byte列で、SHA-256は
`637cd6cc029452db349f87e0a1cae4e6ecf214a3d458ba9ce0ad87ea6344cd69`。公開URLからの再取得でも
署名、staple、Gatekeeper、version/build、Universal binaryを確認済みである。
以下の未チェック項目は製品全体の継続的な運用・回帰確認であり、R9を未完了へ戻すものではない。

## 事前条件

- 本番Gatewayがdeploy済み。
- テストユーザーがログイン済みで利用枠がある。
- マイク、画面収録、Accessibilityを許可済み。
- ConsoleでUniversal I/Oのエラーを確認できる。

## Compose

- [ ] 右Shift 2回で入力パネルが開き、下書きへフォーカスする。
- [ ] Enterで下書きが対象アプリへ送信される。
- [ ] レビュー完了後も下書きへフォーカスが残り、Enterは下書きを送信する。
- [ ] 明示的にレビュー欄へ切り替えた時だけレビュー案を送信できる。
- [ ] 入力履歴は初期状態で閉じており、開いて選ぶと送信せず下書きへ復元する。
- [ ] レビュー前はレビュー枠を表示しない。
- [ ] Gatewayエラーはパネル全体のエラーとして表示する。
- [ ] リッチテキスト、画像、ファイル、複数itemをclipboardへ入れてから送信すると、対象欄へ本文が
  1回貼り付けられ、clipboardには送信本文だけが残り、時間差で過去内容へ戻らない。
- [ ] Compose送信直後に別アプリで⌘Cすると、その新しい内容が後から上書きされない。
- [ ] Accessibilityを拒否した状態で送信すると、本文がclipboardへ残り、手動⌘Vと設定導線が
  明示される。手動⌘Vで同じ本文を貼り付けられる。

## 音声入力

- [ ] 右Shift長押しで録音し、離すと本番 `/api/ai/transcribe` の結果が下書きへ入る。
- [ ] Visionパネルでも文字起こし結果が質問欄へ入る。
- [ ] 無音・短すぎる録音は送信せず終了する。
- [ ] 未ログイン時は端末APIキーを探さず、ログイン確認エラーになる。

## Vision / Copilot

- [ ] 他アプリで文章または意味のある要素を選択して右Shift 2回すると、同じVisionパネルに
  対象カード、capture上の枠、対象を優先した初期説明が表示される。
- [ ] 編集可能欄に選択が無い時はCompose、それ以外は通常Visionへ進む。
- [ ] AXで選択を取得できない時も合成⌘Cへfallbackせず、通常VisionまたはComposeへ退化する。
- [ ] 右Shift起動前後で標準clipboardのchangeCountと全flavorが変化しない。
- [ ] カメラまたは空下書きから撮影し、選択範囲の画像が表示される。
- [ ] 本番 `/api/ai/vision` が初期説明を返す。
- [ ] 追加質問が同じcaptureと履歴を使って回答される。
- [ ] 操作案内で有効なcandidateがある時だけ赤枠が出る。
- [ ] 「案内を開始」で小型stripへ移行し、ユーザー操作後に新しい画面を再評価する。
- [ ] VisionとCopilotが同じ一次・二次モデル順序とfallback noticeを使う。
- [ ] 目的達成、判断が必要、回数上限の各状態で誤った自動操作を行わない。
- [ ] endpoint欠落時に404 HTML本文を表示せず、配備不足の明示エラーになる。
- [ ] パネル終了後に現在のVision一時画像が削除され、異常終了分も次回起動時に削除される。

## 認証・設定・データ

- [ ] session期限切れで再ログインを案内する。
- [ ] 設定画面は本番Product APIだけを表示し、local/BYOK/Navigator切替を持たない。
- [ ] 履歴OFFで新しい履歴を保存しない。
- [ ] AでログアウトしてBでログインしても、Aの履歴・下書きが表示・注入・同期されない。
- [ ] アカウント画面のusageが成功リクエスト後に更新される。
- [ ] 使い捨てテストユーザーで退会確認をキャンセルでき、確定後は再ログイン不可かつMac内の
  履歴・下書きが消えている。有効契約中の退会は拒否される。
- [ ] OpenAI ProjectとGroqのData ControlsでZDRが有効であることを、確認日と担当者付きで記録する。

## 課金（Stripe）

sandbox鍵で検証した。**本番鍵へ差し替えたら全項目を再実施する** — webhook送信先とprice idが
別物なので、sandboxで通ったことは本番の保証にならない。

- [x] 製品サイトの料金ページ →`/billing/start`→ Checkout で購入でき、`plan`が`standard`へ上がる
  （2026-07-29）。
- [x] webhookが全イベントに`applied_at`を書き、`error`が残らない（2026-07-29、1〜1.5秒で適用）。
- [x] ポータルからの即時解約で`plan='free'`、`status='active'`、`stripe_subscription_id`がNULLになる
  （2026-07-29）。`status='canceled'`を書かない・契約IDを残さないという2点の実地確認である。
- [x] 期間終了時解約で`plan='standard'`のまま`cancel_at`が入り、契約状態が
  「解約手続き完了（◯年◯月◯日まで有効）」と表示される（2026-07-29）。
- [x] アプリ「料金プラン」のボタンが、有料プランでは「サブスクリプションを解約…」と表示される
  （2026-07-29）。「お支払い管理」では解約経路だと気づけなかったため変更した。
- [x] Webで購入してアプリへ戻ると、前面化だけでプランが反映される（2026-07-29）。
- [ ] 解約直後にAI操作を行い、無料枠が使えること（entitlementが`canceled`になっていないこと）を
  実際の応答で確認する。
- [ ] 解約後に退会でき、契約ID残存で`ACTIVE_SUBSCRIPTION`拒否にならない。
- [ ] 契約済みで`/billing/start`を開くと`SUBSCRIPTION_EXISTS`表示になり、その場のボタンで
  ポータルへ行ける（`/admin`へ送っていない）。
- [ ] 同じwebhookイベントを再送すると`bs_stripe_events`で無視され、二重適用されない。
- [ ] 管理画面「設定」の実効モードが、実際に置かれている鍵の接頭辞と一致する。
- [ ] Stripe顧客ポータルのキャンセル設定が「期間終了時」になっている（テストで「即時」に
  変えたまま出荷しない）。

## 権限・障害

- [ ] 各権限を個別に拒否した時、無限プロンプトやクラッシュにならない。
- [ ] Gateway停止・タイムアウト時に別経路へ切り替えず、同じパネルで明示的に失敗する。
- [ ] 各AI機能で一次モデルを失敗させると二次モデルで成功し、使用した両モデルを含む
  共通の切替noticeが表示される。
- [ ] 各AI機能で一次・二次を両方失敗させると、三番目を試さず共通エラーが表示される。
- [ ] オフライン復帰後、パネルを開き直して正常に再実行できる。
- [ ] アプリ再起動後も権限ダイアログが不必要に反復しない。

## リリースビルド

- [x] 追跡ファイルへの秘密情報混入と、usage／ログへの入力本文・画像・音声・画像パス・
  アプリ名・ウインドウタイトル漏洩を点検（2026-07-22）。
- [ ] 操作中のクラッシュと異常終了を点検。
- [x] Developer ID署名とHardened Runtimeが有効（2026-07-22、Universal binaryで確認）。
- [x] アプリとDeveloper ID署名済みDMGのnotarization、staple、Gatekeeper評価が成功
  （2026-07-22、`0.1.0` build `2`）。
- [ ] DMGからApplicationsへコピーして初回起動できる。
- [x] `0.1.0` build `2`、不変配布URL、`v0.1.0`タグ（`700f607`）が一致
  （2026-07-22）。

## 外部テスターへの候補版配布

- [x] 本番GatewayをmacOSクライアントより先にdeployし、旧クライアントとの互換性を維持した
  （2026-07-25）。
- [x] `0.1.1` build `3`として署名・notarization済みDMGを公開した。
- [ ] テスターへ、Xcode版や旧Applications版を終了してから候補版をApplicationsへコピーするよう案内する。
- [ ] ZDRの運用確認が終わるまでは、実名・私信・業務機密ではなくテスト用データを使用してもらう。
- [ ] クラッシュ、Keychain許可の反復、アカウント切替、オフライン復帰、退会を重点確認する。
- [x] 不変URLへ公開し、latest aliasを切り替え、`v0.1.1`タグを付けた。

## `v0.2.0` 正式採用

- [x] Vision / Copilot、自動返信、AI性能共通化を実装しmainへ統合した（2026-07-25）。
- [x] Web production buildとmacOS unit testを通過した。
- [x] `0.2.0` build `4`をDeveloper ID署名・notarizationし、不変URLへ公開した
  （2026-07-25、Apple notary Accepted）。
- [x] 公開DMGを再ダウンロード・マウントし、署名、staple、Gatekeeper、`0.2.0` build `4`、
  Universal binary、SHA-256一致を再検証した。
- [x] 公開URLを`0.2.0` build `4`へpromoteし、リリース記録コミット`3ce1690`へ
  Gitタグ`v0.2.0`を付与した。

## `v0.2.1` Focused Vision正式採用

- [x] TransformをFocused Visionへ統合し、clipboard退避・復元と起動時の合成⌘Cを撤去した
  （2026-07-30）。
- [x] macOS 28 unit test、署名なしDebug build、Web lint／TypeScript／production build、
  開始tagからの差分監査を通過した（2026-07-30）。
- [x] 署名付きアプリのFocused Vision、通常Vision、Compose、clipboard安全化の機能確認で
  問題なしとユーザーが確認した（2026-07-30）。
- [x] `0.2.1` build `5`をDeveloper ID署名・notarizationし、検証した同一DMGを不変URL、
  version alias、公開URLへpublish／promoteした（2026-07-30）。
- [x] 公開DMGを再取得し、署名、staple、Gatekeeper、version/build、Universal binary、
  SHA-256一致を再検証した（2026-07-30）。
- [x] mainと本番Gatewayを更新し、現行4 AI routeの応答と旧`/api/ai/transform`の404を確認した
  （2026-07-30）。
- [x] リリース記録コミットへGitタグ`v0.2.1`を付与した（2026-07-30）。

## R10 Selection Extension C6候補検証

`feat/vision-selection-extension`の候補検証である。後方互換Gatewayは2026-08-01にmacOS候補版より
先に`main`／本番へ配備した。以下の実機項目は署名付き候補版で行い、旧Gatewayで得た回答を
R10の合否に使わない。

- [x] macOS 41 unit test、Gateway 14 test、Web lint／TypeScript／production build、署名なしDebug
  buildを通過した（2026-08-01）。
- [x] 通常VisionとSelection Extension付きrequestを比較し、`selection`以外の画像、turns、
  candidates、diagnostics、identityが同一であることを固定した（2026-08-01）。
- [x] 開始tag差分に別endpoint、別model route、長期flag、短命probe、起動時clipboard／合成⌘Cの
  再混入が無いことを確認した（2026-08-01）。
- [x] document textを読む前にsecure descendantを検査し、存在時はdocument selectionを読まない
  順序をtestで固定した（2026-08-01）。
- [ ] Chrome Gmailで件名＋複数node本文を選び、カードと回答が全文を扱い、件名と選択状態の報告だけで
  終わらない。
- [ ] Safari Gmailで公開AX本文が取れない時、同じVisionが`visualOnly`へ安全に退化する。
- [ ] TextEdit、Apple Mail、Chrome Slack、Electron SlackまたはVS Codeで、単一／複数node、
  編集欄、順方向／逆方向、viewport内／画面外の選択取得または安全な退化を確認する。
- [ ] VoiceOver、Full Keyboard Access、Increase Contrast、Reduce Transparency、Reduce Motionで
  選択全文カード、展開Button、複数枠、読み上げ順を確認する。
- [ ] Accessibility拒否／画面収録拒否、secure field混在、prompt模倣本文、複数display、capture外だけの
  selectionで安全な退化と事実に沿う表示を確認する。
- [ ] リッチテキスト、画像、ファイル、複数itemをclipboardへ置き、通常Vision、Selection Extension、
  Copilotの前後でchangeCountと全flavorが変わらないことを確認する。
- [ ] 同一端末・同一対象の`v0.2.1`と候補版で右ShiftからGateway dispatchまでを計測し、warm時
  p50 +50ms以内、p95 +150ms以内を確認する。cold Chromiumは既存2秒deadlineを超えない。
