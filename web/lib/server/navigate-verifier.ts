import type {
  ObservationCandidate,
  VisionObservation,
} from "@/lib/context/observation";
import {
  navigatePostconditionsSchema,
  type CandidateSelector,
  type NavigatePostcondition,
} from "@/lib/server/navigate-postcondition";

export type RuleVerifierStatus =
  | "verified"
  | "not_changed"
  | "ambiguous"
  | "blocked"
  | "complete";

export type RuleVerifierReason =
  | "ALL_POSTCONDITIONS_MET"
  | "NO_POSTCONDITIONS"
  | "OBSERVATION_UNSTABLE"
  | "CAPTURE_SCOPE_CHANGED"
  | "TARGET_DISABLED"
  | "NO_VISIBLE_CHANGE"
  | "INSUFFICIENT_OR_CONFLICTING_EVIDENCE";

export type RuleVerifierResult = {
  source: "rule";
  status: RuleVerifierStatus;
  reason: RuleVerifierReason;
  evidenceCandidateIds: string[];
};

export type ModelVerifierReason =
  | "MODEL_POSTCONDITIONS_SUPPORTED"
  | "MODEL_NO_VISIBLE_CHANGE"
  | "MODEL_TARGET_BLOCKED"
  | "MODEL_INSUFFICIENT_EVIDENCE";

/** "model_generic" marks a result reached without a typed postcondition
 * (owner decision 2026-07-15: generic Vision judgment is the base layer,
 * recipes/postconditions are an added precision layer). See
 * docs/navigator-stabilization-followups.md §0.6. */
export type ModelVerifierResult = {
  source: "model" | "model_generic";
  status: RuleVerifierStatus;
  reason: ModelVerifierReason;
  evidenceCandidateIds: string[];
  confidence: number;
};

export type NavigateVerifierResult = RuleVerifierResult | ModelVerifierResult;

type ConditionResult = {
  outcome: "met" | "unmet" | "unknown" | "blocked";
  evidenceCandidateIds: string[];
};

export function verifyPostconditions(args: {
  before: VisionObservation;
  after: VisionObservation;
  postconditions: NavigatePostcondition[];
  completesTask?: boolean;
}): RuleVerifierResult {
  const postconditions = navigatePostconditionsSchema.parse(args.postconditions);
  // Capture-contract failures take priority over the postcondition check so a
  // step with no typed postcondition still gets the same safety gate before
  // it is offered to the generic model fallback (see navigate-run-verifier).
  if (args.after.transition_state !== "stable") {
    return result("ambiguous", "OBSERVATION_UNSTABLE");
  }
  if (args.before.capture_scope !== args.after.capture_scope) {
    return result("ambiguous", "CAPTURE_SCOPE_CHANGED");
  }
  if (postconditions.length === 0) {
    return result("ambiguous", "NO_POSTCONDITIONS");
  }

  const checks = postconditions.map((condition) =>
    evaluateCondition(condition, args.before, args.after));
  const evidence = unique(checks.flatMap((check) => check.evidenceCandidateIds));
  if (checks.some((check) => check.outcome === "blocked")) {
    return result("blocked", "TARGET_DISABLED", evidence);
  }
  if (checks.every((check) => check.outcome === "met")) {
    return result(
      args.completesTask ? "complete" : "verified",
      "ALL_POSTCONDITIONS_MET",
      evidence,
    );
  }
  if (sameVisibleState(args.before, args.after)) {
    return result("not_changed", "NO_VISIBLE_CHANGE", evidence);
  }
  return result("ambiguous", "INSUFFICIENT_OR_CONFLICTING_EVIDENCE", evidence);
}

function evaluateCondition(
  condition: NavigatePostcondition,
  before: VisionObservation,
  after: VisionObservation,
): ConditionResult {
  switch (condition.kind) {
  case "candidate_present": {
    const matches = matchingCandidates(after.candidates, condition.selector);
    return matches.length > 0
      ? conditionResult("met", matches)
      : conditionResult("unknown");
  }
  case "candidate_absent": {
    const matches = matchingCandidates(after.candidates, condition.selector);
    return matches.length === 0
      ? conditionResult("met")
      : conditionResult("unmet", matches);
  }
  case "candidate_state": {
    const matches = matchingCandidates(after.candidates, condition.selector);
    if (matches.some((candidate) => candidate.states.includes(condition.state))) {
      return conditionResult(
        "met",
        matches.filter((candidate) => candidate.states.includes(condition.state)),
      );
    }
    if (matches.some((candidate) => candidate.states.includes("disabled"))) {
      return conditionResult("blocked", matches);
    }
    return matches.length > 0
      ? conditionResult("unmet", matches)
      : conditionResult("unknown");
  }
  case "environment_matches": {
    const urlOutcome = containsOrUnknown(
      after.environment?.url,
      condition.url_contains,
    );
    const titleOutcome = containsOrUnknown(
      after.environment?.window_title,
      condition.window_title_contains,
    );
    return conditionResult(combineRequired([urlOutcome, titleOutcome]));
  }
  case "environment_changed": {
    const previous = environmentField(before, condition.field);
    const current = environmentField(after, condition.field);
    if (previous === undefined || current === undefined) return conditionResult("unknown");
    return conditionResult(normalize(previous) === normalize(current) ? "unmet" : "met");
  }
  }
}

function matchingCandidates(
  candidates: ObservationCandidate[],
  selector: CandidateSelector,
): ObservationCandidate[] {
  return candidates.filter((candidate) =>
    normalize(candidate.label) === normalize(selector.label) &&
    (!selector.parent_label ||
      normalize(candidate.parent_label ?? "") === normalize(selector.parent_label)) &&
    (!selector.role || normalize(candidate.role ?? "") === normalize(selector.role)));
}

function containsOrUnknown(
  actual: string | undefined,
  expected: string | undefined,
): ConditionResult["outcome"] | null {
  if (expected === undefined) return null;
  if (actual === undefined) return "unknown";
  return normalize(actual).includes(normalize(expected)) ? "met" : "unmet";
}

function combineRequired(
  outcomes: Array<ConditionResult["outcome"] | null>,
): ConditionResult["outcome"] {
  const required = outcomes.filter((outcome): outcome is ConditionResult["outcome"] =>
    outcome !== null);
  if (required.some((outcome) => outcome === "unmet")) return "unmet";
  if (required.some((outcome) => outcome === "unknown")) return "unknown";
  return "met";
}

function environmentField(
  observation: VisionObservation,
  field: "url" | "window_title",
): string | undefined {
  return field === "url"
    ? observation.environment?.url
    : observation.environment?.window_title;
}

function sameVisibleState(before: VisionObservation, after: VisionObservation): boolean {
  if (normalize(before.environment?.url ?? "") !== normalize(after.environment?.url ?? "")) {
    return false;
  }
  if (
    normalize(before.environment?.window_title ?? "") !==
    normalize(after.environment?.window_title ?? "")
  ) {
    return false;
  }
  const candidateState = (observation: VisionObservation) => observation.candidates
    .map((candidate) => [
      normalize(candidate.label),
      normalize(candidate.parent_label ?? ""),
      normalize(candidate.role ?? ""),
      [...candidate.states].sort().join(","),
    ].join("|"))
    .sort();
  return JSON.stringify(candidateState(before)) === JSON.stringify(candidateState(after));
}

function normalize(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase().replace(/\s+/gu, "");
}

function conditionResult(
  outcome: ConditionResult["outcome"],
  candidates: ObservationCandidate[] = [],
): ConditionResult {
  return { outcome, evidenceCandidateIds: candidates.map((candidate) => candidate.id) };
}

function result(
  status: RuleVerifierStatus,
  reason: RuleVerifierReason,
  evidenceCandidateIds: string[] = [],
): RuleVerifierResult {
  return { source: "rule", status, reason, evidenceCandidateIds };
}

function unique(values: string[]): string[] {
  return [...new Set(values)];
}
