import {
  authenticate,
  enforceQuota,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
  recordUsageAfterResponse,
  warmAIRequest,
} from "@/lib/server/gateway";
import {
  aiModelFailureContract,
  AI_MODEL_ROUTES,
} from "@/lib/server/ai-routing";
import {
  runSuggest,
  SUGGEST_IMAGE_DETAIL,
  SUGGEST_PROMPT_VERSION,
  SUGGEST_REASONING_EFFORT,
} from "@/lib/server/suggest-engine";

const MAX_IMAGE_BASE64_CHARS = 4 * 1024 * 1024;
const MAX_CAPTURE_ID_CHARS = 128;
const MAX_CONTEXT_FIELD_CHARS = 8_000;

type SuggestRequestBody = {
  request_id?: string;
  operation?: string;
  input?: {
    capture_id?: string;
    image_base64?: string;
    media_type?: string;
    context?: {
      app_name?: string;
      bundle_id?: string;
      window_title?: string;
      conversation_excerpt?: string;
    };
  };
  preferences?: { output_language?: string };
  client?: { platform?: string; app_version?: string };
};

export const GET = warmAIRequest;

export async function POST(request: Request): Promise<Response> {
  let requestId: string | null = null;
  try {
    const body = (await request.json().catch(() => null)) as
      | SuggestRequestBody
      | null;
    if (!body) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be JSON.", null);
    }
    requestId = typeof body.request_id === "string" ? body.request_id : null;
    const validationError = validateBody(body, requestId);
    if (validationError) return validationError;

    const imageBase64 = body.input!.image_base64!;
    const mediaType = body.input!.media_type ?? "image/png";
    const captureId = body.input!.capture_id!;
    const language = body.preferences!.output_language as "japanese" | "english";
    const rawContext = body.input!.context;
    const context = rawContext
      ? {
          appName: rawContext.app_name,
          bundleId: rawContext.bundle_id,
          windowTitle: rawContext.window_title,
          conversationExcerpt: rawContext.conversation_excerpt,
        }
      : undefined;

    const { userId, tenantId, entitlement } = await authenticate(request);
    await enforceQuota(tenantId, entitlement);

    const metadata = {
      capture_id: captureId,
      platform: body.client!.platform,
      app_version: body.client?.app_version,
      media_type: mediaType,
      image_base64_chars: imageBase64.length,
      has_context: Boolean(context),
      api: "responses",
      image_detail: SUGGEST_IMAGE_DETAIL,
      reasoning_effort: SUGGEST_REASONING_EFFORT,
    };

    const started = Date.now();
    try {
      const output = await runSuggest({
        imageDataURL: `data:${mediaType};base64,${imageBase64}`,
        context,
        language,
      });
      const latencyMs = Date.now() - started;
      recordUsageAfterResponse(tenantId, userId, {
        operation: "suggest",
        unitType: "call",
        requestId: requestId!,
        status: "success",
        modelVendor: output.modelVendor,
        modelId: output.modelId,
        inputUnits: output.inputTokens,
        outputUnits: output.outputTokens,
        latencyMs,
        metadata: {
          ...metadata,
          fallback_used: output.fallbackUsed,
          operational_notice_codes: output.notices.map((notice) => notice.code),
        },
      });

      return Response.json({
        request_id: requestId,
        capture_id: captureId,
        result: {
          draft: output.result.draft,
          note: output.result.note,
        },
        meta: {
          output_language: language,
          model_vendor: output.modelVendor,
          model_id: output.modelId,
          route: output.route,
          api: output.modelApi,
          image_detail: SUGGEST_IMAGE_DETAIL,
          reasoning_effort: SUGGEST_REASONING_EFFORT,
          prompt_version: SUGGEST_PROMPT_VERSION,
          context_package: output.contextPackageId,
          fallback_used: output.fallbackUsed,
          latency_ms: latencyMs,
          notices: output.notices,
        },
      });
    } catch (error) {
      const latencyMs = Date.now() - started;
      const failure = aiModelFailureContract(error);
      console.error(
        `[/api/ai/suggest] primary and secondary failed (request ${requestId}):`,
        failure.detail,
      );
      const primary = AI_MODEL_ROUTES.suggest.primary;
      const secondary = AI_MODEL_ROUTES.suggest.secondary;
      recordUsageAfterResponse(tenantId, userId, {
        operation: "suggest",
        unitType: "call",
        requestId: requestId!,
        status: "error",
        modelVendor: primary.vendor,
        modelId: primary.modelId,
        errorCode: failure.code,
        latencyMs,
        metadata: {
          ...metadata,
          fallback_attempted: true,
          secondary_model_vendor: secondary.vendor,
          secondary_model_id: secondary.modelId,
        },
      });
      return errorResponse(
        failure.status,
        failure.code,
        failure.message,
        requestId,
        {
          primary_model_id: primary.modelId,
          secondary_model_id: secondary.modelId,
          fallback_attempted: true,
        },
      );
    }
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, requestId);
    }
    console.error("[/api/ai/suggest] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}

function validateBody(
  body: SuggestRequestBody,
  requestId: string | null,
): Response | null {
  if (!requestId) {
    return errorResponse(400, "BAD_REQUEST", "request_id is required.", requestId);
  }
  if (body.operation !== "suggest") {
    return errorResponse(400, "BAD_REQUEST", "operation must be 'suggest'.", requestId);
  }
  const captureId = body.input?.capture_id?.trim();
  if (!captureId || captureId.length > MAX_CAPTURE_ID_CHARS) {
    return errorResponse(400, "BAD_REQUEST", "A valid input.capture_id is required.", requestId);
  }
  const imageBase64 = body.input?.image_base64;
  if (!imageBase64 || imageBase64.length > MAX_IMAGE_BASE64_CHARS) {
    return errorResponse(400, "BAD_REQUEST", "A valid input.image_base64 is required.", requestId);
  }
  const mediaType = body.input?.media_type ?? "image/png";
  if (mediaType !== "image/png" && mediaType !== "image/jpeg") {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "input.media_type must be 'image/png' or 'image/jpeg'.",
      requestId,
    );
  }
  const context = body.input?.context;
  if (context !== undefined) {
    if (typeof context !== "object" || context === null || Array.isArray(context)) {
      return errorResponse(400, "BAD_REQUEST", "input.context is invalid.", requestId);
    }
    const fields = [
      context.app_name,
      context.bundle_id,
      context.window_title,
      context.conversation_excerpt,
    ];
    if (fields.some((field) =>
      field !== undefined
      && (typeof field !== "string" || field.length > MAX_CONTEXT_FIELD_CHARS)
    )) {
      return errorResponse(400, "BAD_REQUEST", "input.context fields are invalid.", requestId);
    }
  }
  const language = body.preferences?.output_language;
  if (language !== "japanese" && language !== "english") {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "preferences.output_language must be 'japanese' or 'english'.",
      requestId,
    );
  }
  const platform = body.client?.platform;
  if (platform !== "macos" && platform !== "ios" && platform !== "android" && platform !== "web") {
    return errorResponse(400, "BAD_REQUEST", "client.platform is required.", requestId);
  }
  return null;
}
