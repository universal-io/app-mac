import type { VisionObservation } from "@/lib/context/observation";
import { getServerEnv } from "@/lib/server/env";
import { GatewayError } from "@/lib/server/gateway";
import { loadNavigateRun } from "@/lib/server/navigate-run";
import {
  assertSnapshotMatchesRun,
  verifyNavigateRunSnapshot,
} from "@/lib/server/navigate-run-snapshot";
import {
  verifyPostconditions,
  type RuleVerifierResult,
} from "@/lib/server/navigate-verifier";

/**
 * Verifies one carried Run against its authoritative row, then evaluates only
 * the current signed step. This is response/trace-only during shadow: it does
 * not mutate the Run revision or trust the client-owned v3 task.
 */
export async function verifyNavigateRunInShadow(args: {
  tenantId: string;
  userId: string;
  snapshot: unknown;
  before: VisionObservation;
  after: VisionObservation;
}): Promise<RuleVerifierResult> {
  const env = getServerEnv();
  if (!env.navigateV4Enabled) {
    throw new GatewayError(
      404,
      "FEATURE_NOT_ENABLED",
      "新しいナビゲーション検証は現在利用できません。",
    );
  }
  const snapshot = verifyNavigateRunSnapshot(
    args.snapshot,
    env.navigateRunSigningSecret ?? "",
  );
  const auth = { tenantId: args.tenantId, userId: args.userId };
  const run = await loadNavigateRun(auth, snapshot.run_id);
  assertSnapshotMatchesRun(snapshot, run);
  const step = snapshot.plan.task.steps[snapshot.current_step];
  if (!step) {
    throw new GatewayError(
      409,
      "RUN_STEP_CONFLICT",
      "署名済み計画に現在のステップがありません。最新状態へ同期してください。",
    );
  }
  return verifyPostconditions({
    before: args.before,
    after: args.after,
    postconditions: step.postconditions,
    completesTask: snapshot.current_step === snapshot.plan.task.steps.length - 1,
  });
}
