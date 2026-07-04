"use client";

import { useEffect, useState } from "react";
import { getPublicEnv } from "@/lib/env";
import { ensureBombSquadUser } from "@/lib/supabase/bootstrap";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";
import { useBrowserSession } from "@/lib/supabase/use-browser-session";

const env = getPublicEnv();

type AuthShellProps = {
  initialProvider?: string;
  initialStatus?: string;
};

export function AuthShell({ initialProvider, initialStatus }: AuthShellProps) {
  const [email, setEmail] = useState("");
  const { isConfigured, session } = useBrowserSession();
  const [notice, setNotice] = useState<string | null>(messageForStatus(initialStatus, initialProvider));
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isSending, setIsSending] = useState(false);
  const [isGoogleSigningIn, setIsGoogleSigningIn] = useState(false);
  const [isSigningOut, setIsSigningOut] = useState(false);
  const [hasSentLink, setHasSentLink] = useState(false);

  useEffect(() => {
    if (!session) {
      return;
    }

    let isMounted = true;

    void ensureBombSquadUser(session)
      .catch((error) => {
        if (!isMounted) {
          return;
        }
        setErrorMessage(messageOf(error));
      });

    return () => {
      isMounted = false;
    };
  }, [session]);

  async function sendMagicLink(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!env.isConfigured || !email.trim()) {
      return;
    }

    setIsSending(true);
    setErrorMessage(null);
    setNotice(null);

    try {
      const supabase = getSupabaseBrowserClient();
      const { error } = await supabase.auth.signInWithOtp({
        email: email.trim(),
        options: {
          emailRedirectTo: `${window.location.origin}/auth/callback?provider=email`,
        },
      });

      if (error) {
        throw error;
      }

      setHasSentLink(true);
      setNotice("ログイン用メールを送信しました。受信したメールのリンクを開くと、この画面に戻ってログインが完了します。");
    } catch (error) {
      setErrorMessage(messageOf(error));
    } finally {
      setIsSending(false);
    }
  }

  async function signInWithGoogle() {
    if (!env.isConfigured) {
      return;
    }

    setIsGoogleSigningIn(true);
    setErrorMessage(null);
    setNotice(null);

    try {
      const supabase = getSupabaseBrowserClient();
      const { error } = await supabase.auth.signInWithOAuth({
        options: {
          redirectTo: `${window.location.origin}/auth/callback?provider=google`,
        },
        provider: "google",
      });

      if (error) {
        throw error;
      }
    } catch (error) {
      setIsGoogleSigningIn(false);
      setErrorMessage(messageOf(error));
    }
  }

  async function signOut() {
    if (!env.isConfigured) {
      return;
    }

    setIsSigningOut(true);
    setErrorMessage(null);
    setNotice(null);

    try {
      const supabase = getSupabaseBrowserClient();
      const { error } = await supabase.auth.signOut();
      if (error) {
        throw error;
      }
      setHasSentLink(false);
      setNotice("ログアウトしました。");
    } catch (error) {
      setErrorMessage(messageOf(error));
    } finally {
      setIsSigningOut(false);
    }
  }

  if (!isConfigured) {
    return (
      <section className="rounded-2xl border border-line bg-white p-8 shadow-[0_1px_2px_rgba(16,17,20,0.04)]">
        <h2 className="text-2xl font-semibold text-ink">ログイン</h2>
        <p className="mt-3 text-sm leading-6 text-body">
          現在はログイン設定を確認しています。少し時間を置いて再度お試しください。
        </p>
      </section>
    );
  }

  return (
    <section className="rounded-2xl border border-line bg-white p-8 shadow-[0_1px_2px_rgba(16,17,20,0.04)]">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-2xl font-semibold text-ink">
            {session ? "ログイン済み" : "ログイン"}
          </h2>
          <p className="mt-3 text-sm leading-6 text-body">
            {session
              ? "このブラウザで Universal I/O にログインできています。"
              : "メールアドレスまたは Google アカウントでログインできます。"}
          </p>
        </div>
        <div className="rounded-full border border-line px-3 py-1 text-xs text-slate">
          {session ? "Signed in" : "Guest"}
        </div>
      </div>

      {notice ? (
        <div aria-live="polite" className="mt-6 flex items-start gap-2.5 rounded-xl border border-line bg-paper px-4 py-3 text-sm leading-6 text-body">
          <span className="mt-[7px] h-2 w-2 shrink-0 rounded-full bg-cyan" />
          {notice}
        </div>
      ) : null}

      {errorMessage ? (
        <div aria-live="polite" className="mt-6 rounded-xl border border-coral/40 bg-coral/5 px-4 py-3 text-sm leading-6 text-ink">
          {errorMessage}
        </div>
      ) : null}

      {session?.user.email ? (
        <div className="mt-8 space-y-6">
          <div className="rounded-xl border border-line bg-paper p-5">
            <div className="text-sm text-slate">アカウント</div>
            <div className="mt-2 text-lg font-medium text-ink">{session.user.email}</div>
            <p className="mt-3 text-sm leading-6 text-body">
              このブラウザでは現在このアカウントで利用できます。
            </p>
          </div>

          <div className="flex flex-wrap gap-3">
            <button
              className="rounded-xl bg-ink px-5 py-3 text-sm font-medium text-white transition-colors hover:bg-iris disabled:cursor-not-allowed disabled:opacity-50"
              disabled={isSigningOut}
              onClick={signOut}
              type="button"
            >
              {isSigningOut ? "ログアウト中..." : "ログアウト"}
            </button>
          </div>
        </div>
      ) : (
        <div className="mt-8">
          <form className="space-y-5" onSubmit={sendMagicLink}>
            <div>
              <label className="mb-2 block text-sm font-medium text-body" htmlFor="email">
                メールアドレス
              </label>
              <input
                aria-describedby={hasSentLink ? "email-help" : errorMessage ? "email-error" : undefined}
                aria-invalid={errorMessage ? "true" : "false"}
                className="w-full rounded-xl border border-edge bg-white px-4 py-3 text-ink outline-none transition-colors placeholder:text-faint focus:border-iris"
                id="email"
                onChange={(event) => setEmail(event.target.value)}
                placeholder="you@example.com"
                type="email"
                value={session?.user.email ?? email}
              />
              <p className="mt-2 text-sm text-slate" id={hasSentLink ? "email-help" : errorMessage ? "email-error" : undefined}>
                {hasSentLink
                  ? "メールを再送したい場合は、そのままもう一度送信できます。"
                  : "入力したアドレス宛てにログインリンクを送信します。"}
              </p>
            </div>

            <button
              className="w-full rounded-xl bg-ink px-5 py-3 text-sm font-medium text-white transition-colors hover:bg-iris disabled:cursor-not-allowed disabled:opacity-50"
              disabled={isSending || !email.trim()}
              type="submit"
            >
              {isSending ? "送信中..." : hasSentLink ? "ログインリンクを再送" : "ログインリンクを送信"}
            </button>
          </form>

          <div className="my-6 flex items-center gap-3">
            <div className="h-px flex-1 bg-line" />
            <span className="text-sm text-slate">または</span>
            <div className="h-px flex-1 bg-line" />
          </div>

          <button
            className="w-full rounded-xl border border-edge bg-white px-5 py-3 text-sm font-medium text-ink transition-colors hover:border-ink disabled:cursor-not-allowed disabled:opacity-50"
            disabled={isGoogleSigningIn}
            onClick={signInWithGoogle}
            type="button"
          >
            {isGoogleSigningIn ? "Google に移動しています..." : "Google でログイン"}
          </button>
        </div>
      )}
    </section>
  );
}

function messageForStatus(status: string | undefined, provider: string | undefined) {
  if (status === "complete") {
    return provider === "google"
      ? "Google 認証が完了しました。ログイン済みです。"
      : "メールリンクでのログインが完了しました。ログイン済みです。";
  }
  return null;
}

function messageOf(error: unknown) {
  if (isStatus500(error)) {
    return "Supabase Auth が 500 を返しました。メールプロバイダ設定、Auth テンプレート、または auth.users まわりのDB設定を確認してください。";
  }
  if (error instanceof Error) {
    return error.message;
  }
  if (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message;
  }
  try {
    return JSON.stringify(error);
  } catch {
    return "認証処理で不明なエラーが発生しました。";
  }
}

function isStatus500(error: unknown) {
  return (
    typeof error === "object" &&
    error !== null &&
    "status" in error &&
    error.status === 500
  );
}
