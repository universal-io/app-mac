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
  type ScreenUnderstandingCandidate,
  type ScreenUnderstandingTurn,
} from "@/lib/server/screen-understanding-engine";

const MAX_IMAGE_BASE64_CHARS = 4 * 1024 * 1024;
const MAX_CAPTURE_ID_CHARS = 128;
const MAX_TURNS = 20;
const MAX_TURN_CHARS = 4_000;
const MAX_CANDIDATES = 500;

type ScreenUnderstandingRequestBody = {
  request_id?: string;
  operation?: string;
  input?: {
    capture_id?: string;
    image_base64?: string;
    media_type?: string;
    question?: string;
    turns?: ScreenUnderstandingTurn[];
    candidate_diagnostics?: {
      elapsed_ms?: number;
      visited_nodes?: number;
      candidate_count?: number;
      truncated_reason?: string;
    };
    guidance?: {
      goal?: string;
      previous_instruction?: string;
    };
    candidates?: Array<{
      id?: string;
      source?: string;
      role?: string;
      label?: string;
      parent_label?: string;
      states?: string[];
    }>;
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
    const candidates = (body.input!.candidates ?? []).map((candidate) => ({
      id: candidate.id!,
      source: candidate.source as "ax" | "dom",
      role: candidate.role,
      label: candidate.label!,
      parentLabel: candidate.parent_label,
      states: candidate.states ?? [],
    })) satisfies ScreenUnderstandingCandidate[];
    const language = body.preferences!.output_language as "japanese" | "english";
    const guidance = body.input!.guidance
      ? {
          goal: body.input!.guidance.goal!,
          previousInstruction: body.input!.guidance.previous_instruction!,
        }
      : undefined;

    const { userId, tenantId, entitlement } = await authenticate(request);
    await enforceQuota(tenantId, entitlement);

    const metadata = {
      challenge: 3,
      capture_id: captureId,
      platform: body.client!.platform,
      app_version: body.client?.app_version,
      media_type: mediaType,
      image_base64_chars: imageBase64.length,
      candidate_count: candidates.length,
      candidate_diagnostics: body.input!.candidate_diagnostics ?? null,
      turn_count: turns.length,
      has_question: Boolean(question),
      is_guidance_progress: Boolean(guidance),
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
        candidates,
        guidance,
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
        result: {
          mode: output.result.mode,
          message: output.result.message,
          observations: output.result.observations,
          uncertainties: output.result.uncertainties,
          target_candidate_id: output.result.targetCandidateId,
        },
        meta: {
          output_language: language,
          model_vendor: output.modelVendor,
          model_id: output.modelId,
          route: output.route,
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
  const guidance = body.input?.guidance;
  if (guidance && body.input?.question) {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "input.guidance and input.question are mutually exclusive.",
      requestId,
    );
  }
  if (guidance && (
    typeof guidance.goal !== "string"
    || guidance.goal.trim().length === 0
    || guidance.goal.length > MAX_TURN_CHARS
    || typeof guidance.previous_instruction !== "string"
    || guidance.previous_instruction.trim().length === 0
    || guidance.previous_instruction.length > MAX_TURN_CHARS
  )) {
    return errorResponse(400, "BAD_REQUEST", "input.guidance is invalid.", requestId);
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
  const candidates = body.input?.candidates ?? [];
  if (
    !Array.isArray(candidates)
    || candidates.length > MAX_CANDIDATES
    || candidates.some((candidate) => (
      typeof candidate.id !== "string" || candidate.id.length === 0 || candidate.id.length > 128
      || (candidate.source !== "ax" && candidate.source !== "dom")
      || typeof candidate.label !== "string" || candidate.label.length === 0
      || candidate.label.length > 512
      || (candidate.role !== undefined
        && (typeof candidate.role !== "string" || candidate.role.length > 64))
      || (candidate.parent_label !== undefined
        && (typeof candidate.parent_label !== "string" || candidate.parent_label.length > 512))
      || !Array.isArray(candidate.states)
      || candidate.states.length > 16
      || candidate.states.some((state) => typeof state !== "string" || state.length > 64)
    ))
    || new Set(candidates.map((candidate) => candidate.id)).size !== candidates.length
  ) {
    return errorResponse(400, "BAD_REQUEST", "input.candidates is invalid.", requestId);
  }
  const diagnostics = body.input?.candidate_diagnostics;
  const allowedTruncationReasons = new Set([
    "no_target_app",
    "unknown_capture_rect",
    "permission_denied",
    "node_limit",
    "candidate_limit",
    "deadline",
    "not_configured",
  ]);
  if (diagnostics && (
    !Number.isInteger(diagnostics.elapsed_ms)
    || diagnostics.elapsed_ms! < 0
    || diagnostics.elapsed_ms! > 60_000
    || !Number.isInteger(diagnostics.visited_nodes)
    || diagnostics.visited_nodes! < 0
    || diagnostics.visited_nodes! > 100_000
    || !Number.isInteger(diagnostics.candidate_count)
    || diagnostics.candidate_count! < 0
    || diagnostics.candidate_count! > MAX_CANDIDATES
    || diagnostics.candidate_count !== candidates.length
    || (diagnostics.truncated_reason !== undefined
      && !allowedTruncationReasons.has(diagnostics.truncated_reason))
  )) {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "input.candidate_diagnostics is invalid.",
      requestId,
    );
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
