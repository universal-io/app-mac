// Tool harness selection for the screen navigator (docs/navigator-copilot-plan.md
// §9-a). The client never picks a harness: it only sends hints (frontmost app
// name, window title, URL) and the gateway decides. No match → the generic
// navigator prompt alone, which must always work — the harness is an
// invisible accuracy add-on, not a mode.
//
// Packs are data (docs/foundation-redesign-plan.md §5-b): enabled global rows
// of `bs_harness_packs` are loaded through the service-role client behind a
// short in-memory cache, so adding tool support is a row insert — no deploy.
// The inline harnesses below stay as seed data and as the fallback whenever
// the table is empty or the query fails; selection semantics are identical
// either way.

import { getSupabaseAdminClient } from "@/lib/server/supabase-admin";
import {
  dataFallbackNotice,
  type OperationalNotice,
} from "@/lib/server/operational-notice";

export type NavigateHints = {
  app_name?: string;
  window_title?: string;
  url?: string;
};

/** One step of a task recipe. `target` is the exact on-screen label the
 * client resolves via OCR/AX; `fill` is approval-driven text entry. */
export type RecipeStep = {
  verbal: string;
  target?: string;
  fill?: string;
};

/** A known multi-step path through the tool's UI. Recipes are deterministic
 * data (docs/navigator-copilot-plan.md §3-b): the planner adopts a matching
 * recipe verbatim instead of inventing steps, and each recipe doubles as a
 * golden-set case. Placeholders like {ページパス} mark values the planner
 * must substitute from the user's actual question. */
export type Recipe = {
  goal: string;
  steps: RecipeStep[];
};

export type Harness = {
  id: string;
  promptBlock: string;
  recipes?: Recipe[];
  operationalNotices?: OperationalNotice[];
};

/** A harness plus the matching rule `selectHarness` evaluates. */
type MatchableHarness = Harness & {
  /** Lowercased substrings; any one occurring in the joined hints matches. */
  matchTerms: string[];
};

export async function selectHarness(hints?: NavigateHints): Promise<Harness | null> {
  if (!hints) return null;
  const haystack = [hints.url, hints.window_title, hints.app_name]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  if (!haystack) return null;

  const loaded = await loadGlobalPacks();
  for (const pack of loaded.packs) {
    if (pack.matchTerms.some((term) => haystack.includes(term))) {
      return {
        id: pack.id,
        promptBlock: pack.promptBlock,
        recipes: pack.recipes,
        operationalNotices: loaded.notice ? [loaded.notice] : undefined,
      };
    }
  }
  return null;
}

// --- Pack loading (bs_harness_packs) ---------------------------------------

const PACK_CACHE_TTL_MS = 60_000;

let packCache: {
  packs: MatchableHarness[];
  notice: OperationalNotice | null;
  expiresAt: number;
} | null = null;

/**
 * Enabled global packs, newest read at most every PACK_CACHE_TTL_MS. Any
 * failure (missing table, network, malformed rows) falls back to the in-code
 * seed packs — harness selection must never take the navigator down.
 *
 * TODO(foundation-redesign-plan §5-b): tenant-scoped packs. The table already
 * carries scope='tenant' + tenant_id, but wiring them into selection needs
 * the authenticated tenant id threaded down to selectHarness, and min_plan
 * needs the entitlements feature gate (§5-c). Global packs only for now.
 */
async function loadGlobalPacks(): Promise<{
  packs: MatchableHarness[];
  notice: OperationalNotice | null;
}> {
  const now = Date.now();
  if (packCache && now < packCache.expiresAt) {
    return { packs: packCache.packs, notice: packCache.notice };
  }

  let packs = SEED_HARNESSES;
  let notice: OperationalNotice | null = dataFallbackNotice(
    "Capability Pack",
    "組み込み版Pack",
  );
  try {
    const admin = getSupabaseAdminClient();
    const { data, error } = await admin
      .from("bs_harness_packs")
      .select("tool_id, match_hints, ui_map, recipes, prompt")
      .eq("scope", "global")
      .eq("enabled", true);
    if (error) {
      throw new Error(error.message);
    }
    const rows = (data ?? [])
      .map(packFromRow)
      .filter((pack): pack is MatchableHarness => pack !== null);
    if (rows.length > 0) {
      packs = rows;
      notice = null;
    }
  } catch (error) {
    console.error(
      "[harness] pack load failed, using built-in fallback:",
      error instanceof Error ? error.message : error,
    );
  }
  packCache = { packs, notice, expiresAt: now + PACK_CACHE_TTL_MS };
  return { packs, notice };
}

type PackRow = {
  tool_id: string | null;
  match_hints: unknown;
  ui_map: string | null;
  recipes: unknown;
  prompt: string | null;
};

/** Maps a DB row to the in-memory shape. Returns null (row skipped) rather
 * than throwing: one bad row must not disable every pack. */
function packFromRow(row: PackRow): MatchableHarness | null {
  const id = row.tool_id?.trim();
  if (!id) return null;

  // match_hints contract: {"contains": ["analytics.google.com", ...]} —
  // case-insensitive substring match, mirroring the historical inline checks.
  const matchTerms = parseMatchTerms(row.match_hints);
  if (matchTerms.length === 0) return null;

  const promptBlock = [row.prompt?.trim(), row.ui_map?.trim()]
    .filter((part): part is string => Boolean(part))
    .join("\n\n");
  if (!promptBlock) return null;

  return { id, promptBlock, matchTerms, recipes: parseRecipes(row.recipes) };
}

function parseMatchTerms(value: unknown): string[] {
  if (typeof value !== "object" || value === null) return [];
  const contains = (value as { contains?: unknown }).contains;
  if (!Array.isArray(contains)) return [];
  return contains
    .filter((term): term is string => typeof term === "string" && Boolean(term.trim()))
    .map((term) => term.trim().toLowerCase());
}

/** Strict validation: a malformed recipe list degrades to "no recipes"
 * (the pack still ships its prompt) instead of failing the pack. */
function parseRecipes(value: unknown): Recipe[] | undefined {
  if (!Array.isArray(value) || value.length === 0) return undefined;
  const recipes: Recipe[] = [];
  for (const raw of value) {
    if (typeof raw !== "object" || raw === null) return undefined;
    const recipe = raw as { goal?: unknown; steps?: unknown };
    if (typeof recipe.goal !== "string" || !recipe.goal.trim()) return undefined;
    if (!Array.isArray(recipe.steps) || recipe.steps.length === 0) return undefined;
    const steps: RecipeStep[] = [];
    for (const rawStep of recipe.steps) {
      if (typeof rawStep !== "object" || rawStep === null) return undefined;
      const step = rawStep as { verbal?: unknown; target?: unknown; fill?: unknown };
      if (typeof step.verbal !== "string" || !step.verbal.trim()) return undefined;
      steps.push({
        verbal: step.verbal.trim(),
        target: typeof step.target === "string" && step.target.trim() ? step.target.trim() : undefined,
        fill: typeof step.fill === "string" && step.fill ? step.fill : undefined,
      });
    }
    recipes.push({ goal: recipe.goal.trim(), steps });
  }
  return recipes;
}

// --- Seed / fallback packs -------------------------------------------------
// These are the rows to seed `bs_harness_packs` from, and the fallback when
// the table is empty or unreachable. Keep them in sync with the seeded data
// until the admin console owns pack editing (admin-dashboard-plan v1).

// GA4 (Google Analytics 4) pack v0.
// UI map + task recipes for the demo scenario ("あるページの直帰率を見たい").
// Kept compact on purpose: the navigator must stay terse, the pack only has
// to prevent the classic wrong turns (bounce rate is absent from default
// reports; user acquisition vs traffic acquisition; editor-only customize).

const GA4_HARNESS: MatchableHarness = {
  id: "ga4",
  // Chrome's window title for GA4 is just the tab title — "アナリティクス"
  // without "Google" — and the client sends no URL hint yet, so the bare
  // title must match too (the 2026-07-06 harness miss: no recipes, no
  // planner, no GA4 knowledge, silently generic).
  matchTerms: [
    "analytics.google.com",
    "google analytics",
    "google アナリティクス",
    "アナリティクス",
  ],
  promptBlock: `# ツール知識: Google Analytics 4（GA4）
この画面は GA4 の可能性が高い。以下の UI マップとレシピを正として案内する。実際の画面と食い違う場合は画面を優先し、その旨を一言添える。

## UI マップ
- 画面左端の細いナビ（アイコン列）: ホーム / レポート / 探索 / 広告。
- 「レポート」内の左メニュー: レポートのスナップショット / リアルタイム / ユーザー（ユーザー属性・テクノロジー）/ ライフサイクル（集客・エンゲージメント・収益化・維持率）。
  - **トピックの対応（間違えやすい）**: 国・地域・言語・年齢・性別 → **ユーザー属性**。デバイス（mobile/desktop）・OS・ブラウザ・画面サイズ → **テクノロジー**。流入元・チャネル → **集客**。ページ別の閲覧 → **エンゲージメント**。
  - 「概要」という項目はユーザー属性・テクノロジー・各ライフサイクル配下など**複数箇所にある**。案内するときは必ず「どのセクションの下の概要か」を言葉で添え、位置マーカーで特定する。
  - 集客 → ユーザー獲得: ユーザーの初回接点別。トラフィック獲得: セッション別。「流入経路」は通常トラフィック獲得。
  - エンゲージメント → ページとスクリーン: ページ別の指標表。表の上の検索欄でページパスを絞り込める。
- レポート表の右上: 検索 / 期間セレクタ / 共有 / 「レポートをカスタマイズ」（鉛筆アイコン。編集者以上の権限が必要）。
- 探索（Explore）: 自由形式の分析。左の「変数」列に指標・ディメンションを追加し、「タブの設定」へドラッグして表を組む。

## タスクレシピ
- 特定ページのトラフィックを見る: レポート → ライフサイクル → エンゲージメント → ページとスクリーン → 表の検索欄にページパス（例: /pricing）を入力。
- 直帰率を見る: **GA4 の既定レポートに直帰率は表示されない**。次のいずれか:
  1. ページとスクリーン → 右上の鉛筆（レポートをカスタマイズ）→ 指標 → 「直帰率」を追加 → 適用 → 保存。鉛筆が見えない場合は編集者権限が無いので 2 へ。
  2. 探索 → 空白 → 指標に「直帰率」、ディメンションに「ページパスとスクリーンクラス」を追加して表を組む。
  3. 目安だけなら: 直帰率 = 100% − エンゲージメント率。
- 流入元（チャネル別）を見る: レポート → ライフサイクル → 集客 → トラフィック獲得（セッションのデフォルトチャネルグループ）。`,
  recipes: [
    {
      goal: "特定ページの指標（表示回数・セッション・ユーザー数など）を見る",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「エンゲージメント」を開く", target: "エンゲージメント" },
        { verbal: "「ページとスクリーン」を開く", target: "ページとスクリーン" },
        {
          verbal: "表の上の検索欄にページパスを入力して絞り込む",
          target: "検索",
          fill: "{ページパス}",
        },
        { verbal: "右上の期間セレクタで対象期間（先月・過去30日など）を選ぶ" },
        { verbal: "絞り込んだ行から対象の指標を読み取る" },
      ],
    },
    {
      goal: "直帰率を見る（既定レポートには無い指標）",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「エンゲージメント」を開く", target: "エンゲージメント" },
        { verbal: "「ページとスクリーン」を開く", target: "ページとスクリーン" },
        {
          verbal:
            "右上の鉛筆アイコン（レポートをカスタマイズ）を開く。見えない場合は編集者権限が無いので、探索で直帰率の表を組むか、目安として 100%−エンゲージメント率 を使う",
          target: "レポートをカスタマイズ",
        },
        { verbal: "「指標」を開いて「直帰率」を追加し、適用する", target: "指標" },
        { verbal: "表に追加された「直帰率」列を読み取る" },
      ],
    },
    {
      goal: "流入元（チャネル別のセッション数）を見る",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「集客」を開く", target: "集客" },
        { verbal: "「トラフィック獲得」を開く", target: "トラフィック獲得" },
        { verbal: "「セッションのデフォルトチャネルグループ」別の表から読み取る" },
      ],
    },
    {
      goal: "訪問者の国・地域・言語を見る",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「ユーザー属性」を開く", target: "ユーザー属性" },
        { verbal: "「ユーザー属性の詳細」を開く（国別の表が出る）", target: "ユーザー属性の詳細" },
        {
          verbal:
            "表のディメンション（列見出しのプルダウン）で「国」「地域」「市区町村」「言語」を切り替えて読み取る",
        },
      ],
    },
    {
      goal: "デバイス別（モバイル/デスクトップ）の利用状況を見る",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「テクノロジー」を開く", target: "テクノロジー" },
        { verbal: "「ユーザーの環境の詳細」を開く", target: "ユーザーの環境の詳細" },
        {
          verbal:
            "表のディメンションを「デバイス カテゴリ」にして mobile / desktop / tablet の行を読み取る",
        },
      ],
    },
  ],
};

const SEED_HARNESSES: MatchableHarness[] = [GA4_HARNESS];
