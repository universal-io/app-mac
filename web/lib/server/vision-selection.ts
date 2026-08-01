export type VisionSelectionFrame = {
  x: number;
  y: number;
  width: number;
  height: number;
};

export type VisionSelectionStructure = {
  source: "ax" | "dom";
  role?: string;
  label?: string;
  parentLabel?: string;
  relationship: "selection_container" | "intersects_selection" | "surrounding_context";
  states: string[];
  actions: string[];
  frame?: VisionSelectionFrame;
  coverage: "whole" | "partial" | "context" | "unknown";
};

/**
 * The Selection Extension, which exists only for text the user actually
 * selected. `kind` and a non-empty `text` are constants of the type because a
 * selection that was not acquired is not a weaker selection — it is an
 * ordinary Vision request.
 */
export type VisionSelection = {
  kind: "text";
  text: string;
  structures: VisionSelectionStructure[];
  frames: VisionSelectionFrame[];
  acquisitionCompleteness: "complete" | "partial" | "visual_only";
  acquisition: "ax_document_selection" | "ax_selected_text" | "ax_element" | "visual_highlight";
  captureVisibility: "visible" | "partial" | "off_capture" | "unknown";
  wireTruncated: boolean;
  originalUTF16Units: number;
};

/**
 * A validated wire or legacy selection before the positive-evidence rule runs.
 * `normalizeVisionSelection` is the only place that turns one of these into a
 * `VisionSelection`.
 */
export type VisionSelectionCandidate = Omit<VisionSelection, "kind" | "text"> & {
  kind: string;
  text?: string;
};

export type VisionSelectionWire = {
  kind?: string;
  text?: string;
  acquisition_completeness?: string;
  acquisition?: string;
  capture_visibility?: string;
  frames?: Partial<VisionSelectionFrame>[];
  structures?: Array<{
    source?: string;
    role?: string;
    label?: string;
    parent_label?: string;
    relationship?: string;
    states?: string[];
    actions?: string[];
    frame?: Partial<VisionSelectionFrame>;
    coverage?: string;
  }>;
  wire_truncated?: boolean;
  original_utf16_units?: number;
};

const MAX_TEXT_UTF16_UNITS = 12_000;
const MAX_ROLE_UTF16_UNITS = 128;
const MAX_LABEL_UTF16_UNITS = 512;
const MAX_COORDINATE = 100_000;
const MAX_STRUCTURES = 64;
const MAX_FRAMES = 64;
const MAX_ARRAY_ITEMS = 16;
const MAX_ORIGINAL_UTF16_UNITS = 1_000_000;

export function isValidVisionSelectionWire(value: unknown): value is VisionSelectionWire {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const selection = value as VisionSelectionWire;
  const kinds = new Set(["text", "accessibility_element", "visual_only"]);
  const completeness = new Set(["complete", "partial", "visual_only"]);
  const acquisitions = new Set([
    "ax_document_selection",
    "ax_selected_text",
    "ax_element",
    "visual_highlight",
  ]);
  const visibility = new Set(["visible", "partial", "off_capture", "unknown"]);
  if (!kinds.has(selection.kind ?? "")
      || !completeness.has(selection.acquisition_completeness ?? "")
      || !acquisitions.has(selection.acquisition ?? "")
      || !visibility.has(selection.capture_visibility ?? "")
      || typeof selection.wire_truncated !== "boolean"
      || !Number.isInteger(selection.original_utf16_units)
      || selection.original_utf16_units! < 0
      || selection.original_utf16_units! > MAX_ORIGINAL_UTF16_UNITS) {
    return false;
  }

  const text = selection.text;
  if (text !== undefined && (typeof text !== "string"
      || text.trim().length === 0
      || text.length > MAX_TEXT_UTF16_UNITS
      || hasForbiddenControlCharacters(text))) return false;
  if (selection.kind === "text") {
    if (selection.acquisition_completeness === "visual_only"
        || typeof text !== "string" || text.trim().length === 0) return false;
  } else if (text !== undefined) return false;
  if (selection.kind === "visual_only" && (
    selection.acquisition_completeness !== "visual_only"
    || selection.acquisition !== "visual_highlight"
  )) return false;
  if (selection.kind !== "visual_only"
      && selection.acquisition_completeness === "visual_only") return false;

  const originalUnits = selection.original_utf16_units!;
  const textUnits = text?.length ?? 0;
  if (selection.wire_truncated ? originalUnits <= textUnits : originalUnits !== textUnits) {
    return false;
  }
  const frames = selection.frames;
  if (!Array.isArray(frames) || frames.length > MAX_FRAMES
      || frames.some((frame) => !isValidFrame(frame))) return false;
  const structures = selection.structures;
  if (!Array.isArray(structures) || structures.length > MAX_STRUCTURES
      || structures.some((structure) => !isValidStructure(structure))) return false;
  return selection.kind !== "accessibility_element"
    || structures.length > 0
    || frames.length > 0;
}

export function visionSelectionFromWire(raw: VisionSelectionWire): VisionSelectionCandidate {
  return {
    kind: raw.kind!,
    text: raw.text,
    acquisitionCompleteness:
      raw.acquisition_completeness as VisionSelection["acquisitionCompleteness"],
    acquisition: raw.acquisition as VisionSelection["acquisition"],
    captureVisibility: raw.capture_visibility as VisionSelection["captureVisibility"],
    frames: raw.frames!.map((frame) => frame as VisionSelectionFrame),
    structures: raw.structures!.map((structure) => ({
      source: structure.source as "ax" | "dom",
      role: structure.role,
      label: structure.label,
      parentLabel: structure.parent_label,
      relationship: structure.relationship as VisionSelectionStructure["relationship"],
      states: structure.states!,
      actions: structure.actions!,
      frame: structure.frame as VisionSelectionFrame | undefined,
      coverage: structure.coverage as VisionSelectionStructure["coverage"],
    })),
    wireTruncated: raw.wire_truncated!,
    originalUTF16Units: raw.original_utf16_units!,
  };
}

function isValidStructure(
  structure: NonNullable<VisionSelectionWire["structures"]>[number],
): boolean {
  const relationships = new Set([
    "selection_container", "intersects_selection", "surrounding_context",
  ]);
  const coverage = new Set(["whole", "partial", "context", "unknown"]);
  if ((structure.source !== "ax" && structure.source !== "dom")
      || !relationships.has(structure.relationship ?? "")
      || !coverage.has(structure.coverage ?? "")) return false;
  const fields: Array<[unknown, number]> = [
    [structure.role, MAX_ROLE_UTF16_UNITS],
    [structure.label, MAX_LABEL_UTF16_UNITS],
    [structure.parent_label, MAX_LABEL_UTF16_UNITS],
  ];
  if (fields.some(([field, limit]) => field !== undefined && (
    typeof field !== "string" || field.trim().length === 0
    || field.length > limit || hasForbiddenControlCharacters(field)
  ))) return false;
  if (!isValidStringArray(structure.states) || !isValidStringArray(structure.actions)) {
    return false;
  }
  if (structure.frame !== undefined && !isValidFrame(structure.frame)) return false;
  return structure.role !== undefined || structure.label !== undefined
    || structure.parent_label !== undefined || structure.frame !== undefined
    || structure.states.length > 0 || structure.actions.length > 0;
}

function isValidStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.length <= MAX_ARRAY_ITEMS
    && value.every((item) => typeof item === "string" && item.trim().length > 0
      && item.length <= MAX_ROLE_UTF16_UNITS && !hasForbiddenControlCharacters(item));
}

function isValidFrame(frame: Partial<VisionSelectionFrame>): frame is VisionSelectionFrame {
  if (typeof frame !== "object" || frame === null || Array.isArray(frame)) return false;
  const { x, y, width, height } = frame;
  return typeof x === "number" && Number.isFinite(x) && x >= 0 && x <= MAX_COORDINATE
    && typeof y === "number" && Number.isFinite(y) && y >= 0 && y <= MAX_COORDINATE
    && typeof width === "number" && Number.isFinite(width) && width > 0 && width <= MAX_COORDINATE
    && typeof height === "number" && Number.isFinite(height) && height > 0 && height <= MAX_COORDINATE;
}

function hasForbiddenControlCharacters(value: string): boolean {
  return /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/u.test(value);
}

export type LegacyVisionFocusTarget = {
  kind: "selected_text" | "accessibility_element" | "region";
  text?: string;
  role?: string;
  label?: string;
  frame?: VisionSelectionFrame;
  source: "ax_selected_text" | "ax_element" | "user_region";
  truncated: boolean;
};

/**
 * Permanent compatibility adapter and the single place where a request becomes
 * (or does not become) a Selection Extension. Once request validation has
 * completed, both old client fields and `selection` use one internal
 * representation and one prompt path.
 */
export function normalizeVisionSelection(input: {
  selection?: VisionSelectionCandidate;
  focusTarget?: LegacyVisionFocusTarget;
  /**
   * Accepted from published clients and deliberately ignored. The client never
   * looks at the screenshot, so this flag was always a guess about whether a
   * highlight might be visible, never an observation of one.
   */
  visualSelectionHint?: boolean;
}): VisionSelection | undefined {
  const candidate = input.selection ?? legacySelectedText(input.focusTarget);
  // A Selection Extension needs text the user actually selected. Failed
  // acquisition, a timeout, a focused element, an `AXSelected` current item,
  // and a possible on-screen highlight are not evidence of a selection. Those
  // requests are ordinary Vision, which is the complete product surface rather
  // than a degraded one, so the kinds that carry no text are dropped here.
  if (candidate?.kind !== "text") return undefined;
  const text = candidate.text;
  if (typeof text !== "string" || text.trim().length === 0) return undefined;
  return { ...candidate, kind: "text", text };
}

function legacySelectedText(
  target: LegacyVisionFocusTarget | undefined,
): VisionSelectionCandidate | undefined {
  if (target?.kind !== "selected_text") return undefined;
  return {
    kind: "text",
    text: target.text,
    structures: legacyStructures(target),
    frames: target.frame ? [target.frame] : [],
    acquisitionCompleteness: target.truncated ? "partial" : "complete",
    acquisition: "ax_selected_text",
    captureVisibility: target.frame ? "visible" : "unknown",
    // The legacy payload did not carry the original length. Its `truncated`
    // bit therefore describes incomplete acquisition, not a measurable
    // truncation performed by this new wire contract.
    wireTruncated: false,
    originalUTF16Units: target.text?.length ?? 0,
  };
}

function legacyStructures(target: LegacyVisionFocusTarget): VisionSelectionStructure[] {
  if (!target.role && !target.label && !target.frame) return [];
  return [{
    source: "ax",
    role: target.role,
    label: target.label,
    relationship: "selection_container",
    states: [],
    actions: [],
    frame: target.frame,
    // Legacy payloads did not report range coverage. Never infer that their
    // short label names the selected text.
    coverage: "unknown",
  }];
}
