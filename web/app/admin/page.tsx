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

type Overview = { config: EffectiveConfig; stats: OverviewStats };
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
            実効設定と利用統計（読み取り専用）
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
        ) : (
          <AdminBody data={state.data} />
        )}
      </div>
    </main>
  );
}

function AdminBody({ data }: { data: Overview }) {
  const { config, stats } = data;
  return (
    <div className="flex flex-col gap-8">
      <EffectiveConfigSection config={config} />
      <SummarySection stats={stats} />
      <OperationSection operations={stats.operations} />
      <ModelSection models={stats.models} />
      <DailySection daily={stats.daily} />
      <LinksSection />
    </div>
  );
}

// --- 3-a. Effective model configuration ------------------------------------

function EffectiveConfigSection({ config }: { config: EffectiveConfig }) {
  return (
    <Section title="実効モデル設定" note="実際に使われる値。env 上書き中は強調表示。">
      <table className="w-full border-collapse text-sm">
        <thead>
          <Row header cells={["操作", "ベンダー", "モデルID", "出所"]} />
        </thead>
        <tbody>
          {config.models.map((m) => {
            const overridden = m.vendorSource === "env" || m.modelSource === "env";
            const inherited = m.vendorSource === "inherited" && m.modelSource === "inherited";
            return (
              <tr
                key={m.label}
                className={overridden ? "bg-iris/8" : undefined}
              >
                <Cell>{m.label}</Cell>
                <Cell mono>{m.vendor}</Cell>
                <Cell mono>{m.modelId}</Cell>
                <Cell>
                  <span className={overridden ? "font-semibold text-iris" : "text-slate"}>
                    {overridden ? "env 上書き" : inherited ? "navigate 継承" : "コード既定"}
                  </span>
                </Cell>
              </tr>
            );
          })}
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
