// AI gateway: POST /api/ai/memory/distill.
// operation = "bootstrap": past-message samples in, persona card Markdown out.
// operation = "distill":   one deploy observation in, high-confidence notes out.
// Card storage stays on the client until the memory sync API ships; the
// gateway never persists any of this content.

import {
  authenticate,
  enforceQuota,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
  recordUsage,
} from "@/lib/server/gateway";
import {
  aiModelFailureContract,
} from "@/lib/server/ai-routing";
import {
  runDistillation,
  runPersonaBootstrap,
} from "@/lib/server/memory-engine";
import type { SituationalContextPayload } from "@/lib/server/prompts";

type DistillRequestBody = {
  request_id?: string;
  operation?: string;
  input?: {
    samples?: string;
    original?: string;
    suggestion?: string;
    final?: string;
    context?: SituationalContextPayload;
  };
  client?: {
    platform?: string;
    app_version?: string;
  };
};

export async function POST(request: Request): Promise<Response> {
  let requestId: string | null = null;
  try {
    const body = (await request.json().catch(() => null)) as DistillRequestBody | null;
    if (!body) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be JSON.", null);
    }
    requestId = typeof body.request_id === "string" ? body.request_id : null;

    const operation = body.operation;
    const platform = body.client?.platform;
    if (!requestId) {
      return errorResponse(400, "BAD_REQUEST", "request_id is required.", requestId);
    }
    if (operation !== "bootstrap" && operation !== "distill") {
      return errorResponse(400, "BAD_REQUEST", "operation must be 'bootstrap' or 'distill'.", requestId);
    }
    if (platform !== "macos" && platform !== "ios" && platform !== "android" && platform !== "web") {
      return errorResponse(400, "BAD_REQUEST", "client.platform is required.", requestId);
    }

    const samples = body.input?.samples?.trim();
    const original = body.input?.original?.trim();
    const suggestion = body.input?.suggestion?.trim();
    const final = body.input?.final?.trim();
    if (operation === "bootstrap" && !samples) {
      return errorResponse(400, "BAD_REQUEST", "input.samples must not be empty.", requestId);
    }
    if (operation === "distill" && (!original || !suggestion || !final)) {
      return errorResponse(400, "BAD_REQUEST", "input.original / suggestion / final are required.", requestId);
    }

    const { userId, tenantId, entitlement } = await authenticate(request);
    await enforceQuota(tenantId, entitlement);

    const metadata = {
      operation,
      platform,
      app_version: body.client?.app_version,
      has_context: Boolean(body.input?.context?.conversation_excerpt),
    };

    const started = Date.now();
    let engineOutput;
    try {
      engineOutput =
        operation === "bootstrap"
          ? await runPersonaBootstrap(samples!)
          : await runDistillation({
              original: original!,
              suggestion: suggestion!,
              final: final!,
              context: body.input?.context,
            });
    } catch (error) {
      const failure = aiModelFailureContract(error);
      console.error(
        `[/api/ai/memory/distill] provider error (request ${requestId}):`,
        failure.detail,
      );
      await recordUsage(tenantId, userId, {
        operation: "memory_distill",
        unitType: "call",
        requestId,
        status: "error",
        errorCode: failure.code,
        latencyMs: Date.now() - started,
        metadata,
      });
      return errorResponse(failure.status, failure.code, failure.message, requestId);
    }
    const latencyMs = Date.now() - started;

    await recordUsage(tenantId, userId, {
      operation: "memory_distill",
      unitType: "call",
      requestId,
      status: "success",
      modelVendor: engineOutput.modelVendor,
      modelId: engineOutput.modelId,
      inputUnits: engineOutput.inputTokens,
      outputUnits: engineOutput.outputTokens,
      latencyMs,
      metadata: {
        ...metadata,
        operational_notice_codes: engineOutput.notices.map((notice) => notice.code),
      },
    });

    return Response.json({
      request_id: requestId,
      result: engineOutput.result,
      meta: {
        operation,
        model_vendor: engineOutput.modelVendor,
        model_id: engineOutput.modelId,
        api: engineOutput.modelApi,
        fallback_used: engineOutput.fallbackUsed,
        latency_ms: latencyMs,
        notices: engineOutput.notices,
      },
    });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, requestId);
    }
    console.error("[/api/ai/memory/distill] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}
