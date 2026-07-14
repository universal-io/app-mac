import { describe, expect, test } from "vitest";

import { GatewayError } from "./gateway";
import {
  assertRunOwner,
  assertRunPlanMatchesInput,
  validateMutation,
  validateRunId,
  validateTransition,
} from "./navigate-run";

describe("Navigator Run invariants", () => {
  test("rejects a run from another tenant or user without disclosing it", () => {
    const run = { tenantId: "tenant-a", userId: "user-a" };
    for (const auth of [
      { tenantId: "tenant-b", userId: "user-a" },
      { tenantId: "tenant-a", userId: "user-b" },
    ]) {
      expect(() => assertRunOwner(run, auth)).toThrowError(
        expect.objectContaining<Partial<GatewayError>>({
          status: 404,
          code: "RUN_NOT_FOUND",
        }),
      );
    }
  });

  test("accepts only bounded revisions, steps, and known statuses", () => {
    expect(() => validateMutation({
      expectedRevision: 3,
      currentStep: 2,
      status: "active",
    })).not.toThrow();

    expect(() => validateMutation({
      expectedRevision: -1,
      currentStep: 2,
      status: "active",
    })).toThrowError(/revision/);
    expect(() => validateMutation({
      expectedRevision: 0,
      currentStep: -1,
      status: "active",
    })).toThrowError(/current_step/);
  });

  test("rejects malformed run IDs before they reach the store", () => {
    expect(() => validateRunId("not-a-run-id")).toThrowError(
      expect.objectContaining({ status: 400, code: "BAD_REQUEST" }),
    );
    expect(() => validateRunId("84e72746-49bd-4c60-b8a7-6ac9a78bf344")).not.toThrow();
  });

  test("requires the latest revision and advances at most one step", () => {
    const current = { revision: 4, currentStep: 2, status: "active" as const };
    expect(() => validateTransition(current, {
      expectedRevision: 4,
      currentStep: 3,
      status: "active",
    })).not.toThrow();
    expect(() => validateTransition(current, {
      expectedRevision: 3,
      currentStep: 3,
      status: "active",
    })).toThrowError(expect.objectContaining({ code: "RUN_REVISION_CONFLICT" }));
    expect(() => validateTransition(current, {
      expectedRevision: 4,
      currentStep: 4,
      status: "active",
    })).toThrowError(expect.objectContaining({ code: "RUN_STEP_CONFLICT" }));
  });

  test("does not revive terminal runs", () => {
    expect(() => validateTransition(
      { revision: 2, currentStep: 1, status: "complete" },
      { expectedRevision: 2, currentStep: 1, status: "active" },
    )).toThrowError(expect.objectContaining({ code: "RUN_TERMINAL" }));
  });

  test("accepts only an idempotent retry of the same signed plan", () => {
    const input = {
      packId: "ga4",
      packVersion: "unversioned-v3",
      planId: "626ca186-44c8-4338-9a20-829d663dc682",
      planVersion: 1,
      planHash: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    const run = { ...input };
    expect(() => assertRunPlanMatchesInput(run, input)).not.toThrow();
    expect(() => assertRunPlanMatchesInput(
      { ...run, planHash: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
      input,
    )).toThrowError(expect.objectContaining({ code: "RUN_PLAN_CONFLICT" }));
  });
});
