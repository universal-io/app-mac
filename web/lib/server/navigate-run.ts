import { GatewayError, type AuthContext } from "@/lib/server/gateway";
import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";

export const NAVIGATE_RUN_TTL_MS = 24 * 60 * 60 * 1_000;

export type NavigateRunStatus =
  | "active"
  | "ambiguous"
  | "blocked"
  | "complete"
  | "cancelled"
  | "expired";

export type NavigateRun = {
  id: string;
  tenantId: string;
  userId: string;
  packId: string;
  packVersion: string;
  planId: string;
  planVersion: number;
  planHash: string;
  currentStep: number;
  status: NavigateRunStatus;
  revision: number;
  expiresAt: string;
  createdAt: string;
  updatedAt: string;
};

export type CreateNavigateRunInput = {
  packId: string;
  packVersion: string;
  planId: string;
  planVersion: number;
  planHash: string;
};

export type MutateNavigateRunInput = {
  expectedRevision: number;
  currentStep: number;
  status: NavigateRunStatus;
};

type RunRow = {
  id: string;
  tenant_id: string;
  user_id: string;
  pack_id: string;
  pack_version: string;
  plan_id: string;
  plan_version: number;
  plan_hash: string;
  current_step: number;
  status: string;
  revision: number;
  expires_at: string;
  created_at: string;
  updated_at: string;
};

const RUN_COLUMNS = [
  "id", "tenant_id", "user_id", "pack_id", "pack_version", "plan_id",
  "plan_version", "plan_hash", "current_step", "status", "revision",
  "expires_at", "created_at", "updated_at",
].join(",");

export async function createNavigateRun(
  auth: Pick<AuthContext, "tenantId" | "userId">,
  input: CreateNavigateRunInput,
  now = new Date(),
): Promise<NavigateRun> {
  validateCreateInput(input);
  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_navigator_runs")
    .insert({
      tenant_id: auth.tenantId,
      user_id: auth.userId,
      pack_id: input.packId.trim(),
      pack_version: input.packVersion.trim(),
      plan_id: input.planId,
      plan_version: input.planVersion,
      plan_hash: input.planHash,
      expires_at: new Date(now.getTime() + NAVIGATE_RUN_TTL_MS).toISOString(),
    })
    .select(RUN_COLUMNS)
    .single();
  if (error || !data) throw runStoreError("create", error?.message);
  return mapRun(data as unknown as RunRow);
}

export async function loadNavigateRun(
  auth: Pick<AuthContext, "tenantId" | "userId">,
  runId: string,
  now = new Date(),
): Promise<NavigateRun> {
  const run = await loadScopedRun(auth, runId);
  if (new Date(run.expiresAt).getTime() <= now.getTime() && run.status !== "expired") {
    return mutateNavigateRun(auth, run.id, {
      expectedRevision: run.revision,
      currentStep: run.currentStep,
      status: "expired",
    }, now);
  }
  return run;
}

/** Internal Gateway mutation. No client route may call this before Verifier
 * has authorized the transition. The revision predicate makes concurrent
 * advance attempts an explicit conflict instead of a double step. */
export async function mutateNavigateRun(
  auth: Pick<AuthContext, "tenantId" | "userId">,
  runId: string,
  input: MutateNavigateRunInput,
  now = new Date(),
): Promise<NavigateRun> {
  validateRunId(runId);
  validateMutation(input);
  const current = await loadScopedRun(auth, runId);
  validateTransition(current, input);
  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_navigator_runs")
    .update({
      current_step: input.currentStep,
      status: input.status,
      revision: input.expectedRevision + 1,
      expires_at: new Date(now.getTime() + NAVIGATE_RUN_TTL_MS).toISOString(),
    })
    .eq("id", runId)
    .eq("tenant_id", auth.tenantId)
    .eq("user_id", auth.userId)
    .eq("revision", input.expectedRevision)
    .select(RUN_COLUMNS)
    .maybeSingle();
  if (error) throw runStoreError("update", error.message);
  if (!data) {
    throw new GatewayError(
      409,
      "RUN_REVISION_CONFLICT",
      "Navigation state changed. Reload the latest run before continuing.",
    );
  }
  return mapRun(data as unknown as RunRow);
}

export async function purgeExpiredNavigateRuns(now = new Date()): Promise<number> {
  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_navigator_runs")
    .delete()
    .lte("expires_at", now.toISOString())
    .select("id");
  if (error) throw runStoreError("purge", error.message);
  return data?.length ?? 0;
}

export function assertRunOwner(
  run: Pick<NavigateRun, "tenantId" | "userId">,
  auth: Pick<AuthContext, "tenantId" | "userId">,
): void {
  if (run.tenantId !== auth.tenantId || run.userId !== auth.userId) {
    throw new GatewayError(404, "RUN_NOT_FOUND", "Navigation run was not found.");
  }
}

export function validateMutation(input: MutateNavigateRunInput): void {
  if (!Number.isInteger(input.expectedRevision) || input.expectedRevision < 0) {
    throw new GatewayError(400, "BAD_REQUEST", "run revision must be a non-negative integer.");
  }
  if (!Number.isInteger(input.currentStep) || input.currentStep < 0) {
    throw new GatewayError(400, "BAD_REQUEST", "current_step must be a non-negative integer.");
  }
  if (!RUN_STATUSES.has(input.status)) {
    throw new GatewayError(400, "BAD_REQUEST", "run status is invalid.");
  }
}

export function validateRunId(runId: string): void {
  if (!UUID_PATTERN.test(runId)) {
    throw new GatewayError(400, "BAD_REQUEST", "run_id must be a UUID.");
  }
}

export function validateTransition(
  current: Pick<NavigateRun, "revision" | "currentStep" | "status">,
  next: MutateNavigateRunInput,
): void {
  if (current.revision !== next.expectedRevision) {
    throw new GatewayError(
      409,
      "RUN_REVISION_CONFLICT",
      "Navigation state changed. Reload the latest run before continuing.",
    );
  }
  if (TERMINAL_RUN_STATUSES.has(current.status)) {
    throw new GatewayError(
      409,
      "RUN_TERMINAL",
      "This navigation run has ended and cannot be advanced.",
    );
  }
  if (next.currentStep < current.currentStep || next.currentStep > current.currentStep + 1) {
    throw new GatewayError(
      409,
      "RUN_STEP_CONFLICT",
      "Navigation steps must advance one at a time from the latest run state.",
    );
  }
}

async function loadScopedRun(
  auth: Pick<AuthContext, "tenantId" | "userId">,
  runId: string,
): Promise<NavigateRun> {
  validateRunId(runId);
  const admin = getSupabaseAdminClient();
  const { data, error } = await admin
    .from("bs_navigator_runs")
    .select(RUN_COLUMNS)
    .eq("id", runId)
    .eq("tenant_id", auth.tenantId)
    .eq("user_id", auth.userId)
    .maybeSingle();
  if (error) throw runStoreError("read", error.message);
  if (!data) throw new GatewayError(404, "RUN_NOT_FOUND", "Navigation run was not found.");
  const run = mapRun(data as unknown as RunRow);
  assertRunOwner(run, auth);
  return run;
}

function validateCreateInput(input: CreateNavigateRunInput): void {
  if (!input.packId.trim() || !input.packVersion.trim()) {
    throw new GatewayError(400, "BAD_REQUEST", "pack id/version are required.");
  }
  if (!UUID_PATTERN.test(input.planId)) {
    throw new GatewayError(400, "BAD_REQUEST", "plan_id must be a UUID.");
  }
  if (!Number.isInteger(input.planVersion) || input.planVersion < 1) {
    throw new GatewayError(400, "BAD_REQUEST", "plan_version must be at least 1.");
  }
  if (input.planHash.length < 16 || input.planHash.length > 200) {
    throw new GatewayError(400, "BAD_REQUEST", "plan_hash length is invalid.");
  }
}

function mapRun(row: RunRow): NavigateRun {
  const status = row.status as NavigateRunStatus;
  if (!RUN_STATUSES.has(status)) {
    throw runStoreError("decode", `unknown status ${row.status}`);
  }
  return {
    id: row.id,
    tenantId: row.tenant_id,
    userId: row.user_id,
    packId: row.pack_id,
    packVersion: row.pack_version,
    planId: row.plan_id,
    planVersion: row.plan_version,
    planHash: row.plan_hash,
    currentStep: row.current_step,
    status,
    revision: row.revision,
    expiresAt: row.expires_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function runStoreError(operation: string, detail?: string): GatewayError {
  console.error(`[navigate-run] ${operation} failed:`, detail ?? "unknown error");
  return new GatewayError(
    503,
    "RUN_STORE_UNAVAILABLE",
    "Navigation state could not be saved. No step was advanced; please retry.",
  );
}

const RUN_STATUSES = new Set<NavigateRunStatus>([
  "active", "ambiguous", "blocked", "complete", "cancelled", "expired",
]);

const TERMINAL_RUN_STATUSES = new Set<NavigateRunStatus>([
  "complete", "cancelled", "expired",
]);

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
