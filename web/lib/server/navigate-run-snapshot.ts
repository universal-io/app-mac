import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";

import { GatewayError } from "@/lib/server/gateway";
import type { NavigateRun } from "@/lib/server/navigate-run";

const taskStepSchema = z.object({
  id: z.string().min(1).max(80),
  verbal: z.string().min(1).max(300),
  target: z.string().min(1).max(120).nullable(),
  fill: z.string().max(500).nullable(),
  // Milestone D replaces this deliberately empty placeholder with typed
  // postconditions. Arbitrary model objects must never enter a signed Task.
  postconditions: z.array(z.never()).length(0),
}).strict();

const taskSchema = z.object({
  goal: z.string().min(1).max(200),
  steps: z.array(taskStepSchema).min(1).max(8),
}).strict();

const unsignedSnapshotSchema = z.object({
  schema_version: z.literal(1),
  run_id: z.string().uuid(),
  pack: z.object({
    id: z.string().min(1).max(120),
    version: z.string().min(1).max(80),
  }).strict(),
  plan: z.object({
    id: z.string().uuid(),
    version: z.number().int().min(1),
    hash: z.string().regex(/^sha256:[0-9a-f]{64}$/),
    task: taskSchema,
  }).strict(),
  current_step: z.number().int().min(0),
  status: z.enum(["active", "ambiguous", "blocked", "complete", "cancelled", "expired"]),
  revision: z.number().int().min(0),
  expires_at: z.string().datetime({ offset: true }),
}).strict();

const signedSnapshotSchema = unsignedSnapshotSchema.extend({
  signature: z.string().regex(/^v1\.[A-Za-z0-9_-]{43}$/),
}).strict();

export type NavigateSnapshotTask = z.infer<typeof taskSchema>;
export type UnsignedNavigateRunSnapshot = z.infer<typeof unsignedSnapshotSchema>;
export type SignedNavigateRunSnapshot = z.infer<typeof signedSnapshotSchema>;

type ProposedTask = {
  goal: string;
  steps: Array<{ verbal: string; target?: string; fill?: string }>;
};

/** Converts Planner output into the only Task shape milestone C may sign.
 * Step IDs are positional because a plan is immutable once hashed. */
export function materializeSnapshotTask(task: ProposedTask): NavigateSnapshotTask {
  return taskSchema.parse({
    goal: task.goal,
    steps: task.steps.map((step, index) => ({
      id: `step-${index + 1}`,
      verbal: step.verbal,
      target: step.target ?? null,
      fill: step.fill ?? null,
      postconditions: [],
    })),
  });
}

export function hashSnapshotTask(task: NavigateSnapshotTask): string {
  const normalized = taskSchema.parse(task);
  return `sha256:${createHash("sha256").update(JSON.stringify(normalized)).digest("hex")}`;
}

export function unsignedSnapshotFromRun(
  run: NavigateRun,
  task: NavigateSnapshotTask,
): UnsignedNavigateRunSnapshot {
  const normalizedTask = taskSchema.parse(task);
  const taskHash = hashSnapshotTask(normalizedTask);
  if (taskHash !== run.planHash) {
    throw snapshotConflict("The navigation plan no longer matches its saved run.");
  }
  if (run.currentStep >= normalizedTask.steps.length && run.status !== "complete") {
    throw snapshotConflict("The navigation step is outside the signed plan.");
  }
  return unsignedSnapshotSchema.parse({
    schema_version: 1,
    run_id: run.id,
    pack: { id: run.packId, version: run.packVersion },
    plan: {
      id: run.planId,
      version: run.planVersion,
      hash: run.planHash,
      task: normalizedTask,
    },
    current_step: run.currentStep,
    status: run.status,
    revision: run.revision,
    expires_at: run.expiresAt,
  });
}

export function signNavigateRunSnapshot(
  run: NavigateRun,
  task: NavigateSnapshotTask,
  secret: string,
): SignedNavigateRunSnapshot {
  validateSigningSecret(secret);
  const unsigned = unsignedSnapshotFromRun(run, task);
  return {
    ...unsigned,
    signature: `v1.${signatureFor(unsigned, secret)}`,
  };
}

/** Verifies shape and HMAC before any snapshot field is trusted. */
export function verifyNavigateRunSnapshot(
  input: unknown,
  secret: string,
): SignedNavigateRunSnapshot {
  validateSigningSecret(secret);
  const parsed = signedSnapshotSchema.safeParse(input);
  if (!parsed.success) {
    throw new GatewayError(400, "BAD_REQUEST", "run_snapshot is malformed.");
  }
  const { signature, ...unsigned } = parsed.data;
  const expected = Buffer.from(signatureFor(unsigned, secret), "utf8");
  const actual = Buffer.from(signature.slice(3), "utf8");
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
    throw snapshotConflict("The navigation snapshot signature is invalid.");
  }
  if (hashSnapshotTask(unsigned.plan.task) !== unsigned.plan.hash) {
    throw snapshotConflict("The signed navigation task was modified.");
  }
  return parsed.data;
}

/** Compares a verified client-carried snapshot with the authoritative row. */
export function assertSnapshotMatchesRun(
  snapshot: SignedNavigateRunSnapshot,
  run: NavigateRun,
): void {
  if (
    snapshot.run_id !== run.id ||
    snapshot.pack.id !== run.packId ||
    snapshot.pack.version !== run.packVersion ||
    snapshot.plan.id !== run.planId ||
    snapshot.plan.version !== run.planVersion ||
    snapshot.plan.hash !== run.planHash ||
    snapshot.current_step !== run.currentStep ||
    snapshot.status !== run.status ||
    snapshot.revision !== run.revision ||
    snapshot.expires_at !== run.expiresAt
  ) {
    throw snapshotConflict("Navigation state changed. Reload the latest run before continuing.");
  }
}

function signatureFor(snapshot: UnsignedNavigateRunSnapshot, secret: string): string {
  const normalized = unsignedSnapshotSchema.parse(snapshot);
  return createHmac("sha256", secret)
    .update(JSON.stringify(normalized))
    .digest("base64url");
}

function validateSigningSecret(secret: string): void {
  if (Buffer.byteLength(secret, "utf8") < 32) {
    throw new GatewayError(
      503,
      "RUN_SIGNING_UNAVAILABLE",
      "Navigation state signing is unavailable. No navigation run was changed.",
    );
  }
}

function snapshotConflict(message: string): GatewayError {
  return new GatewayError(409, "RUN_SNAPSHOT_CONFLICT", message);
}
