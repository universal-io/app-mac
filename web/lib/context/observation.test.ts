import { describe, expect, test } from "vitest";

import { visionObservationSchema } from "./observation";

const validObservation = {
  schema_version: 1,
  capture_id: "ca2fd38e-5bb7-4d88-8fec-9f9ae2f8c23f",
  captured_at: "2026-07-14T06:00:00.000Z",
  capture_scope: "display",
  coordinate_space: "normalized_top_left",
  pixel_size: { width: 1600, height: 1000 },
  screen_rect: { x: 0, y: 0, width: 1440, height: 900 },
  environment: {
    app_name: "Google Chrome",
    bundle_id: "com.google.Chrome",
    window_title: "アナリティクス",
    url: "https://analytics.google.com/",
  },
  transition_state: "stable",
  candidates: [
    {
      id: "ocr:0",
      source: "ocr",
      role: "text",
      label: "ユーザー属性",
      rect: { x: 0.1, y: 0.2, width: 0.2, height: 0.05 },
      states: [],
    },
  ],
} as const;

describe("Vision Observation v1", () => {
  test("accepts a bounded versioned snapshot", () => {
    expect(visionObservationSchema.parse(validObservation)).toMatchObject(validObservation);
  });

  test("rejects a candidate rectangle outside the normalized image", () => {
    const invalid = {
      ...validObservation,
      candidates: [
        {
          ...validObservation.candidates[0],
          rect: { x: 0.9, y: 0.2, width: 0.2, height: 0.05 },
        },
      ],
    };
    expect(visionObservationSchema.safeParse(invalid).success).toBe(false);
  });

  test("rejects unknown fields rather than silently changing the contract", () => {
    expect(visionObservationSchema.safeParse({ ...validObservation, tenant_id: "client-controlled" }).success)
      .toBe(false);
  });
});
