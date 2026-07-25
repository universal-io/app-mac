// Gateway: /api/facts. The user's own facts — what the app is allowed to
// remember about them — plus the vocabulary of everything it could ever
// remember. No AI call, no usage event: this is account data, so it stays
// readable on a lapsed plan for the same reason /api/account does.
//
// The whole set is a few dozen rows, so there is no cursor, no delta, and no
// tombstone. Clients pull all of it and write one key at a time.

import {
  authenticate,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";
import { factSlot, factVocabulary } from "@/lib/server/skills/registry";
import { MAX_FACT_VALUE_CHARS } from "@/lib/server/skills/types";
import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";

type StoredFact = {
  scope: string;
  key: string;
  value: string;
  updated_at: string;
};

export async function GET(request: Request): Promise<Response> {
  try {
    const { userId } = await authenticate(request, { requireActiveEntitlement: false });
    const admin = getSupabaseAdminClient();
    const { data, error } = await admin
      .from("bs_user_facts")
      .select("scope, key, value, updated_at")
      .eq("user_id", userId);
    if (error) {
      console.error("[/api/facts] read failed:", error.message);
      return errorResponse(500, "FACTS_READ_FAILED", "記憶している内容を読み込めませんでした。", null);
    }

    const stored = (data ?? []) as StoredFact[];
    return Response.json({
      // Every slot, whether filled or not: the point of this list is that the
      // user can see what the app is able to learn, not only what it did.
      facts: factVocabulary().map((slot) => {
        const match = stored.find(
          (fact) => fact.scope === slot.scope && fact.key === slot.key,
        );
        return {
          scope: slot.scope,
          scope_label: slot.scopeLabel,
          key: slot.key,
          label: slot.label,
          value: match?.value ?? null,
          updated_at: match?.updated_at ?? null,
        };
      }),
      max_value_chars: MAX_FACT_VALUE_CHARS,
    });
  } catch (error) {
    if (error instanceof GatewayError) return gatewayErrorResponse(error, null);
    console.error("[/api/facts] GET internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}

export async function PUT(request: Request): Promise<Response> {
  try {
    const body = (await request.json().catch(() => null)) as
      | { scope?: unknown; key?: unknown; value?: unknown }
      | null;
    const scope = typeof body?.scope === "string" ? body.scope : null;
    const key = typeof body?.key === "string" ? body.key : null;
    const rawValue = typeof body?.value === "string" ? body.value : null;
    if (!scope || !key || rawValue === null) {
      return errorResponse(400, "BAD_REQUEST", "scope, key, value are required.", null);
    }
    // A key outside the declared vocabulary is the one thing that could make
    // this table grow without limit, so it is refused before anything else.
    if (!factSlot(scope, key)) {
      return errorResponse(400, "UNKNOWN_FACT_KEY", "その項目は保存できません。", null);
    }
    const value = normalizeValue(rawValue);
    if (!value) {
      return errorResponse(
        400,
        "BAD_REQUEST",
        `値は1〜${MAX_FACT_VALUE_CHARS}文字で入力してください。`,
        null,
      );
    }

    const { userId } = await authenticate(request, { requireActiveEntitlement: false });
    const admin = getSupabaseAdminClient();
    const { data, error } = await admin
      .from("bs_user_facts")
      .upsert(
        { user_id: userId, scope, key, value, updated_at: new Date().toISOString() },
        { onConflict: "user_id,scope,key" },
      )
      .select("scope, key, value, updated_at")
      .single();
    if (error || !data) {
      console.error("[/api/facts] upsert failed:", error?.message);
      return errorResponse(500, "FACT_WRITE_FAILED", "内容を保存できませんでした。", null);
    }

    return Response.json({ fact: data });
  } catch (error) {
    if (error instanceof GatewayError) return gatewayErrorResponse(error, null);
    console.error("[/api/facts] PUT internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}

export async function DELETE(request: Request): Promise<Response> {
  try {
    const body = (await request.json().catch(() => null)) as
      | { scope?: unknown; key?: unknown }
      | null;
    const scope = typeof body?.scope === "string" ? body.scope : null;
    const key = typeof body?.key === "string" ? body.key : null;
    if (!scope || !key) {
      return errorResponse(400, "BAD_REQUEST", "scope and key are required.", null);
    }

    const { userId } = await authenticate(request, { requireActiveEntitlement: false });
    const admin = getSupabaseAdminClient();
    // Deleting a key the vocabulary no longer declares must keep working: a
    // retired skill leaves rows behind, and the user has to be able to remove
    // them. Only writes are checked against the vocabulary.
    const { error } = await admin
      .from("bs_user_facts")
      .delete()
      .eq("user_id", userId)
      .eq("scope", scope)
      .eq("key", key);
    if (error) {
      console.error("[/api/facts] delete failed:", error.message);
      return errorResponse(500, "FACT_DELETE_FAILED", "内容を削除できませんでした。", null);
    }

    return Response.json({ deleted: true });
  } catch (error) {
    if (error instanceof GatewayError) return gatewayErrorResponse(error, null);
    console.error("[/api/facts] DELETE internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}

/** Facts are shown back to the user and, later, injected into prompts. Newlines
 * and control characters have no place in an identifier and are exactly what a
 * hostile screen would use to break out of the surrounding text. */
function normalizeValue(raw: string): string | null {
  const collapsed = raw
    .replace(/[\u0000-\u001F\u007F]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!collapsed || collapsed.length > MAX_FACT_VALUE_CHARS) return null;
  return collapsed;
}
