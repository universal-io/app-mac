import assert from "node:assert/strict";
import test from "node:test";

import { resolveSkills, visionSkill, suggestSkill } from "./skills/registry.ts";

// Activity Monitor is the first skill for a native macOS utility rather than a
// web product, so what is being pinned here is that the native path — bundle id
// on the frontmost app, no host at all — actually reaches a skill.
test("activity monitor is detected by bundle id alone", () => {
  const skills = resolveSkills({
    appName: "アクティビティモニタ",
    bundleId: "com.apple.ActivityMonitor",
  });
  assert.deepEqual(skills.map((skill) => skill.id), ["activity-monitor"]);
});

test("activity monitor is detected by localized and english app name", () => {
  for (const appName of ["アクティビティモニタ", "Activity Monitor"]) {
    const skills = resolveSkills({ appName });
    assert.deepEqual(skills.map((skill) => skill.id), ["activity-monitor"], appName);
  }
});

// A browser tab that merely talks about the tool is not the tool. Host-based
// products keep their screen even when the words appear in the page title.
test("a web product screen is not claimed by activity monitor", () => {
  const skills = resolveSkills({
    appName: "Google Chrome",
    windowTitle: "Activity Monitoring for GA4",
    host: "analytics.google.com",
  });
  assert.deepEqual(skills.map((skill) => skill.id), ["ga4"]);
});

// Vision is the only consumer that matters here: nothing is written in Activity
// Monitor, so the drafting path must receive reading and nothing more.
test("activity monitor injects vision sections and stays out of drafting", () => {
  const signals = { appName: "アクティビティモニタ", bundleId: "com.apple.ActivityMonitor" };

  const vision = visionSkill(signals);
  assert.equal(vision?.name, "アクティビティモニタ");
  assert.match(vision.instructions, /メモリプレッシャー/);
  assert.match(vision.instructions, /Sample Process/);

  // No conventions section exists, so drafting sees the reading rules only.
  const suggest = suggestSkill(signals);
  assert.ok(suggest);
  assert.doesNotMatch(suggest.instructions, /Sample Process/);
});
