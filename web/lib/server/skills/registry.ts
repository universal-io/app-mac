import { ACTIVITY_MONITOR_SKILL } from "@/lib/server/skills/tools/activity-monitor";
import { GA4_SKILL } from "@/lib/server/skills/tools/ga4";
import { GMAIL_SKILL } from "@/lib/server/skills/tools/gmail";
import { SLACK_SKILL } from "@/lib/server/skills/tools/slack";
import { STRIPE_SKILL } from "@/lib/server/skills/tools/stripe";
import {
  GLOBAL_FACTS,
  GLOBAL_FACT_SCOPE,
  GLOBAL_FACT_SCOPE_LABEL,
  SUGGEST_SECTIONS,
  VISION_SECTIONS,
  type ActiveSkill,
  type AppSignals,
  type FactSlot,
  type Skill,
  type SkillSection,
} from "@/lib/server/skills/types";

// One file per tool. Adding a product means adding a file and one line here —
// if that ever stops being true, the abstraction is wrong and belongs back on
// the workbench, because the whole premise is that the hundredth tool costs
// what the second one did.
const TOOL_SKILLS: readonly Skill[] = [
  SLACK_SKILL,
  GMAIL_SKILL,
  GA4_SKILL,
  STRIPE_SKILL,
  ACTIVITY_MONITOR_SKILL,
];

const DOMAIN_SKILLS: readonly Skill[] = [];
const TENANT_SKILLS: readonly Skill[] = [];

/**
 * Resolve which skills apply to a screen, most general first so that a domain
 * skill can qualify a tool skill and a tenant skill can qualify both.
 *
 * At most one skill per layer: two tools claiming the same screen means the
 * detection is wrong, and injecting both would have them contradict each other
 * inside one prompt. First match wins, so order within a layer is meaningful.
 */
export function resolveSkills(signals: AppSignals | undefined): Skill[] {
  if (!signals) return [];
  const resolved: Skill[] = [];
  for (const layer of [TOOL_SKILLS, DOMAIN_SKILLS, TENANT_SKILLS]) {
    const matched = layer.find((skill) => skill.detect(signals));
    if (matched) resolved.push(matched);
  }
  return resolved;
}

/**
 * Build the injectable attachment for one consumer. Returns null when nothing
 * matched or when the matched skills carry none of the requested sections —
 * the caller then sends no attachment at all rather than an empty heading.
 */
export function skillAttachment(
  signals: AppSignals | undefined,
  sections: readonly SkillSection[],
): ActiveSkill | null {
  const skills = resolveSkills(signals);
  if (skills.length === 0) return null;

  const blocks: string[] = [];
  for (const skill of skills) {
    for (const section of sections) {
      const body = skill[section]?.trim();
      if (body) blocks.push(body);
    }
  }
  if (blocks.length === 0) return null;

  // The most specific skill names the attachment: what the user is shown is the
  // thing that most shaped the answer.
  const leading = skills[skills.length - 1];
  return {
    id: skills.map((skill) => skill.id).join("+"),
    name: leading.name,
    layer: leading.layer,
    instructions: blocks.join("\n\n"),
  };
}

export function suggestSkill(signals: AppSignals | undefined): ActiveSkill | null {
  return skillAttachment(signals, SUGGEST_SECTIONS);
}

export function visionSkill(signals: AppSignals | undefined): ActiveSkill | null {
  return skillAttachment(signals, VISION_SECTIONS);
}

const GLOBAL_FACT_SLOTS: readonly FactSlot[] = GLOBAL_FACTS.map((fact) => ({
  scope: GLOBAL_FACT_SCOPE,
  scopeLabel: GLOBAL_FACT_SCOPE_LABEL,
  key: fact.key,
  label: fact.label,
}));

function slotsFor(skill: Skill): FactSlot[] {
  return (skill.facts ?? []).map((fact) => ({
    scope: skill.id,
    scopeLabel: skill.name,
    key: fact.key,
    label: fact.label,
  }));
}

/**
 * Every place a fact may be stored, across all registered skills. This is the
 * store's only guardrail: a key outside this list is refused, so the fact store
 * is bounded by the vocabulary rather than by expiry or confidence decay. Adding
 * a tool extends it from that tool's own file and nowhere else.
 */
export function factVocabulary(): FactSlot[] {
  const slots = [...GLOBAL_FACT_SLOTS];
  for (const layer of [TOOL_SKILLS, DOMAIN_SKILLS, TENANT_SKILLS]) {
    for (const skill of layer) slots.push(...slotsFor(skill));
  }
  return slots;
}

export function factSlot(scope: string, key: string): FactSlot | null {
  return factVocabulary().find((slot) => slot.scope === scope && slot.key === key) ?? null;
}

/**
 * The slots relevant to one screen: the global vocabulary plus what the matched
 * skills declare. This is what a detection may ask about and what injection may
 * read — deliberately narrower than the whole store.
 */
export function allowedFactSlots(signals: AppSignals | undefined): FactSlot[] {
  const allowed = [...GLOBAL_FACT_SLOTS];
  for (const skill of resolveSkills(signals)) {
    allowed.push(...slotsFor(skill));
  }
  return allowed;
}
