// AI gateway: POST /api/ai/transcribe (multipart/form-data).
// Fields: request_id, platform, app_version (optional), file (audio).
// Entitlement must be active; ASR has no hard quota yet (usage is recorded
// per call so a cap can be enforced when Stripe plans land in M3-B).

import {
  authenticateAIRequest,
  enforceQuota,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
  recordUsageAfterResponse,
  warmAIRequest,
} from "@/lib/server/gateway";
import {
  aiModelFailureContract,
} from "@/lib/server/ai-routing";
import { runTranscription } from "@/lib/server/transcribe-engine";

// Recordings are short hold-to-talk clips; anything bigger is a client bug.
const MAX_AUDIO_BYTES = 25 * 1024 * 1024;

/**
 * Two models run in series here, so the request needs a budget that clears
 * both. Without one the platform's default decides when a hung provider ends,
 * which is how a stalled call could outlive the user's patience with nothing
 * to show for it. Budgets: lib/server/provider-timeout.ts.
 */
export const maxDuration = 60;

export const GET = warmAIRequest;

export async function POST(request: Request): Promise<Response> {
  const totalStarted = performance.now();
  let requestId: string | null = null;
  try {
    const form = await request.formData().catch(() => null);
    if (!form) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be multipart/form-data.", null);
    }

    const requestIdField = form.get("request_id");
    requestId = typeof requestIdField === "string" && requestIdField ? requestIdField : null;
    const platform = form.get("platform");
    const languageField = form.get("language");
    const language = languageField === "ja" || languageField === "en"
      ? languageField
      : undefined;
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

    const authStarted = performance.now();
    const { userId, tenantId, entitlement } =
      await authenticateAIRequest(request);
    const authMs = performance.now() - authStarted;
    const quotaStarted = performance.now();
    await enforceQuota(tenantId, entitlement);
    const quotaMs = performance.now() - quotaStarted;

    const metadata = {
      platform,
      app_version: stringField(form, "app_version"),
      file_bytes: file.size,
    };

    const started = performance.now();
    let output;
    try {
      output = await runTranscription(file, language);
    } catch (error) {
      const failure = aiModelFailureContract(error);
      console.error(`[/api/ai/transcribe] provider error (request ${requestId}):`, failure.detail);
      recordUsageAfterResponse(tenantId, userId, {
        operation: "transcribe",
        unitType: "seconds",
        requestId,
        status: "error",
        errorCode: failure.code,
        latencyMs: Math.round(performance.now() - started),
        metadata,
      });
      return errorResponse(failure.status, failure.code, failure.message, requestId);
    }
    const providerMs = performance.now() - started;
    const latencyMs = Math.round(providerMs);

    recordUsageAfterResponse(tenantId, userId, {
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
    const totalMs = performance.now() - totalStarted;

    return Response.json({
      request_id: requestId,
      result: { text: output.text },
      meta: {
        model_vendor: output.modelVendor,
        model_id: output.modelId,
        api: output.modelApi,
        fallback_used: output.fallbackUsed,
        duration_seconds: output.durationSeconds,
        latency_ms: latencyMs,
        timing_ms: {
          auth: Math.round(authMs),
          quota: Math.round(quotaMs),
          provider: Math.round(providerMs),
          usage: 0,
          total: Math.round(totalMs),
        },
        usage_deferred: true,
        notices: output.notices,
      },
    }, {
      headers: {
        "server-timing": [
          `auth;dur=${authMs.toFixed(1)}`,
          `quota;dur=${quotaMs.toFixed(1)}`,
          `provider;dur=${providerMs.toFixed(1)}`,
          "usage;dur=0;desc=\"deferred\"",
          `total;dur=${totalMs.toFixed(1)}`,
        ].join(", "),
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
