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
  transformModelId: string;
  /** Lowercased emails allowed into /admin (docs/admin-dashboard-plan.md §2). */
  adminEmails: string[];
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
    transformModelId:
      normalize(process.env.BOMB_SQUAD_TRANSFORM_MODEL_ID) ?? "gpt-5.4-mini",
    // Comma-separated allowlist for the admin console (v0 authorization;
    // admin-dashboard-plan §2). Empty list means nobody is an admin.
    adminEmails: parseEmailList(process.env.ADMIN_EMAILS),
  };
}

function parseEmailList(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((email) => email.trim().toLowerCase())
    .filter(Boolean);
}

function normalize(value: string | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}
