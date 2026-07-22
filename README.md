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

メモリは、ユーザーが実際に送った文章とレビュー案との差分、またはユーザー自身が提供した
過去文例から、文体・敬語・相手との距離感だけを抽出する機能です。保存内容はユーザーが閲覧・
編集でき、次回のComposeレビューとTransformへ任意の参考コンテクストとして注入されます。

## 現行機能

- 入力パネル: 文章の作成、音声入力、レビュー、対象アプリへの送信
- 受信変換: 選択中の文章を読み取り、要点と返信案を表示
- Vision: スクリーンショットを読み、質問への回答や次の操作位置を提示
- Copilot: ユーザーの操作後に画面を再取得し、目的に到達するまで次の一手を案内
- 履歴・メモリ: ローカル履歴とユーザー管理のスタイル情報

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

- 右 Shift 1回: 入力パネル内のフォーカス切替
- 右 Shift 2回: パネル表示、入力レビュー、Vision開始、またはパネルを閉じる
- 右 Shift 長押し: 音声入力
- Esc: パネルを閉じる
- 入力パネルのカメラ: Vision用スクリーンショット取得

レビュー結果は参考表示です。レビュー完了後も入力フォーカスは自分の下書きに残り、
Enter は下書きを送信します。レビュー案を使う場合だけ明示的にフォーカスを切り替えます。

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

現行の正式版は `v0.1.0`（build `2`、ソース `700f607`）です。配布DMGは
`https://dl.universal-io.com/releases/0.1.0/build-2/Universal-IO.dmg`、SHA-256は
`e0b08385d11cb591019490a93a5bfc2aa3b0f510ef577f116ab768c3f90f2f90`です。

公開版は長期ブランチではなく、Gitタグと変更しないバージョン／build別DMGで保存します。
`main`は次のリリースへ進め、公開済みコードへ緊急修正が必要な場合だけタグからfixブランチを
作成します。versionは公開単位で更新し、build番号は署名・配布ビルドごとに増加させます。

```bash
# Developer ID署名、notarization、staple、Gatekeeper検証、DMG作成まで
bash tools/release.sh

# 上記に加え、履歴用の不変URLへ保存してWebサイトの最新版を切り替える
bash tools/release.sh --publish
```

通常実行は配布物を変更しません。`--publish`だけがR2へアップロードします。公開時は
`releases/<version>/build-<build>/Universal-IO.dmg`を履歴として保持し、
`Universal-IO-<version>.dmg`と互換用latest aliasの`Universal-IO.dmg`も更新します。
CDNの旧aliasキャッシュを避けるため、WebサイトのCTAは履歴用の不変URLを直接参照します。
公開成功後、そのソースコミットへ`v<version>`タグを付けます。

## 設定

`BOMB_SQUAD_API_BASE_URL` は `project.yml` の Info.plist 定義が唯一の正本です。
`BombSquad.local.plist` は Supabase の公開クライアント設定だけに使用し、Gateway URLは読みません。

詳細は [ドキュメント索引](docs/README.md) を参照してください。
