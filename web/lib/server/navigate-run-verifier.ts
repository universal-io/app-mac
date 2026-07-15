import type { VisionObservation } from "@/lib/context/observation";
import { getServerEnv } from "@/lib/server/env";
import { GatewayError } from "@/lib/server/gateway";
import { loadNavigateRun } from "@/lib/server/navigate-run";
import {
  renderNavigateRunInShadow,
  type NavigateShadowRendering,
} from "@/lib/server/navigate-run-renderer";
import { verifyPostconditionsWithModel } from "@/lib/server/navigate-model-verifier";
import { resolveNavigateRoleRoute } from "@/lib/server/navigate-provider-route";
import {
  assertSnapshotMatchesRun,
  verifyNavigateRunSnapshot,
} from "@/lib/server/navigate-run-snapshot";
import {
  verifyPostconditions,
  type NavigateVerifierResult,
  type RuleVerifierResult,
} from "@/lib/server/navigate-verifier";
import {
  modelFallbackNotice,
  roleDegradedNotice,
  type OperationalNotice,
} from "@/lib/server/operational-notice";

export type NavigateRunVerificationExecution = {
  result: NavigateVerifierResult;
  ruleResult: RuleVerifierResult;
  modelAttempted: boolean;
  modelVendor: string | null;
  modelId: string | null;
  modelInputTokens: number;
  modelOutputTokens: number;
  modelFailureReason: "ROUTE_UNAVAILABLE" | "SCHEMA_INVALID" | "PROVIDER_CALL_FAILED" | null;
  rendering: NavigateShadowRendering;
  notices: OperationalNotice[];
};

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
  /** The current turn's screen capture, when the client sent one alongside
   * the after Observation. Only used for the generic (no-postcondition)
   * model fallback below; the rule-ambiguous escalation path is unchanged. */
  afterImageDataURL?: string;
}): Promise<NavigateRunVerificationExecution> {
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
  const completesTask = snapshot.current_step === snapshot.plan.task.steps.length - 1;
  const ruleResult = verifyPostconditions({
    before: args.before,
    after: args.after,
    postconditions: step.postconditions,
    completesTask,
  });
  const base: NavigateRunVerificationExecution = {
    result: ruleResult,
    ruleResult,
    modelAttempted: false,
    modelVendor: null,
    modelId: null,
    modelInputTokens: 0,
    modelOutputTokens: 0,
    modelFailureReason: null,
    rendering: renderNavigateRunInShadow(snapshot, ruleResult),
    notices: [],
  };
  // Unstable/scope-changed observations are capture-contract failures, not
  // model questions. A model must never reason around them. A step with no
  // typed postcondition, however, is escalated too: owner decision
  // 2026-07-15 makes generic Vision judgment the base layer and recipes an
  // added precision layer, so "no postcondition" must not mean "always
  // ambiguous" (docs/navigator-stabilization-followups.md §0.6).
  const isGenericFallback = ruleResult.reason === "NO_POSTCONDITIONS";
  if (ruleResult.reason !== "INSUFFICIENT_OR_CONFLICTING_EVIDENCE" && !isGenericFallback) {
    return base;
  }

  const route = resolveNavigateRoleRoute(
    env,
    env.navigateVerifierModelVendor,
    env.navigateVerifierModelId,
    env.navigateModelVendor,
    env.navigateModelId,
  );
  if (!route) {
    return {
      ...base,
      modelFailureReason: "ROUTE_UNAVAILABLE",
      notices: [roleDegradedNotice(
        "Verifier",
        "Verifier用モデルにも継承先モデルにも接続できません。APIキーとモデル設定を確認してください。",
      )],
    };
  }
  const notices = route.fallbackFrom
    ? [modelFallbackNotice({
        fromVendor: route.fallbackFrom.vendor,
        fromModelId: route.fallbackFrom.modelId,
        toVendor: route.vendor,
        toModelId: route.modelId,
      })]
    : [];
  try {
    const model = await verifyPostconditionsWithModel({
      route,
      before: args.before,
      after: args.after,
      postconditions: step.postconditions,
      completesTask,
      generic: isGenericFallback
        ? {
            goal: snapshot.plan.task.goal,
            stepVerbal: step.verbal,
            stepTarget: step.target,
            afterImageDataURL: args.afterImageDataURL,
          }
        : undefined,
    });
    if (!model.result) {
      notices.push(roleDegradedNotice(
        "Verifier",
        "モデル応答が検証用のstrict schemaに一致しませんでした。",
      ));
    }
    const result = model.result ?? ruleResult;
    return {
      ...base,
      result,
      modelAttempted: true,
      modelVendor: route.vendor,
      modelId: route.modelId,
      modelInputTokens: model.inputTokens,
      modelOutputTokens: model.outputTokens,
      modelFailureReason: model.result ? null : "SCHEMA_INVALID",
      rendering: renderNavigateRunInShadow(snapshot, result),
      notices,
    };
  } catch {
    notices.push(roleDegradedNotice(
      "Verifier",
      "モデルAPIの呼び出しに失敗しました。ネットワーク、利用上限、モデル設定を確認してください。",
    ));
    return {
      ...base,
      modelAttempted: true,
      modelVendor: route.vendor,
      modelId: route.modelId,
      modelFailureReason: "PROVIDER_CALL_FAILED",
      notices,
    };
  }
}
