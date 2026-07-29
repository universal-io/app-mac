// Where Stripe returns the browser after Checkout or the customer portal.
//
// Deliberately says nothing about what the plan now is: the entitlement is
// applied by the webhook, which may land a moment after this redirect, so a
// claim made here could be wrong. The app reads the real state from /api/account.
//
// It does need a way out, though. Checkout starts on the product site, and
// landing on a Gateway page with nothing to click leaves the visitor stranded on
// a host that has no navigation of its own.

import { PRODUCT_SITE_URL } from "@/lib/site";

export const metadata = { title: "お手続き完了 — Universal I/O" };

export default function BillingCompletePage() {
  return (
    <main className="flex min-h-dvh items-center justify-center bg-paper px-6 text-ink">
      <section className="w-full max-w-md rounded-2xl border border-line bg-white p-6 shadow-[0_1px_2px_rgba(16,17,20,0.04)]">
        <h1 className="text-base font-semibold">お手続きが完了しました</h1>
        <p className="mt-2 text-sm leading-6 text-body">
          Universal IO に戻ってお使いください。プランの反映には数秒かかることがあります。
        </p>
        <a
          href={PRODUCT_SITE_URL}
          className="mt-5 inline-flex rounded-xl bg-ink px-5 py-3 text-sm font-medium text-white transition-colors hover:bg-iris"
        >
          製品サイトへ戻る
        </a>
      </section>
    </main>
  );
}
