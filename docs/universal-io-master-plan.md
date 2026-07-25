# Universal I/O マスタープラン

最終更新: 2026-07-23 ／ ステータス: `v0.1.0` 公開済み・`v0.1.1` 候補準備

## 製品

Universal I/O は、人が情報を送る・受け取る・画面上で行動する間に入り、意図と表現を
整える中間レイヤーである。自律操作ではなく、最終判断と操作はユーザーが行う。

製品surfaceは4つだけとする。

1. Compose: 自分の文章を作り、必要ならレビューして送信する。
2. Transform: 受信文章を理解し、返信や次の行動を準備する。
3. Vision: 現在の画面を読み、質問へ答える。
4. Copilot: 画面上の次の一手を示し、ユーザー操作後に再評価する。

## 現行アーキテクチャ

```text
macOS UI
  └─ SessionCoordinator
       ├─ ComposeSession  ── /api/ai/review
       ├─ TransformSession ─ /api/ai/transform
       ├─ VisionSession ──── /api/ai/vision
       └─ GatewayTranscriber /api/ai/transcribe
                              │
                       Production Gateway
                              │
                       AI providers + Supabase
```

設計原則:

- 状態遷移は `SessionCoordinator` に集約する。
- 各surfaceはSessionとViewを1組だけ持つ。
- AIは本番Gateway経由だけ。macOSからプロバイダーを直接呼ばない。
- ローカルGateway、BYOK、旧endpoint、shadow実行、macOS側のfallbackを持たない。
- 全AI機能はGatewayの単一モデルルーターで一次・二次モデルを指定する。一次失敗時だけ二次を
  1回実行し、切替時はユーザーへ共通noticeを表示する。両方失敗時は共通エラーを返す。
- 音声入力はGroq Whisper Large V3 Turboと16 kHz mono WAVを本番経路とする。
- 全AI機能は共通`GatewayAIWarmup`から、アプリ起動時と各機能へ入る直前に同一routeの
  認証・quota前処理をウォームする。Gateway instance内で5分キャッシュし、providerは呼ばないため
  ウォームアップ自体は課金・usage記録しない。
- 全AI routeのusage記録は共通処理で応答後に実行する。SSEも最終結果をクライアントへ返してから
  記録し、運用上のDB書き込みをユーザーの待ち時間から外す。
- Visionは画像、同一captureの候補、会話を1回のVLM呼び出しへ渡す。
- Composeの先回り文案は共通判断、ユーザーPersona、任意のアプリ文脈を独立した添付として渡す。
  最新メッセージの話者・宛先・行為主体を確定してから、現在のユーザー視点で文案を作る。
  アプリ文脈はbundle ID、アプリ名、ウインドウタイトルから選び、現行はSlackとGmailを補足する。
  検出条件と指示は製品単位の既定パッケージとして分離し、複数製品を持つ提供元名では束ねない。
  文案より先に話者、宛先、ユーザーの立場、添付所有者、依頼、返信意図を構造化出力させる。
  Gateway応答にはprompt versionと適用context packageを含め、実行時の適用有無を観測可能にする。
- モデル結果が選んだcandidate IDだけを、コードが保持する矩形へ変換する。
- Visionの`guide`回答はcandidate矩形の有無にかかわらずCopilotを開始できる。矩形は
  ハイライトにのみ使い、取得できないWeb/Electron画面でも文章案内とクリック後の再評価を続ける。
- 「どこから」「どうやって」「取得」「設定」等の操作意図はローカルでも判定し、モデルが
  `answer`へ分類しても任意のCopilot開始導線を出す。Gateway側も同種の質問を`guide`へ寄せる。
- Composeの自動返信モード見出しとオン／オフスイッチは常設し、切替は開いているセッションへ
  即時反映する。オフ時は説明用プレースホルダーを出さず、見出しより下を畳む。ただし完成済みの
  文案は現セッション中だけ保持・編集・送信でき、設定は次回のComposeから自動生成を止める。
- 入力履歴の閲覧は管理画面だけに置く。Composeパネルでは履歴を先読み・再読込・復元しない。
- 実験は短命ブランチで完結し、本番ツリーへ残さない。

モデルルーティングの正本は `web/lib/server/ai-routing.ts` だけとする。個別engine、route、
macOS、環境変数にモデル名やfallback順序を重複させない。Admin Consoleはこの正本を読み、
各機能の一次・二次、vendor、model ID、API方式をそのまま表示する。

## データ境界

- 認証、entitlement、usage、同期メモリはSupabaseを正とする。
- 下書きとCompose送信履歴はMacローカル。履歴上限は100件。Transformは一切履歴化しない。
- スクリーンショット、音声、周辺コンテクストは処理用で、Gatewayへ恒久保存しない。一時画像は
  セッション終了時、異常終了で残った画像は次回起動時に削除する。
- 同期メモリを削除した時は、同期用tombstoneからも本文と相手名を消去する。
- ローカル履歴・下書き・メモリはSupabase user ID単位で物理分離し、ログアウト時にDBを閉じる。
- Supabase認証セッションはUniversal I/O専用のmacOS Keychain service/keyへ保存する。旧SDK共通
  keyは一度だけ移行し、unit testのhost起動ではKeychainへアクセスしない。
- メモリ同期はdirty差分とserver cursorを使う。Gateway時刻によるbase version競合検出を行い、
  競合時は端末側・クラウド側の選択をユーザーへ提示する。
- usageと運用ログには入力本文、画像・音声、画像パス、アプリ名、ウインドウタイトルを保存しない。
- request単位usageは90日で月次rollupへ集約して削除する。退会時はユーザーおよび個人tenantに
  cascadeするデータと、Mac内のユーザー専用領域を削除する。
- APIキーはGateway環境だけに置く。macOSのKeychainへAI APIキーを保存しない。
- OpenAIへの保存対応endpointは`store: false`を必須とし、OpenAI/GroqのZDR有効状態は
  provider管理画面のリリースチェック対象とする。

## リリースまでのマイルストーン

### R1 — 経路一本化（完了、2026-07-18）

- 現行Visionを正式な `VisionSession` と `/api/ai/vision` に昇格。
- 旧Vision、Navigator v3/v4、Run、shadow、harness、fixture、local Gateway、BYOKを削除。
- Compose、Transform、Transcribe、Memoryを本番Gateway専用に統一。
- 実験資料とアーカイブをGit履歴へ戻し、作業ツリーから削除。

### R2 — 機械検証（完了、2026-07-22）

- XcodeGen生成が成功する。
- macOS Debugを署名なしでビルドできる。
- Web lint、TypeScript、production buildが成功する。
- 本番route一覧とクライアントendpointが一対一で一致する。
- リポジトリ内に旧経路の参照が残っていない。

### R3 — 本番E2E（進行中）

- ログイン、レビュー、音声入力、受信変換、Vision、Copilot、履歴、メモリを実機確認。
- 本番Gatewayで全routeがJSON/SSE契約を返し、404 HTMLを返さない。
- 全AI機能で実モデルと `fallback_used` をクライアントとusageで確認する。
- 一次失敗時は二次で成功して共通noticeが表示され、両方失敗時は共通エラーになる。
- 権限再起動、ネットワーク障害、期限切れsessionで明示的エラーになる。

### R4 — リリース品質

- [manual-golden-paths.md](manual-golden-paths.md) を全項目実施。
- UI文言、フォーカス、キーボード操作、VoiceOverラベルを確認。
- クラッシュ、秘密情報、ログへの入力本文・画像パス漏洩を点検。
- 署名、Hardened Runtime、notarization、DMG、更新導線を確認。

### R5 — 公開（`v0.1.0` 完了、2026-07-22）

- 正式版は `0.1.0`（build `2`）、Gitタグは `v0.1.0`、ソースは `700f607`。
- main、本番Gateway、Webサイトをdeploy済み。
- Developer ID署名、notarization、staple、Gatekeeper評価済みDMGを配布。
- 公開DMGはversion／build別の不変URLへ保存し、Webサイトは不変URLを直接参照する。
  version aliasとlatest aliasも互換用に更新する。
- 公式DMGのSHA-256は
  `e0b08385d11cb591019490a93a5bfc2aa3b0f510ef577f116ab768c3f90f2f90`。
- 初期usage、エラー率、レイテンシを監視する。

### R6 — データ境界修正版（`v0.1.1` 候補）

2026-07-23時点で実装と機械検証を完了し、fixブランチからmainへの統合・本番反映待ち。

- Compose履歴、下書き、メモリをSupabase user ID単位で分離した。
- メモリ同期をdirty差分・server cursor・競合解決方式へ変更した。
- アカウント退会と、サーバー・Mac双方の関連データ削除を実装した。
- Supabase認証をアプリ専用Keychainへ移し、unit test起動時の不要なKeychainアクセスを止めた。
- request単位usageを90日後に月次rollupへ移すmigrationと日次cronを本番適用・記録した。
- 削除済みメモリから本文・相手名を消すtriggerは本番適用済み。migration台帳との整合確認を
  `v0.1.1`公開前に完了する。
- `0.1.1` build `3`へ更新し、Gateway先行deploy、外部候補テスト、署名、notarization、DMG公開の
  順で進める。公開中の`0.1.0` build `2`は変更せず、rollback可能な履歴として保持する。

## リリース判定

以下をすべて満たした時だけ公開する。

- R2〜R4が完了している。
- 主要5 AI endpointに旧・代替endpointが存在せず、各routeのモデル指定が共通SSOTだけにある。
- 重大度Highの既知不具合が0件。
- Composeのレビュー後フォーカス、履歴復元、音声入力、Vision初回応答が実機で再現可能。
- rollback先と本番Gatewayの互換性が確認されている。

## 次期改善候補（2026-07-22 実機テスト所見）

以下は現行リリースの阻害要因ではなく、別セッションで設計・実装する改善候補とする。

### Copilot完了時の終了・フィードバック導線

- 完了時の「目的の情報を確認しました」は、状態説明なのか案内終了なのか意図が曖昧。
- 「目的を達成したので閉じる」「案内を終了」など、ユーザーが完了を確認して閉じる明示的な
  操作に置き換える。この操作は目的達成のフィードバック信号としても扱えるようにする。
- 完了操作の横にGood / Badとコメント用の吹き出しを置き、任意で評価や具体的な意見を
  運営へ送れる導線を検討する。
- 収集項目、送信前の説明、本文・画像・画面情報を含めるかどうか、保存期間を実装前に定め、
  ユーザーの意図しない情報を送信しない。

### Transformのパネル内スペース配分

- 画面内テキストを選択してTransformを開いた時、選択元テキストの入力欄が縦に広すぎて
  解説・変換結果の表示領域を圧縮している。
- 選択元テキストは確認に必要な高さへ抑え、解説・変換結果へ優先的に縦方向のスペースを割く。
- 長文時のスクロール、最小・最大高、ウインドウサイズ変更時の配分を含めてUIを調整する。

### メモリ学習の品質評価

- 現行は送信差分から高確度の文体・関係性メモを抽出し、重複排除した直近20件をレビューへ
  注入する。経路は機能するが、推論されたメモの正確性は実利用で評価する必要がある。
- 誤学習率、レビュー品質への寄与、相手名の重複、ユーザーが修正・削除した割合を測定し、
  自動反映を続けるか、保存前確認方式へ変更するかを決める。
- usage保持期間と退会機能は実装済み。provider ZDRはコードでは確認不能な外部設定なので、
  管理画面で有効化・記録するリリース運用を完了させる。

### データ保持・アカウント境界（実装済み、本番反映待ち）

- Compose履歴、下書き、メモリDBをユーザーUUID配下へ移し、アカウント切替時の混在を防ぐ。
- メモリを全件・client-clock同期から、差分・server-version同期へ変更する。
- 同期失敗と競合をメモリ画面へ表示し、競合はユーザーが残す側を選択する。
- `DELETE /api/account`と二段階確認UIで退会し、サーバー・Mac双方の関連データを削除する。
- usage詳細を90日後に月次集計へ移し、pg_cronで日次削除する。
- tombstoneは本文・相手名を持たず、長期間オフラインだった端末による削除済みカードの復活を
  防ぐため期限削除しない。差分同期のため通常リクエスト数・payload上限には影響しない。

### 次期開発: アカウント、課金、テスター運用

- 現在、新規ユーザーは全員`free`・月500件で作成される。`standard` / `pro` / `team` /
  `enterprise`のplan catalogは存在するが、購入・自動割当・Stripe連携は未実装である。
- 管理画面へ入れる`ADMIN_EMAILS`と商用planは別概念である。管理者であることだけではquotaや
  billingを免除しない。次期設計では権限、契約、利用制限を独立した軸として扱う。
- Stripe課金の有無に加え、社内運用、招待テスター、無償提供など、請求や通常制限を適用しない
  account classを明示的に持たせる。個別ユーザーの場当たり的なquota変更で代用しない。
- Admin Consoleでplan・account class・契約状態を確認・変更し、変更者、変更時刻、理由を監査する。
- テスター別・cohort別の利用回数、機能別成功率、fallback、エラー率、レイテンシを監視する。
  入力本文、回答、画像、音声などの内容は管理画面へ保存・表示しない。
- モデル別token／音声秒数へ価格表を掛けたAPIコスト概算、ユーザー／機能／日別の推移、予算閾値を
  表示する。最終請求額はOpenAI、Groq等のprovider管理画面を正とする。
- 詳細設計と実装順序の正本は[admin-dashboard-plan.md](admin-dashboard-plan.md)に置く。

## 変更ルール

新しい方式を試す時は、この本番構造を変更する前に短命ブランチを作る。採用時は現行方式を
同じ変更で置換し、不採用時はブランチを閉じる。二方式の常設並走は禁止する。
