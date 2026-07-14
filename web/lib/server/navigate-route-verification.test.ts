import { beforeEach, describe, expect, test, vi } from "vitest";

import { visionObservationSchema, type VisionObservation } from "@/lib/context/observation";

const mocks = vi.hoisted(() => ({
  getServerEnv: vi.fn(),
  loadNavigateRun: vi.fn(),
  verifySnapshot: vi.fn(),
  assertSnapshotMatchesRun: vi.fn(),
}));

vi.mock("@/lib/server/env", () => ({ getServerEnv: mocks.getServerEnv }));
vi.mock("@/lib/server/navigate-run", () => ({
  loadNavigateRun: mocks.loadNavigateRun,
}));
vi.mock("@/lib/server/navigate-run-snapshot", () => ({
  assertSnapshotMatchesRun: mocks.assertSnapshotMatchesRun,
  createNavigateRunProposal: vi.fn(),
  verifyNavigateRunSnapshot: mocks.verifySnapshot,
}));

import { verifyNavigateRunInShadow } from "@/lib/server/navigate-run-verifier";

const auth = { tenantId: "tenant-a", userId: "user-a" };
const run = { id: "43fe19ea-c422-4b3f-8ee2-e063fea8f7b5" };

describe("Navigator route Run shadow verification", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getServerEnv.mockReturnValue({
      navigateV4Enabled: true,
      navigateRunSigningSecret: "test-only-signing-secret-with-at-least-32-bytes",
    });
    mocks.loadNavigateRun.mockResolvedValue(run);
    mocks.verifySnapshot.mockReturnValue({
      run_id: run.id,
      current_step: 0,
      plan: {
        task: {
          steps: [{
            postconditions: [{
              kind: "candidate_present",
              selector: { label: "国" },
            }],
          }],
        },
      },
    });
  });

  test("checks the authoritative Run and evaluates its current signed step", async () => {
    const before = observation([{ id: "ax:overview", label: "概要" }]);
    const after = observation([{ id: "ax:country", label: "国" }]);

    const result = await verifyNavigateRunInShadow({
      ...auth,
      snapshot: { signed: true },
      before,
      after,
    });

    expect(mocks.loadNavigateRun).toHaveBeenCalledWith(auth, run.id);
    expect(mocks.assertSnapshotMatchesRun).toHaveBeenCalledWith(
      expect.objectContaining({ run_id: run.id }),
      run,
    );
    expect(result).toEqual({
      source: "rule",
      status: "complete",
      reason: "ALL_POSTCONDITIONS_MET",
      evidenceCandidateIds: ["ax:country"],
    });
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
