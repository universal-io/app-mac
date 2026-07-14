// AI gateway: POST /api/ai/navigate — the screen navigator
// (docs/navigator-copilot-plan.md). Multi-turn: input.messages carries the
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
import {
  visionObservationSchema,
  type VisionObservation,
} from "@/lib/context/observation";
import { ProviderCallError } from "@/lib/server/review-engine";
import {
  isAutoFirstTurn,
  runNavigateStream,
  type NavigateEngineOutput,
  type NavigateMessage,
  type NavigateTask,
} from "@/lib/server/navigate-engine";
import type { NavigateHints } from "@/lib/server/harness";
import type { OutputLanguageCode } from "@/lib/server/prompts";
import { getServerEnv } from "@/lib/server/env";
import { stateFallbackNotice } from "@/lib/server/operational-notice";
import { createNavigateRunProposal } from "@/lib/server/navigate-run-snapshot";

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
  observation?: unknown;
};

type WireTask = {
  goal?: string;
  steps?: Array<{ verbal?: string; target?: string; fill?: string }>;
  current_step?: number;
};

type NavigateRequestBody = {
  request_id?: string;
  operation?: string;
  input?: {
    messages?: WireMessage[];
    hints?: NavigateHints;
    task?: WireTask;
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
    let observationCount = 0;
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
      let observation: VisionObservation | undefined;
      if (message.observation !== undefined) {
        if (message.role !== "user") {
          return errorResponse(400, "BAD_REQUEST", "Only user messages may carry an observation.", requestId);
        }
        const parsed = visionObservationSchema.safeParse(message.observation);
        if (!parsed.success) {
          return errorResponse(400, "BAD_REQUEST", "message.observation is malformed.", requestId);
        }
        observationCount += 1;
        if (observationCount > 1) {
          return errorResponse(400, "BAD_REQUEST", "Only the latest observation may be sent.", requestId);
        }
        observation = parsed.data;
      }
      messages.push({
        role: message.role,
        text: message.text,
        imageDataURL,
        ocrText: message.ocr_text,
        observation,
      });
    }
    const last = messages[messages.length - 1];
    if (last.role !== "user") {
      return errorResponse(400, "BAD_REQUEST", "The last message must be from the user.", requestId);
    }

    // Active copilot task (client-held session state; docs/navigator-copilot-plan.md §3-a).
    let task: NavigateTask | undefined;
    if (body.input?.task) {
      const wireTask = body.input.task;
      const steps = Array.isArray(wireTask.steps) ? wireTask.steps : [];
      const validSteps = steps.every(
        (step) =>
          typeof step?.verbal === "string" &&
          step.verbal.length > 0 &&
          step.verbal.length <= 300 &&
          (step.target === undefined || (typeof step.target === "string" && step.target.length <= 120)) &&
          (step.fill === undefined || (typeof step.fill === "string" && step.fill.length <= 500)),
      );
      if (
        typeof wireTask.goal !== "string" ||
        !wireTask.goal ||
        wireTask.goal.length > 200 ||
        steps.length < 1 ||
        steps.length > 8 ||
        !validSteps ||
        typeof wireTask.current_step !== "number" ||
        !Number.isInteger(wireTask.current_step) ||
        wireTask.current_step < 0 ||
        wireTask.current_step >= steps.length
      ) {
        return errorResponse(400, "BAD_REQUEST", "input.task is malformed.", requestId);
      }
      task = {
        goal: wireTask.goal,
        steps: steps.map((step) => ({
          verbal: step.verbal!,
          target: step.target,
          fill: step.fill,
        })),
        currentStep: wireTask.current_step,
      };
    }

    const { userId, tenantId, entitlement } = await authenticate(request);
    await enforceQuota(tenantId, entitlement);

    const latestObservation = messages.find((message) => message.observation)?.observation;
    const observationSources = latestObservation
      ? [...new Set(latestObservation.candidates.map((candidate) => candidate.source))]
      : [];

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
      has_observation: Boolean(latestObservation),
      observation_schema_version: latestObservation?.schema_version,
      observation_capture_scope: latestObservation?.capture_scope,
      observation_transition_state: latestObservation?.transition_state,
      observation_candidate_count: latestObservation?.candidates.length ?? 0,
      observation_candidate_sources: observationSources,
      task_active: Boolean(task),
      task_step: task?.currentStep,
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
        task,
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
        const notices = [...finalOutput.notices];
        let runProposal: ReturnType<typeof createNavigateRunProposal> | null = null;
        const env = getServerEnv();
        if (env.navigateV4Enabled && finalOutput.proposedTask && finalOutput.harnessId) {
          try {
            runProposal = createNavigateRunProposal({
              tenantId: input.tenantId,
              userId: input.userId,
            }, {
              packId: finalOutput.harnessId,
              // The existing harness schema is intentionally labelled as
              // legacy until milestone D introduces typed Pack v1.
              packVersion: "unversioned-v3",
              task: finalOutput.proposedTask,
            }, env.navigateRunSigningSecret ?? "");
          } catch (error) {
            console.error(
              `[/api/ai/navigate] Run proposal unavailable (request ${input.requestId}):`,
              error instanceof Error ? error.message : error,
            );
            notices.push(stateFallbackNotice(
              "新しいナビゲーション状態",
              "従来のクライアント管理方式",
            ));
          }
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
            grounder_attempted: finalOutput.groundingAttempted,
            grounding_selected: Boolean(finalOutput.grounding),
            grounding_method: finalOutput.grounding?.method,
            grounding_input_tokens: finalOutput.groundingInputTokens,
            grounding_output_tokens: finalOutput.groundingOutputTokens,
            planner_model_vendor: finalOutput.plannerModelVendor,
            planner_model_id: finalOutput.plannerModelId,
            planner_input_tokens: finalOutput.plannerInputTokens,
            planner_output_tokens: finalOutput.plannerOutputTokens,
            grounder_model_vendor: finalOutput.grounderModelVendor,
            grounder_model_id: finalOutput.grounderModelId,
            model_fallback_from: finalOutput.modelFallbackFrom,
            operational_notice_codes: notices.map((notice) => notice.code),
            task_proposed: Boolean(finalOutput.proposedTask),
          },
        });
        send("result", {
          request_id: input.requestId,
          result: {
            text: finalOutput.text,
            harness: finalOutput.harnessId,
            // Proposed plan for this session; the client shows the "start
            // navigation" button and owns the task state from here on.
            task: finalOutput.proposedTask
              ? {
                  goal: finalOutput.proposedTask.goal,
                  steps: finalOutput.proposedTask.steps.map((step) => ({
                    verbal: step.verbal,
                    target: step.target ?? null,
                    fill: step.fill ?? null,
                  })),
                  current_step: finalOutput.proposedTask.currentStep,
                }
              : null,
            // Shadow-only until the macOS client explicitly starts v4. The
            // proposal creates no DB row and expires after ten minutes.
            run_proposal: runProposal,
            grounding: finalOutput.grounding
              ? {
                  capture_id: finalOutput.grounding.captureId,
                  candidate_id: finalOutput.grounding.candidateId,
                  confidence: finalOutput.grounding.confidence,
                  method: finalOutput.grounding.method,
                }
              : null,
          },
          meta: {
            output_language: input.language,
            model_vendor: finalOutput.modelVendor,
            model_id: finalOutput.modelId,
            latency_ms: latencyMs,
            notices,
          },
        });
      } catch (error) {
        if (error instanceof GatewayError) {
          console.error(
            `[/api/ai/navigate] stream state error (request ${input.requestId}):`,
            error.message,
          );
          await recordUsage(input.tenantId, input.userId, {
            operation: "navigate",
            unitType: "call",
            requestId: input.requestId,
            status: "error",
            errorCode: error.code,
            latencyMs: Date.now() - started,
            metadata: input.metadata,
          });
          send("error", {
            error: { code: error.code, message: error.message },
            request_id: input.requestId,
          });
          return;
        }
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
