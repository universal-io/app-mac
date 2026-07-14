import { describe, expect, test } from "vitest";

import type { NavigateRun } from "./navigate-run";
import {
  assertSnapshotMatchesRun,
  createNavigateRunProposal,
  hashSnapshotTask,
  materializeSnapshotTask,
  signNavigateRunSnapshot,
  verifyNavigateRunProposal,
  verifyNavigateRunSnapshot,
} from "./navigate-run-snapshot";

const SECRET = "test-only-signing-secret-with-at-least-32-bytes";

function fixture() {
  const task = materializeSnapshotTask({
    recipeId: "demographics",
    goal: "国別のユーザー数を見る",
    steps: [
      {
        id: "demographics.step-1",
        verbal: "ユーザー属性を開く",
        target: "ユーザー属性",
        postconditions: [{
          kind: "candidate_present",
          selector: { label: "ユーザー属性の詳細" },
        }],
      },
      { verbal: "ユーザー属性の概要を開く", target: "概要" },
    ],
  });
  const run: NavigateRun = {
    id: "84e72746-49bd-4c60-b8a7-6ac9a78bf344",
    tenantId: "tenant-a",
    userId: "user-a",
    packId: "ga4",
    packVersion: "1",
    planId: "626ca186-44c8-4338-9a20-829d663dc682",
    planVersion: 1,
    planHash: hashSnapshotTask(task),
    currentStep: 0,
    status: "active",
    revision: 0,
    expiresAt: "2026-07-15T08:00:00.000Z",
    createdAt: "2026-07-14T08:00:00.000Z",
    updatedAt: "2026-07-14T08:00:00.000Z",
  };
  return { run, task };
}

describe("signed Navigator Run snapshot", () => {
  test("binds a short-lived proposal to the authenticated tenant and user", () => {
    const auth = { tenantId: "tenant-a", userId: "user-a" };
    const now = new Date("2026-07-14T08:00:00.000Z");
    const proposal = createNavigateRunProposal(auth, {
      packId: "ga4",
      packVersion: "unversioned-v3",
      task: {
        goal: "国別のユーザー数を見る",
        steps: [{ verbal: "ユーザー属性を開く", target: "ユーザー属性" }],
      },
    }, SECRET, now);

    expect(() => verifyNavigateRunProposal(proposal, auth, SECRET, now)).not.toThrow();
    expect(() => verifyNavigateRunProposal(
      proposal,
      { tenantId: "tenant-b", userId: "user-a" },
      SECRET,
      now,
    )).toThrowError(expect.objectContaining({ code: "RUN_PROPOSAL_NOT_FOUND", status: 404 }));
  });

  test("rejects expired and modified proposals", () => {
    const auth = { tenantId: "tenant-a", userId: "user-a" };
    const now = new Date("2026-07-14T08:00:00.000Z");
    const proposal = createNavigateRunProposal(auth, {
      packId: "ga4",
      packVersion: "unversioned-v3",
      task: { goal: "国別に見る", steps: [{ verbal: "ユーザー属性を開く" }] },
    }, SECRET, now);

    expect(() => verifyNavigateRunProposal(
      proposal,
      auth,
      SECRET,
      new Date("2026-07-14T08:11:00.000Z"),
    )).toThrowError(expect.objectContaining({ code: "RUN_PROPOSAL_EXPIRED", status: 410 }));
    expect(() => verifyNavigateRunProposal({
      ...proposal,
      pack: { ...proposal.pack, id: "notion" },
    }, auth, SECRET, now)).toThrowError(expect.objectContaining({
      code: "RUN_PROPOSAL_CONFLICT",
    }));
  });

  test("round-trips an immutable Task without storing the body in the row", () => {
    const { run, task } = fixture();
    const signed = signNavigateRunSnapshot(run, task, SECRET);
    const verified = verifyNavigateRunSnapshot(signed, SECRET);

    expect(verified.plan.task.steps[0]).toMatchObject({
      id: "demographics.step-1",
      target: "ユーザー属性",
      postconditions: [{
        kind: "candidate_present",
        selector: { label: "ユーザー属性の詳細" },
      }],
    });
    expect(verified.plan.task.recipe_id).toBe("demographics");
    expect(() => assertSnapshotMatchesRun(verified, run)).not.toThrow();
  });

  test("rejects Task and progress tampering", () => {
    const { run, task } = fixture();
    const signed = signNavigateRunSnapshot(run, task, SECRET);

    expect(() => verifyNavigateRunSnapshot({
      ...signed,
      current_step: 1,
    }, SECRET)).toThrowError(expect.objectContaining({ code: "RUN_SNAPSHOT_CONFLICT" }));
    expect(() => verifyNavigateRunSnapshot({
      ...signed,
      plan: {
        ...signed.plan,
        task: { ...signed.plan.task, goal: "別の目的" },
      },
    }, SECRET)).toThrowError(expect.objectContaining({ code: "RUN_SNAPSHOT_CONFLICT" }));
  });

  test("rejects a valid but stale snapshot against the current row", () => {
    const { run, task } = fixture();
    const signed = verifyNavigateRunSnapshot(
      signNavigateRunSnapshot(run, task, SECRET),
      SECRET,
    );
    expect(() => assertSnapshotMatchesRun(signed, {
      ...run,
      revision: 1,
      currentStep: 1,
    })).toThrowError(expect.objectContaining({ code: "RUN_SNAPSHOT_CONFLICT" }));
  });

  test("fails closed when the signing secret is not safely configured", () => {
    const { run, task } = fixture();
    expect(() => signNavigateRunSnapshot(run, task, "too-short")).toThrowError(
      expect.objectContaining({ code: "RUN_SIGNING_UNAVAILABLE", status: 503 }),
    );
  });
});
