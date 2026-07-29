"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { useBrowserSession } from "@/lib/supabase/use-browser-session";

/** Plans this page may start. The server re-checks against bs_plan_prices; this
 * only keeps a stray query string from reaching the API. */
const PURCHASABLE_PLANS = new Set(["standard"]);
const DEFAULT_PLAN = "standard";

type Outcome =
  | { kind: "subscribed" }
  | { kind: "error"; message: string };

export function CheckoutStarter({ plan }: { plan?: string }) {
  const router = useRouter();
  const { isConfigured, isLoading, session } = useBrowserSession();
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  // Checkout session creation must fire once. The auth listener can re-render
  // this component, and a second POST would create a second Stripe session.
  const started = useRef(false);

  const resolvedPlan = plan && PURCHASABLE_PLANS.has(plan) ? plan : DEFAULT_PLAN;

  useEffect(() => {
    if (!isConfigured || isLoading) return;

    if (!session) {
      // Buying requires an account, so send them to sign-in and come back here
      // with the same plan. AuthShell forwards to `next` on success, and
      // bounces straight there if a session already exists.
      const back = `/billing/start?plan=${encodeURIComponent(resolvedPlan)}`;
      router.replace(`/auth?next=${encodeURIComponent(back)}`);
      return;
    }

    if (started.current) return;
    started.current = true;

    let cancelled = false;
    void (async () => {
      try {
        const res = await fetch("/api/billing/checkout", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${session.access_token}`,
          },
          body: JSON.stringify({ plan: resolvedPlan }),
        });
        const body = (await res.json().catch(() => null)) as
          | { url?: string; error?: { code?: string; message?: string } }
          | null;
        if (cancelled) return;

        if (res.ok && body?.url) {
          // Leave the SPA entirely: Checkout is hosted by Stripe.
          window.location.href = body.url;
          return;
        }
        if (body?.error?.code === "SUBSCRIPTION_EXISTS") {
          setOutcome({ kind: "subscribed" });
          return;
        }
        setOutcome({
          kind: "error",
          message:
            body?.error?.message
            ?? "お手続きを開始できませんでした。時間をおいて再試行してください。",
        });
      } catch {
        if (!cancelled) {
          setOutcome({
            kind: "error",
            message: "通信に失敗しました。接続を確認して再試行してください。",
          });
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [isConfigured, isLoading, session, resolvedPlan, router]);

  // Derived during render rather than set from the effect: a missing Supabase
  // configuration is knowable without doing anything.
  const view: Outcome | null = !isConfigured
    ? {
        kind: "error",
        message: "現在お手続きを開始できません。時間をおいて再試行してください。",
      }
    : outcome;

  return (
    <section className="w-full max-w-md rounded-2xl border border-line bg-white p-8 shadow-[0_1px_2px_rgba(16,17,20,0.04)]">
      <h1 className="text-2xl font-semibold">
        {view === null
          ? "お手続きを準備しています"
          : view.kind === "subscribed"
            ? "すでに契約があります"
            : "お手続きを開始できませんでした"}
      </h1>
      <p className="mt-4 text-sm leading-6 text-body">
        {view === null
          ? "決済ページへ移動します。そのままお待ちください。"
          : view.kind === "subscribed"
            ? "プランの変更と解約は、お支払い管理から行えます。"
            : view.message}
      </p>
      {view !== null ? (
        <Link
          className="mt-6 inline-flex rounded-xl bg-ink px-5 py-3 text-sm font-medium text-white transition-colors hover:bg-iris"
          href="/admin"
        >
          アカウントへ戻る
        </Link>
      ) : null}
    </section>
  );
}
