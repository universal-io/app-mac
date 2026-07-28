// Where Stripe returns the browser after Checkout or the customer portal.
// Deliberately says nothing about what the plan now is: the entitlement is
// applied by the webhook, which may land a moment after this redirect, so a
// claim made here could be wrong. The app reads the real state from /api/account.

export const metadata = { title: "お手続き完了 — Universal I/O" };

export default function BillingCompletePage() {
  return (
    <main className="flex min-h-dvh items-center justify-center bg-paper px-6 text-ink">
      <section className="w-full max-w-md rounded-2xl border border-line bg-white p-6 shadow-[0_1px_2px_rgba(16,17,20,0.04)]">
        <h1 className="text-base font-semibold">お手続きが完了しました</h1>
        <p className="mt-2 text-sm text-body">
          このページは閉じて、Universal IO に戻ってください。プランの反映には数秒かかることがあります。
        </p>
      </section>
    </main>
  );
}
