import { GMAIL_SKILL } from "@/lib/server/skills/tools/gmail";
import { SLACK_SKILL } from "@/lib/server/skills/tools/slack";
import {
  GLOBAL_FACT_KEYS,
  SUGGEST_SECTIONS,
  VISION_SECTIONS,
  type ActiveSkill,
  type AppSignals,
  type FactKey,
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

/**
 * Fact keys the store may accept for a screen: the global vocabulary plus the
 * keys the matched skills declare, each scoped to its own skill id. Anything
 * outside this set is refused, which is what bounds the store.
 */
export function allowedFactKeys(
  signals: AppSignals | undefined,
): Array<{ scope: string; key: FactKey }> {
  const allowed = GLOBAL_FACT_KEYS.map((key) => ({ scope: "global", key: key as FactKey }));
  for (const skill of resolveSkills(signals)) {
    for (const key of skill.facts ?? []) {
      allowed.push({ scope: skill.id, key });
    }
  }
  return allowed;
}
