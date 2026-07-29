# 管理ダッシュボード（Admin Console）— 設計書

作成: 2026-07-06 ／ ステータス: **v1 step1-2 実装済み・本番稼働中**
（2026-07-23 更新: v1以降へアカウント区分、Stripe、テスター監視、APIコスト管理を追加。
2026-07-24 更新: §10 step1（account model migration）＋ step2（手動運用UI）実装。
2026-07-30 更新: 独立Transform撤去に合わせて現行feature／operation一覧を更新。
`bs_profiles.role`＋`bs_entitlements.account_class`＋`bs_admin_audit_log`を追加し、
`assertAdmin`をenv→DBロール化（ADMIN_EMAILSは和集合のブートストラップとして併存）。
現行実装は`web/app/admin/page.tsx`・`web/lib/server/admin.ts`・`admin-stats.ts`・
`admin-users.ts`・`web/app/api/admin/users/*`・`supabase/migrations/20260724000000_account_model.sql`。
step3以降（Stripe・tester監視・cost・alert）とguest modeは未着手）

全体をコントロールするための簡易ダッシュボード。実効モデル設定・利用統計・登録状況を
一望し、事故（実験用モデルの入れっぱなし等）を可視化で防ぐ。

## 0. 背景と目的

過去に環境変数へ残ったモデル指定で想定外のモデルを使い続け、「修正が効かない／
ロールバックした」ように見える事故が起きた。現在は一次・二次モデルとAPI方式を
`web/lib/server/ai-routing.ts` へ集約し、個別engineとモデル用環境変数から削除済み。

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
`AI_MODEL_ROUTES` の内容をそのまま表示する。「個別engineが何を指定しているか」を推測せず、
「**実際に使われる一次・二次の順序**」を見せる。

| 操作 | 順序 | ベンダー | モデルID | API |
|---|---|---|---|---|
| Compose review | 一次 | openai | gpt-5.6-luna | chat_completions |
| Compose review | 二次 | groq | openai/gpt-oss-120b | chat_completions |
| Vision / Copilot | 一次 | openai | gpt-5.6-luna | responses |
| Vision / Copilot | 二次 | openai | gpt-5.4-mini | responses |

- Review、Vision/Copilot、Transcribe、Memoryの全機能を表示する。
- 一次・二次の順序とAPI方式を隠さない。個別engineにはモデル名を置かない。
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
- **operation 別**: review / vision / transcribe / distill の件数・成功率・平均レイテンシ・トークン合計
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

> `bs_usage_events` のrequest単位詳細は90日保持する。期限後は日次cronが
> `bs_usage_monthly_rollups`へ加算して詳細を削除する。現行画面の今月・直近30日表示はdetailを、
> 90日を超える将来の長期比較はrollupを読む。

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
- **v1（アカウント運用）**: plan、account class、契約状態、個別quota overrideを管理し、変更者・
  時刻・理由を監査する。招待テスター、社内、無償提供をStripe契約なしで明示的に設定できる。
- **v1.1（Stripe）**: 実装済み。Product / Priceとplanの対応（`bs_plan_prices`）、Checkout、
  Customer Portal、署名検証済みwebhook、冪等なsubscription反映（`bs_stripe_events`）。
  Stripeの状態を直接権限判定せず、webhookでentitlementへ反映する。実効モードは管理画面「設定」に表示する。
  残るのは本番有効化（本番価格の作成と`livemode=true`行の追加）と顧客ポータルのStripe側設定。
- **v2（運用の深掘り）**: 既存の月次rollupを使う長期推移、テスターcohort・テナント別ドリルダウン、
  モデル単価に基づくコスト概算、予算・エラー率・レイテンシのアラートを追加する。
- **v3（実効モデル設定）**: `AI_MODEL_ROUTES` と同じschemaをDB設定テーブルへ昇格し、管理画面から
  一次・二次・API方式を変更する。変更履歴とrollbackを必須にし、個別engineは共通ルーターだけを呼ぶ。

## 7. 非スコープ（当面やらない）

- 個別ユーザーの会話内容の閲覧（プライバシー原則: 画面・私信は保存しない方針と衝突）。
  管理画面が見るのは**集計された数字**であって中身ではない。
- Stripeの請求書・入金・税務画面の再実装。アプリ側はplanとsubscription状態だけを同期し、金銭の
  正本はStripe Dashboardとする。
- Vercel / Supabase / R2 が自前で持つメトリクスの再実装（リンクで済ませる）。

## 8. 「今どのモデルか」を見えなくしない — 恒久対策の位置づけ

今回の事故の直接の再発防止は既に2つ入れた:
1. パネルのヘッダーに**実モデルID表示**（`gpt-5.6-luna · 1704 ms`）
2. モデル指定を `AI_MODEL_ROUTES` へ集約し、モデル用env上書きを削除

管理ダッシュボード 3-a はこれの**サーバー側の正本**。クライアント表示は「利用者が今使っている
モデル」、管理画面は「システム全体の実効設定」を担い、二層で不可視化を防ぐ
（開発GWバッジ・向き先警告バーと同じ思想）。

## 9. 次期アカウントモデル

### 9-a. 現状

- 新規登録は`bs_provision_user()`により全員`free`、月500件、`active`で作成される。
- `bs_plans`には`free` / `standard` / `pro` / `team` / `enterprise`があるが、現時点でfree以外は
  購入導線も自動割当もなく、手動運用前提である。
- `/admin`の権限は`ADMIN_EMAILS`で決まり、`bs_entitlements.plan`とは独立している。
  したがって管理者であってもfreeのままなら通常quotaが適用される。
- `bs_entitlements`のStripe ID列は、Checkout（customer作成時）とwebhook（subscription反映時）が
  書き込む。管理画面はStripe連携中のplanを変更できない（`STRIPE_LINKED`）。

### 9-b. 分離する3つの軸

1. **権限**: `user` / `operator` / `admin`。管理画面で何を閲覧・変更できるか。
2. **商品plan**: `free` / 有料個人 / team / enterprise。機能と標準quota。
3. **account class**: `standard` / `internal` / `tester` / `complimentary`。誰が支払い、通常のquota・
   trial・退会制約をどう適用するか。

管理者を「特別な有料plan」として表現しない。逆にpremium契約者へ管理権限を付けない。
Stripeを通さない無償・社内・テスターアカウントもaccount classで明示し、期限、理由、付与者を持つ。
実カラム名と制約はmigration設計時に確定し、`bs_entitlements`を商用状態のSSOTとして維持する。

### 9-c. 管理画面の操作

- ユーザー／tenant検索、登録日、最終利用、plan、account class、subscription、今月利用量を表示する。
- premium、tester、complimentary等への変更は確認画面を通し、変更前後、操作者、理由を監査ログへ残す。
- Stripe連携中のplanを管理画面だけで矛盾した状態へ変更できないよう、操作可能範囲を制限する。
- 管理者自身の変更や無制限化も監査対象とし、「ADMIN_EMAILSだから無制限」という暗黙ルールを作らない。

## 10. Stripeとコスト監視の実装順序

1. **account model migration**: account class、管理role、期限、監査ログを設計し、既存freeユーザーを
   `standard`へ安全にbackfillする。
2. **手動運用UI**: Stripeなしでpremium候補、tester、complimentary、internalを設定できるようにする。
3. **Stripe test mode**: 実装済み（Product / Price対応表、Checkout、Portal、webhook署名、イベント冪等性）。
4. **tester monitoring**: cohort、最終利用、機能別件数、成功率、fallback、エラー、レイテンシを表示する。
5. **cost estimate**: model pricing snapshotを日付付きで保持し、input/output tokenと音声秒数から概算する。
   provider請求との差を定期確認し、価格改定時に過去集計を書き換えない。
6. **alerts**: 日次・月次予算、ユーザー単位の急増、エラー率、fallback率の閾値通知を追加する。

管理画面へ入力本文、AI回答、画像、音声、Visionの選択対象を表示しない。テスターの利用状況は
operation、時刻、モデル、unit、成否、レイテンシ等の運用メタデータだけで把握する。
