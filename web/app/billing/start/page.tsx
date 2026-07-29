// The purchase entry point linked from the pricing page on universal-io.com.
// Sign-in is required to buy, so this page is the join between the two: it
// bounces an anonymous visitor through /auth?next=… and back, then starts
// Checkout. A signed-in visitor never sees it for more than a moment.
//
// `plan` arrives as a search param and is passed down rather than read with
// useSearchParams, so the client component needs no Suspense boundary.

import { CheckoutStarter } from "./checkout-starter";

export const metadata = { title: "お手続きを開始します — Universal I/O" };

type PageProps = {
  searchParams?: Promise<{ plan?: string }>;
};

export default async function BillingStartPage({ searchParams }: PageProps) {
  const params = await searchParams;
  return (
    <main className="flex min-h-dvh items-center justify-center bg-paper px-6 text-ink">
      <CheckoutStarter plan={params?.plan} />
    </main>
  );
}
