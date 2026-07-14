import { createHash, createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { z } from "zod";

import { GatewayError } from "@/lib/server/gateway";
import type { NavigateRun } from "@/lib/server/navigate-run";
import {
  navigatePostconditionsSchema,
  type NavigatePostcondition,
} from "@/lib/server/navigate-postcondition";

export const NAVIGATE_RUN_PROPOSAL_TTL_MS = 10 * 60 * 1_000;

const taskStepSchema = z.object({
  id: z.string().min(1).max(80),
  verbal: z.string().min(1).max(300),
  target: z.string().min(1).max(120).nullable(),
  fill: z.string().max(500).nullable(),
  postconditions: navigatePostconditionsSchema,
}).strict();

const taskSchema = z.object({
  recipe_id: z.string().min(1).max(120).nullable(),
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

const unsignedProposalSchema = z.object({
  schema_version: z.literal(1),
  kind: z.literal("navigate_run_proposal"),
  audience: z.string().regex(/^v1\.[A-Za-z0-9_-]{43}$/),
  pack: unsignedSnapshotSchema.shape.pack,
  plan: unsignedSnapshotSchema.shape.plan,
  expires_at: z.string().datetime({ offset: true }),
}).strict();

const signedProposalSchema = unsignedProposalSchema.extend({
  signature: z.string().regex(/^v1\.[A-Za-z0-9_-]{43}$/),
}).strict();

export type NavigateSnapshotTask = z.infer<typeof taskSchema>;
export type UnsignedNavigateRunSnapshot = z.infer<typeof unsignedSnapshotSchema>;
export type SignedNavigateRunSnapshot = z.infer<typeof signedSnapshotSchema>;
export type SignedNavigateRunProposal = z.infer<typeof signedProposalSchema>;

type ProposalAuth = { tenantId: string; userId: string };

type ProposedTask = {
  recipeId?: string;
  goal: string;
  steps: Array<{
    id?: string;
    verbal: string;
    target?: string;
    fill?: string;
    postconditions?: NavigatePostcondition[];
  }>;
};

/** Converts Planner output into the only Task shape milestone C may sign.
 * Step IDs are positional because a plan is immutable once hashed. */
export function materializeSnapshotTask(task: ProposedTask): NavigateSnapshotTask {
  return taskSchema.parse({
    recipe_id: task.recipeId ?? null,
    goal: task.goal,
    steps: task.steps.map((step, index) => ({
      id: step.id ?? `step-${index + 1}`,
      verbal: step.verbal,
      target: step.target ?? null,
      fill: step.fill ?? null,
      postconditions: step.postconditions ?? [],
    })),
  });
}

export function hashSnapshotTask(task: NavigateSnapshotTask): string {
  const normalized = taskSchema.parse(task);
  return `sha256:${createHash("sha256").update(JSON.stringify(normalized)).digest("hex")}`;
}

/** Creates a short-lived, identity-bound proposal. It does not create a Run;
 * the authenticated start action is the only point that writes the row. */
export function createNavigateRunProposal(
  auth: ProposalAuth,
  input: { packId: string; packVersion: string; task: ProposedTask },
  secret: string,
  now = new Date(),
): SignedNavigateRunProposal {
  validateSigningSecret(secret);
  const task = materializeSnapshotTask(input.task);
  const planId = randomUUID();
  const unsigned = unsignedProposalSchema.parse({
    schema_version: 1,
    kind: "navigate_run_proposal",
    audience: proposalAudience(auth, planId, secret),
    pack: { id: input.packId, version: input.packVersion },
    plan: {
      id: planId,
      version: 1,
      hash: hashSnapshotTask(task),
      task,
    },
    expires_at: new Date(now.getTime() + NAVIGATE_RUN_PROPOSAL_TTL_MS).toISOString(),
  });
  return {
    ...unsigned,
    signature: `v1.${signatureForValue(unsigned, secret)}`,
  };
}

export function verifyNavigateRunProposal(
  input: unknown,
  auth: ProposalAuth,
  secret: string,
  now = new Date(),
): SignedNavigateRunProposal {
  validateSigningSecret(secret);
  const parsed = signedProposalSchema.safeParse(input);
  if (!parsed.success) {
    throw new GatewayError(400, "BAD_REQUEST", "ナビゲーション開始情報の形式が不正です。");
  }
  const { signature, ...unsigned } = parsed.data;
  verifySignature(
    unsigned,
    signature,
    secret,
    proposalConflict("ナビゲーション開始情報の署名を確認できません。新しい計画を作り直してください。"),
  );
  if (parsed.data.audience !== proposalAudience(auth, parsed.data.plan.id, secret)) {
    throw new GatewayError(404, "RUN_PROPOSAL_NOT_FOUND", "このナビゲーション開始情報は利用できません。");
  }
  if (hashSnapshotTask(parsed.data.plan.task) !== parsed.data.plan.hash) {
    throw proposalConflict("署名後に計画内容が変更されています。新しい計画を作り直してください。");
  }
  if (new Date(parsed.data.expires_at).getTime() <= now.getTime()) {
    throw new GatewayError(
      410,
      "RUN_PROPOSAL_EXPIRED",
      "ナビゲーションの開始期限が切れました。Copilotに新しい計画を作ってもらってください。",
    );
  }
  return parsed.data;
}

export function unsignedSnapshotFromRun(
  run: NavigateRun,
  task: NavigateSnapshotTask,
): UnsignedNavigateRunSnapshot {
  const normalizedTask = taskSchema.parse(task);
  const taskHash = hashSnapshotTask(normalizedTask);
  if (taskHash !== run.planHash) {
    throw snapshotConflict("計画の内容が保存済みナビゲーションと一致しません。新しい計画を作り直してください。");
  }
  if (run.currentStep >= normalizedTask.steps.length && run.status !== "complete") {
    throw snapshotConflict("現在のステップが署名済み計画の範囲外です。最新状態へ同期してください。");
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
    throw new GatewayError(400, "BAD_REQUEST", "ナビゲーション状態の形式が不正です。");
  }
  const { signature, ...unsigned } = parsed.data;
  verifySignature(
    unsigned,
    signature,
    secret,
    snapshotConflict("ナビゲーション状態の署名を確認できません。最新状態へ同期してください。"),
  );
  if (hashSnapshotTask(unsigned.plan.task) !== unsigned.plan.hash) {
    throw snapshotConflict("署名後にナビゲーション計画が変更されています。最新状態へ同期してください。");
  }
  return parsed.data;
}

/** Compares a verified client-carried snapshot with the authoritative row. */
export function assertSnapshotMatchesRun(
  snapshot: SignedNavigateRunSnapshot,
  run: NavigateRun,
): void {
  assertSnapshotPlanMatchesRun(snapshot, run);
  if (
    snapshot.current_step !== run.currentStep ||
    snapshot.status !== run.status ||
    snapshot.revision !== run.revision ||
    snapshot.expires_at !== run.expiresAt
  ) {
    throw snapshotConflict("ナビゲーション状態が更新されています。最新状態へ同期してから続けてください。");
  }
}

/** Checks immutable identity while allowing sync to replace stale progress. */
export function assertSnapshotPlanMatchesRun(
  snapshot: SignedNavigateRunSnapshot,
  run: NavigateRun,
): void {
  if (
    snapshot.run_id !== run.id ||
    snapshot.pack.id !== run.packId ||
    snapshot.pack.version !== run.packVersion ||
    snapshot.plan.id !== run.planId ||
    snapshot.plan.version !== run.planVersion ||
    snapshot.plan.hash !== run.planHash
  ) {
    throw snapshotConflict("ナビゲーション状態と保存済み計画が一致しません。新しい計画を作り直してください。");
  }
}

function signatureFor(snapshot: UnsignedNavigateRunSnapshot, secret: string): string {
  const normalized = unsignedSnapshotSchema.parse(snapshot);
  return signatureForValue(normalized, secret);
}

function signatureForValue(value: unknown, secret: string): string {
  return createHmac("sha256", secret).update(JSON.stringify(value)).digest("base64url");
}

function verifySignature(
  unsigned: unknown,
  signature: string,
  secret: string,
  error: GatewayError,
): void {
  const expected = Buffer.from(signatureForValue(unsigned, secret), "utf8");
  const actual = Buffer.from(signature.slice(3), "utf8");
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
    throw error;
  }
}

function proposalAudience(auth: ProposalAuth, planId: string, secret: string): string {
  return `v1.${createHmac("sha256", secret)
    .update(`${auth.tenantId}:${auth.userId}:${planId}`)
    .digest("base64url")}`;
}

function validateSigningSecret(secret: string): void {
  if (Buffer.byteLength(secret, "utf8") < 32) {
    throw new GatewayError(
      503,
      "RUN_SIGNING_UNAVAILABLE",
      "ナビゲーション状態の署名機能を利用できません。状態は変更されていません。管理者へ連絡してください。",
    );
  }
}

function snapshotConflict(message: string): GatewayError {
  return new GatewayError(409, "RUN_SNAPSHOT_CONFLICT", message);
}

function proposalConflict(message: string): GatewayError {
  return new GatewayError(409, "RUN_PROPOSAL_CONFLICT", message);
}
