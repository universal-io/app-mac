# Universal I/O for macOS

Universal I/O は、入力・受信・画面理解をひとつの操作体系にまとめる macOS アプリです。

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

ローカル Gateway、BYOK、旧 Navigator、shadow、runtime feature flag、自動フォールバックは
実行経路に存在しません。別方式を試す場合は短命ブランチで行い、終了時に削除します。

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

## 設定

`BOMB_SQUAD_API_BASE_URL` は `project.yml` の Info.plist 定義が唯一の正本です。
`BombSquad.local.plist` は Supabase の公開クライアント設定だけに使用し、Gateway URLは読みません。

詳細は [ドキュメント索引](docs/README.md) を参照してください。
