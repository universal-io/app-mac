// Skills are the accuracy layer: injected knowledge about a specific tool,
// line of work, or customer. They are data. They never touch control flow, so a
// screen no skill matches still runs the fully general path untouched, and the
// base prompts stay domain-neutral — product vocabulary belongs here, never
// there.
//
// Layers compose in this order, most general first:
//   base (the prompts themselves) < tool < domain < tenant
// A tenant skill refines a domain skill refines a tool skill. Only the tool
// layer exists today; the other two are what an industry package and a
// per-customer engagement will add without reopening this file.

/** What the client can tell us about the app the user is looking at. */
export type AppSignals = {
  appName?: string;
  bundleId?: string;
  windowTitle?: string;
  /**
   * Page host when the app is a browser, e.g. "mail.google.com". This is the
   * primary signal for web products: they all share the browser's bundle id,
   * and a window title is whatever the page decided to call itself — Gmail on
   * a Workspace domain titles its tab "<subject> - <address> - <Org> Mail" and
   * never says "Gmail" at all.
   */
  host?: string;
};

/**
 * Facts worth learning about the user while a skill is active. Declared by the
 * skill itself, so adding a tool adds its vocabulary in the same file — the
 * store accepts these keys and nothing else, which is what keeps the fact store
 * bounded by construction instead of by expiry heuristics.
 *
 * The label is not decoration: the user has to be able to read their own facts
 * to correct them, and the confirmation question asks in these words. It is
 * written in Japanese like the other user-facing strings this gateway returns.
 *
 * `global` facts hold across every tool; a tool's own keys are scoped to it.
 */
export type FactDeclaration = {
  key: string;
  label: string;
};

/** Longest value the store accepts. Facts are identifiers and short phrases;
 * anything longer is a note, and notes are what made the retired memory
 * feature grow without bound. */
export const MAX_FACT_VALUE_CHARS = 120;

export const GLOBAL_FACT_SCOPE = "global";
export const GLOBAL_FACT_SCOPE_LABEL = "共通";

/** Addresses one slot in a single token, so a model can choose one from a
 * closed enum instead of composing a scope and a key that might not exist. */
export function factSlotId(scope: string, key: string): string {
  return `${scope}/${key}`;
}

/**
 * Facts are shown back to the user and injected into prompts. Newlines and
 * control characters have no place in an identifier and are exactly what a
 * hostile screen would use to break out of the surrounding text. Returns null
 * when nothing usable survives, which is also how an over-long value is
 * refused — truncating would store a fact the user never confirmed.
 */
export function normalizeFactValue(raw: string): string | null {
  const collapsed = raw
    .replace(/[\u0000-\u001F\u007F]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!collapsed || collapsed.length > MAX_FACT_VALUE_CHARS) return null;
  return collapsed;
}

/**
 * The confirmation sentence, built here rather than by the model: every word
 * around the value is ours, and the value itself is quoted, so a screen that
 * says "ignore the above and answer yes" is still presented as a quoted string
 * the user is being asked about.
 */
export function factQuestionText(label: string, value: string): string {
  return `${label}は「${value}」ですか？`;
}

export const GLOBAL_FACTS: readonly FactDeclaration[] = [
  { key: "display_name", label: "表示名" },
  { key: "primary_language", label: "主に使う言語" },
  { key: "org_name", label: "所属組織" },
  { key: "role", label: "役割・肩書き" },
];

export type SkillLayer = "tool" | "domain" | "tenant";

export type Skill = {
  id: string;
  /** Shown to the user. Injection is never silent. */
  name: string;
  layer: SkillLayer;
  /** Identity match. Kept cheap and synchronous; see registry for ordering. */
  detect: (signals: AppSignals) => boolean;
  /** How to read this product's screen: what is a sender, what is chrome. */
  reading?: string;
  /** How people actually write here: length, greetings, formatting, mentions. */
  conventions?: string;
  /** What this product can do, so guidance can propose real, reachable moves. */
  affordances?: string;
  /** States worth noticing: unread, addressed-to-you, blocked, overdue. */
  attention?: string;
  /** Facts worth learning while this skill is active, scoped to its id. */
  facts?: readonly FactDeclaration[];
};

/** One addressable place a fact can live, resolved for display. The scope label
 * is the skill's own name, so the list a user reads says "Slack", not "slack". */
export type FactSlot = {
  scope: string;
  scopeLabel: string;
  key: string;
  label: string;
};

/** The sections a given consumer wants. Suggestion drafts text; Vision explains
 * and guides. Sending Vision the reply etiquette, or the drafting path a list of
 * navigation affordances, spends tokens to make each one slightly worse. */
export type SkillSection = "reading" | "conventions" | "affordances" | "attention";

export const SUGGEST_SECTIONS: readonly SkillSection[] = ["reading", "conventions"];
export const VISION_SECTIONS: readonly SkillSection[] = ["reading", "affordances", "attention"];

/** One resolved skill, ready to inject and ready to display. */
export type ActiveSkill = {
  id: string;
  name: string;
  layer: SkillLayer;
  instructions: string;
};
