// AI gateway: POST /api/ai/navigate — the screen navigator
// (docs/poc-ga-navigator.md). Multi-turn: input.messages carries the
// conversation (screenshots + OCR text ride on user turns), input.hints lets
// the gateway pick a tool harness (the client never selects one). The
// response is always SSE: `delta` events with plain-text increments, then one
// `result` event, mirroring the ai/review streaming envelope.
// Entitlement must be active; like vision there is no hard quota yet (usage
// is recorded per call so a cap can be added later).

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
  isAutoFirstTurn,
  runNavigateStream,
  type NavigateEngineOutput,
  type NavigateMessage,
} from "@/lib/server/navigate-engine";
import type { NavigateHints } from "@/lib/server/harness";
import type { OutputLanguageCode } from "@/lib/server/prompts";

// Vercel rejects bodies past ~4.5MB; the client keeps history light by
// sending at most the first and the latest screenshot.
const MAX_TOTAL_IMAGE_BASE64_CHARS = 4 * 1024 * 1024;
const MAX_MESSAGES = 24;
const MAX_TEXT_CHARS = 8_000;
const MAX_OCR_CHARS = 16_000;

type WireMessage = {
  role?: string;
  text?: string;
  image_base64?: string;
  media_type?: string;
  ocr_text?: string;
};

type NavigateRequestBody = {
  request_id?: string;
  operation?: string;
  input?: {
    messages?: WireMessage[];
    hints?: NavigateHints;
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
    const body = (await request.json().catch(() => null)) as NavigateRequestBody | null;
    if (!body) {
      return errorResponse(400, "BAD_REQUEST", "Request body must be JSON.", null);
    }
    requestId = typeof body.request_id === "string" ? body.request_id : null;

    const language = body.preferences?.output_language;
    const platform = body.client?.platform;
    if (!requestId) {
      return errorResponse(400, "BAD_REQUEST", "request_id is required.", requestId);
    }
    if (body.operation !== "navigate") {
      return errorResponse(400, "BAD_REQUEST", "operation must be 'navigate'.", requestId);
    }
    if (language !== "japanese" && language !== "english") {
      return errorResponse(400, "BAD_REQUEST", "preferences.output_language must be 'japanese' or 'english'.", requestId);
    }
    if (platform !== "macos" && platform !== "ios" && platform !== "android" && platform !== "web") {
      return errorResponse(400, "BAD_REQUEST", "client.platform is required.", requestId);
    }

    const wire = body.input?.messages;
    if (!Array.isArray(wire) || wire.length === 0 || wire.length > MAX_MESSAGES) {
      return errorResponse(400, "BAD_REQUEST", `input.messages must hold 1-${MAX_MESSAGES} messages.`, requestId);
    }

    const messages: NavigateMessage[] = [];
    let totalImageChars = 0;
    for (const message of wire) {
      if (message.role !== "user" && message.role !== "assistant") {
        return errorResponse(400, "BAD_REQUEST", "message.role must be 'user' or 'assistant'.", requestId);
      }
      if (message.text && message.text.length > MAX_TEXT_CHARS) {
        return errorResponse(400, "BAD_REQUEST", "message.text is too long.", requestId);
      }
      if (message.ocr_text && message.ocr_text.length > MAX_OCR_CHARS) {
        return errorResponse(400, "BAD_REQUEST", "message.ocr_text is too long.", requestId);
      }
      let imageDataURL: string | undefined;
      if (message.image_base64) {
        const mediaType = message.media_type ?? "image/jpeg";
        if (mediaType !== "image/png" && mediaType !== "image/jpeg") {
          return errorResponse(400, "BAD_REQUEST", "message.media_type must be 'image/png' or 'image/jpeg'.", requestId);
        }
        totalImageChars += message.image_base64.length;
        if (totalImageChars > MAX_TOTAL_IMAGE_BASE64_CHARS) {
          return errorResponse(400, "BAD_REQUEST", "Combined images are too large.", requestId);
        }
        imageDataURL = `data:${mediaType};base64,${message.image_base64}`;
      }
      messages.push({
        role: message.role,
        text: message.text,
        imageDataURL,
        ocrText: message.ocr_text,
      });
    }
    const last = messages[messages.length - 1];
    if (last.role !== "user") {
      return errorResponse(400, "BAD_REQUEST", "The last message must be from the user.", requestId);
    }

    const { userId, tenantId, entitlement } = await authenticate(request);
    await enforceQuota(tenantId, entitlement);

    const metadata = {
      platform,
      app_version: body.client?.app_version,
      message_count: messages.length,
      auto_first_turn: isAutoFirstTurn(messages),
      image_base64_chars: totalImageChars,
      has_ocr: messages.some((m) => Boolean(m.ocrText?.trim())),
      has_hints: Boolean(
        body.input?.hints?.app_name || body.input?.hints?.window_title || body.input?.hints?.url,
      ),
    };

    return streamingResponse({
      requestId,
      tenantId,
      userId,
      language,
      engineInput: {
        messages,
        hints: body.input?.hints,
        language: language as OutputLanguageCode,
      },
      metadata,
    });
  } catch (error) {
    if (error instanceof GatewayError) {
      return gatewayErrorResponse(error, requestId);
    }
    console.error("[/api/ai/navigate] internal error:", error);
    return errorResponse(500, "INTERNAL_ERROR", "Unclassified server failure.", requestId);
  }
}

type StreamingResponseInput = {
  requestId: string;
  tenantId: string;
  userId: string;
  language: string;
  engineInput: Parameters<typeof runNavigateStream>[0];
  metadata: Record<string, unknown>;
};

/**
 * SSE envelope over the streaming engine. Events:
 * - `delta`:  {"text": "..."} — plain-text increments of the answer
 * - `result`: {request_id, result: {text, harness}, meta}
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
        let finalOutput: NavigateEngineOutput | null = null;
        for await (const event of runNavigateStream(input.engineInput)) {
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
          operation: "navigate",
          unitType: "call",
          requestId: input.requestId,
          status: "success",
          modelVendor: finalOutput.modelVendor,
          modelId: finalOutput.modelId,
          inputUnits: finalOutput.inputTokens,
          outputUnits: finalOutput.outputTokens,
          latencyMs,
          metadata: {
            ...input.metadata,
            harness: finalOutput.harnessId,
            // Marker adherence metrics (docs/navigator-copilot-plan.md §2-d):
            // has_locator tracks the highlight rate, locator_supplemented how
            // often the model missed the contract and enforcement kicked in.
            has_locator: finalOutput.hasLocator,
            locator_supplemented: finalOutput.locatorSupplemented,
          },
        });
        send("result", {
          request_id: input.requestId,
          result: {
            text: finalOutput.text,
            harness: finalOutput.harnessId,
          },
          meta: {
            output_language: input.language,
            model_vendor: finalOutput.modelVendor,
            model_id: finalOutput.modelId,
            latency_ms: latencyMs,
          },
        });
      } catch (error) {
        const rateLimited = error instanceof ProviderCallError && error.rateLimited;
        const message = rateLimited
          ? (error as ProviderCallError).message
          : "画面の読み取りに失敗しました。少し待ってから再試行してください。";
        const detail = error instanceof ProviderCallError ? error.message : String(error);
        console.error(`[/api/ai/navigate] stream provider error (request ${input.requestId}):`, detail);
        await recordUsage(input.tenantId, input.userId, {
          operation: "navigate",
          unitType: "call",
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
