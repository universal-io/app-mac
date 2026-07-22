// AI gateway: POST /api/ai/transform. Organizes a received message and
// returns a concise interpretation plus suggested actions.

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
import { runTransformInterpretation } from "@/lib/server/transform-engine";
import type {
  MemoryPayload,
  OutputLanguageCode,
  SituationalContextPayload,
} from "@/lib/server/prompts";

// Vercel rejects bodies past ~4.5MB; fail with a contract error before that.
const MAX_TEXT_CHARS = 16_000;

type TransformRequestBody = {
  request_id?: string;
  operation?: string;
  input?: {
    text?: string;
    instruction?: string;
    context?: SituationalContextPayload;
    memory?: MemoryPayload;
  };
  preferences?: {
    output_language?: string;
  };
  client?: {
    platform?: string;
    app_version?: string;
  };
};

export async function POST(request: Request): Promise<Response> {
  let requestId: string | null = null;
  try {
    const body = (await request.json().catch(() => null)) as TransformRequestBody | null;
    if (!body) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be JSON.", null);
    }
    requestId = typeof body.request_id === "string" ? body.request_id : null;

    const sourceText = body.input?.text?.trim();
    const language = body.preferences?.output_language;
    const platform = body.client?.platform;
    if (!requestId) {
      return errorResponse(400, "BAD_REQUEST", "request_id is required.", requestId);
    }
    if (body.operation !== "transform") {
      return errorResponse(400, "BAD_REQUEST", "operation must be 'transform'.", requestId);
    }
    if (!sourceText) {
      return errorResponse(400, "BAD_REQUEST", "input.text is required.", requestId);
    }
    if (sourceText && sourceText.length > MAX_TEXT_CHARS) {
      return errorResponse(400, "BAD_REQUEST", "input.text is too long.", requestId);
    }
    if (language !== "japanese" && language !== "english") {
      return errorResponse(400, "BAD_REQUEST", "preferences.output_language must be 'japanese' or 'english'.", requestId);
    }
    if (platform !== "macos" && platform !== "ios" && platform !== "android" && platform !== "web") {
      return errorResponse(400, "BAD_REQUEST", "client.platform is required.", requestId);
    }

    const { userId, tenantId, entitlement } = await authenticate(request);
    await enforceQuota(tenantId, entitlement);

    const metadata = {
      platform,
      app_version: body.client?.app_version,
      input_kind: "text",
      text_chars: sourceText?.length,
      has_instruction: Boolean(body.input?.instruction?.trim()),
      has_context: Boolean(body.input?.context?.conversation_excerpt),
      has_memory: Boolean(body.input?.memory?.persona_md || body.input?.memory?.relationship_md),
    };

    const started = Date.now();
    let engineOutput;
    try {
      engineOutput = await runTransformInterpretation({
        sourceText,
        instruction: body.input?.instruction,
        language: language as OutputLanguageCode,
        context: body.input?.context,
        memory: body.input?.memory,
      });
    } catch (error) {
      const failure = aiModelFailureContract(error);
      console.error(`[/api/ai/transform] provider error (request ${requestId}):`, failure.detail);
      await recordUsage(tenantId, userId, {
        operation: "transform",
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
      operation: "transform",
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
        output_language: language,
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
    console.error("[/api/ai/transform] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}
