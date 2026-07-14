import { z } from "zod";

const shortText = z.string().trim().min(1).max(256);
const labelText = z.string().trim().min(1).max(512);

export const normalizedRectSchema = z.strictObject({
  x: z.number().finite().min(0).max(1),
  y: z.number().finite().min(0).max(1),
  width: z.number().finite().positive().max(1),
  height: z.number().finite().positive().max(1),
}).refine((rect) => rect.x + rect.width <= 1.000_001, {
  message: "rect must fit within normalized width",
}).refine((rect) => rect.y + rect.height <= 1.000_001, {
  message: "rect must fit within normalized height",
});

export const observationCandidateSchema = z.strictObject({
  id: z.string().trim().min(1).max(160),
  source: z.enum(["ocr", "ax", "dom", "vendor_api"]),
  role: shortText.optional(),
  label: labelText,
  rect: normalizedRectSchema.optional(),
  parent_label: labelText.optional(),
  states: z
    .array(z.enum([
      "selected", "expanded", "collapsed", "disabled", "focused", "loading",
      "checked", "unchecked",
    ]))
    .max(8)
    .default([]),
});

export const visionObservationSchema = z.strictObject({
  schema_version: z.literal(1),
  capture_id: z.uuid(),
  captured_at: z.iso.datetime(),
  capture_scope: z.enum(["display", "region", "unknown"]),
  coordinate_space: z.literal("normalized_top_left"),
  pixel_size: z.strictObject({
    width: z.number().int().positive().max(32_768),
    height: z.number().int().positive().max(32_768),
  }).optional(),
  screen_rect: z.strictObject({
    x: z.number().finite(),
    y: z.number().finite(),
    width: z.number().finite().positive().max(100_000),
    height: z.number().finite().positive().max(100_000),
  }).optional(),
  environment: z.strictObject({
    app_name: shortText,
    bundle_id: shortText.optional(),
    window_title: z.string().trim().min(1).max(1_024).optional(),
    url: z.url().max(4_096).optional(),
  }).optional(),
  transition_state: z.enum(["stable", "waiting_for_change", "settling", "timed_out"]),
  candidates: z.array(observationCandidateSchema).max(500),
});

export type VisionObservation = z.infer<typeof visionObservationSchema>;
export type ObservationCandidate = z.infer<typeof observationCandidateSchema>;
