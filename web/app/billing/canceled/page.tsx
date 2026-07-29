// Where Stripe returns the browser when Checkout was abandoned. Nothing was
// charged and nothing changed, so this only needs to say so — and, like the
// completion page, give the visitor a way back to a host that has navigation.

import { PRODUCT_SITE_URL } from "@/lib/site";

export const metadata = { title: "お手続きを中止しました — Universal I/O" };

export default function BillingCanceledPage() {
  return (
    <main className="flex min-h-dvh items-center justify-center bg-paper px-6 text-ink">
      <section className="w-full max-w-md rounded-2xl border border-line bg-white p-6 shadow-[0_1px_2px_rgba(16,17,20,0.04)]">
        <h1 className="text-base font-semibold">お手続きを中止しました</h1>
        <p className="mt-2 text-sm leading-6 text-body">
          お支払いは発生していません。無料プランはそのままお使いいただけます。
        </p>
        <div className="mt-5 flex flex-wrap items-center gap-4">
          <a
            href={`${PRODUCT_SITE_URL}/ja/pricing`}
            className="inline-flex rounded-xl bg-ink px-5 py-3 text-sm font-medium text-white transition-colors hover:bg-iris"
          >
            料金ページへ戻る
          </a>
          <a
            href={PRODUCT_SITE_URL}
            className="text-sm font-medium text-iris transition-colors hover:underline"
          >
            製品サイトへ
          </a>
        </div>
      </section>
    </main>
  );
}
