// Account-scoped incremental memory sync: GET returns the current server
// state for diagnostics/older clients; PUT sends a bounded dirty-card batch
// plus a server cursor and returns only newer server rows. The gateway owns
// the authoritative updated_at clock. A base-version mismatch is returned as
// an explicit conflict and never silently overwrites either copy.

import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";
import {
  authenticate,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";

const MAX_BATCH = 100;
const PAGE_SIZE = 500;
const MAX_SUBJECT_CHARS = 500;
const MAX_CONTENT_CHARS = 20_000;
const MAX_FUTURE_SKEW_SECONDS = 5 * 60;
const MAX_DATE_EPOCH_SECONDS = 8_640_000_000_000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CARD_KINDS = new Set(["persona", "relationship"]);
const CARD_SOURCES = new Set(["bootstrap", "distilled", "user_edited"]);
const CARD_SELECT_COLUMNS =
  "id, kind, subject, content_md, source, created_at, updated_at, deleted_at";

type CardKind = "persona" | "relationship";
type CardSource = "bootstrap" | "distilled" | "user_edited";

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

type IncomingCard = WireCard & { base_updated_at: number | null };

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

function parseIncomingCard(raw: unknown, incremental: boolean): IncomingCard | null {
  if (!raw || typeof raw !== "object") return null;
  const card = raw as Record<string, unknown>;
  const { id, kind, subject, source } = card;
  const contentMd = card.content_md;
  const createdAt = card.created_at;
  const updatedAt = card.updated_at;
  const deletedAt = card.deleted_at;
  const baseUpdatedAt = card.base_updated_at;

  if (typeof id !== "string" || !UUID_RE.test(id)) return null;
  if (typeof kind !== "string" || !CARD_KINDS.has(kind)) return null;
  if (subject !== undefined && subject !== null && typeof subject !== "string") return null;
  if (typeof contentMd !== "string") return null;
  if (typeof subject === "string" && subject.length > MAX_SUBJECT_CHARS) return null;
  if (contentMd.length > MAX_CONTENT_CHARS) return null;
  if (typeof source !== "string" || !CARD_SOURCES.has(source)) return null;
  if (typeof createdAt !== "number" || !Number.isFinite(createdAt)) return null;
  if (typeof updatedAt !== "number" || !Number.isFinite(updatedAt)) return null;
  if (Math.abs(createdAt) > MAX_DATE_EPOCH_SECONDS) return null;
  if (Math.abs(updatedAt) > MAX_DATE_EPOCH_SECONDS) return null;
  if (
    deletedAt !== undefined &&
    deletedAt !== null &&
    (typeof deletedAt !== "number" || !Number.isFinite(deletedAt))
  ) return null;
  if (typeof deletedAt === "number" && Math.abs(deletedAt) > MAX_DATE_EPOCH_SECONDS) return null;
  if (
    incremental &&
    baseUpdatedAt !== undefined &&
    baseUpdatedAt !== null &&
    (typeof baseUpdatedAt !== "number" || !Number.isFinite(baseUpdatedAt))
  ) return null;

  const isDeleted = deletedAt !== undefined && deletedAt !== null;
  return {
    id,
    kind: kind as CardKind,
    subject: isDeleted ? null : (subject ?? null) as string | null,
    content_md: isDeleted ? "" : contentMd,
    source: source as CardSource,
    created_at: createdAt,
    updated_at: updatedAt,
    deleted_at: (deletedAt as number | null | undefined) ?? null,
    base_updated_at: incremental
      ? (baseUpdatedAt as number | null | undefined) ?? null
      : null,
  };
}

function hasSamePayload(row: MemoryCardRow, card: IncomingCard): boolean {
  const current = toWireCard(row);
  return current.kind === card.kind
    && current.subject === card.subject
    && current.content_md === card.content_md
    && current.source === card.source
    && (current.deleted_at !== null) === (card.deleted_at !== null);
}

export async function GET(request: Request): Promise<Response> {
  try {
    const { userId } = await authenticate(request);
    const admin = getSupabaseAdminClient();
    const { data, error } = await admin
      .from("bs_memory_cards")
      .select(CARD_SELECT_COLUMNS)
      .eq("user_id", userId)
      .order("updated_at", { ascending: true });
    if (error) {
      console.error("[/api/memory/cards] GET query failed:", error.message);
      return errorResponse(500, "INTERNAL_ERROR", "Failed to load memory cards.", null);
    }
    return Response.json({ cards: ((data ?? []) as MemoryCardRow[]).map(toWireCard) });
  } catch (error) {
    if (error instanceof GatewayError) return gatewayErrorResponse(error, null);
    console.error("[/api/memory/cards] GET internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}

export async function PUT(request: Request): Promise<Response> {
  try {
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    if (!body || !Array.isArray(body.cards)) {
      return errorResponse(400, "BAD_REQUEST", "Request body must contain a cards array.", null);
    }

    // `cursor` being present identifies the new incremental protocol. The
    // legacy full-state branch remains during the released client's upgrade
    // window so deploying the Gateway does not break v0.1.0 immediately.
    const incremental = Object.prototype.hasOwnProperty.call(body, "cursor");
    if (incremental) {
      const cursor = body.cursor;
      if (cursor !== null && (typeof cursor !== "number" || !Number.isFinite(cursor))) {
        return errorResponse(400, "BAD_REQUEST", "cursor must be epoch seconds or null.", null);
      }
      if (
        typeof cursor === "number"
        && (cursor < 0 || cursor > Date.now() / 1000 + MAX_FUTURE_SKEW_SECONDS)
      ) {
        return errorResponse(400, "BAD_REQUEST", "cursor is outside the allowed time range.", null);
      }
      if (body.cards.length > MAX_BATCH) {
        return errorResponse(400, "BAD_REQUEST", `cards must not exceed ${MAX_BATCH} entries.`, null);
      }
    } else if (body.cards.length > 200) {
      return errorResponse(400, "BAD_REQUEST", "cards must not exceed 200 entries.", null);
    }

    const parsedCards: IncomingCard[] = [];
    for (const raw of body.cards) {
      const parsed = parseIncomingCard(raw, incremental);
      if (!parsed) {
        return errorResponse(400, "BAD_REQUEST", "Each card must match the memory card schema.", null);
      }
      parsedCards.push(parsed);
    }

    const { userId, tenantId } = await authenticate(request);
    const admin = getSupabaseAdminClient();
    const incomingById = new Map<string, IncomingCard>();
    for (const card of parsedCards) incomingById.set(card.id, card);

    const ids = Array.from(incomingById.keys());
    const existingById = new Map<string, MemoryCardRow & { user_id: string }>();
    if (ids.length > 0) {
      const { data, error } = await admin
        .from("bs_memory_cards")
        .select(`user_id, ${CARD_SELECT_COLUMNS}`)
        .in("id", ids);
      if (error) {
        console.error("[/api/memory/cards] existing lookup failed:", error.message);
        return errorResponse(500, "INTERNAL_ERROR", "Failed to resolve memory cards.", null);
      }
      for (const row of (data ?? []) as (MemoryCardRow & { user_id: string })[]) {
        existingById.set(row.id, row);
      }
    }

    if (!incremental) {
      return await handleLegacyFullSync(userId, tenantId, incomingById, existingById);
    }

    const { data: latestRows, error: latestError } = await admin
      .from("bs_memory_cards")
      .select("updated_at")
      .eq("user_id", userId)
      .order("updated_at", { ascending: false })
      .limit(1);
    if (latestError) {
      console.error("[/api/memory/cards] latest version lookup failed:", latestError.message);
      return errorResponse(500, "INTERNAL_ERROR", "Failed to resolve memory cards.", null);
    }

    const conflicts: WireCard[] = [];
    const syncedIds: string[] = [];
    const acknowledgedRows = new Map<string, MemoryCardRow>();
    const cursor = body.cursor as number | null;
    const latestServerMs = latestRows?.[0]?.updated_at
      ? new Date(latestRows[0].updated_at as string).getTime()
      : 0;
    let nextTimestampMs = Math.max(Date.now(), (cursor ?? 0) * 1000 + 1, latestServerMs + 1);

    for (const card of incomingById.values()) {
      const existing = existingById.get(card.id);
      if (existing?.user_id !== undefined && existing.user_id !== userId) {
        return errorResponse(409, "MEMORY_ID_CONFLICT", "Memory card identity conflict.", null);
      }

      if (existing) {
        const existingMs = new Date(existing.updated_at).getTime();
        const baseMs = card.base_updated_at === null ? null : card.base_updated_at * 1000;
        if (baseMs === null || Math.abs(baseMs - existingMs) >= 0.5) {
          // A request may have reached Postgres even if its HTTP response was
          // lost. Treat an identical payload as an idempotent acknowledgement
          // instead of manufacturing a conflict on retry.
          if (hasSamePayload(existing, card)) {
            syncedIds.push(card.id);
            acknowledgedRows.set(card.id, existing);
            continue;
          }
          conflicts.push(toWireCard(existing));
          continue;
        }
        nextTimestampMs = Math.max(nextTimestampMs, existingMs + 1);
      }

      const serverUpdatedAt = new Date(nextTimestampMs).toISOString();
      nextTimestampMs += 1;
      const rowToWrite = {
        id: card.id,
        tenant_id: tenantId,
        user_id: userId,
        kind: card.kind,
        subject: card.deleted_at === null ? card.subject : null,
        content_md: card.deleted_at === null ? card.content_md : "",
        source: card.source,
        created_at: new Date(card.created_at * 1000).toISOString(),
        updated_at: serverUpdatedAt,
        deleted_at: card.deleted_at === null ? null : serverUpdatedAt,
      };

      if (existing) {
        // Compare-and-swap: the WHERE on the previously-read server version
        // makes conflict detection and mutation one atomic Postgres action.
        const { data: updated, error } = await admin
          .from("bs_memory_cards")
          .update(rowToWrite)
          .eq("id", card.id)
          .eq("user_id", userId)
          .eq("updated_at", existing.updated_at)
          .select(CARD_SELECT_COLUMNS)
          .maybeSingle();
        if (error) {
          console.error("[/api/memory/cards] conditional update failed:", error.message);
          return errorResponse(500, "INTERNAL_ERROR", "Failed to save memory cards.", null);
        }
        if (updated) {
          const row = updated as MemoryCardRow;
          syncedIds.push(card.id);
          acknowledgedRows.set(card.id, row);
          continue;
        }
      } else {
        const { data: inserted, error } = await admin
          .from("bs_memory_cards")
          .insert(rowToWrite)
          .select(CARD_SELECT_COLUMNS)
          .maybeSingle();
        if (!error && inserted) {
          const row = inserted as MemoryCardRow;
          syncedIds.push(card.id);
          acknowledgedRows.set(card.id, row);
          continue;
        }
        if (error?.code !== "23505") {
          console.error("[/api/memory/cards] insert failed:", error?.message);
          return errorResponse(500, "INTERNAL_ERROR", "Failed to save memory cards.", null);
        }
      }

      // Another device won after the lookup (or inserted the same id). Load
      // its authoritative copy. An identical row is a successful retry;
      // otherwise preserve both sides and ask the user to resolve it.
      const { data: current, error: currentError } = await admin
        .from("bs_memory_cards")
        .select(CARD_SELECT_COLUMNS)
        .eq("id", card.id)
        .eq("user_id", userId)
        .maybeSingle();
      if (currentError || !current) {
        console.error("[/api/memory/cards] conflict reload failed:", currentError?.message);
        return errorResponse(409, "MEMORY_ID_CONFLICT", "Memory card identity conflict.", null);
      }
      const currentRow = current as MemoryCardRow;
      if (hasSamePayload(currentRow, card)) {
        syncedIds.push(card.id);
        acknowledgedRows.set(card.id, currentRow);
      } else {
        conflicts.push(toWireCard(currentRow));
      }
    }

    let query = admin
      .from("bs_memory_cards")
      .select(CARD_SELECT_COLUMNS)
      .eq("user_id", userId)
      .order("updated_at", { ascending: true })
      .limit(PAGE_SIZE + 1);
    // The boundary is inclusive. It may return the last-seen row once more,
    // but it cannot miss a concurrent write that received the same timestamp.
    if (cursor !== null) query = query.gte("updated_at", new Date(cursor * 1000).toISOString());
    const { data: changedRows, error: changedError } = await query;
    if (changedError) {
      console.error("[/api/memory/cards] incremental pull failed:", changedError.message);
      return errorResponse(500, "INTERNAL_ERROR", "Failed to load memory changes.", null);
    }

    const rows = (changedRows ?? []) as MemoryCardRow[];
    const page = rows.slice(0, PAGE_SIZE);
    const nextCursor = page.length > 0
      ? new Date(page[page.length - 1].updated_at).getTime() / 1000
      : cursor;

    const responseRows = new Map(page.map((row) => [row.id, row]));
    for (const [id, row] of acknowledgedRows) responseRows.set(id, row);

    return Response.json({
      cards: Array.from(responseRows.values()).map(toWireCard),
      synced_ids: syncedIds,
      conflicts,
      cursor: nextCursor,
      has_more: rows.length > PAGE_SIZE,
    });
  } catch (error) {
    if (error instanceof GatewayError) return gatewayErrorResponse(error, null);
    console.error("[/api/memory/cards] PUT internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", null);
  }
}

async function handleLegacyFullSync(
  userId: string,
  tenantId: string,
  incomingById: Map<string, IncomingCard>,
  existingById: Map<string, MemoryCardRow & { user_id: string }>,
): Promise<Response> {
  const admin = getSupabaseAdminClient();
  const rowsToWrite: Record<string, unknown>[] = [];
  for (const card of incomingById.values()) {
    const existing = existingById.get(card.id);
    if (existing && existing.user_id !== userId) continue;
    if (existing && card.updated_at <= new Date(existing.updated_at).getTime() / 1000) continue;
    rowsToWrite.push({
      id: card.id,
      tenant_id: tenantId,
      user_id: userId,
      kind: card.kind,
      subject: card.deleted_at === null ? card.subject : null,
      content_md: card.deleted_at === null ? card.content_md : "",
      source: card.source,
      created_at: new Date(card.created_at * 1000).toISOString(),
      updated_at: new Date(card.updated_at * 1000).toISOString(),
      deleted_at: card.deleted_at === null ? null : new Date(card.deleted_at * 1000).toISOString(),
    });
  }
  if (rowsToWrite.length > 0) {
    const { error } = await admin.from("bs_memory_cards").upsert(rowsToWrite, { onConflict: "id" });
    if (error) return errorResponse(500, "INTERNAL_ERROR", "Failed to save memory cards.", null);
  }
  const { data, error } = await admin
    .from("bs_memory_cards")
    .select(CARD_SELECT_COLUMNS)
    .eq("user_id", userId);
  if (error) return errorResponse(500, "INTERNAL_ERROR", "Failed to load memory cards.", null);
  return Response.json({ cards: ((data ?? []) as MemoryCardRow[]).map(toWireCard) });
}
