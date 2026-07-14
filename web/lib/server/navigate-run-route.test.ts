import { beforeEach, describe, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getServerEnv: vi.fn(),
  authenticate: vi.fn(),
  createNavigateRun: vi.fn(),
  loadNavigateRun: vi.fn(),
  mutateNavigateRun: vi.fn(),
  verifyProposal: vi.fn(),
  verifySnapshot: vi.fn(),
  assertSnapshotMatchesRun: vi.fn(),
  assertSnapshotPlanMatchesRun: vi.fn(),
  signSnapshot: vi.fn(),
}));

vi.mock("@/lib/server/env", () => ({ getServerEnv: mocks.getServerEnv }));
vi.mock("@/lib/server/gateway", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/server/gateway")>()),
  authenticate: mocks.authenticate,
}));
vi.mock("@/lib/server/navigate-run", () => ({
  createNavigateRun: mocks.createNavigateRun,
  loadNavigateRun: mocks.loadNavigateRun,
  mutateNavigateRun: mocks.mutateNavigateRun,
}));
vi.mock("@/lib/server/navigate-run-snapshot", () => ({
  assertSnapshotMatchesRun: mocks.assertSnapshotMatchesRun,
  assertSnapshotPlanMatchesRun: mocks.assertSnapshotPlanMatchesRun,
  signNavigateRunSnapshot: mocks.signSnapshot,
  verifyNavigateRunProposal: mocks.verifyProposal,
  verifyNavigateRunSnapshot: mocks.verifySnapshot,
}));

import { POST } from "@/app/api/ai/navigate/run/route";

const auth = { tenantId: "tenant-a", userId: "user-a" };
const task = { goal: "goal", steps: [] };
const run = { id: "run-1", revision: 0, currentStep: 0, status: "active" };
const carried = { run_id: "run-1", plan: { task } };

describe("Navigator Run control route", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getServerEnv.mockReturnValue({
      navigateV4Enabled: true,
      navigateRunSigningSecret: "test-only-signing-secret-with-at-least-32-bytes",
    });
    mocks.authenticate.mockResolvedValue(auth);
    mocks.signSnapshot.mockReturnValue({ signed: true });
  });

  test("starts only from a verified proposal and is repository-idempotent", async () => {
    mocks.verifyProposal.mockReturnValue({
      pack: { id: "ga4", version: "unversioned-v3" },
      plan: { id: "plan-1", version: 1, hash: "sha256:hash", task },
    });
    mocks.createNavigateRun.mockResolvedValue(run);

    const response = await POST(request({ action: "start", proposal: { signed: true } }));

    expect(response.status).toBe(200);
    expect(mocks.createNavigateRun).toHaveBeenCalledWith(auth, {
      packId: "ga4",
      packVersion: "unversioned-v3",
      planId: "plan-1",
      planVersion: 1,
      planHash: "sha256:hash",
    });
    expect(await response.json()).toMatchObject({ result: { run_snapshot: { signed: true } } });
  });

  test("sync replaces stale progress without accepting client mutations", async () => {
    mocks.verifySnapshot.mockReturnValue(carried);
    mocks.loadNavigateRun.mockResolvedValue({ ...run, revision: 2, currentStep: 1 });

    const response = await POST(request({ action: "sync", run_snapshot: carried }));

    expect(response.status).toBe(200);
    expect(mocks.assertSnapshotPlanMatchesRun).toHaveBeenCalledOnce();
    expect(mocks.assertSnapshotMatchesRun).not.toHaveBeenCalled();
    expect(mocks.mutateNavigateRun).not.toHaveBeenCalled();
  });

  test("cancel mutates only the verified current revision", async () => {
    mocks.verifySnapshot.mockReturnValue(carried);
    mocks.loadNavigateRun.mockResolvedValue(run);
    mocks.mutateNavigateRun.mockResolvedValue({ ...run, revision: 1, status: "cancelled" });

    const response = await POST(request({ action: "cancel", run_snapshot: carried }));

    expect(response.status).toBe(200);
    expect(mocks.assertSnapshotMatchesRun).toHaveBeenCalledWith(carried, run);
    expect(mocks.mutateNavigateRun).toHaveBeenCalledWith(auth, "run-1", {
      expectedRevision: 0,
      currentStep: 0,
      status: "cancelled",
    });
  });
});

function request(body: Record<string, unknown>): Request {
  return new Request("https://example.test/api/ai/navigate/run", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ request_id: "request-1", ...body }),
  });
}
