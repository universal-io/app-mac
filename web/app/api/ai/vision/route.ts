// AI gateway: POST /api/ai/vision. Screenshot interpretation ("see →
// understand → respond"): situation, extracted content, asks, and suggested
// actions with persona-aware reply drafts.
// The image arrives as base64 (PNG or JPEG); optional context/memory blocks
// ride along for the prompt. The gateway stores none of them.
// Entitlement must be active; Vision has no hard quota yet (usage is recorded
// per call so a cap can be enforced when Stripe plans land in M3-B).

import {
  authenticate,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
  recordUsage,
} from "@/lib/server/gateway";
import { ProviderCallError } from "@/lib/server/review-engine";
import { runVisionInterpretation } from "@/lib/server/vision-engine";
import type {
  MemoryPayload,
  OutputLanguageCode,
  SituationalContextPayload,
} from "@/lib/server/prompts";

// Vercel rejects bodies past ~4.5MB; fail with a contract error before that.
const MAX_IMAGE_BASE64_CHARS = 4 * 1024 * 1024;

type VisionRequestBody = {
  request_id?: string;
  operation?: string;
  input?: {
    image_base64?: string;
    media_type?: string;
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
    const body = (await request.json().catch(() => null)) as VisionRequestBody | null;
    if (!body) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be JSON.", null);
    }
    requestId = typeof body.request_id === "string" ? body.request_id : null;

    const imageBase64 = body.input?.image_base64;
    const mediaType = body.input?.media_type ?? "image/png";
    const language = body.preferences?.output_language;
    const platform = body.client?.platform;
    if (!requestId) {
      return errorResponse(400, "BAD_REQUEST", "request_id is required.", requestId);
    }
    if (body.operation !== "vision") {
      return errorResponse(400, "BAD_REQUEST", "operation must be 'vision'.", requestId);
    }
    if (!imageBase64) {
      return errorResponse(400, "BAD_REQUEST", "input.image_base64 must not be empty.", requestId);
    }
    if (imageBase64.length > MAX_IMAGE_BASE64_CHARS) {
      return errorResponse(400, "BAD_REQUEST", "Image is too large.", requestId);
    }
    if (mediaType !== "image/png" && mediaType !== "image/jpeg") {
      return errorResponse(400, "BAD_REQUEST", "input.media_type must be 'image/png' or 'image/jpeg'.", requestId);
    }
    if (language !== "japanese" && language !== "english") {
      return errorResponse(400, "BAD_REQUEST", "preferences.output_language must be 'japanese' or 'english'.", requestId);
    }
    if (platform !== "macos" && platform !== "ios" && platform !== "android" && platform !== "web") {
      return errorResponse(400, "BAD_REQUEST", "client.platform is required.", requestId);
    }

    const { userId, tenantId } = await authenticate(request);

    const metadata = {
      platform,
      app_version: body.client?.app_version,
      media_type: mediaType,
      image_base64_chars: imageBase64.length,
      has_instruction: Boolean(body.input?.instruction?.trim()),
      has_context: Boolean(body.input?.context?.conversation_excerpt),
      has_memory: Boolean(body.input?.memory?.persona_md || body.input?.memory?.relationship_md),
    };

    const started = Date.now();
    let engineOutput;
    try {
      engineOutput = await runVisionInterpretation({
        imageDataURL: `data:${mediaType};base64,${imageBase64}`,
        instruction: body.input?.instruction,
        language: language as OutputLanguageCode,
        context: body.input?.context,
        memory: body.input?.memory,
      });
    } catch (error) {
      const rateLimited = error instanceof ProviderCallError && error.rateLimited;
      const message = rateLimited
        ? (error as ProviderCallError).message
        : "画面の読み取りに失敗しました。少し待ってから再試行してください。";
      const detail = error instanceof ProviderCallError ? error.message : String(error);
      console.error(`[/api/ai/vision] provider error (request ${requestId}):`, detail);
      await recordUsage(tenantId, userId, {
        operation: "vision",
        unitType: "call",
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
      operation: "vision",
      unitType: "call",
      requestId,
      status: "success",
      modelVendor: engineOutput.modelVendor,
      modelId: engineOutput.modelId,
      inputUnits: engineOutput.inputTokens,
      outputUnits: engineOutput.outputTokens,
      latencyMs,
      metadata,
    });

    return Response.json({
      request_id: requestId,
      result: engineOutput.result,
      meta: {
        output_language: language,
        model_vendor: engineOutput.modelVendor,
        model_id: engineOutput.modelId,
        latency_ms: latencyMs,
      },
    });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, requestId);
    }
    console.error("[/api/ai/vision] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}
