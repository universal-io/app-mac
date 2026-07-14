// Navigator v4 Run control plane. The route never accepts tenant/user IDs,
// Task edits, or a client-selected step. It starts a Gateway-signed Planner
// proposal, re-signs authoritative state, or cancels the current revision.

import { getServerEnv } from "@/lib/server/env";
import {
  authenticate,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
} from "@/lib/server/gateway";
import {
  createNavigateRun,
  loadNavigateRun,
  mutateNavigateRun,
} from "@/lib/server/navigate-run";
import {
  assertSnapshotMatchesRun,
  assertSnapshotPlanMatchesRun,
  signNavigateRunSnapshot,
  verifyNavigateRunProposal,
  verifyNavigateRunSnapshot,
} from "@/lib/server/navigate-run-snapshot";

type RunActionBody = {
  request_id?: string;
  action?: string;
  proposal?: unknown;
  run_snapshot?: unknown;
};

export async function POST(request: Request): Promise<Response> {
  let requestId: string | null = null;
  try {
    const body = (await request.json().catch(() => null)) as RunActionBody | null;
    if (!body) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be JSON.", null);
    }
    requestId = typeof body.request_id === "string" && body.request_id.trim()
      ? body.request_id
      : null;
    if (!requestId) {
      return errorResponse(400, "BAD_REQUEST", "request_id is required.", null);
    }

    const env = getServerEnv();
    if (!env.navigateV4Enabled) {
      throw new GatewayError(
        404,
        "FEATURE_NOT_ENABLED",
        "新しいナビゲーション状態機能はまだ有効になっていません。従来方式をご利用ください。",
      );
    }
    const secret = env.navigateRunSigningSecret ?? "";
    const auth = await authenticate(request);

    if (body.action === "start") {
      const proposal = verifyNavigateRunProposal(body.proposal, auth, secret);
      const run = await createNavigateRun(auth, {
        packId: proposal.pack.id,
        packVersion: proposal.pack.version,
        planId: proposal.plan.id,
        planVersion: proposal.plan.version,
        planHash: proposal.plan.hash,
      });
      return runResponse(
        requestId,
        signNavigateRunSnapshot(run, proposal.plan.task, secret),
      );
    }

    if (body.action === "sync" || body.action === "cancel") {
      const carried = verifyNavigateRunSnapshot(body.run_snapshot, secret);
      const run = await loadNavigateRun(auth, carried.run_id);
      assertSnapshotPlanMatchesRun(carried, run);

      if (body.action === "sync" || run.status === "cancelled") {
        return runResponse(
          requestId,
          signNavigateRunSnapshot(run, carried.plan.task, secret),
        );
      }
      assertSnapshotMatchesRun(carried, run);
      const cancelled = await mutateNavigateRun(auth, run.id, {
        expectedRevision: run.revision,
        currentStep: run.currentStep,
        status: "cancelled",
      });
      return runResponse(
        requestId,
        signNavigateRunSnapshot(cancelled, carried.plan.task, secret),
      );
    }

    return errorResponse(
      400,
      "BAD_REQUEST",
      "actionにはstart、sync、cancelのいずれかを指定してください。",
      requestId,
    );
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, requestId);
    }
    console.error("[/api/ai/navigate/run] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}

function runResponse(requestId: string, runSnapshot: unknown): Response {
  return Response.json({
    request_id: requestId,
    result: { run_snapshot: runSnapshot },
  });
}
