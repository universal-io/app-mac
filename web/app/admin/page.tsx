"use client";

// Admin console v0 (docs/admin-dashboard-plan.md). Read-only. A client
// component because the web session lives in the browser (localStorage), not
// a server-readable cookie: it reads the Supabase session, then fetches
// /api/admin/overview with the Bearer token. Authorization is enforced
// server-side in assertAdmin — this page only renders what the API returns.

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { useBrowserSession } from "@/lib/supabase/use-browser-session";
import type { EffectiveConfig } from "@/lib/server/admin";
import type {
  OverviewStats,
  OperationStat,
  ModelStat,
} from "@/lib/server/admin-stats";
import type { AdminUserRow } from "@/lib/server/admin-users";

type Overview = { config: EffectiveConfig; stats: OverviewStats };

// Runtime option lists kept local to the client (importing the const arrays
// from admin-users would pull its server-only imports into the browser bundle).
const ROLE_OPTIONS = ["user", "operator", "admin"] as const;
const PLAN_OPTIONS = ["free", "standard", "pro", "team", "enterprise"] as const;
const ACCOUNT_CLASS_OPTIONS = [
  "standard",
  "internal",
  "tester",
  "complimentary",
] as const;
type LoadState =
  | { kind: "loading" }
  | { kind: "forbidden" }
  | { kind: "error"; message: string }
  | { kind: "ready"; data: Overview };

export default function AdminPage() {
  const router = useRouter();
  const { isConfigured, isLoading, session } = useBrowserSession();
  const [state, setState] = useState<LoadState>({ kind: "loading" });

  useEffect(() => {
    if (isLoading) {
      return;
    }
    if (!session) {
      router.replace("/auth?next=/admin");
      return;
    }
    let cancelled = false;
    void (async () => {
      try {
        const res = await fetch("/api/admin/overview", {
          headers: { Authorization: `Bearer ${session.access_token}` },
        });
        if (cancelled) {
          return;
        }
        if (res.status === 403) {
          setState({ kind: "forbidden" });
          return;
        }
        if (!res.ok) {
          setState({ kind: "error", message: `HTTP ${res.status}` });
          return;
        }
        const data = (await res.json()) as Overview;
        setState({ kind: "ready", data });
      } catch (error) {
        if (!cancelled) {
          setState({ kind: "error", message: String(error) });
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [isLoading, session, router]);

  return (
    <main className="min-h-dvh bg-paper px-6 py-10 text-ink">
      <div className="mx-auto w-full max-w-[900px]">
        <header className="mb-8">
          <span className="text-2xl font-semibold tracking-[-0.02em]">
            I<span className="text-iris">{"//"}</span>O Admin
          </span>
          <p className="mt-1 text-sm text-slate">
            利用統計・ユーザー運用・実効設定
          </p>
        </header>

        {!isConfigured ? (
          <Notice>Supabase の環境変数が未設定です。</Notice>
        ) : state.kind === "loading" ? (
          <Notice>読み込み中…</Notice>
        ) : state.kind === "forbidden" ? (
          <Notice>このアカウントには管理者権限がありません。</Notice>
        ) : state.kind === "error" ? (
          <Notice>読み込みに失敗しました: {state.message}</Notice>
        ) : session ? (
          <AdminBody data={state.data} token={session.access_token} />
        ) : null}
      </div>
    </main>
  );
}

type AdminTab = "dashboard" | "users" | "models";

const ADMIN_TABS: { id: AdminTab; label: string }[] = [
  { id: "dashboard", label: "ダッシュボード" },
  { id: "users", label: "ユーザー" },
  { id: "models", label: "設定" },
];

function AdminBody({ data, token }: { data: Overview; token: string }) {
  const { config, stats } = data;
  const [tab, setTab] = useState<AdminTab>("dashboard");
  return (
    <div>
      <TabBar tab={tab} onChange={setTab} />
      {tab === "dashboard" ? (
        <div className="flex flex-col gap-8">
          <SummarySection stats={stats} />
          <OperationSection operations={stats.operations} />
          <ModelSection models={stats.models} />
          <DailySection daily={stats.daily} />
          <LinksSection />
        </div>
      ) : tab === "users" ? (
        <UsersSection token={token} />
      ) : (
        <div className="flex flex-col gap-8">
          <EffectiveConfigSection config={config} />
          <BillingConfigSection billing={config.billing} />
        </div>
      )}
    </div>
  );
}

function TabBar({
  tab,
  onChange,
}: {
  tab: AdminTab;
  onChange: (tab: AdminTab) => void;
}) {
  return (
    <nav className="mb-8 flex gap-1 border-b border-line">
      {ADMIN_TABS.map((t) => {
        const active = t.id === tab;
        return (
          <button
            key={t.id}
            type="button"
            onClick={() => onChange(t.id)}
            aria-current={active ? "page" : undefined}
            className={`-mb-px border-b-2 px-4 py-2.5 text-sm font-medium transition-colors ${
              active
                ? "border-iris text-ink"
                : "border-transparent text-slate hover:text-ink"
            }`}
          >
            {t.label}
          </button>
        );
      })}
    </nav>
  );
}

// --- 3-a. Effective model configuration ------------------------------------

function EffectiveConfigSection({ config }: { config: EffectiveConfig }) {
  return (
    <Section title="実効モデル設定" note="全機能の一次・二次モデル。GatewayのルーティングSSOTを表示。">
      <table className="w-full border-collapse text-sm">
        <thead>
          <Row header cells={["操作", "順序", "ベンダー", "モデルID", "API"]} />
        </thead>
        <tbody>
          {config.models.map((m) => (
            <tr key={`${m.label}-${m.priority}`}>
              <Cell>{m.label}</Cell>
              <Cell>{m.priority === "primary" ? "一次" : "二次"}</Cell>
              <Cell mono>{m.vendor}</Cell>
              <Cell mono>{m.modelId}</Cell>
              <Cell mono>{m.api}</Cell>
            </tr>
          ))}
        </tbody>
      </table>

      <div className="mt-4 flex flex-wrap items-center gap-x-5 gap-y-1 text-sm">
        <span className="text-slate">
          無料枠 / 月:{" "}
          <span className="text-ink">
            {config.freeMonthlyLimit.value ?? "無制限"}
          </span>
          <span className="ml-1 text-iris">(bs_plans)</span>
        </span>
        <span className="text-slate">APIキー:</span>
        {Object.entries(config.apiKeys).map(([name, present]) => (
          <span key={name} className="text-ink">
            {present ? "●" : "○"} {name}
          </span>
        ))}
      </div>
    </Section>
  );
}

// --- Stripe mode and sellable prices ---------------------------------------
// Exists to catch one specific mistake: shipping to production while the
// Gateway still holds a sandbox key. Read from the key prefix, not from the
// deployment, because only the key decides which environment is really in play.

function BillingConfigSection({ billing }: { billing: EffectiveConfig["billing"] }) {
  return (
    <Section
      title="課金（Stripe）"
      note="鍵の接頭辞から判定した実効モード。販売可能な価格は bs_plan_prices が正本。"
    >
      {billing.mode === "sandbox" ? (
        <p className="mb-4 rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          サンドボックス鍵で動作中です。実際の課金は発生しません。本番公開前に
          <span className="font-medium"> STRIPE_SECRET_KEY </span>
          を本番鍵へ差し替え、本番価格の行を bs_plan_prices に追加してください。
        </p>
      ) : billing.mode === null ? (
        <p className="mb-4 rounded-md border border-line bg-paper px-3 py-2 text-sm text-slate">
          STRIPE_SECRET_KEY が未設定です（課金は無効）。
        </p>
      ) : null}

      <div className="mb-4 flex flex-wrap items-center gap-x-5 gap-y-1 text-sm">
        <span className="text-slate">
          モード:{" "}
          <span className="text-ink">
            {billing.mode === "live"
              ? "本番（live）"
              : billing.mode === "sandbox"
                ? "サンドボックス（test）"
                : "未設定"}
          </span>
        </span>
        <span className="text-slate">
          Webhook署名シークレット:{" "}
          <span className="text-ink">
            {billing.webhookSecretPresent ? "● 設定済み" : "○ 未設定"}
          </span>
        </span>
      </div>

      {billing.purchasablePrices.length === 0 ? (
        <Empty />
      ) : (
        <table className="w-full border-collapse text-sm">
          <thead>
            <Row header cells={["プラン", "価格ID", "間隔", "通貨"]} />
          </thead>
          <tbody>
            {billing.purchasablePrices.map((p) => (
              <tr key={p.priceId}>
                <Cell>{p.plan}</Cell>
                <Cell mono>{p.priceId}</Cell>
                <Cell>{p.interval === "month" ? "月次" : "年次"}</Cell>
                <Cell mono>{p.currency}</Cell>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Section>
  );
}

// --- 3-b. Summary cards -----------------------------------------------------

function SummarySection({ stats }: { stats: OverviewStats }) {
  return (
    <Section title="利用統計（今月）">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Card label="登録ユーザー" value={String(stats.userCount)} />
        <Card label="テナント" value={String(stats.tenantCount)} />
        <Card
          label="今月のリクエスト"
          value={String(stats.monthTotal)}
          sub={`成功 ${stats.monthSuccess}`}
        />
        <Card
          label="エラー率"
          value={formatPercent(stats.monthErrorRate)}
          sub={
            stats.avgLatencyMs != null ? `平均 ${stats.avgLatencyMs} ms` : "—"
          }
        />
      </div>
    </Section>
  );
}

// --- Users (account model v1, admin-dashboard-plan §10 step 2) --------------

type UsersState =
  | { kind: "loading" }
  | { kind: "error"; message: string }
  | { kind: "ready"; viewerRole: "operator" | "admin"; users: AdminUserRow[] };

function UsersSection({ token }: { token: string }) {
  const [state, setState] = useState<UsersState>({ kind: "loading" });
  const [editing, setEditing] = useState<string | null>(null);
  // Bump to refetch after a mutation (avoids calling a setState-ful callback
  // synchronously from the effect — the roster is re-derived from this key).
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const res = await fetch("/api/admin/users", {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (cancelled) {
          return;
        }
        if (!res.ok) {
          setState({ kind: "error", message: `HTTP ${res.status}` });
          return;
        }
        const data = (await res.json()) as {
          viewerRole: "operator" | "admin";
          users: AdminUserRow[];
        };
        if (!cancelled) {
          setState({ kind: "ready", viewerRole: data.viewerRole, users: data.users });
        }
      } catch (error) {
        if (!cancelled) {
          setState({ kind: "error", message: String(error) });
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [token, reloadKey]);

  return (
    <Section
      title="ユーザー"
      note="権限(role)・plan・account classを変更できます（変更はadminのみ・理由必須で監査記録）。"
    >
      {state.kind === "loading" ? (
        <p className="text-sm text-faint">読み込み中…</p>
      ) : state.kind === "error" ? (
        <p className="text-sm text-faint">読み込みに失敗しました: {state.message}</p>
      ) : state.users.length === 0 ? (
        <Empty />
      ) : (
        <table className="w-full border-collapse text-sm">
          <thead>
            <Row
              header
              cells={["メール", "role", "plan", "class", "今月", "登録日", ""]}
            />
          </thead>
          <tbody>
            {state.users.map((u) => (
              <UserRow
                key={u.userId}
                user={u}
                canMutate={state.viewerRole === "admin"}
                token={token}
                expanded={editing === u.userId}
                onToggle={() =>
                  setEditing((cur) => (cur === u.userId ? null : u.userId))
                }
                onSaved={() => {
                  setEditing(null);
                  setReloadKey((k) => k + 1);
                }}
              />
            ))}
          </tbody>
        </table>
      )}
    </Section>
  );
}

function UserRow({
  user,
  canMutate,
  token,
  expanded,
  onToggle,
  onSaved,
}: {
  user: AdminUserRow;
  canMutate: boolean;
  token: string;
  expanded: boolean;
  onToggle: () => void;
  onSaved: () => void;
}) {
  return (
    <>
      <tr>
        <Cell>{user.email ?? "—"}</Cell>
        <Cell mono>{user.role}</Cell>
        <Cell mono>
          {user.plan ?? "—"}
          {user.stripeLinked ? " 🔒" : ""}
        </Cell>
        <Cell mono>{user.accountClass ?? "—"}</Cell>
        <Cell>{user.monthUsage}</Cell>
        <Cell>{user.createdAt.slice(0, 10)}</Cell>
        <Cell>
          {canMutate ? (
            <button
              type="button"
              onClick={onToggle}
              className="text-iris hover:underline"
            >
              {expanded ? "閉じる" : "変更"}
            </button>
          ) : null}
        </Cell>
      </tr>
      {expanded && canMutate ? (
        <tr>
          <td colSpan={7} className="border-b border-hair px-2 py-3">
            <UserEditor user={user} token={token} onSaved={onSaved} />
          </td>
        </tr>
      ) : null}
    </>
  );
}

function UserEditor({
  user,
  token,
  onSaved,
}: {
  user: AdminUserRow;
  token: string;
  onSaved: () => void;
}) {
  const [role, setRole] = useState<string>(user.role);
  const [plan, setPlan] = useState<string>(user.plan ?? "free");
  const [accountClass, setAccountClass] = useState<string>(
    user.accountClass ?? "standard",
  );
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const roleChanged = role !== user.role;
  const planChanged = plan !== (user.plan ?? "free");
  const classChanged = accountClass !== (user.accountClass ?? "standard");
  const anyChange = roleChanged || planChanged || classChanged;

  async function mutate(action: string, targetId: string, value: string) {
    const res = await fetch("/api/admin/users/mutate", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ action, targetId, value, reason }),
    });
    if (!res.ok) {
      const detail = (await res.json().catch(() => null)) as
        | { error?: { message?: string } }
        | null;
      throw new Error(detail?.error?.message ?? `HTTP ${res.status}`);
    }
  }

  async function apply() {
    setError(null);
    if (!reason.trim()) {
      setError("理由を入力してください。");
      return;
    }
    setBusy(true);
    try {
      // Each axis is a separate audited change; role targets the user, plan and
      // class target the tenant.
      if (roleChanged) {
        await mutate("set_role", user.userId, role);
      }
      if ((planChanged || classChanged) && !user.tenantId) {
        throw new Error("テナントが未解決のためplan/classを変更できません。");
      }
      if (planChanged && user.tenantId) {
        await mutate("set_plan", user.tenantId, plan);
      }
      if (classChanged && user.tenantId) {
        await mutate("set_account_class", user.tenantId, accountClass);
      }
      onSaved();
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-col gap-3 rounded-md border border-hair bg-paper p-3">
      <div className="flex flex-wrap gap-4">
        <EditField label="role">
          <SelectBox value={role} options={ROLE_OPTIONS} onChange={setRole} />
        </EditField>
        <EditField label="plan">
          <SelectBox
            value={plan}
            options={PLAN_OPTIONS}
            onChange={setPlan}
            disabled={user.stripeLinked}
          />
        </EditField>
        <EditField label="account class">
          <SelectBox
            value={accountClass}
            options={ACCOUNT_CLASS_OPTIONS}
            onChange={setAccountClass}
          />
        </EditField>
      </div>
      {user.stripeLinked ? (
        <p className="text-xs text-faint">
          このテナントはStripe連携中のため、planは管理画面から変更できません。
        </p>
      ) : null}
      <label className="flex flex-col gap-1 text-xs text-slate">
        理由（監査ログに残ります）
        <input
          type="text"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="例: ベータテスター登録、社内利用など"
          className="rounded border border-line bg-white px-2 py-1 text-sm text-ink"
        />
      </label>
      {error ? <p className="text-xs text-red-600">{error}</p> : null}
      <div className="flex items-center gap-3">
        <button
          type="button"
          onClick={apply}
          disabled={!anyChange || busy}
          className="rounded bg-iris px-3 py-1 text-sm text-white disabled:opacity-40"
        >
          {busy ? "適用中…" : "適用"}
        </button>
        {!anyChange ? (
          <span className="text-xs text-faint">変更はありません。</span>
        ) : null}
      </div>
    </div>
  );
}

function EditField({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <label className="flex flex-col gap-1 text-xs text-slate">
      {label}
      {children}
    </label>
  );
}

function SelectBox({
  value,
  options,
  onChange,
  disabled,
}: {
  value: string;
  options: readonly string[];
  onChange: (value: string) => void;
  disabled?: boolean;
}) {
  return (
    <select
      value={value}
      disabled={disabled}
      onChange={(e) => onChange(e.target.value)}
      className="rounded border border-line bg-white px-2 py-1 text-sm text-ink disabled:opacity-40"
    >
      {options.map((option) => (
        <option key={option} value={option}>
          {option}
        </option>
      ))}
    </select>
  );
}

// --- 3-c. Breakdown tables --------------------------------------------------

function OperationSection({ operations }: { operations: OperationStat[] }) {
  return (
    <Section title="操作別（今月）">
      {operations.length === 0 ? (
        <Empty />
      ) : (
        <table className="w-full border-collapse text-sm">
          <thead>
            <Row
              header
              cells={["操作", "件数", "成功率", "平均レイテンシ", "トークン合計"]}
            />
          </thead>
          <tbody>
            {operations.map((op) => (
              <tr key={op.operation}>
                <Cell mono>{op.operation}</Cell>
                <Cell>{op.total}</Cell>
                <Cell>{formatPercent(op.successRate)}</Cell>
                <Cell>{op.avgLatencyMs != null ? `${op.avgLatencyMs} ms` : "—"}</Cell>
                <Cell>{op.totalUnits.toLocaleString()}</Cell>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Section>
  );
}

function ModelSection({ models }: { models: ModelStat[] }) {
  return (
    <Section title="モデル別（今月・成功のみ）">
      {models.length === 0 ? (
        <Empty />
      ) : (
        <table className="w-full border-collapse text-sm">
          <thead>
            <Row header cells={["ベンダー", "モデルID", "件数"]} />
          </thead>
          <tbody>
            {models.map((m) => (
              <tr key={`${m.vendor} ${m.modelId}`}>
                <Cell mono>{m.vendor}</Cell>
                <Cell mono>{m.modelId}</Cell>
                <Cell>{m.count}</Cell>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Section>
  );
}

// --- 3-c. Daily trend (last 30 days) ---------------------------------------

function DailySection({ daily }: { daily: OverviewStats["daily"] }) {
  const max = Math.max(1, ...daily.map((d) => d.count));
  return (
    <Section title="日次推移（直近30日）">
      <div className="flex items-end gap-[3px]" style={{ height: 120 }}>
        {daily.map((d) => (
          <div
            key={d.day}
            className="flex-1 rounded-t-[2px] bg-iris"
            style={{
              height: `${(d.count / max) * 100}%`,
              minHeight: d.count > 0 ? 2 : 0,
            }}
            title={`${d.day}: ${d.count}`}
          />
        ))}
      </div>
      <div className="mt-1 flex justify-between text-[11px] text-faint">
        <span>{daily[0]?.day ?? ""}</span>
        <span>{daily[daily.length - 1]?.day ?? ""}</span>
      </div>
    </Section>
  );
}

// --- 3-d. External resource links ------------------------------------------

function LinksSection() {
  const links = [
    ["Vercel（帯域・関数・ログ）", "https://vercel.com/dashboard"],
    ["Supabase（DB・行数・Auth）", "https://supabase.com/dashboard"],
    ["Cloudflare R2（配布DMG）", "https://dash.cloudflare.com"],
  ];
  return (
    <Section title="外部リソース" note="容量・帯域は各社の公式ダッシュボードを参照。">
      <ul className="flex flex-col gap-1 text-sm">
        {links.map(([label, href]) => (
          <li key={href}>
            <a
              href={href}
              target="_blank"
              rel="noreferrer"
              className="text-iris hover:underline"
            >
              {label} ↗
            </a>
          </li>
        ))}
      </ul>
    </Section>
  );
}

// --- Shared presentational pieces ------------------------------------------

function Section({
  title,
  note,
  children,
}: {
  title: string;
  note?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-lg border border-line bg-white p-5">
      <div className="mb-3">
        <h2 className="text-base font-semibold">{title}</h2>
        {note ? <p className="mt-0.5 text-xs text-slate">{note}</p> : null}
      </div>
      {children}
    </section>
  );
}

function Card({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="rounded-md border border-hair bg-paper px-3 py-3">
      <div className="text-xs text-slate">{label}</div>
      <div className="mt-1 text-xl font-semibold">{value}</div>
      {sub ? <div className="mt-0.5 text-xs text-faint">{sub}</div> : null}
    </div>
  );
}

function Row({ header, cells }: { header?: boolean; cells: string[] }) {
  return (
    <tr>
      {cells.map((c, i) => (
        <th
          key={c + i}
          className={`border-b border-line px-2 py-2 text-left text-xs font-semibold ${
            header ? "text-slate" : "text-ink"
          } ${i === 0 ? "" : "text-right"}`}
        >
          {c}
        </th>
      ))}
    </tr>
  );
}

function Cell({
  children,
  mono,
}: {
  children: React.ReactNode;
  mono?: boolean;
}) {
  return (
    <td
      className={`border-b border-hair px-2 py-1.5 text-body ${
        mono ? "font-mono text-[13px]" : ""
      } first:text-left [&:not(:first-child)]:text-right`}
    >
      {children}
    </td>
  );
}

function Notice({ children }: { children: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-line bg-white px-5 py-8 text-center text-sm text-slate">
      {children}
    </div>
  );
}

function Empty() {
  return <p className="text-sm text-faint">今月のデータはまだありません。</p>;
}

function formatPercent(value: number): string {
  return `${(value * 100).toFixed(1)}%`;
}
