// Whisper proxy for the production AI gateway, including its hallucination
// filter.
//
import {
  apiKeyFor,
  endpointFor,
  ProviderCallError,
  runWithModelFallback,
  type AIModelTarget,
} from "@/lib/server/ai-routing";
import type { OperationalNotice } from "@/lib/server/operational-notice";

export type TranscriptionOutput = {
  text: string;
  modelVendor: string;
  modelId: string;
  modelApi: string;
  fallbackUsed: boolean;
  durationSeconds: number;
  notices: OperationalNotice[];
};

type WhisperSegment = {
  text?: string;
  no_speech_prob?: number;
  avg_logprob?: number;
  compression_ratio?: number;
};

export async function runTranscription(audio: File): Promise<TranscriptionOutput> {
  const routed = await runWithModelFallback("transcribe", (target) =>
    transcribeWith(target, audio)
  );
  return {
    text: routed.value.text,
    modelVendor: routed.modelVendor,
    modelId: routed.modelId,
    modelApi: routed.api,
    fallbackUsed: routed.fallbackUsed,
    durationSeconds: routed.value.durationSeconds,
    notices: routed.notices,
  };
}

async function transcribeWith(
  target: AIModelTarget,
  audio: File,
): Promise<{ text: string; durationSeconds: number }> {
  if (target.api !== "transcriptions") {
    throw new ProviderCallError(`Transcription cannot use API "${target.api}".`);
  }
  const form = new FormData();
  form.append("model", target.modelId);
  form.append("temperature", "0");
  // verbose_json gives per-segment confidence used to filter hallucinations.
  form.append("response_format", "verbose_json");
  form.append("file", audio, audio.name || "audio.m4a");

  const response = await fetch(endpointFor(target), {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKeyFor(target)}` },
    body: form,
    signal: AbortSignal.timeout(target.vendor === "groq" ? 15_000 : 60_000),
  });

  if (!response.ok) {
    const detail = (await response.text()).slice(0, 500);
    throw new ProviderCallError(`Provider HTTP ${response.status}: ${detail}`, {
      rateLimited: response.status === 429,
    });
  }

  const root = (await response.json()) as {
    text?: string;
    duration?: number;
    segments?: WhisperSegment[];
  };

  // Drop segments that look like silence-driven hallucinations, then rebuild
  // the text from what's left. Fall back to the top-level text otherwise.
  let text: string;
  if (Array.isArray(root.segments)) {
    text = root.segments
      .filter((segment) => !isHallucinated(segment))
      .map((segment) => segment.text ?? "")
      .join("")
      .trim();
  } else if (typeof root.text === "string") {
    text = root.text.trim();
  } else {
    throw new ProviderCallError("Transcription response had no text.");
  }

  return {
    text,
    durationSeconds: typeof root.duration === "number" ? root.duration : 0,
  };
}

/**
 * Whisper's own silence heuristic plus a repetition guard. A segment is
 * treated as a hallucination when the model is both confident there is no
 * speech and uncertain about its tokens, or when the output is degenerate
 * (highly repetitive text compresses far more than natural language).
 */
function isHallucinated(segment: WhisperSegment): boolean {
  const noSpeechProb = segment.no_speech_prob ?? 0;
  const avgLogprob = segment.avg_logprob ?? 0;
  const compressionRatio = segment.compression_ratio ?? 0;
  if (noSpeechProb > 0.6 && avgLogprob < -1.0) return true;
  if (compressionRatio > 2.4) return true;
  return false;
}
