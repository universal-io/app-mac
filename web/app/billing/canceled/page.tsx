// Where Stripe returns the browser when Checkout was abandoned. Nothing was
// charged and nothing changed, so this only needs to say so.

export const metadata = { title: "お手続きを中止しました — Universal I/O" };

export default function BillingCanceledPage() {
  return (
    <main className="flex min-h-dvh items-center justify-center bg-paper px-6 text-ink">
      <section className="w-full max-w-md rounded-2xl border border-line bg-white p-6 shadow-[0_1px_2px_rgba(16,17,20,0.04)]">
        <h1 className="text-base font-semibold">お手続きを中止しました</h1>
        <p className="mt-2 text-sm text-body">
          お支払いは発生していません。このページは閉じて、Universal IO に戻ってください。
        </p>
      </section>
    </main>
  );
}
