# Universal I/O Web / Production Gateway

このNext.jsアプリは、製品サイト、認証、アカウント、管理画面、本番AI Gatewayを所有します。

## Routes

- `/`, `/auth`, `/auth/callback`, `/admin`
- `/api/account`（GET / DELETE）、`/api/admin/overview`
- `/api/ai/review`
- `/api/ai/transcribe`
- `/api/ai/vision`
- `/api/ai/suggest`（コンポーズの先回り文案。画像＋文脈→入力候補）

AI routeはこの一覧だけです。旧route、評価route、ローカルGateway用routeは置きません。

## Development

```bash
npm install
npm run dev
npm run lint
npm run build
```

ローカルのNext.jsはWeb/Gateway自体の開発にだけ使用します。macOSアプリはDebugを含め常に
`https://api.universal-io.com` を参照します。

環境変数は `.env.example` を正とし、APIキーとSupabase service roleはサーバー環境にだけ置きます。
