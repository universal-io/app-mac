import { z } from "zod";

const nonEmpty = z.string().trim().min(1);

export const rectSchema = z.strictObject({
  x: z.number().min(0),
  y: z.number().min(0),
  width: z.number().positive(),
  height: z.number().positive(),
});

export const candidateSchema = z.strictObject({
  id: nonEmpty,
  source: z.enum(["ocr", "ax", "dom", "vendor_api"]),
  role: nonEmpty.optional(),
  label: nonEmpty,
  rect: rectSchema.optional(),
  parent_label: nonEmpty.optional(),
  states: z
    .array(z.enum(["selected", "expanded", "collapsed", "disabled", "focused", "loading"]))
    .default([]),
});

export const observationSchema = z.strictObject({
  capture_id: nonEmpty,
  captured_at: z.iso.datetime(),
  app_name: nonEmpty,
  bundle_id: nonEmpty.optional(),
  window_title: nonEmpty.optional(),
  url: z.url().optional(),
  transition_state: z.enum(["stable", "waiting_for_change", "settling", "timed_out"]),
  image_path: nonEmpty.optional(),
  ocr_text: z.string().optional(),
  candidates: z.array(candidateSchema),
});

const plannerExpectationSchema = z.strictObject({
  feasible: z.boolean(),
  goal_term_groups: z.array(z.array(nonEmpty).min(1)).default([]),
  target_sequence: z.array(nonEmpty).default([]),
});

const groundingExpectationSchema = z.strictObject({
  candidate_id: nonEmpty,
});

const verifierStatusSchema = z.enum([
  "verified",
  "not_changed",
  "ambiguous",
  "blocked",
  "complete",
]);

const verifierExpectationSchema = z.strictObject({
  status: verifierStatusSchema,
});

export const navigatorFixtureCaseSchema = z.strictObject({
  id: nonEmpty,
  description: nonEmpty,
  tags: z.array(nonEmpty).default([]),
  input: z.strictObject({
    language: z.enum(["japanese", "english"]),
    question: nonEmpty,
    observation: observationSchema,
    previous_observation: observationSchema.optional(),
  }),
  expected: z.strictObject({
    planner: plannerExpectationSchema.optional(),
    grounding: groundingExpectationSchema.optional(),
    verifier: verifierExpectationSchema.optional(),
  }),
});

export const navigatorFixtureSuiteSchema = z.strictObject({
  schema_version: z.literal(1),
  suite_id: nonEmpty,
  description: nonEmpty,
  cases: z.array(navigatorFixtureCaseSchema).min(1),
});

const plannedStepSchema = z.strictObject({
  verbal: nonEmpty,
  target: nonEmpty.optional(),
  fill: z.string().optional(),
});

const plannerResultSchema = z.strictObject({
  feasible: z.boolean(),
  goal: z.string(),
  steps: z.array(plannedStepSchema),
});

const groundingResultSchema = z.strictObject({
  candidate_id: nonEmpty.nullable(),
  confidence: z.number().min(0).max(1).optional(),
});

const verifierResultSchema = z.strictObject({
  status: verifierStatusSchema,
  confidence: z.number().min(0).max(1).optional(),
  evidence_candidate_ids: z.array(nonEmpty).default([]),
});

export const navigatorEvalResultsSchema = z.strictObject({
  schema_version: z.literal(1),
  run: z.strictObject({
    run_id: nonEmpty,
    created_at: z.iso.datetime(),
    implementation: nonEmpty,
    model_provider: nonEmpty,
    model_id: nonEmpty,
    pack_versions: z.array(nonEmpty).default([]),
  }),
  cases: z.array(
    z.strictObject({
      case_id: nonEmpty,
      planner: plannerResultSchema.optional(),
      grounding: groundingResultSchema.optional(),
      verifier: verifierResultSchema.optional(),
      metrics: z
        .strictObject({
          duration_ms: z.number().nonnegative().optional(),
          input_tokens: z.number().int().nonnegative().optional(),
          output_tokens: z.number().int().nonnegative().optional(),
        })
        .optional(),
    }),
  ),
});

export type NavigatorFixtureSuite = z.infer<typeof navigatorFixtureSuiteSchema>;
export type NavigatorEvalResults = z.infer<typeof navigatorEvalResultsSchema>;
