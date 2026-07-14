import type { VisionObservation } from "@/lib/context/observation";
import { getServerEnv } from "@/lib/server/env";
import {
  groundObservationCandidate,
  type CandidateGrounding,
} from "@/lib/server/navigate-grounder";
import type { NavigateShadowRendering } from "@/lib/server/navigate-run-renderer";
import { resolveNavigateRoleRoute } from "@/lib/server/navigate-provider-route";
import {
  modelFallbackNotice,
  roleDegradedNotice,
  type OperationalNotice,
} from "@/lib/server/operational-notice";

export type NavigateShadowGrounding = {
  schema_version: 1;
  status: "grounded" | "ambiguous" | "unresolved" | "not_applicable";
  comparison: "agreement" | "disagreement" | "not_comparable";
  safe_to_prompt: boolean;
  capture_id: string;
  step_id: string | null;
  candidate_id: string | null;
  confidence: number | null;
  method: CandidateGrounding["method"] | null;
  legacy_candidate_id: string | null;
};

export type NavigateRunGroundingExecution = {
  result: NavigateShadowGrounding;
  rendering: NavigateShadowRendering;
  attempted: boolean;
  modelVendor: string | null;
  modelId: string | null;
  inputTokens: number;
  outputTokens: number;
  notices: OperationalNotice[];
};

/**
 * Grounds only the step selected by the code Renderer. A disagreement with
 * the legacy path is fail-closed: the shadow rendering asks for confirmation
 * and the client receives an explicit prohibition on prompting/highlighting.
 */
export async function groundNavigateRunRenderingInShadow(args: {
  rendering: NavigateShadowRendering;
  observation: VisionObservation;
  legacyGrounding: CandidateGrounding | null;
}): Promise<NavigateRunGroundingExecution> {
  const target = args.rendering.step?.target?.trim();
  if (
    !args.rendering.step
    || !target
    || (args.rendering.state !== "current_step" && args.rendering.state !== "next_step")
  ) {
    return emptyExecution(args, "not_applicable");
  }

  const env = getServerEnv();
  const route = resolveNavigateRoleRoute(
    env,
    env.navigateGrounderModelVendor,
    env.navigateGrounderModelId,
    env.navigateModelVendor,
    env.navigateModelId,
  );
  if (!route) {
    const execution = emptyExecution(args, "unresolved");
    return {
      ...execution,
      notices: [roleDegradedNotice(
        "Grounder",
        "署名済みステップの操作対象を確認するモデルへ接続できません。APIキーとモデル設定を確認してください。",
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
    const grounding = await groundObservationCandidate({
      endpoint: route.endpoint,
      apiKey: route.apiKey,
      vendor: route.vendor,
      modelId: route.modelId,
      observation: args.observation,
      targetLabel: target,
      context: [
        `Signed step: ${args.rendering.step.verbal}`,
        `Renderer state: ${args.rendering.state}`,
      ].join("\n"),
    });
    const selection = grounding.selection;
    if (!selection) {
      return {
        ...emptyExecution(args, "unresolved"),
        attempted: grounding.attempted,
        modelVendor: route.vendor,
        modelId: route.modelId,
        inputTokens: grounding.inputTokens,
        outputTokens: grounding.outputTokens,
        notices,
      };
    }

    const comparison = args.legacyGrounding
      && args.legacyGrounding.captureId === selection.captureId
      ? args.legacyGrounding.candidateId === selection.candidateId
        ? "agreement"
        : "disagreement"
      : "not_comparable";
    const ambiguous = comparison === "disagreement" || selection.confidence < 0.85;
    return {
      result: {
        schema_version: 1,
        status: ambiguous ? "ambiguous" : "grounded",
        comparison,
        safe_to_prompt: !ambiguous,
        capture_id: args.observation.capture_id,
        step_id: args.rendering.step.id,
        candidate_id: selection.candidateId,
        confidence: selection.confidence,
        method: selection.method,
        legacy_candidate_id: args.legacyGrounding?.candidateId ?? null,
      },
      rendering: ambiguous
        ? { ...args.rendering, state: "needs_confirmation" }
        : args.rendering,
      attempted: grounding.attempted,
      modelVendor: route.vendor,
      modelId: route.modelId,
      inputTokens: grounding.inputTokens,
      outputTokens: grounding.outputTokens,
      notices,
    };
  } catch {
    return {
      ...emptyExecution(args, "unresolved"),
      attempted: true,
      modelVendor: route.vendor,
      modelId: route.modelId,
      notices: [
        ...notices,
        roleDegradedNotice(
          "Grounder",
          "署名済みステップの操作対象を確認できませんでした。ネットワーク、利用上限、モデル設定を確認してください。",
        ),
      ],
    };
  }
}

function emptyExecution(
  args: {
    rendering: NavigateShadowRendering;
    observation: VisionObservation;
    legacyGrounding: CandidateGrounding | null;
  },
  status: "unresolved" | "not_applicable",
): NavigateRunGroundingExecution {
  return {
    result: {
      schema_version: 1,
      status,
      comparison: "not_comparable",
      safe_to_prompt: status === "unresolved",
      capture_id: args.observation.capture_id,
      step_id: args.rendering.step?.id ?? null,
      candidate_id: null,
      confidence: null,
      method: null,
      legacy_candidate_id: args.legacyGrounding?.candidateId ?? null,
    },
    rendering: args.rendering,
    attempted: false,
    modelVendor: null,
    modelId: null,
    inputTokens: 0,
    outputTokens: 0,
    notices: [],
  };
}
