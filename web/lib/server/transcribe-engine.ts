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

export async function runTranscription(
  audio: File,
  language?: "ja" | "en",
): Promise<TranscriptionOutput> {
  const routed = await runWithModelFallback("transcribe", (target) =>
    transcribeWith(target, audio, language)
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
  language?: "ja" | "en",
): Promise<{ text: string; durationSeconds: number }> {
  if (target.api !== "transcriptions") {
    throw new ProviderCallError(`Transcription cannot use API "${target.api}".`);
  }
  const form = new FormData();
  form.append("model", target.modelId);
  form.append("temperature", "0");
  // Keep duration for usage metering and confidence data for the secondary
  // silence/hallucination guard. Client-side inspection already drops most
  // empty clips before upload.
  form.append("response_format", "verbose_json");
  if (language) form.append("language", language);
  form.append("file", audio, audio.name || "audio.m4a");

  const response = await fetch(endpointFor(target), {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKeyFor(target)}` },
    body: form,
    signal: AbortSignal.timeout(target.vendor === "groq" ? 15_000 : 60_000),
  });

  if (!response.ok) {
    throw new ProviderCallError(`Provider HTTP ${response.status}.`, {
      rateLimited: response.status === 429,
    });
  }

  const root = (await response.json()) as {
    text?: string;
    duration?: number;
    segments?: WhisperSegment[];
  };

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

function isHallucinated(segment: WhisperSegment): boolean {
  const noSpeechProb = segment.no_speech_prob ?? 0;
  const avgLogprob = segment.avg_logprob ?? 0;
  const compressionRatio = segment.compression_ratio ?? 0;
  if (noSpeechProb > 0.6 && avgLogprob < -1.0) return true;
  if (compressionRatio > 2.4) return true;
  return false;
}
