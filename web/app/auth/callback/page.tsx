import { Suspense } from "react";
import { AuthCallbackHandler } from "./callback-handler";

export default function AuthCallbackPage() {
  return (
    <main className="flex min-h-dvh items-center justify-center bg-paper px-6 text-ink">
      <Suspense
        fallback={
          <section className="w-full max-w-md rounded-2xl border border-line bg-white p-6 shadow-[0_1px_2px_rgba(16,17,20,0.04)]">
            <p className="text-sm text-body">メールリンクのログインを確認しています。</p>
          </section>
        }
      >
        <AuthCallbackHandler />
      </Suspense>
    </main>
  );
}
