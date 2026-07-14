// AI gateway: POST /api/ai/transcribe (multipart/form-data).
// Fields: request_id, platform, app_version (optional), file (audio).
// Entitlement must be active; ASR has no hard quota yet (usage is recorded
// per call so a cap can be enforced when Stripe plans land in M3-B).

import {
  authenticate,
  enforceQuota,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
  recordUsage,
} from "@/lib/server/gateway";
import { ProviderCallError } from "@/lib/server/review-engine";
import { runTranscription } from "@/lib/server/transcribe-engine";

// Recordings are short hold-to-talk clips; anything bigger is a client bug.
const MAX_AUDIO_BYTES = 25 * 1024 * 1024;

export async function POST(request: Request): Promise<Response> {
  let requestId: string | null = null;
  try {
    const form = await request.formData().catch(() => null);
    if (!form) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be multipart/form-data.", null);
    }

    const requestIdField = form.get("request_id");
    requestId = typeof requestIdField === "string" && requestIdField ? requestIdField : null;
    const platform = form.get("platform");
    const file = form.get("file");

    if (!requestId) {
      return errorResponse(400, "BAD_REQUEST", "request_id is required.", requestId);
    }
    if (platform !== "macos" && platform !== "ios" && platform !== "android" && platform !== "web") {
      return errorResponse(400, "BAD_REQUEST", "platform is required.", requestId);
    }
    if (!(file instanceof File) || file.size === 0) {
      return errorResponse(400, "BAD_REQUEST", "file must be a non-empty audio upload.", requestId);
    }
    if (file.size > MAX_AUDIO_BYTES) {
      return errorResponse(400, "BAD_REQUEST", "Audio file is too large.", requestId);
    }

    const { userId, tenantId, entitlement } = await authenticate(request);
    await enforceQuota(tenantId, entitlement);

    const metadata = {
      platform,
      app_version: stringField(form, "app_version"),
      file_bytes: file.size,
    };

    const started = Date.now();
    let output;
    try {
      output = await runTranscription(file);
    } catch (error) {
      const rateLimited = error instanceof ProviderCallError && error.rateLimited;
      const message = rateLimited
        ? (error as ProviderCallError).message
        : "音声の文字起こしに失敗しました。少し待ってから再試行してください。";
      const detail = error instanceof ProviderCallError ? error.message : String(error);
      console.error(`[/api/ai/transcribe] provider error (request ${requestId}):`, detail);
      await recordUsage(tenantId, userId, {
        operation: "transcribe",
        unitType: "seconds",
        requestId,
        status: "error",
        errorCode: "PROVIDER_ERROR",
        latencyMs: Date.now() - started,
        metadata,
      });
      return errorResponse(502, "PROVIDER_ERROR", message, requestId);
    }
    const latencyMs = Date.now() - started;

    await recordUsage(tenantId, userId, {
      operation: "transcribe",
      unitType: "seconds",
      requestId,
      status: "success",
      modelVendor: output.modelVendor,
      modelId: output.modelId,
      inputUnits: Math.round(output.durationSeconds),
      latencyMs,
      metadata: {
        ...metadata,
        operational_notice_codes: output.notices.map((notice) => notice.code),
      },
    });

    return Response.json({
      request_id: requestId,
      result: { text: output.text },
      meta: {
        model_vendor: output.modelVendor,
        model_id: output.modelId,
        duration_seconds: output.durationSeconds,
        latency_ms: latencyMs,
        notices: output.notices,
      },
    });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, requestId);
    }
    console.error("[/api/ai/transcribe] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}

function stringField(form: FormData, name: string): string | null {
  const value = form.get(name);
  return typeof value === "string" && value ? value : null;
}
