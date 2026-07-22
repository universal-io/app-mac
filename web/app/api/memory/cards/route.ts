// Memory sync: GET/PUT /api/memory/cards.
// Persona/relationship cards are authored client-side (bootstrap, distill,
// user edits) and live in local SQLite; this route is the only place they
// leave the device, so a signed-in user can share cards across their Macs.
// GET returns the full server-side state (including tombstones). PUT accepts
// the client's full local state, merges it with last-write-wins conflict
// resolution keyed on the client logical clock (`updated_at`), and returns
// the merged server state so the client can complete a pull in one round
// trip. There is no DELETE: deletions propagate as tombstone rows
// (`deleted_at` set) sent through PUT, same as any other card update.

import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";
import {
  authenticate,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";

const MAX_CARDS = 200;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CARD_KINDS = new Set(["persona", "relationship"]);
const CARD_SOURCES = new Set(["bootstrap", "distilled", "user_edited"]);

type CardKind = "persona" | "relationship";
type CardSource = "bootstrap" | "distilled" | "user_edited";

// Wire format: timestamps are epoch seconds (number), matching the client's
// SQLite representation. The database stores them as timestamptz; this
// route does the conversion in both directions.
type WireCard = {
  id: string;
  kind: CardKind;
  subject: string | null;
  content_md: string;
  source: CardSource;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
};

type MemoryCardRow = {
  id: string;
  kind: string;
  subject: string | null;
  content_md: string;
  source: string;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
};

function toWireCard(row: MemoryCardRow): WireCard {
  const isDeleted = row.deleted_at !== null;
  return {
    id: row.id,
    kind: row.kind as CardKind,
    subject: isDeleted ? null : row.subject,
    content_md: isDeleted ? "" : row.content_md,
    source: row.source as CardSource,
    created_at: new Date(row.created_at).getTime() / 1000,
    updated_at: new Date(row.updated_at).getTime() / 1000,
    deleted_at: row.deleted_at ? new Date(row.deleted_at).getTime() / 1000 : null,
  };
}

/** Validates one card from the request body. Returns null if malformed. */
function parseIncomingCard(raw: unknown): WireCard | null {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const card = raw as Record<string, unknown>;
  const { id, kind, subject, source } = card;
  const contentMd = card.content_md;
  const createdAt = card.created_at;
  const updatedAt = card.updated_at;
  const deletedAt = card.deleted_at;

  if (typeof id !== "string" || !UUID_RE.test(id)) {
    return null;
  }
  if (typeof kind !== "string" || !CARD_KINDS.has(kind)) {
    return null;
  }
  if (subject !== undefined && subject !== null && typeof subject !== "string") {
    return null;
  }
  if (typeof contentMd !== "string") {
    return null;
  }
  if (typeof source !== "string" || !CARD_SOURCES.has(source)) {
    return null;
  }
  if (typeof createdAt !== "number" || !Number.isFinite(createdAt)) {
    return null;
  }
  if (typeof updatedAt !== "number" || !Number.isFinite(updatedAt)) {
    return null;
  }
  if (
    deletedAt !== undefined &&
    deletedAt !== null &&
    (typeof deletedAt !== "number" || !Number.isFinite(deletedAt))
  ) {
    return null;
  }

  const isDeleted = deletedAt !== undefined && deletedAt !== null;
  return {
    id,
    kind: kind as CardKind,
    subject: isDeleted ? null : (subject ?? null),
    content_md: isDeleted ? "" : contentMd,
    source: source as CardSource,
    created_at: createdAt,
    updated_at: updatedAt,
    deleted_at: (deletedAt as number | null | undefined) ?? null,
  };
}

const CARD_SELECT_COLUMNS =
  "id, kind, subject, content_md, source, created_at, updated_at, deleted_at";

export async function GET(request: Request): Promise<Response> {
  try {
    const { userId } = await authenticate(request);

    const admin = getSupabaseAdminClient();
    const { data, error } = await admin
      .from("bs_memory_cards")
      .select(CARD_SELECT_COLUMNS)
      .eq("user_id", userId);
    if (error) {
      console.error("[/api/memory/cards] GET query failed:", error.message);
      return errorResponse(500, "INTERNAL_ERROR", "Failed to load memory cards.", null);
    }

    return Response.json({ cards: ((data ?? []) as MemoryCardRow[]).map(toWireCard) });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, null);
    }
    console.error("[/api/memory/cards] GET internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}

export async function PUT(request: Request): Promise<Response> {
  try {
    const body = (await request.json().catch(() => null)) as { cards?: unknown } | null;
    if (!body || !Array.isArray(body.cards)) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be JSON with a 'cards' array.", null);
    }
    if (body.cards.length > MAX_CARDS) {
      return errorResponse(400, "BAD_REQUEST", `cards must not exceed ${MAX_CARDS} entries.`, null);
    }

    const parsedCards: WireCard[] = [];
    for (const raw of body.cards) {
      const parsed = parseIncomingCard(raw);
      if (!parsed) {
        return errorResponse(400, "BAD_REQUEST", "Each card must match the memory card schema.", null);
      }
      parsedCards.push(parsed);
    }

    const { userId, tenantId } = await authenticate(request);
    const admin = getSupabaseAdminClient();

    // Dedupe by id in case the client sent the same card twice in one
    // payload, keeping whichever copy has the newer logical clock.
    const incomingById = new Map<string, WireCard>();
    for (const card of parsedCards) {
      const current = incomingById.get(card.id);
      if (!current || card.updated_at > current.updated_at) {
        incomingById.set(card.id, card);
      }
    }

    const ids = Array.from(incomingById.keys());
    const existingById = new Map<string, { user_id: string; updated_at: string }>();
    if (ids.length > 0) {
      const { data: existingRows, error: existingError } = await admin
        .from("bs_memory_cards")
        .select("id, user_id, updated_at")
        .in("id", ids);
      if (existingError) {
        console.error("[/api/memory/cards] PUT existing-lookup failed:", existingError.message);
        return errorResponse(500, "INTERNAL_ERROR", "Failed to resolve existing memory cards.", null);
      }
      for (const row of (existingRows ?? []) as { id: string; user_id: string; updated_at: string }[]) {
        existingById.set(row.id, { user_id: row.user_id, updated_at: row.updated_at });
      }
    }

    // Last-write-wins merge: write a card only if it is new, or if it already
    // belongs to this user and its logical clock is strictly newer than what
    // is stored. A card whose id already belongs to a different user is
    // skipped rather than overwritten -- the admin client bypasses RLS, so
    // that ownership check has to happen here, in the route.
    const rowsToWrite: Record<string, unknown>[] = [];
    for (const card of incomingById.values()) {
      const existing = existingById.get(card.id);
      if (existing && existing.user_id !== userId) {
        continue;
      }
      if (existing) {
        const existingUpdatedAt = new Date(existing.updated_at).getTime() / 1000;
        if (card.updated_at <= existingUpdatedAt) {
          continue;
        }
      }
      rowsToWrite.push({
        id: card.id,
        tenant_id: tenantId,
        user_id: userId,
        kind: card.kind,
        subject: card.deleted_at !== null ? null : card.subject,
        content_md: card.deleted_at !== null ? "" : card.content_md,
        source: card.source,
        created_at: new Date(card.created_at * 1000).toISOString(),
        updated_at: new Date(card.updated_at * 1000).toISOString(),
        deleted_at: card.deleted_at !== null ? new Date(card.deleted_at * 1000).toISOString() : null,
      });
    }

    if (rowsToWrite.length > 0) {
      const { error: upsertError } = await admin
        .from("bs_memory_cards")
        .upsert(rowsToWrite, { onConflict: "id" });
      if (upsertError) {
        console.error("[/api/memory/cards] PUT upsert failed:", upsertError.message);
        return errorResponse(500, "INTERNAL_ERROR", "Failed to save memory cards.", null);
      }
    }

    const { data: mergedRows, error: mergedError } = await admin
      .from("bs_memory_cards")
      .select(CARD_SELECT_COLUMNS)
      .eq("user_id", userId);
    if (mergedError) {
      console.error("[/api/memory/cards] PUT merged-state query failed:", mergedError.message);
      return errorResponse(500, "INTERNAL_ERROR", "Failed to load merged memory cards.", null);
    }

    return Response.json({ cards: ((mergedRows ?? []) as MemoryCardRow[]).map(toWireCard) });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, null);
    }
    console.error("[/api/memory/cards] PUT internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}
