# Universal I/O for macOS

Universal I/O は、入力・受信・画面理解をひとつの操作体系にまとめる macOS アプリです。

## 重要: 本番AIモデルとfallback

全AIモデルの一次・二次ルートは
[`web/lib/server/ai-routing.ts`](web/lib/server/ai-routing.ts) が唯一の正本です。
個別のengine、macOSクライアント、環境変数へモデル名を分散させません。

| 機能 | 一次モデル | 二次モデル |
|---|---|---|
| Composeレビュー | OpenAI `gpt-5.6-luna` | Groq `openai/gpt-oss-120b` |
| Transform（選択テキストの解説） | OpenAI `gpt-5.6-luna` | OpenAI `gpt-5.4-mini` |
| Vision / Copilot | OpenAI `gpt-5.6-luna` | OpenAI `gpt-5.4-mini` |
| 音声入力 | Groq `whisper-large-v3` | OpenAI `whisper-1` |
| メモリ抽出 | OpenAI `gpt-5.6-luna` | Groq `openai/gpt-oss-120b` |

共通規則:

- 一次モデルが失敗した時だけ二次モデルを1回実行する。三番目の経路は持たない。
- 二次モデルで成功した場合は、全routeが `fallback_used: true` と同じ形式のnoticeを返す。
  macOSは「一次へアクセスできなかったため、二次で処理した」と必ず表示する。
- 両方が失敗した場合は、全機能で同じ明示的エラーを返す。
- macOSはモデルを選ばず、認証済みの本番Gatewayだけを呼ぶ。

メモリは、ユーザーがレビュー案を採用して実際に送った文章との差分、またはユーザー自身が
提供した過去文例から、文体・敬語・相手との距離感だけを抽出する機能です。保存内容はユーザーが
閲覧・編集・削除でき、次回のComposeレビューとTransformへ任意の参考コンテクストとして
注入されます。自動学習部分は重複を除いた直近20件に制限します。

## 現行機能

- 入力パネル: 文章の作成、音声入力、レビュー、対象アプリへの送信
- 受信変換: 選択中の文章を読み取り、要点と返信案を表示
- Vision: スクリーンショットを読み、質問への回答や次の操作位置を提示
- Copilot: ユーザーの操作後に画面を再取得し、目的に到達するまで次の一手を案内
- 履歴・メモリ: ローカル履歴とユーザー管理のスタイル情報

## 開発予定の新機能

### ゲストプレビュー（ログイン前に試せる体験）

初回起動でいきなり「ログインが必要」とせず、**ログインなしで約20回まで試せる**プレビューを提供する。
デモを触る感覚で入力レビューや変換を体験でき、システム許可の設定を終えた直後にオンボーディングで
うんざりさせない。

- 実現方式: Supabase の**匿名サインイン**をゲストの正体とする（本アプリは全AIを認証済みGateway経由で
  呼ぶため、ゲストにも認証済みセッションが要る）。匿名ユーザーには free(500) ではなく **guest 枠（約20）**を
  provisioning で割り当てる。
- 枠を使い切った時に初めて「利用継続にはログインが必要です。月◯◯クレジット分無料でお使いいただけます。」を
  表示する。◯◯は `bs_plans` の free 上限（現在500）を**動的に**反映し、100や1000へ変えても文言が追従する。
- 継続は匿名アカウントを Google / メールへ**リンク**して昇格（guest→free）。ログイン画面は最初から登録として
  表示し、Google かメールをその場で選べる。
- 要検討: 20回を端末単位/匿名ユーザー単位のどちらで数えるか（再インストール悪用の許容度、`bs_app_devices`）、
  ゲストデータのZDR扱い、初期値「20」。

サーバー（Supabase 匿名認証・guest plan・provisioning 分岐）＋クライアント＋商品/セキュリティ判断に
またがる中規模機能。アカウント管理UI（`docs/admin-dashboard-plan.md` §9-b の権限/plan/account class 分離）と
同じライフサイクル上にあるため、そのプロジェクトと合わせて設計・実装する。

## データ保存

- 入力履歴はComposeで実際に送信した原文と最終文だけを、ログイン中のユーザー専用領域へ
  最新100件保存する。
  Transformの選択文、解説、返信案、コピー結果は履歴へ保存しない。
- 未送信のCompose下書きもユーザー単位でこのMacへ保存する。送信した下書きは消去する。
- メモリカードはこのMacと、ログイン中のユーザーに紐づくSupabaseへ同期する。削除時は
  同期用tombstoneだけを残し、本文と相手名はローカル・サーバー双方から消去する。
- 履歴・下書き・メモリはSupabase user IDごとに分離する。ログアウト時はローカルDBを閉じ、
  別アカウントへ内容を表示・注入・同期しない。旧版の未分離データは、起動時に復元できた既存
  セッションにだけ一度移行する。
- SupabaseのログインセッションはUniversal I/O専用のmacOS Keychain領域へ保存する。旧SDK共通
  キーは一度だけ移行し、テスト起動ではKeychainを開かない。
- メモリ同期は変更分だけを最大100件ずつ送る。Gatewayの時刻を版として競合を検出し、別Macの
  同時変更はユーザーが「このMac」「クラウド」のどちらを残すか決めるまで上書きしない。
  内容を消去したtombstoneは長期オフライン端末からの復活を防ぐため保持するが、毎回は送らない。
- スクリーンショットと音声は処理用の一時ファイルだけに置く。通常終了時に削除し、異常終了で
  残ったVision画像も次回起動時に削除する。Vision/Copilotの会話は永続化しない。
- Supabaseのusageには機能、モデル、token／秒数、成功・失敗、処理時間などの運用情報だけを
  記録し、入力本文、回答本文、画像、音声、アプリ名、ウインドウタイトルは保存しない。
- request単位のusageは90日保持し、期限後はユーザーID・request IDを持たないテナント月次集計へ
  加算して詳細行を自動削除する。月次利用枠は当月の成功行だけで計算する。
- アカウント画面から退会できる。直近10分以内の再認証を要求し、Authユーザー、メモリ、usage、
  profile、個人tenantと、このMacの履歴・下書き・メモリを削除する。有効な契約があれば先に解約する。

### AI事業者側の保持（ZDR）

- OpenAIのResponses / Chat Completionsにはすべて`store: false`を指定する。これはAPIの会話状態を
  保存しない指定であり、不正利用監視ログも除外するZDRとは別である。
- OpenAI ZDRは承認後にOrganization / ProjectのData controlsで有効化する。Groq ZDRはData
  Controlsで有効化する。コードから有効状態は取得できないため、リリース前チェックで両方の
  管理画面を確認する。
- 公式仕様: [OpenAI Data controls](https://developers.openai.com/api/docs/guides/your-data)、
  [Groq Your Data](https://console.groq.com/docs/your-data)。

## 本番アーキテクチャ

macOS アプリは AI プロバイダーを直接呼びません。認証済みの全 AI リクエストは
`https://api.universal-io.com` の本番 Gateway に送信します。

| 機能 | macOS | Gateway |
|---|---|---|
| 入力レビュー | `ComposeSession` / `GatewayReviewClient` | `POST /api/ai/review` |
| 音声入力 | `GatewayTranscriber` | `POST /api/ai/transcribe` |
| 受信変換 | `TransformSession` / `GatewayTransformClient` | `POST /api/ai/transform` |
| Vision / Copilot | `VisionSession` / `GatewayVisionClient` | `POST /api/ai/vision` |
| メモリ抽出 | `MemoryDistiller` | `POST /api/ai/memory/distill` |

ローカルGateway、BYOK、旧Navigator endpoint、shadow、runtime feature flag、macOS側の
代替経路は存在しません。モデルfallbackは本番Gateway内の共通ルーターだけが行います。
別方式を試す場合は短命ブランチで行い、終了時に削除します。

## 操作

- 右 Shift 1回: 入力パネル内のフォーカス切替（自分の下書き ⇄ 文案／レビュー結果）
- 右 Shift 2回: 起動 / Vision開始 / 閉じる。起動時は、選択テキストがあれば受信変換、編集可能な
  入力欄にフォーカスがあればコンポーズ、どちらも無ければ最初からVision（書き込む先が無いため）。
  コンポーズからさらに右 Shift 2回でVisionへ。フォーカス判定は前面化する前に同期で行う
- 右 Shift 長押し: 音声入力
- Esc: パネルを閉じる
- 入力パネルの「レビュー」ボタン: 自分の下書きをレビュー
- 入力パネルのカメラ: Vision用スクリーンショット取得（範囲選択あり）

レビュー結果は参考表示です。レビュー完了後も入力フォーカスは自分の下書きに残り、
Enter は下書きを送信します。レビュー案を使う場合だけ明示的にフォーカスを切り替えます。

入力パネルを開くと、フォーカス中のフォームに入れる文案を画面から先回りで生成し、レビュー結果と
同じ位置に自動表示します（設定でオフにでき、オフでもVisionの先読みは続きます）。採用すると
自分の下書き欄に入り、通常どおりレビュー・送信できます。使わなければ保存されません。Shift×2で
Visionへ進むときは、パネル起動時に撮った画面をそのまま再利用します。

## 開発

必要環境:

- macOS 14+
- Xcode 16+
- XcodeGen
- Node.js / npm

```bash
xcodegen generate
xcodebuild -project BombSquad.xcodeproj -scheme BombSquad -configuration Debug \
  -derivedDataPath /tmp/universal-io-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

cd web
npm install
npm run lint
npm run build
```

通常のCLI検証では署名を無効にします。署名付き実行はマイク・画面収録・Accessibility・
Keychain の許可状態に影響するため、明示的な実機確認時だけ行います。

## リリース運用

現行の正式版は `v0.1.1`（build `3`、ソース `7171d35`）です。配布DMGは
`https://dl.universal-io.com/releases/0.1.1/build-3/Universal-IO.dmg`、SHA-256は
`9b46618325f296bd78a7e48b75e383454f58ccb457d8617037dfacd887c2afca`です。データ保持、
アカウント分離・退会、メモリ差分同期、Keychainのアプリ専用化、開発/本番のアプリ正体分離、
初回セットアップのUX改善、アプリアイコンを含む。本番Gatewayとマイグレーションは先に反映済み。

公開URL（`Universal-IO.dmg`）は現在 0.1.1 build 3 を配信中である。外部テスターへは不変URLを
限定共有し、公開に確定する時は `--promote` で公開URLを向け直す（下記）。
一つ前の `v0.1.0`（build `2`、ソース `700f607`）は
`https://dl.universal-io.com/releases/0.1.0/build-2/Universal-IO.dmg`、SHA-256
`e0b08385d11cb591019490a93a5bfc2aa3b0f510ef577f116ab768c3f90f2f90` として不変保存されている。

公開版は長期ブランチではなく、Gitタグと変更しないバージョン／build別DMGで保存します。
`main`は次のリリースへ進め、公開済みコードへ緊急修正が必要な場合だけタグからfixブランチを
作成します。versionは公開単位で更新し、build番号は署名・配布ビルドごとに増加させます。

```bash
# Developer ID署名、notarization、staple、Gatekeeper検証、DMG作成まで
bash tools/release.sh

# 上記に加え、不変URLとversion aliasへアップロード（公開URLは変えない）
bash tools/release.sh --publish

# 検証後、公開URL（Universal-IO.dmg）を選んだビルドへ向ける＝公開確定
bash tools/release.sh --promote 0.1.1 3
```

**ビルドの公開と「公開ダウンロードにする」を分離する。** `--publish` は
`releases/<version>/build-<build>/Universal-IO.dmg`（不変）と `Universal-IO-<version>.dmg` だけを
書き、**公開URL `Universal-IO.dmg` は触らない**。候補を検証したら `--promote <version> <build>` で
公開URLをそのビルドへ server-side copy する。これにより **WebサイトのCTAは版を持たない
`https://dl.universal-io.com/Universal-IO.dmg` に固定でき、二度と編集不要**（公開の切替は promote で
行う）。問題時は旧ビルドへ `--promote` し直せば公開を戻せる。公開成功後、そのソースコミットへ
`v<version>` タグを付ける。

ここでいう「旧DMGを上書きしない」は配布サーバー上の履歴管理を指す。ユーザーが新しいDMGから
Applicationsへコピーし、既存の `Universal IO.app` を置き換えるのは通常のアップデートである。
XcodeのRunで使うDebugアプリは通常DerivedData内にあり、Applications版とは別のファイルである。
インストーラー確認時は両方を同時起動せず、Xcode版を終了してApplications版だけを起動する。

## 設定

`BOMB_SQUAD_API_BASE_URL` は `project.yml` の Info.plist 定義が唯一の正本です。
`BombSquad.local.plist` は Supabase の公開クライアント設定だけに使用し、Gateway URLは読みません。

詳細は [ドキュメント索引](docs/README.md) を参照してください。
