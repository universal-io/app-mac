import {
  authenticate,
  enforceQuota,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
  recordUsage,
  recordUsageAfterResponse,
  warmAIRequest,
  type AuthTimings,
  type QuotaTimings,
  type UsageInput,
} from "@/lib/server/gateway";
import { after } from "next/server";
import {
  aiModelFailureContract,
  AI_MODEL_ROUTES,
  ProviderCallError,
} from "@/lib/server/ai-routing";
import {
  runVision,
  runVisionStream,
  VISION_IMAGE_DETAIL,
  VISION_REASONING_EFFORT,
  type VisionCandidate,
  type VisionEngineOutput,
  type VisionTurn,
} from "@/lib/server/vision-engine";
import {
  isValidVisionSelectionWire,
  normalizeVisionSelection,
  visionSelectionFromWire,
  type LegacyVisionFocusTarget,
  type VisionSelectionWire,
} from "@/lib/server/vision-selection";

const MAX_IMAGE_BASE64_CHARS = 4 * 1024 * 1024;
const MAX_CAPTURE_ID_CHARS = 128;
const MAX_TURNS = 20;
const MAX_TURN_CHARS = 4_000;
const MAX_CANDIDATES = 500;
const MAX_CONTEXT_FIELD_CHARS = 1_024;
const MAX_FOCUS_TEXT_CHARS = 12_000;
const MAX_FOCUS_ROLE_CHARS = 128;
const MAX_FOCUS_LABEL_CHARS = 512;
const MAX_FOCUS_COORDINATE = 100_000;

type VisionRequestBody = {
  request_id?: string;
  operation?: string;
  /** When true, the response is SSE: `delta` events carrying increments of
   * result.message, then one `result` event with the full JSON envelope. A
   * `reset` event means discard what was shown — see `runStreamWithModelFallback`. */
  stream?: boolean;
  input?: {
    capture_id?: string;
    image_base64?: string;
    media_type?: string;
    question?: string;
    turns?: VisionTurn[];
    /** Identity of the app behind the capture, used to pick a skill. Never
     * persisted: `candidate_diagnostics` stays identity-free because it is
     * what feeds usage. */
    context?: {
      app_name?: string;
      bundle_id?: string;
      host?: string;
      window_title?: string;
    };
    candidate_diagnostics?: {
      elapsed_ms?: number;
      visited_nodes?: number;
      candidate_count?: number;
      truncated_reason?: string;
      target_app_name?: string;
      target_bundle_id?: string;
      target_window_present?: boolean;
      target_window_title?: string;
      collection_root?: string;
      capture_scope?: string;
      collection_passes?: number;
      web_area_present?: boolean;
    };
    guidance?: {
      goal?: string;
      previous_instruction?: string;
    };
    focus_target?: {
      kind?: string;
      text?: string;
      role?: string;
      label?: string;
      frame?: {
        x?: number;
        y?: number;
        width?: number;
        height?: number;
      };
      source?: string;
      truncated?: boolean;
    };
    visual_selection_hint?: boolean;
    selection?: VisionSelectionWire;
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

/**
 * Two models run in series here, so the request needs a budget that clears
 * both. Without one the platform's default decides when a hung provider ends,
 * which is how a stalled call could outlive the user's patience with nothing
 * to show for it. Budgets: lib/server/provider-timeout.ts.
 */
export const maxDuration = 60;

export const GET = warmAIRequest;

export async function POST(request: Request): Promise<Response> {
  let requestId: string | null = null;
  // Started before the body is read. A capture arrives as ~750KB of base64
  // inside JSON, and parsing that is part of the wait even though no timing so
  // far attributed it to anything. The client measured 7.1s round trips against
  // a model call the server clocked at 2.8s, and nothing said where the rest
  // went (docs/latency-plan.md 1-k).
  const totalStarted = performance.now();
  try {
    const body = (await request.json().catch(() => null)) as
      | VisionRequestBody
      | null;
    const bodyMs = performance.now() - totalStarted;
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
    })) satisfies VisionCandidate[];
    const language = body.preferences!.output_language as "japanese" | "english";
    const rawContext = body.input!.context;
    const context = rawContext
      ? {
          appName: rawContext.app_name,
          bundleId: rawContext.bundle_id,
          windowTitle: rawContext.window_title,
          host: rawContext.host,
        }
      : undefined;
    const guidance = body.input!.guidance
      ? {
          goal: body.input!.guidance.goal!,
          previousInstruction: body.input!.guidance.previous_instruction!,
        }
      : undefined;
    const rawFocusTarget = body.input!.focus_target;
    const focusTarget = rawFocusTarget
      ? {
          kind: rawFocusTarget.kind!,
          text: rawFocusTarget.text,
          role: rawFocusTarget.role,
          label: rawFocusTarget.label,
          frame: rawFocusTarget.frame
            ? {
                x: rawFocusTarget.frame.x!,
                y: rawFocusTarget.frame.y!,
                width: rawFocusTarget.frame.width!,
                height: rawFocusTarget.frame.height!,
              }
            : undefined,
          source: rawFocusTarget.source!,
          truncated: rawFocusTarget.truncated!,
        } as LegacyVisionFocusTarget
      : undefined;
    const visualSelectionHint = body.input!.visual_selection_hint === true;
    const rawSelection = body.input!.selection;
    const selection = normalizeVisionSelection({
      selection: rawSelection ? visionSelectionFromWire(rawSelection) : undefined,
      focusTarget,
      visualSelectionHint,
    });

    const authStarted = performance.now();
    const {
      userId,
      tenantId,
      entitlement,
      timings: authTimings,
    } = await authenticate(request);
    const authMs = performance.now() - authStarted;
    const quotaStarted = performance.now();
    const quotaTimings = await enforceQuota(tenantId, entitlement);
    const quotaMs = performance.now() - quotaStarted;
    const timing: GatewayTiming = {
      bodyMs,
      authMs,
      quotaMs,
      authTimings,
      quotaTimings,
      totalStarted,
    };

    const metadata = {
      capture_id: captureId,
      platform: body.client!.platform,
      app_version: body.client?.app_version,
      media_type: mediaType,
      image_base64_chars: imageBase64.length,
      candidate_count: candidates.length,
      candidate_diagnostics: candidateDiagnosticsForUsage(
        body.input!.candidate_diagnostics,
      ),
      turn_count: turns.length,
      has_context: Boolean(context),
      has_question: Boolean(question),
      is_guidance_progress: Boolean(guidance),
      selection_present: Boolean(selection),
      selection_acquisition_completeness: selection?.acquisitionCompleteness,
      selection_wire_kind: selectionWireKindForUsage(body.input!),
      api: "responses",
      image_detail: VISION_IMAGE_DETAIL,
      reasoning_effort: VISION_REASONING_EFFORT,
    };

    const engineInput = {
      imageDataURL: `data:${mediaType};base64,${imageBase64}`,
      question,
      turns,
      candidates,
      guidance,
      selection,
      context,
      language,
    };

    // --- Streaming path (SSE) ---
    // Validation, auth, and quota are already settled above, so a rejected
    // request is still an ordinary HTTP error. Only the model call streams.
    if (body.stream === true) {
      return streamingResponse({
        requestId: requestId!,
        captureId,
        tenantId,
        userId,
        language,
        engineInput,
        metadata,
        timing,
      });
    }

    const started = Date.now();
    try {
      const output = await runVision(engineInput);
      const latencyMs = Date.now() - started;
      recordUsageAfterResponse(tenantId, userId, {
        operation: "vision",
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

      return Response.json(visionSuccessBody({
        requestId: requestId!,
        captureId,
        language,
        output,
        latencyMs,
        timing,
      }));
    } catch (error) {
      const latencyMs = Date.now() - started;
      const failure = aiModelFailureContract(error);
      console.error(
        `[/api/ai/vision] primary and secondary failed (request ${requestId}):`,
        failure.detail,
      );
      const primary = AI_MODEL_ROUTES.vision.primary;
      const secondary = AI_MODEL_ROUTES.vision.secondary;
      recordUsageAfterResponse(tenantId, userId, {
        operation: "vision",
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
    console.error("[/api/ai/vision] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}

type StreamingResponseInput = {
  requestId: string;
  captureId: string;
  tenantId: string;
  userId: string;
  language: "japanese" | "english";
  engineInput: Parameters<typeof runVisionStream>[0];
  metadata: Record<string, unknown>;
  timing: GatewayTiming;
};

/** What the route spent before the model, and when it started counting. */
type GatewayTiming = {
  bodyMs: number;
  authMs: number;
  quotaMs: number;
  /** Present only when the preflight caches missed and round trips were made. */
  authTimings?: AuthTimings;
  quotaTimings: QuotaTimings | null;
  totalStarted: number;
};

/**
 * SSE envelope over the streaming engine. Events:
 * - `delta`:  {"text": "..."} — increments of result.message
 * - `reset`:  {} — discard every delta so far; a different model is restarting
 * - `result`: the same JSON as the non-streaming success response
 * - `error`:  the same JSON as the error contract
 *
 * The result event is what the client acts on. Deltas exist so the user can
 * start reading; the mode, the highlight target, and the uncertainties are only
 * ever taken from the validated object at the end.
 *
 * Usage is recorded once, after the stream is closed, so bookkeeping stays out
 * of the user's wait (README「データ保存」).
 */
function streamingResponse(input: StreamingResponseInput): Response {
  const encoder = new TextEncoder();
  const started = Date.now();

  // Usage cannot be written from inside the stream. By the time the stream
  // finishes the route handler has already returned, so an `await` in there
  // races the platform ending the invocation — and loses: two of thirteen
  // vision calls on 2026-08-05 were served, streamed, and never recorded, which
  // for a metered product means a request nobody was charged for and a quota
  // that undercounts. `after` is registered here, while the request scope still
  // exists, and waits for the stream to say what happened.
  let reportUsage: (usage: UsageInput | null) => void = () => {};
  const usageReported = new Promise<UsageInput | null>((resolve) => {
    reportUsage = resolve;
  });
  after(async () => {
    const usage = await usageReported;
    if (usage) await recordUsage(input.tenantId, input.userId, usage);
  });

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      let responseClosed = false;
      const send = (event: string, data: unknown) => {
        controller.enqueue(
          encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
        );
      };
      try {
        let output: VisionEngineOutput | null = null;
        for await (const event of runVisionStream(input.engineInput)) {
          if (event.type === "delta") {
            send("delta", { text: event.text });
          } else if (event.type === "reset") {
            send("reset", {});
          } else {
            output = event.output;
          }
        }
        if (!output) {
          throw new ProviderCallError("Vision stream ended without a result.");
        }
        const latencyMs = Date.now() - started;
        send("result", visionSuccessBody({
          requestId: input.requestId,
          captureId: input.captureId,
          language: input.language,
          output,
          latencyMs,
          timing: input.timing,
        }));
        controller.close();
        responseClosed = true;
        reportUsage({
          operation: "vision",
          unitType: "call",
          requestId: input.requestId,
          status: "success",
          modelVendor: output.modelVendor,
          modelId: output.modelId,
          inputUnits: output.inputTokens,
          outputUnits: output.outputTokens,
          latencyMs,
          metadata: {
            ...input.metadata,
            streamed: true,
            // False here means the client asked to stream and got a streamed
            // answer. True means it silently ran the ordinary call instead, and
            // this turn's latency says nothing about streaming.
            stream_degraded: output.streamDegraded === true,
            fallback_used: output.fallbackUsed,
            operational_notice_codes: output.notices.map((notice) => notice.code),
          },
        });
      } catch (error) {
        const latencyMs = Date.now() - started;
        const failure = aiModelFailureContract(error);
        console.error(
          `[/api/ai/vision] stream provider error (request ${input.requestId}):`,
          failure.detail,
        );
        const primary = AI_MODEL_ROUTES.vision.primary;
        const secondary = AI_MODEL_ROUTES.vision.secondary;
        if (!responseClosed) {
          send("error", {
            error: { code: failure.code, message: failure.message },
            request_id: input.requestId,
          });
          controller.close();
          responseClosed = true;
        }
        reportUsage({
          operation: "vision",
          unitType: "call",
          requestId: input.requestId,
          status: "error",
          modelVendor: primary.vendor,
          modelId: primary.modelId,
          errorCode: failure.code,
          latencyMs,
          metadata: {
            ...input.metadata,
            streamed: true,
            fallback_attempted: true,
            secondary_model_vendor: secondary.vendor,
            secondary_model_id: secondary.modelId,
          },
        });
      } finally {
        if (!responseClosed) controller.close();
        // Releases the `after` callback when neither branch reported — a client
        // that disconnected mid-stream, say. Resolving twice is a no-op, so the
        // reported outcome above always wins.
        reportUsage(null);
      }
    },
  });

  return new Response(stream, {
    headers: {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
    },
  });
}

/** One shape for the success envelope, so the streamed `result` event and the
 * non-streaming body cannot drift apart. */
function visionSuccessBody(input: {
  requestId: string;
  captureId: string;
  language: string;
  output: VisionEngineOutput;
  latencyMs: number;
  timing: GatewayTiming;
}): Record<string, unknown> {
  const { output } = input;
  return {
    request_id: input.requestId,
    capture_id: input.captureId,
    result: {
      mode: output.result.mode,
      message: output.result.message,
      observations: output.result.observations,
      uncertainties: output.result.uncertainties,
      target_candidate_id: output.result.targetCandidateId,
      skill: output.skill,
    },
    meta: {
      output_language: input.language,
      skill: output.skill?.id ?? null,
      model_vendor: output.modelVendor,
      model_id: output.modelId,
      route: output.route,
      api: output.modelApi,
      image_detail: VISION_IMAGE_DETAIL,
      reasoning_effort: VISION_REASONING_EFFORT,
      fallback_used: output.fallbackUsed,
      latency_ms: input.latencyMs,
      // Everything the route can see. What the client waited on top of `total`
      // is the network: uploading the capture, TLS, and reading the response.
      timing_ms: {
        body: Math.round(input.timing.bodyMs),
        auth: Math.round(input.timing.authMs),
        quota: Math.round(input.timing.quotaMs),
        provider: input.latencyMs,
        usage: 0,
        total: Math.round(performance.now() - input.timing.totalStarted),
        // Which Supabase round trip cost what, on a cold instance. Zero means
        // the cache answered and nothing was asked.
        get_user: Math.round(input.timing.authTimings?.getUserMs ?? 0),
        tenant: Math.round(input.timing.authTimings?.tenantMs ?? 0),
        entitlement: Math.round(input.timing.authTimings?.entitlementMs ?? 0),
        plan: Math.round(input.timing.quotaTimings?.planMs ?? 0),
        count: Math.round(input.timing.quotaTimings?.countMs ?? 0),
      },
      usage_deferred: true,
      notices: output.notices,
    },
  };
}

function validateBody(
  body: VisionRequestBody,
  requestId: string | null,
): Response | null {
  if (!requestId) {
    return errorResponse(400, "BAD_REQUEST", "request_id is required.", requestId);
  }
  if (body.operation !== "vision") {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "operation must be 'vision'.",
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
  const focusTarget = body.input?.focus_target;
  if (focusTarget !== undefined && !isValidFocusTarget(focusTarget)) {
    return errorResponse(400, "BAD_REQUEST", "input.focus_target is invalid.", requestId);
  }
  const selection = body.input?.selection;
  if (selection !== undefined && !isValidVisionSelectionWire(selection)) {
    return errorResponse(400, "BAD_REQUEST", "input.selection is invalid.", requestId);
  }
  if (
    body.input?.visual_selection_hint !== undefined
    && typeof body.input.visual_selection_hint !== "boolean"
  ) {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "input.visual_selection_hint is invalid.",
      requestId,
    );
  }
  if (focusTarget && body.input?.visual_selection_hint === true) {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "input.focus_target and input.visual_selection_hint are mutually exclusive.",
      requestId,
    );
  }
  if (selection && (focusTarget || body.input?.visual_selection_hint === true)) {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "input.selection cannot be combined with legacy selection fields.",
      requestId,
    );
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
  const context = body.input?.context;
  if (context !== undefined) {
    if (typeof context !== "object" || context === null || Array.isArray(context)) {
      return errorResponse(400, "BAD_REQUEST", "input.context is invalid.", requestId);
    }
    const fields = [
      context.app_name,
      context.bundle_id,
      context.host,
      context.window_title,
    ];
    if (fields.some((field) =>
      field !== undefined
      && (typeof field !== "string" || field.length > MAX_CONTEXT_FIELD_CHARS)
    )) {
      return errorResponse(400, "BAD_REQUEST", "input.context fields are invalid.", requestId);
    }
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
  const allowedCollectionRoots = new Set(["none", "focused_window", "application"]);
  const allowedCaptureScopes = new Set(["display", "region", "unknown"]);
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
    || (diagnostics.target_app_name !== undefined
      && (typeof diagnostics.target_app_name !== "string"
        || diagnostics.target_app_name.length > 256))
    || (diagnostics.target_bundle_id !== undefined
      && (typeof diagnostics.target_bundle_id !== "string"
        || diagnostics.target_bundle_id.length > 256))
    || (diagnostics.target_window_present !== undefined
      && typeof diagnostics.target_window_present !== "boolean")
    || (diagnostics.target_window_title !== undefined
      && (typeof diagnostics.target_window_title !== "string"
        || diagnostics.target_window_title.length > 512))
    || (diagnostics.collection_root !== undefined
      && !allowedCollectionRoots.has(diagnostics.collection_root))
    || (diagnostics.capture_scope !== undefined
      && !allowedCaptureScopes.has(diagnostics.capture_scope))
    || (diagnostics.collection_passes !== undefined
      && (!Number.isInteger(diagnostics.collection_passes)
        || diagnostics.collection_passes! < 0
        || diagnostics.collection_passes! > 10))
    || (diagnostics.web_area_present !== undefined
      && typeof diagnostics.web_area_present !== "boolean")
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

function isValidFocusTarget(
  target: NonNullable<NonNullable<VisionRequestBody["input"]>["focus_target"]>,
): boolean {
  const validPair = (
    (target.kind === "selected_text" && target.source === "ax_selected_text")
    || (target.kind === "accessibility_element" && target.source === "ax_element")
    || (target.kind === "region" && target.source === "user_region")
  );
  if (!validPair || typeof target.truncated !== "boolean") return false;

  const fields: Array<[unknown, number]> = [
    [target.text, MAX_FOCUS_TEXT_CHARS],
    [target.role, MAX_FOCUS_ROLE_CHARS],
    [target.label, MAX_FOCUS_LABEL_CHARS],
  ];
  if (fields.some(([value, limit]) => (
    value !== undefined
    && (
      typeof value !== "string"
      || value.trim().length === 0
      || value.length > limit
      || hasForbiddenControlCharacters(value)
    )
  ))) {
    return false;
  }

  if (target.frame !== undefined) {
    if (
      typeof target.frame !== "object"
      || target.frame === null
      || Array.isArray(target.frame)
    ) {
      return false;
    }
    const { x, y, width, height } = target.frame;
    if (
      typeof x !== "number" || !Number.isFinite(x) || x < 0 || x > MAX_FOCUS_COORDINATE
      || typeof y !== "number" || !Number.isFinite(y) || y < 0 || y > MAX_FOCUS_COORDINATE
      || typeof width !== "number" || !Number.isFinite(width)
      || width <= 0 || width > MAX_FOCUS_COORDINATE
      || typeof height !== "number" || !Number.isFinite(height)
      || height <= 0 || height > MAX_FOCUS_COORDINATE
    ) {
      return false;
    }
  }

  if (target.kind === "selected_text") {
    return typeof target.text === "string" && target.text.trim().length > 0;
  }
  if (target.kind === "accessibility_element") {
    return target.role !== undefined
      || target.label !== undefined
      || target.frame !== undefined;
  }
  return target.frame !== undefined;
}

function hasForbiddenControlCharacters(value: string): boolean {
  return /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/u.test(value);
}

/**
 * Which selection field the client sent, recorded before normalization so the
 * migration off the ignored legacy kinds can be observed instead of guessed.
 * Normalized metadata cannot show it: the ignored kinds never reach a
 * `VisionSelection`. Validation has already closed these enums, and no
 * selected content is recorded.
 */
function selectionWireKindForUsage(
  input: NonNullable<VisionRequestBody["input"]>,
): string | null {
  if (input.selection) return `selection:${input.selection.kind}`;
  if (input.focus_target) return `focus_target:${input.focus_target.kind}`;
  if (input.visual_selection_hint === true) return "visual_selection_hint";
  return null;
}

function candidateDiagnosticsForUsage(
  diagnostics: NonNullable<
    NonNullable<VisionRequestBody["input"]>["candidate_diagnostics"]
  > | undefined,
): Record<string, unknown> | null {
  if (!diagnostics) return null;
  // Accept identity fields from older clients for compatibility, but never
  // persist app names, bundle IDs, or window titles in usage metadata.
  return {
    elapsed_ms: diagnostics.elapsed_ms,
    visited_nodes: diagnostics.visited_nodes,
    candidate_count: diagnostics.candidate_count,
    truncated_reason: diagnostics.truncated_reason,
    target_window_present: diagnostics.target_window_present,
    collection_root: diagnostics.collection_root,
    capture_scope: diagnostics.capture_scope,
    collection_passes: diagnostics.collection_passes,
    web_area_present: diagnostics.web_area_present,
  };
}
