import {
  authenticate,
  enforceQuota,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
  recordUsage,
} from "@/lib/server/gateway";
import { ProviderCallError } from "@/lib/server/review-engine";
import {
  runScreenUnderstanding,
  SCREEN_UNDERSTANDING_IMAGE_DETAIL,
  SCREEN_UNDERSTANDING_MODEL_ID,
  SCREEN_UNDERSTANDING_REASONING_EFFORT,
  type ScreenUnderstandingTurn,
} from "@/lib/server/screen-understanding-engine";

const MAX_IMAGE_BASE64_CHARS = 4 * 1024 * 1024;
const MAX_CAPTURE_ID_CHARS = 128;
const MAX_TURNS = 20;
const MAX_TURN_CHARS = 4_000;

type ScreenUnderstandingRequestBody = {
  request_id?: string;
  operation?: string;
  input?: {
    capture_id?: string;
    image_base64?: string;
    media_type?: string;
    question?: string;
    turns?: ScreenUnderstandingTurn[];
  };
  preferences?: { output_language?: string };
  client?: { platform?: string; app_version?: string };
};

export async function POST(request: Request): Promise<Response> {
  let requestId: string | null = null;
  try {
    const body = (await request.json().catch(() => null)) as
      | ScreenUnderstandingRequestBody
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
    const question = body.input!.question?.trim();
    const turns = body.input!.turns ?? [];
    const language = body.preferences!.output_language as "japanese" | "english";

    const { userId, tenantId, entitlement } = await authenticate(request);
    await enforceQuota(tenantId, entitlement);

    const metadata = {
      challenge: 3,
      capture_id: captureId,
      platform: body.client!.platform,
      app_version: body.client?.app_version,
      media_type: mediaType,
      image_base64_chars: imageBase64.length,
      turn_count: turns.length,
      has_question: Boolean(question),
      api: "responses",
      image_detail: SCREEN_UNDERSTANDING_IMAGE_DETAIL,
      reasoning_effort: SCREEN_UNDERSTANDING_REASONING_EFFORT,
      fallback_used: false,
    };

    const started = Date.now();
    try {
      const output = await runScreenUnderstanding({
        imageDataURL: `data:${mediaType};base64,${imageBase64}`,
        question,
        turns,
        language,
      });
      const latencyMs = Date.now() - started;
      await recordUsage(tenantId, userId, {
        operation: "screen_understanding",
        unitType: "call",
        requestId: requestId!,
        status: "success",
        modelVendor: output.modelVendor,
        modelId: output.modelId,
        inputUnits: output.inputTokens,
        outputUnits: output.outputTokens,
        latencyMs,
        metadata,
      });

      return Response.json({
        request_id: requestId,
        capture_id: captureId,
        result: output.result,
        meta: {
          output_language: language,
          model_vendor: output.modelVendor,
          model_id: output.modelId,
          api: "responses",
          image_detail: SCREEN_UNDERSTANDING_IMAGE_DETAIL,
          reasoning_effort: SCREEN_UNDERSTANDING_REASONING_EFFORT,
          fallback_used: false,
          latency_ms: latencyMs,
        },
      });
    } catch (error) {
      const latencyMs = Date.now() - started;
      const rateLimited = error instanceof ProviderCallError && error.rateLimited;
      const detail = error instanceof Error ? error.message : String(error);
      console.error(
        `[/api/ai/screen-understanding] GPT-5.6 Luna failed (request ${requestId}):`,
        detail,
      );
      await recordUsage(tenantId, userId, {
        operation: "screen_understanding",
        unitType: "call",
        requestId: requestId!,
        status: "error",
        modelVendor: "openai",
        modelId: SCREEN_UNDERSTANDING_MODEL_ID,
        errorCode: rateLimited ? "RATE_LIMITED" : "PROVIDER_ERROR",
        latencyMs,
        metadata,
      });
      return errorResponse(
        rateLimited ? 429 : 502,
        rateLimited ? "RATE_LIMITED" : "PROVIDER_ERROR",
        "GPT-5.6 Lunaで画面を読み取れませんでした。Challenge 3では別モデルへ切り替えません。",
        requestId,
        {
          model_id: SCREEN_UNDERSTANDING_MODEL_ID,
          fallback_used: false,
        },
      );
    }
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, requestId);
    }
    console.error("[/api/ai/screen-understanding] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}

function validateBody(
  body: ScreenUnderstandingRequestBody,
  requestId: string | null,
): Response | null {
  if (!requestId) {
    return errorResponse(400, "BAD_REQUEST", "request_id is required.", requestId);
  }
  if (body.operation !== "screen_understanding") {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "operation must be 'screen_understanding'.",
      requestId,
    );
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
  if (body.input?.question && body.input.question.length > MAX_TURN_CHARS) {
    return errorResponse(400, "BAD_REQUEST", "input.question is too long.", requestId);
  }
  const turns = body.input?.turns ?? [];
  if (
    !Array.isArray(turns)
    || turns.length > MAX_TURNS
    || turns.some((turn) => (
      (turn.role !== "user" && turn.role !== "assistant")
      || typeof turn.text !== "string"
      || turn.text.length > MAX_TURN_CHARS
    ))
  ) {
    return errorResponse(400, "BAD_REQUEST", "input.turns is invalid.", requestId);
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
