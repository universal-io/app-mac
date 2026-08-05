export type QuotaState = {
  /** null means an unlimited plan skipped the count because no caller needed it. */
  used: number | null;
  limit: number | null;
};

type QuotaStateEntry = QuotaState & {
  expiresAt: number;
};

/**
 * Short-lived, per-instance knowledge of the quota state already read from
 * Postgres. A successful usage insert advances the known count locally, so
 * the next request does not immediately pay another network round trip for a
 * value this instance just wrote.
 *
 * This does not make the cache authoritative across serverless instances. The
 * previous boolean quota cache already had that same five-minute boundary;
 * carrying the known count makes one instance more accurate, not less.
 */
export class QuotaStateCache {
  private readonly entries = new Map<string, QuotaStateEntry>();
  private readonly ttlMs: number;
  private readonly maxEntries: number;

  constructor(ttlMs: number, maxEntries: number) {
    this.ttlMs = ttlMs;
    this.maxEntries = maxEntries;
  }

  get(tenantId: string, now = Date.now()): QuotaState | null {
    const entry = this.entries.get(tenantId);
    if (!entry) return null;
    if (entry.expiresAt <= now) {
      this.entries.delete(tenantId);
      return null;
    }
    return { used: entry.used, limit: entry.limit };
  }

  set(tenantId: string, state: QuotaState, now = Date.now()): void {
    if (!this.entries.has(tenantId) && this.entries.size >= this.maxEntries) {
      const oldestKey = this.entries.keys().next().value;
      if (oldestKey) this.entries.delete(oldestKey);
    }
    this.entries.set(tenantId, {
      ...state,
      expiresAt: now + this.ttlMs,
    });
  }

  increment(tenantId: string, now = Date.now()): void {
    const entry = this.entries.get(tenantId);
    if (!entry) return;
    if (entry.expiresAt <= now) {
      this.entries.delete(tenantId);
      return;
    }
    if (entry.used !== null) entry.used += 1;
  }

  delete(tenantId: string): void {
    this.entries.delete(tenantId);
  }
}
