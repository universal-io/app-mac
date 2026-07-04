"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { ensureBombSquadUser } from "@/lib/supabase/bootstrap";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";

type CallbackState = "checking" | "error";
type EmailOtpType =
  | "signup"
  | "invite"
  | "magiclink"
  | "recovery"
  | "email_change"
  | "email";

const emailOtpTypes = new Set<EmailOtpType>([
  "signup",
  "invite",
  "magiclink",
  "recovery",
  "email_change",
  "email",
]);

export function AuthCallbackHandler() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [state, setState] = useState<CallbackState>("checking");
  const [message, setMessage] = useState("メールリンクのログインを確認しています。");

  useEffect(() => {
    let isMounted = true;

    async function finishAuth() {
      const supabase = getSupabaseBrowserClient();
      const code = searchParams.get("code");
      const provider = searchParams.get("provider") ?? "email";
      const tokenHash = searchParams.get("token_hash");
      const type = parseEmailOtpType(searchParams.get("type"));

      try {
        if (code) {
          const { error } = await supabase.auth.exchangeCodeForSession(code);
          if (error) {
            throw error;
          }
        } else if (tokenHash) {
          const { error } = await supabase.auth.verifyOtp({
            token_hash: tokenHash,
            type,
          });
          if (error) {
            throw error;
          }
        }

        const {
          data: { session },
          error: sessionError,
        } = await supabase.auth.getSession();
        if (sessionError) {
          throw sessionError;
        }
        if (!session) {
          throw new Error("認証リンクの情報が見つかりません。もう一度メールを送信してください。");
        }

        await ensureBombSquadUser(session);

        if (!isMounted) {
          return;
        }

        router.replace(`/auth?status=complete&provider=${encodeURIComponent(provider)}`);
      } catch (error) {
        if (!isMounted) {
          return;
        }

        setState("error");
        setMessage(messageOf(error));
      }
    }

    void finishAuth();

    return () => {
      isMounted = false;
    };
  }, [router, searchParams]);

  return (
    <section className="w-full max-w-md rounded-2xl border border-line bg-white p-8 shadow-[0_1px_2px_rgba(16,17,20,0.04)]">
      <h1 className="text-2xl font-semibold text-ink">
        {state === "checking" ? "ログイン処理中" : "ログインできませんでした"}
      </h1>
      <p className="mt-4 text-sm leading-6 text-body">{message}</p>
      {state === "error" ? (
        <Link
          className="mt-6 inline-flex rounded-xl bg-ink px-5 py-3 text-sm font-medium text-white transition-colors hover:bg-iris"
          href="/auth"
        >
          認証ページに戻る
        </Link>
      ) : null}
    </section>
  );
}

function parseEmailOtpType(value: string | null): EmailOtpType {
  if (value && emailOtpTypes.has(value as EmailOtpType)) {
    return value as EmailOtpType;
  }
  return "email";
}

function messageOf(error: unknown) {
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
  return "メールリンクのログイン処理に失敗しました。もう一度やり直してください。";
}
