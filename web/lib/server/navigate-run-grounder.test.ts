import { beforeEach, describe, expect, test, vi } from "vitest";

import { visionObservationSchema } from "@/lib/context/observation";

const mocks = vi.hoisted(() => ({
  getServerEnv: vi.fn(),
  resolveRoleRoute: vi.fn(),
}));

vi.mock("@/lib/server/env", () => ({ getServerEnv: mocks.getServerEnv }));
vi.mock("@/lib/server/navigate-provider-route", () => ({
  resolveNavigateRoleRoute: mocks.resolveRoleRoute,
}));

import { groundNavigateRunRenderingInShadow } from "./navigate-run-grounder";
import type { NavigateShadowRendering } from "./navigate-run-renderer";

const captureId = "55555555-5555-4555-8555-555555555555";
const observation = visionObservationSchema.parse({
  schema_version: 1,
  capture_id: captureId,
  captured_at: "2026-07-14T00:00:05.000Z",
  capture_scope: "display",
  coordinate_space: "normalized_top_left",
  transition_state: "stable",
  candidates: [
    { id: "ax:page-title", source: "ax", role: "heading", label: "ユーザー属性の詳細" },
    { id: "ax:country-dimension", source: "ax", role: "button", label: "国" },
  ],
});
const rendering: NavigateShadowRendering = {
  schema_version: 1,
  state: "next_step",
  verification_source: "rule",
  verification_status: "verified",
  step: {
    id: "demographics.step-3",
    verbal: "国ディメンションを確認する",
    target: "国",
    fill: null,
  },
};

describe("Navigator signed-step shadow Grounder", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getServerEnv.mockReturnValue({
      navigateGrounderModelVendor: "openai",
      navigateGrounderModelId: "grounder-model",
      navigateModelVendor: "openai",
      navigateModelId: "main-model",
    });
    mocks.resolveRoleRoute.mockReturnValue({
      vendor: "openai",
      modelId: "grounder-model",
      apiKey: "unused-for-exact-match",
      endpoint: "https://provider.invalid",
    });
  });

  test("grounds the Renderer-selected GA4 step from the latest Observation", async () => {
    const result = await groundNavigateRunRenderingInShadow({
      rendering,
      observation,
      legacyGrounding: null,
    });

    expect(result.result).toMatchObject({
      status: "grounded",
      comparison: "not_comparable",
      safe_to_prompt: true,
      capture_id: captureId,
      step_id: "demographics.step-3",
      candidate_id: "ax:country-dimension",
      confidence: 1,
      method: "exact_unique",
    });
    expect(result.rendering).toEqual(rendering);
  });

  test("records agreement with the legacy grounding path", async () => {
    const result = await groundNavigateRunRenderingInShadow({
      rendering,
      observation,
      legacyGrounding: {
        captureId,
        candidateId: "ax:country-dimension",
        confidence: 1,
        method: "exact_unique",
      },
    });

    expect(result.result).toMatchObject({
      status: "grounded",
      comparison: "agreement",
      safe_to_prompt: true,
    });
  });

  test("fails closed when the signed and legacy paths select different candidates", async () => {
    const result = await groundNavigateRunRenderingInShadow({
      rendering,
      observation,
      legacyGrounding: {
        captureId,
        candidateId: "ax:page-title",
        confidence: 1,
        method: "exact_unique",
      },
    });

    expect(result.result).toMatchObject({
      status: "ambiguous",
      comparison: "disagreement",
      safe_to_prompt: false,
      candidate_id: "ax:country-dimension",
      legacy_candidate_id: "ax:page-title",
    });
    expect(result.rendering.state).toBe("needs_confirmation");
  });

  test("does not compare a legacy candidate from another capture", async () => {
    const result = await groundNavigateRunRenderingInShadow({
      rendering,
      observation,
      legacyGrounding: {
        captureId: "44444444-4444-4444-8444-444444444444",
        candidateId: "ax:page-title",
        confidence: 1,
        method: "exact_unique",
      },
    });

    expect(result.result).toMatchObject({
      status: "grounded",
      comparison: "not_comparable",
      safe_to_prompt: true,
    });
  });

  test("does not ground or prompt when the Renderer requires confirmation", async () => {
    const result = await groundNavigateRunRenderingInShadow({
      rendering: { ...rendering, state: "needs_confirmation" },
      observation,
      legacyGrounding: null,
    });

    expect(result).toMatchObject({
      attempted: false,
      result: {
        status: "not_applicable",
        comparison: "not_comparable",
        safe_to_prompt: false,
        candidate_id: null,
      },
    });
  });
});
