import { beforeEach, describe, expect, test, vi } from "vitest";

import { visionObservationSchema, type VisionObservation } from "@/lib/context/observation";
import type { NavigateEngineOutput } from "@/lib/server/navigate-engine";

const mocks = vi.hoisted(() => ({
  getServerEnv: vi.fn(),
  authenticate: vi.fn(),
  enforceQuota: vi.fn(),
  recordUsage: vi.fn(),
  runNavigateStream: vi.fn(),
  isAutoFirstTurn: vi.fn(),
  createNavigateRunProposal: vi.fn(),
  verifyNavigateRunInShadow: vi.fn(),
  groundNavigateRunRenderingInShadow: vi.fn(),
}));

vi.mock("@/lib/server/env", () => ({ getServerEnv: mocks.getServerEnv }));
vi.mock("@/lib/server/gateway", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/server/gateway")>()),
  authenticate: mocks.authenticate,
  enforceQuota: mocks.enforceQuota,
  recordUsage: mocks.recordUsage,
}));
vi.mock("@/lib/server/navigate-engine", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/server/navigate-engine")>()),
  runNavigateStream: mocks.runNavigateStream,
  isAutoFirstTurn: mocks.isAutoFirstTurn,
}));
vi.mock("@/lib/server/navigate-run-snapshot", () => ({
  createNavigateRunProposal: mocks.createNavigateRunProposal,
}));
vi.mock("@/lib/server/navigate-run-verifier", () => ({
  verifyNavigateRunInShadow: mocks.verifyNavigateRunInShadow,
}));
vi.mock("@/lib/server/navigate-run-grounder", () => ({
  groundNavigateRunRenderingInShadow: mocks.groundNavigateRunRenderingInShadow,
}));

import { POST } from "@/app/api/ai/navigate/route";

const auth = {
  userId: "user-a",
  tenantId: "tenant-a",
  entitlement: { plan: "free", status: "active", monthly_review_limit: null },
};

const task = {
  goal: "設定を変更する",
  steps: [{ verbal: "設定を開く" }],
  current_step: 0,
};

const baseOutput: NavigateEngineOutput = {
  text: "画面を確認しました。",
  harnessId: null,
  harnessVersion: null,
  modelVendor: "openai",
  modelId: "main-model",
  inputTokens: 10,
  outputTokens: 5,
  hasLocator: false,
  locatorSupplemented: false,
  grounding: null,
  groundingAttempted: false,
  groundingInputTokens: 0,
  groundingOutputTokens: 0,
  plannerModelVendor: null,
  plannerModelId: null,
  plannerInputTokens: 0,
  plannerOutputTokens: 0,
  grounderModelVendor: null,
  grounderModelId: null,
  modelFallbackFrom: null,
  notices: [],
  proposedTask: null,
};

describe("Navigator v4 shadow execution visibility", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getServerEnv.mockReturnValue({
      navigateV4Enabled: true,
      navigateRunSigningSecret: "test-only-signing-secret-with-at-least-32-bytes",
    });
    mocks.authenticate.mockResolvedValue(auth);
    mocks.enforceQuota.mockResolvedValue(undefined);
    mocks.recordUsage.mockResolvedValue(undefined);
    mocks.isAutoFirstTurn.mockReturnValue(false);
    mocks.runNavigateStream.mockImplementation(async function* () {
      yield { type: "final", output: baseOutput };
    });
  });

  test("marks the shadow role skipped and emits a notice when a Copilot turn arrives without a run_snapshot", async () => {
    const response = await POST(
      request({
        input: {
          messages: [{ role: "user", text: "次に進めて" }],
          task,
        },
      }),
    );

    const events = await readSSE(response);
    const result = events.find((event) => event.event === "result")!;

    expect(mocks.verifyNavigateRunInShadow).not.toHaveBeenCalled();
    expect(mocks.groundNavigateRunRenderingInShadow).not.toHaveBeenCalled();
    expect(result.data.meta.notices).toContainEqual(
      expect.objectContaining({ code: "RUN_SNAPSHOT_MISSING" }),
    );

    expect(mocks.recordUsage).toHaveBeenCalledOnce();
    const usage = mocks.recordUsage.mock.calls[0][2];
    expect(usage.metadata.run_shadow_state).toBe("skipped_no_snapshot");
    expect(usage.metadata.operational_notice_codes).toContain("RUN_SNAPSHOT_MISSING");
  });

  test.each([
    ["verification_finished", "inactive_verification_finished"],
    ["start_failed", "inactive_start_failed"],
  ])(
    "stays silent when the client declares inactive reason %s",
    async (reason, expectedState) => {
      const response = await POST(
        request({
          input: {
            messages: [{ role: "user", text: "次に進めて" }],
            task,
            run_shadow_inactive_reason: reason,
          },
        }),
      );

      const events = await readSSE(response);
      const result = events.find((event) => event.event === "result")!;

      expect(mocks.verifyNavigateRunInShadow).not.toHaveBeenCalled();
      expect(result.data.meta.notices).not.toContainEqual(
        expect.objectContaining({ code: "RUN_SNAPSHOT_MISSING" }),
      );

      expect(mocks.recordUsage).toHaveBeenCalledOnce();
      const usage = mocks.recordUsage.mock.calls[0][2];
      expect(usage.metadata.run_shadow_state).toBe(expectedState);
    },
  );

  test("treats an unknown inactive reason as a missing snapshot (fail-noisy)", async () => {
    const response = await POST(
      request({
        input: {
          messages: [{ role: "user", text: "次に進めて" }],
          task,
          run_shadow_inactive_reason: "some_future_reason",
        },
      }),
    );

    const events = await readSSE(response);
    const result = events.find((event) => event.event === "result")!;

    expect(mocks.verifyNavigateRunInShadow).not.toHaveBeenCalled();
    expect(result.data.meta.notices).toContainEqual(
      expect.objectContaining({ code: "RUN_SNAPSHOT_MISSING" }),
    );

    expect(mocks.recordUsage).toHaveBeenCalledOnce();
    const usage = mocks.recordUsage.mock.calls[0][2];
    expect(usage.metadata.run_shadow_state).toBe("skipped_no_snapshot");
  });

  test("marks the shadow role executed when the run_snapshot is carried", async () => {
    const before = observation([{ id: "ax:overview", label: "概要" }]);
    const after = observation([{ id: "ax:country", label: "国" }]);
    mocks.verifyNavigateRunInShadow.mockResolvedValue({
      result: {
        source: "rule",
        status: "complete",
        reason: "ALL_POSTCONDITIONS_MET",
        evidenceCandidateIds: ["ax:country"],
      },
      ruleResult: {
        source: "rule",
        status: "complete",
        reason: "ALL_POSTCONDITIONS_MET",
        evidenceCandidateIds: ["ax:country"],
      },
      modelAttempted: false,
      modelVendor: null,
      modelId: null,
      modelInputTokens: 0,
      modelOutputTokens: 0,
      modelFailureReason: null,
      rendering: {
        schema_version: 1,
        state: "complete",
        verification_source: "rule",
        verification_status: "complete",
        step: null,
      },
      notices: [],
    });
    mocks.groundNavigateRunRenderingInShadow.mockResolvedValue({
      result: {
        schema_version: 1,
        status: "not_applicable",
        comparison: "not_comparable",
        safe_to_prompt: false,
        capture_id: after.capture_id,
        step_id: null,
        candidate_id: null,
        confidence: null,
        method: null,
        legacy_candidate_id: null,
      },
      rendering: {
        schema_version: 1,
        state: "complete",
        verification_source: "rule",
        verification_status: "complete",
        step: null,
      },
      attempted: false,
      modelVendor: null,
      modelId: null,
      inputTokens: 0,
      outputTokens: 0,
      notices: [],
    });

    const response = await POST(
      request({
        input: {
          messages: [{ role: "user", text: "次に進めて", observation: after }],
          task,
          run_snapshot: { signed: true },
          previous_observation: before,
        },
      }),
    );

    const events = await readSSE(response);
    const result = events.find((event) => event.event === "result")!;

    expect(mocks.verifyNavigateRunInShadow).toHaveBeenCalledOnce();
    expect(result.data.meta.notices).not.toContainEqual(
      expect.objectContaining({ code: "RUN_SNAPSHOT_MISSING" }),
    );

    expect(mocks.recordUsage).toHaveBeenCalledOnce();
    const usage = mocks.recordUsage.mock.calls[0][2];
    expect(usage.metadata.run_shadow_state).toBe("executed");
  });

  test("marks the shadow role not_applicable outside a Copilot turn", async () => {
    const response = await POST(
      request({
        input: {
          messages: [{ role: "user", text: "これは何？" }],
        },
      }),
    );

    const events = await readSSE(response);
    const result = events.find((event) => event.event === "result")!;

    expect(mocks.verifyNavigateRunInShadow).not.toHaveBeenCalled();
    expect(result.data.meta.notices).not.toContainEqual(
      expect.objectContaining({ code: "RUN_SNAPSHOT_MISSING" }),
    );

    expect(mocks.recordUsage).toHaveBeenCalledOnce();
    const usage = mocks.recordUsage.mock.calls[0][2];
    expect(usage.metadata.run_shadow_state).toBe("not_applicable");
  });
});

function observation(
  candidates: Array<{ id: string; label: string }>,
): VisionObservation {
  return visionObservationSchema.parse({
    schema_version: 1,
    capture_id: crypto.randomUUID(),
    captured_at: "2026-07-14T00:00:00.000Z",
    capture_scope: "display",
    coordinate_space: "normalized_top_left",
    transition_state: "stable",
    candidates: candidates.map((candidate) => ({
      ...candidate,
      source: "ax",
      states: [],
    })),
  });
}

function request(body: Record<string, unknown>): Request {
  return new Request("https://example.test/api/ai/navigate", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer test-token" },
    body: JSON.stringify({
      request_id: "request-1",
      operation: "navigate",
      preferences: { output_language: "japanese" },
      client: { platform: "macos" },
      ...body,
    }),
  });
}

type SSEEvent = {
  event: string;
  data: { meta: { notices: Array<{ code: string; message: string }> } };
};

async function readSSE(response: Response): Promise<SSEEvent[]> {
  const text = await response.text();
  return text
    .split("\n\n")
    .filter((chunk) => chunk.trim().length > 0)
    .map((chunk) => {
      const lines = chunk.split("\n");
      const eventLine = lines.find((line) => line.startsWith("event: "))!;
      const dataLine = lines.find((line) => line.startsWith("data: "))!;
      return {
        event: eventLine.slice("event: ".length),
        data: JSON.parse(dataLine.slice("data: ".length)),
      };
    });
}
