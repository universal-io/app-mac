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
};

/**
 * Facts worth learning about the user while a skill is active. Declared by the
 * skill itself, so adding a tool adds its vocabulary in the same file — the
 * store accepts these keys and nothing else, which is what keeps the fact store
 * bounded by construction instead of by expiry heuristics.
 *
 * `global` facts hold across every tool; a tool's own keys are scoped to it.
 */
export type FactKey = string;

export const GLOBAL_FACT_KEYS = [
  "display_name",
  "primary_language",
  "org_name",
  "role",
] as const satisfies readonly FactKey[];

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
  /** Fact keys worth learning while this skill is active, scoped to its id. */
  facts?: readonly FactKey[];
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
