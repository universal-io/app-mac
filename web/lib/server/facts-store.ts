// Per-user state for the fact vocabulary: what this account already told us,
// and which questions it has already been asked. The vocabulary itself is pure
// data and lives in lib/server/skills — this file is the only place that knows
// a user has a history with it.
//
// The rules it enforces are the ones that decide whether asking is tolerable at
// all: never ask about a fact we already hold, never ask again after a no, and
// stop after a few unanswered attempts. Without them the same question returns
// every single session, which is worse than never learning anything.

import { after } from "next/server";
import { allowedFactSlots } from "@/lib/server/skills/registry";
import {
  factSlotId,
  type AppSignals,
  type FactSlot,
} from "@/lib/server/skills/types";
import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";

/** Unanswered questions worth repeating before dropping the key for good. A
 * user who closed the panel three times has answered in the way that matters. */
export const MAX_FACT_ASKS_PER_KEY = 3;

/**
 * The slots this screen may ask about for this user: the vocabulary the active
 * skills declare, minus everything already known, declined, or exhausted.
 *
 * A failure here returns an empty list rather than throwing. Asking is the
 * optional half of the suggestion route, so a database hiccup must cost the
 * user a question, never their draft.
 */
export async function askableFactSlots(
  userId: string,
  signals: AppSignals | undefined,
): Promise<FactSlot[]> {
  const slots = allowedFactSlots(signals);
  if (slots.length === 0) return [];

  const admin = getSupabaseAdminClient();
  const [known, prompts] = await Promise.all([
    admin.from("bs_user_facts").select("scope, key").eq("user_id", userId),
    admin
      .from("bs_fact_prompts")
      .select("scope, key, ask_count, declined_at")
      .eq("user_id", userId),
  ]);
  if (known.error || prompts.error) {
    console.error(
      "[facts] askable lookup failed:",
      known.error?.message ?? prompts.error?.message,
    );
    return [];
  }

  const blocked = new Set<string>();
  for (const row of (known.data ?? []) as Array<{ scope: string; key: string }>) {
    blocked.add(factSlotId(row.scope, row.key));
  }
  for (const row of (prompts.data ?? []) as Array<{
    scope: string;
    key: string;
    ask_count: number | null;
    declined_at: string | null;
  }>) {
    if (row.declined_at || (row.ask_count ?? 0) >= MAX_FACT_ASKS_PER_KEY) {
      blocked.add(factSlotId(row.scope, row.key));
    }
  }

  return slots.filter((slot) => !blocked.has(factSlotId(slot.scope, slot.key)));
}

/**
 * Count an asked question after the response is on its way. The count belongs
 * to the question being shown, not to the answer, so a user who closes the
 * panel without answering still spends one — that is what eventually retires a
 * question nobody wants to answer.
 */
export function recordFactAskAfterResponse(userId: string, slot: FactSlot): void {
  after(async () => {
    const admin = getSupabaseAdminClient();
    const { data, error } = await admin
      .from("bs_fact_prompts")
      .select("ask_count")
      .eq("user_id", userId)
      .eq("scope", slot.scope)
      .eq("key", slot.key)
      .maybeSingle();
    if (error) {
      console.error("[facts] ask count read failed:", error.message);
      return;
    }
    const askCount = ((data?.ask_count as number | undefined) ?? 0) + 1;
    const { error: writeError } = await admin.from("bs_fact_prompts").upsert(
      {
        user_id: userId,
        scope: slot.scope,
        key: slot.key,
        ask_count: askCount,
        updated_at: new Date().toISOString(),
      },
      { onConflict: "user_id,scope,key" },
    );
    if (writeError) {
      console.error("[facts] ask count write failed:", writeError.message);
    }
  });
}

/** "No" means "do not store this", and it is permanent: a value that is simply
 * wrong is corrected on the management screen, not by being asked again. */
export async function recordFactDeclined(
  userId: string,
  scope: string,
  key: string,
): Promise<boolean> {
  const admin = getSupabaseAdminClient();
  const { data } = await admin
    .from("bs_fact_prompts")
    .select("ask_count")
    .eq("user_id", userId)
    .eq("scope", scope)
    .eq("key", key)
    .maybeSingle();
  const { error } = await admin.from("bs_fact_prompts").upsert(
    {
      user_id: userId,
      scope,
      key,
      ask_count: Math.max((data?.ask_count as number | undefined) ?? 0, 1),
      declined_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    { onConflict: "user_id,scope,key" },
  );
  if (error) {
    console.error("[facts] decline write failed:", error.message);
    return false;
  }
  return true;
}
