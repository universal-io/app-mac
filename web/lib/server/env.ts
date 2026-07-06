// Server-only environment access for the AI gateway. Never import this from
// client components. Names follow docs/api-contract.md.

export type ServerEnv = {
  supabaseUrl: string;
  supabaseAnonKey: string;
  supabaseServiceRoleKey: string;
  groqApiKey: string | null;
  geminiApiKey: string | null;
  openaiApiKey: string | null;
  anthropicApiKey: string | null;
  defaultModelVendor: string;
  defaultModelId: string;
  visionModelId: string;
  navigateModelVendor: string;
  navigateModelId: string;
  navigateFastModelVendor: string;
  navigateFastModelId: string;
  freeMonthlyReviewLimit: number;
};

export function getServerEnv(): ServerEnv {
  const supabaseUrl =
    normalize(process.env.SUPABASE_URL) ??
    normalize(process.env.NEXT_PUBLIC_SUPABASE_URL);
  const supabaseAnonKey =
    normalize(process.env.SUPABASE_ANON_KEY) ??
    normalize(process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY);
  const supabaseServiceRoleKey = normalize(process.env.SUPABASE_SERVICE_ROLE_KEY);

  if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceRoleKey) {
    throw new Error(
      "Missing Supabase server env vars (SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY).",
    );
  }

  return {
    supabaseUrl,
    supabaseAnonKey,
    supabaseServiceRoleKey,
    groqApiKey: normalize(process.env.GROQ_API_KEY),
    geminiApiKey: normalize(process.env.GEMINI_API_KEY),
    openaiApiKey: normalize(process.env.OPENAI_API_KEY),
    anthropicApiKey: normalize(process.env.ANTHROPIC_API_KEY),
    defaultModelVendor:
      normalize(process.env.BOMB_SQUAD_DEFAULT_MODEL_VENDOR) ?? "groq",
    defaultModelId:
      normalize(process.env.BOMB_SQUAD_DEFAULT_MODEL_ID) ?? "openai/gpt-oss-120b",
    // Matches the macOS default (AppSettings.defaultVisionModelID).
    visionModelId: normalize(process.env.BOMB_SQUAD_VISION_MODEL_ID) ?? "gpt-5.4-mini",
    // Screen navigator (POST /api/ai/navigate). The follow-up turns use the
    // main model; the auto first turn (scene recognition one-liner) prefers a
    // fast vision-capable model so the first token lands within ~1s.
    navigateModelVendor:
      normalize(process.env.BOMB_SQUAD_NAVIGATE_MODEL_VENDOR) ?? "openai",
    navigateModelId:
      normalize(process.env.BOMB_SQUAD_NAVIGATE_MODEL_ID) ?? "gpt-5.4-mini",
    navigateFastModelVendor:
      normalize(process.env.BOMB_SQUAD_NAVIGATE_FAST_MODEL_VENDOR) ?? "groq",
    navigateFastModelId:
      normalize(process.env.BOMB_SQUAD_NAVIGATE_FAST_MODEL_ID) ??
      "meta-llama/llama-4-scout-17b-16e-instruct",
    // Since 2026-07-06 this caps ALL AI operations (one request = one unit),
    // not just reviews. 500 is deliberately generous for the initial cohort.
    freeMonthlyReviewLimit: parsePositiveInt(
      process.env.BOMB_SQUAD_FREE_MONTHLY_REVIEW_LIMIT,
      500,
    ),
  };
}

function normalize(value: string | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function parsePositiveInt(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}
