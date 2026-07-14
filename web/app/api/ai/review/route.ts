// AI gateway: POST /api/ai/review (docs/api-contract.md is the contract).
// Flow: verify Supabase JWT -> resolve tenant -> check entitlement/quota ->
// call provider -> record usage event -> return result + quota envelope.

import {
  authenticate,
  countMonthlyUsage,
  effectiveMonthlyLimit,
  errorResponse,
  gatewayErrorResponse,
  GatewayError,
  quotaInfo,
  recordUsage,
  type QuotaInfo,
} from "@/lib/server/gateway";
import {
  ProviderCallError,
  runReview,
  runReviewStream,
  type ReviewEngineOutput,
  type ReviewResultPayload,
} from "@/lib/server/review-engine";
import type {
  MemoryPayload,
  OutputLanguageCode,
  ReviewMode,
  SituationalContextPayload,
} from "@/lib/server/prompts";

type ReviewRequestBody = {
  request_id?: string;
  operation?: string;
  mode?: string;
  /** When true, the response is SSE: `delta` events with revised_text
   * increments, then one `result` event with the full JSON envelope. */
  stream?: boolean;
  input?: {
    draft?: string;
    context?: SituationalContextPayload;
    memory?: MemoryPayload;
  };
  preferences?: {
    output_language?: string;
    model_preference?: { vendor?: string; model_id?: string };
  };
  client?: {
    platform?: string;
    app_version?: string;
    build_number?: string;
    device_id?: string;
  };
};

export async function POST(request: Request): Promise<Response> {
  let requestId: string | null = null;
  try {
    const body = (await request.json().catch(() => null)) as ReviewRequestBody | null;
    if (!body) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be JSON.", null);
    }
    requestId = typeof body.request_id === "string" ? body.request_id : null;

    // --- Validation (contract: BAD_REQUEST) ---
    const draft = body.input?.draft?.trim();
    const mode = body.mode;
    const language = body.preferences?.output_language;
    const platform = body.client?.platform;
    if (!requestId) {
      return errorResponse(400, "BAD_REQUEST", "request_id is required.", requestId);
    }
    if (body.operation !== "review") {
      return errorResponse(400, "BAD_REQUEST", "operation must be 'review'.", requestId);
    }
    if (mode !== "compose" && mode !== "transform") {
      return errorResponse(400, "BAD_REQUEST", "mode must be 'compose' or 'transform'.", requestId);
    }
    if (!draft) {
      return errorResponse(400, "BAD_REQUEST", "input.draft must not be empty.", requestId);
    }
    if (language !== "japanese" && language !== "english") {
      return errorResponse(400, "BAD_REQUEST", "preferences.output_language must be 'japanese' or 'english'.", requestId);
    }
    if (platform !== "macos" && platform !== "ios" && platform !== "android" && platform !== "web") {
      return errorResponse(400, "BAD_REQUEST", "client.platform is required.", requestId);
    }

    // --- Authentication / tenant / entitlement ---
    const { userId, tenantId, entitlement } = await authenticate(request);

    // --- Quota ---
    const limit = await effectiveMonthlyLimit(entitlement);
    const used = await countMonthlyUsage(tenantId);

    const quota = (usedNow: number): QuotaInfo => quotaInfo(entitlement, usedNow, limit);

    if (limit !== null && used >= limit) {
      return errorResponse(429, "QUOTA_EXCEEDED", "Monthly review limit reached.", requestId, quota(used));
    }

    const engineInput = {
      mode: mode as ReviewMode,
      draft,
      language: language as OutputLanguageCode,
      context: body.input?.context,
      memory: body.input?.memory,
      preferredVendor: body.preferences?.model_preference?.vendor,
      preferredModelId: body.preferences?.model_preference?.model_id,
    };

    // --- Streaming path (SSE) ---
    if (body.stream === true) {
      return streamingResponse({
        requestId,
        tenantId,
        userId,
        mode,
        language,
        engineInput,
        metadata: usageMetadata(body),
        quota,
        usedBefore: used,
      });
    }

    // --- Provider call ---
    const started = Date.now();
    let engineOutput;
    try {
      engineOutput = await runReview(engineInput);
    } catch (error) {
      // User-facing message: pass the rate-limit guidance through, keep raw
      // upstream details in the server log only.
      const rateLimited = error instanceof ProviderCallError && error.rateLimited;
      const message = rateLimited
        ? (error as ProviderCallError).message
        : "AI エンジン側で一時的なエラーが発生しました。少し待ってから再試行してください。";
      const detail = error instanceof ProviderCallError ? error.message : String(error);
      console.error(`[/api/ai/review] provider error (request ${requestId}):`, detail);
      await recordUsage(tenantId, userId, {
        operation: "review",
        unitType: "review",
        requestId,
        status: "error",
        errorCode: "PROVIDER_ERROR",
        latencyMs: Date.now() - started,
        metadata: usageMetadata(body),
      });
      return errorResponse(502, "PROVIDER_ERROR", message, requestId);
    }
    const latencyMs = Date.now() - started;

    await recordUsage(tenantId, userId, {
      operation: "review",
      unitType: "review",
      requestId,
      status: "success",
      modelVendor: engineOutput.modelVendor,
      modelId: engineOutput.modelId,
      inputUnits: engineOutput.inputTokens,
      outputUnits: engineOutput.outputTokens,
      latencyMs,
      metadata: {
        ...usageMetadata(body),
        operational_notice_codes: engineOutput.notices.map((notice) => notice.code),
      },
    });

    return Response.json({
      request_id: requestId,
      result: engineOutput.result satisfies ReviewResultPayload,
      meta: {
        mode,
        output_language: language,
        model_vendor: engineOutput.modelVendor,
        model_id: engineOutput.modelId,
        latency_ms: latencyMs,
        notices: engineOutput.notices,
      },
      quota: quota(used + 1),
    });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, requestId);
    }
    console.error("[/api/ai/review] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}

type StreamingResponseInput = {
  requestId: string;
  tenantId: string;
  userId: string;
  mode: string;
  language: string;
  engineInput: Parameters<typeof runReviewStream>[0];
  metadata: Record<string, unknown>;
  quota: (usedNow: number) => QuotaInfo;
  usedBefore: number;
};

/**
 * SSE envelope over the streaming engine. Events:
 * - `delta`:  {"text": "..."} — increments of revised_text
 * - `result`: the same JSON as the non-streaming success response
 * - `error`:  the same JSON as the error contract
 * Usage is recorded exactly once, after the provider stream ends.
 */
function streamingResponse(input: StreamingResponseInput): Response {
  const encoder = new TextEncoder();
  const started = Date.now();

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (event: string, data: unknown) => {
        controller.enqueue(
          encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
        );
      };
      try {
        let finalOutput: ReviewEngineOutput | null = null;
        for await (const event of runReviewStream(input.engineInput)) {
          if (event.type === "delta") {
            send("delta", { text: event.text });
          } else {
            finalOutput = event.output;
          }
        }
        if (!finalOutput) {
          throw new ProviderCallError("Provider stream ended without a result.");
        }
        const latencyMs = Date.now() - started;
        await recordUsage(input.tenantId, input.userId, {
          operation: "review",
          unitType: "review",
          requestId: input.requestId,
          status: "success",
          modelVendor: finalOutput.modelVendor,
          modelId: finalOutput.modelId,
          inputUnits: finalOutput.inputTokens,
          outputUnits: finalOutput.outputTokens,
          latencyMs,
          metadata: {
            ...input.metadata,
            operational_notice_codes: finalOutput.notices.map((notice) => notice.code),
          },
        });
        send("result", {
          request_id: input.requestId,
          result: finalOutput.result,
          meta: {
            mode: input.mode,
            output_language: input.language,
            model_vendor: finalOutput.modelVendor,
            model_id: finalOutput.modelId,
            latency_ms: latencyMs,
            notices: finalOutput.notices,
          },
          quota: input.quota(input.usedBefore + 1),
        });
      } catch (error) {
        const rateLimited = error instanceof ProviderCallError && error.rateLimited;
        const message = rateLimited
          ? (error as ProviderCallError).message
          : "AI エンジン側で一時的なエラーが発生しました。少し待ってから再試行してください。";
        const detail = error instanceof ProviderCallError ? error.message : String(error);
        console.error(`[/api/ai/review] stream provider error (request ${input.requestId}):`, detail);
        await recordUsage(input.tenantId, input.userId, {
          operation: "review",
          unitType: "review",
          requestId: input.requestId,
          status: "error",
          errorCode: "PROVIDER_ERROR",
          latencyMs: Date.now() - started,
          metadata: input.metadata,
        });
        send("error", {
          error: { code: "PROVIDER_ERROR", message },
          request_id: input.requestId,
        });
      } finally {
        controller.close();
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

function usageMetadata(body: ReviewRequestBody): Record<string, unknown> {
  return {
    mode: body.mode,
    output_language: body.preferences?.output_language,
    platform: body.client?.platform,
    app_version: body.client?.app_version,
    has_context: Boolean(body.input?.context?.conversation_excerpt),
    has_memory: Boolean(body.input?.memory?.persona_md || body.input?.memory?.relationship_md),
  };
}
