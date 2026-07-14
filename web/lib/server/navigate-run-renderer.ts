import type { SignedNavigateRunSnapshot } from "@/lib/server/navigate-run-snapshot";
import type { NavigateVerifierResult } from "@/lib/server/navigate-verifier";

export type NavigateShadowRendering = {
  schema_version: 1;
  state: "current_step" | "next_step" | "needs_confirmation" | "blocked" | "complete";
  verification_source: NavigateVerifierResult["source"];
  verification_status: NavigateVerifierResult["status"];
  step: {
    id: string;
    verbal: string;
    target: string | null;
    fill: string | null;
  } | null;
};

/**
 * Code-only projection for the Copilot band. It never reads the streamed
 * answer or markers; all text and action fields come from the signed Task.
 */
export function renderNavigateRunInShadow(
  snapshot: SignedNavigateRunSnapshot,
  verification: NavigateVerifierResult,
): NavigateShadowRendering {
  const current = snapshot.plan.task.steps[snapshot.current_step];
  let state: NavigateShadowRendering["state"];
  let step: typeof current | null = current ?? null;
  switch (verification.status) {
  case "complete":
    state = "complete";
    step = null;
    break;
  case "verified":
    step = snapshot.plan.task.steps[snapshot.current_step + 1] ?? null;
    state = step ? "next_step" : "complete";
    break;
  case "not_changed":
    state = "current_step";
    break;
  case "blocked":
    state = "blocked";
    break;
  case "ambiguous":
    state = "needs_confirmation";
    break;
  }
  return {
    schema_version: 1,
    state,
    verification_source: verification.source,
    verification_status: verification.status,
    step: step
      ? {
          id: step.id,
          verbal: step.verbal,
          target: step.target,
          fill: step.fill,
        }
      : null,
  };
}
