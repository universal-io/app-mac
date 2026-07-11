# 管理ダッシュボード（Admin Console）— 設計書

作成: 2026-07-06 ／ ステータス: **v0（読み取り専用）実装済み・本番稼働中**
（2026-07-12 更新: `web/app/admin/page.tsx`・`web/lib/server/admin.ts`・`admin-stats.ts` として実装済み。
本書は設計の記録として維持。v1 = DB 設定への昇格は未着手）

全体をコントロールするための簡易ダッシュボード。実効モデル設定・利用統計・登録状況を
一望し、事故（実験用モデルの入れっぱなし等）を可視化で防ぐ。

## 0. 背景と目的

2026-07-06、`.env.local` に残った navigate モデルの上書き指定（`gemini-2.5-flash`）で
アプリが最も苦手なモデルを使い続け、「プロンプト修正が効かない／ロールバックした」ように
見える事故が起きた。根本原因は **「今どのモデルで動いているか」「どう切り替えるか」が
環境変数という見えない場所にしかない** こと。

→ 管理者が「実効設定・利用量・登録状況」を1画面で把握でき、将来はモデル選択を
画面から切り替えられるようにする。

北極星（マスタープラン §1.2）と整合: クライアントはセンサー＆アクチュエータに徹する。
管理データを読む権限（service_role）はクライアントに置かない。

## 1. 置き場所の決定：既存 `web/`（Gateway）に `/admin` を追加

3案を比較し、**web/ 内に `/admin` ページ**を採用する。

| 置き場所 | 判定 | 理由 |
|---|---|---|
| **web/ に `/admin`** | ✅ 採用 | 見たいデータ（`bs_usage_events` / `bs_profiles` / `bs_entitlements`）が全てここにあり、それを読む `service_role` キーは Gateway にしか置けない。認証は既存 Supabase auth を流用。Vercel デプロイに自動で乗る。追加インフラ・コストほぼゼロ |
| macOS アプリ内の管理画面 | ❌ 却下 | 管理データを読む service_role キーを配布バイナリに入れられない（致命的）。画面サイズも不足。「クライアントはセンサー＆アクチュエータ」原則に反する |
| 独立した管理用サイト | ❌ 却下（現時点） | デプロイ・認証・env 管理がもう1系統増える。管理者は当面1人で過剰 |

> 容量・システムリソース系（Vercel の帯域・関数実行、Supabase の DB 容量）は各社の
> 公式ダッシュボードが優秀なので**自前で重複させず、リンクを置くだけ**。自前で持つのは
> プロダクト固有の数字（ユーザー・使用量・モデル・エラー）に絞る。

## 2. 認証・認可

- **ログイン**: 既存の Supabase auth（Google / メールリンク）をそのまま流用。`/admin` は
  未ログインなら `/auth?next=/admin` へリダイレクト。
- **管理者判定**: 環境変数 `ADMIN_EMAILS`（カンマ区切りの許可メール）で限定する最小実装。
  ログインユーザーの `email` が含まれなければ 403。
  - v1 で `bs_profiles` に `is_admin boolean` 列を足す案もあるが、v0 は env で足りる
    （管理者は当面1人、DBマイグレーション不要）。
- **サーバー側で必ず再判定**: ページの Server Component と各集計 API の両方で
  `assertAdmin(request)` を通す。クライアント側の表示制御だけに頼らない。

```
lib/server/admin.ts
  assertAdmin(request): Promise<{ email: string }>
    - authenticate 相当で JWT 検証 → email 取得
    - ADMIN_EMAILS に含まれなければ GatewayError(403, "FORBIDDEN")
```

## 3. 画面構成（v0 = 読み取り専用・1ページ）

`/admin` 単一ページ。上から順に4セクション。

### 3-a. 実効モデル設定（今回の事故の再発防止・最優先）
`getServerEnv()` の解決結果をそのまま表示する。「env に何が入っているか」ではなく
「**実際に何が使われるか**」を見せるのが肝。

| 操作 | ベンダー | モデルID | 出所 |
|---|---|---|---|
| review（既定） | groq | openai/gpt-oss-120b | env or default |
| vision | openai | gpt-5.4-mini | … |
| navigate（後続ターン） | openai | gpt-5.4-mini | … |
| navigate（初手・高速） | groq | llama-4-scout | … |

- 「出所」列で **env 上書き中か / コード既定か** を明示（上書き中はハイライト）。
  これがあれば今回の事故は一目で気づけた。
- API キーの設定状況（groq / openai / gemini / anthropic が設定済みか）を
  ●/○ で表示（キー値は絶対に出さない、有無だけ）。

### 3-b. 利用統計（サマリー）
`bs_usage_events` の集計。カード4枚:
- 登録ユーザー数（`bs_profiles` の行数）／テナント数（`bs_tenants`）
- 今月の総リクエスト数（成功のみ／全体）
- 今月のエラー率（status != 'success' の割合）
- 平均レイテンシ（`latency_ms` の平均、operation 別内訳）

### 3-c. 内訳テーブル
今月分（`created_at >= currentMonthStartUTC()`）を軸で集計:
- **operation 別**: review / navigate / vision / transcribe / distill の件数・成功率・平均レイテンシ・トークン合計
- **モデル別**: `model_vendor` + `model_id` ごとの件数（どのモデルがどれだけ使われたか）
- **日次推移**: 直近30日の日別リクエスト数（棒 or 折れ線。dataviz スキル準拠）

### 3-d. 外部リソースへのリンク
- Vercel プロジェクト（帯域・関数実行・ログ）
- Supabase プロジェクト（DB 容量・行数・Auth ユーザー）
- Cloudflare R2（配布 DMG の容量・転送）

## 4. データ取得（集計クエリ）

すべて `getSupabaseAdminClient()`（service_role）で読む。RLS をバイパスするので
`assertAdmin` を通った後だけ呼ぶこと。既存 `gateway.ts` の
`currentMonthStartUTC()` を再利用。

主なクエリ（イメージ）:
```sql
-- 登録ユーザー数
select count(*) from bs_profiles;

-- 今月の operation 別サマリー
select operation, status, count(*), avg(latency_ms),
       sum(input_units), sum(output_units)
from bs_usage_events
where created_at >= :month_start
group by operation, status;

-- モデル別
select model_vendor, model_id, count(*)
from bs_usage_events
where created_at >= :month_start and status = 'success'
group by model_vendor, model_id
order by count(*) desc;

-- 日次推移（直近30日）
select date_trunc('day', created_at) as day, count(*)
from bs_usage_events
where created_at >= now() - interval '30 days'
group by day order by day;
```

> **パフォーマンス注意**: `bs_usage_events` は成長するテーブル。日次推移や月次集計は
> `created_at` インデックス前提（既存の使用量カウントと同じ）。件数が増えたら
> Postgres の集計を毎回叩くのは重くなるので、v1 で日次サマリーを別テーブル
> （`bs_usage_daily`）にロールアップする案を検討（下記ロードマップ）。

## 5. 実装スケッチ（ファイル構成）

```
web/
  lib/server/admin.ts            … assertAdmin() + ADMIN_EMAILS 判定
  lib/server/admin-stats.ts      … 集計クエリ群（純関数、テスト可能）
  app/api/admin/overview/route.ts … GET: 実効設定 + サマリー + 内訳を1レスポンスで
  app/admin/page.tsx             … Server Component。assertAdmin → 集計 → 表示
  components/admin/*.tsx         … カード・テーブル・チャート（dataviz スキル準拠）
```

- 集計は Server Component で直接 `admin-stats` を呼んでも、`/api/admin/overview` 経由でも
  よい。**Server Component 直呼び**が最小（API 層を1枚省ける、SSR で速い）。
  自動更新が欲しくなったら API に切り出してクライアントから poll。
- env 追加: `ADMIN_EMAILS`。`.env.example` と Vercel 環境変数に追記。

## 6. ロードマップ（v0 → v1 → v2）

- **v0（本設計・読み取り専用）**: 実効設定表示 ＋ 利用統計 ＋ 内訳 ＋ 外部リンク。
  ADMIN_EMAILS で認可。今回の事故の再発防止が主目的。
- **v1（設定の書き込み）**: モデル選択を env から **DB 設定テーブル `bs_app_config`** に昇格。
  管理画面から navigate/review/vision のモデルを切替（**再デプロイ不要**・変更履歴も残る）。
  エンジンの解決順を「DB設定 → env → コード既定」に変更。
  → これが本来の「選択肢をいろいろ選べるようにする」の正しい実装場所。
     現状の env 上書きは「開発者が一時的に試す」用途に留める。
- **v2（運用の深掘り）**: 日次ロールアップ（`bs_usage_daily`）、テナント別ドリルダウン、
  コスト概算（モデル別トークン×単価）、アラート（エラー率・レイテンシ閾値超え）。

## 7. 非スコープ（当面やらない）

- 個別ユーザーの会話内容の閲覧（プライバシー原則: 画面・私信は保存しない方針と衝突）。
  管理画面が見るのは**集計された数字**であって中身ではない。
- 課金・請求管理（Stripe 側のダッシュボードを使う）。
- Vercel / Supabase / R2 が自前で持つメトリクスの再実装（リンクで済ませる）。

## 8. 「今どのモデルか」を見えなくしない — 恒久対策の位置づけ

今回の事故の直接の再発防止は既に2つ入れた:
1. パネルのヘッダーに**実モデルID表示**（`gpt-5.4-mini · 1704 ms`）
2. 実験用 env 上書きの削除

管理ダッシュボード 3-a はこれの**サーバー側の正本**。クライアント表示は「利用者が今使っている
モデル」、管理画面は「システム全体の実効設定」を担い、二層で不可視化を防ぐ
（開発GWバッジ・向き先警告バーと同じ思想）。
