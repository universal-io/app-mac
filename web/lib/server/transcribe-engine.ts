// Whisper proxy for the AI gateway. Port of the macOS GroqTranscriber
// (BombSquad/Services/GroqTranscriber.swift) including its hallucination
// filter; keep the two in sync until the BYOK fallback path is removed.
//
// Availability principle (owner decision, 2026-07-03): a provider-side
// failure (outage, provider rate limit, misconfigured operator quota) must
// never take the feature away from the user. Groq is the fast primary; on
// any provider error the request silently falls back to OpenAI whisper-1
// (a different vendor, so a Groq outage cannot take both down). Only the
// user's own plan quota may stop a request — that check lives in the route.

import { getServerEnv } from "@/lib/server/env";
import { ProviderCallError } from "@/lib/server/review-engine";

type TranscriptionEngine = {
  vendor: string;
  modelId: string;
  endpoint: string;
  apiKey: string | null;
  timeoutMs: number;
};

export type TranscriptionOutput = {
  text: string;
  modelVendor: string;
  modelId: string;
  durationSeconds: number;
};

type WhisperSegment = {
  text?: string;
  no_speech_prob?: number;
  avg_logprob?: number;
  compression_ratio?: number;
};

export async function runTranscription(audio: File): Promise<TranscriptionOutput> {
  const env = getServerEnv();
  // Hold-to-talk clips are seconds long; a primary that stalls counts as
  // down, so it gets a tight budget and the fallback a generous one.
  const engines: TranscriptionEngine[] = [
    {
      vendor: "groq",
      modelId: "whisper-large-v3",
      endpoint: "https://api.groq.com/openai/v1/audio/transcriptions",
      apiKey: env.groqApiKey,
      timeoutMs: 15_000,
    },
    {
      vendor: "openai",
      modelId: "whisper-1",
      endpoint: "https://api.openai.com/v1/audio/transcriptions",
      apiKey: env.openaiApiKey,
      timeoutMs: 60_000,
    },
  ].filter((engine) => Boolean(engine.apiKey));

  if (engines.length === 0) {
    throw new ProviderCallError("No provider key configured for transcription.");
  }

  let lastError: ProviderCallError | null = null;
  for (const engine of engines) {
    try {
      return await transcribeWith(engine, audio);
    } catch (error) {
      lastError =
        error instanceof ProviderCallError
          ? error
          : new ProviderCallError(String(error));
      console.warn(
        `[transcribe] ${engine.vendor}/${engine.modelId} failed, ` +
          `${engine === engines[engines.length - 1] ? "no fallback left" : "falling back"}:`,
        lastError.message,
      );
    }
  }

  throw lastError ?? new ProviderCallError("Transcription failed.");
}

async function transcribeWith(
  engine: TranscriptionEngine,
  audio: File,
): Promise<TranscriptionOutput> {
  const form = new FormData();
  form.append("model", engine.modelId);
  form.append("temperature", "0");
  // verbose_json gives per-segment confidence used to filter hallucinations.
  form.append("response_format", "verbose_json");
  form.append("file", audio, audio.name || "audio.m4a");

  const response = await fetch(engine.endpoint, {
    method: "POST",
    headers: { Authorization: `Bearer ${engine.apiKey}` },
    body: form,
    signal: AbortSignal.timeout(engine.timeoutMs),
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
    modelVendor: engine.vendor,
    modelId: engine.modelId,
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
