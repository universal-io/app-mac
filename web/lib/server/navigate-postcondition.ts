import { z } from "zod";

const boundedText = z.string().trim().min(1).max(512);

export const candidateSelectorSchema = z.strictObject({
  label: boundedText,
  parent_label: boundedText.optional(),
  role: z.string().trim().min(1).max(256).optional(),
});

const candidatePresentSchema = z.strictObject({
  kind: z.literal("candidate_present"),
  selector: candidateSelectorSchema,
});

const candidateAbsentSchema = z.strictObject({
  kind: z.literal("candidate_absent"),
  selector: candidateSelectorSchema,
});

const candidateStateSchema = z.strictObject({
  kind: z.literal("candidate_state"),
  selector: candidateSelectorSchema,
  state: z.enum([
    "selected", "expanded", "collapsed", "disabled", "focused", "loading",
    "checked", "unchecked",
  ]),
});

const environmentMatchesSchema = z.strictObject({
  kind: z.literal("environment_matches"),
  url_contains: boundedText.optional(),
  window_title_contains: boundedText.optional(),
}).refine(
  (value) => Boolean(value.url_contains || value.window_title_contains),
  { message: "environment_matches requires url_contains or window_title_contains" },
);

const environmentChangedSchema = z.strictObject({
  kind: z.literal("environment_changed"),
  field: z.enum(["url", "window_title"]),
});

/** Pack v1 postconditions. Deliberately excludes arbitrary expressions,
 * model prose, coordinates, OCR blobs, and secret field values. */
export const navigatePostconditionSchema = z.discriminatedUnion("kind", [
  candidatePresentSchema,
  candidateAbsentSchema,
  candidateStateSchema,
  environmentMatchesSchema,
  environmentChangedSchema,
]);

export const navigatePostconditionsSchema = z.array(navigatePostconditionSchema).max(8);

export type CandidateSelector = z.infer<typeof candidateSelectorSchema>;
export type NavigatePostcondition = z.infer<typeof navigatePostconditionSchema>;
