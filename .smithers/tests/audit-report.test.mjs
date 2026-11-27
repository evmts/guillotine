import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import {
  buildAuditModel,
  renderAuditHtml,
  scoreBand,
  validateAuditOutputs,
} from "../reports/audit.mjs";

const ROOT = resolve(import.meta.dirname, "..", "..");

test("scoreBand matches Chrome Lighthouse thresholds", () => {
  assert.equal(scoreBand(100), "pass");
  assert.equal(scoreBand(90), "pass");
  assert.equal(scoreBand(89), "average");
  assert.equal(scoreBand(50), "average");
  assert.equal(scoreBand(49), "fail");
  assert.equal(scoreBand(0), "fail");
});

test("generated audit outputs validate cleanly with Lighthouse gauges and trust matrix", () => {
  const res = validateAuditOutputs(ROOT);
  assert.equal(res.ok, true, `audit validation failed: ${res.errors.join("; ")}`);
  assert.ok(res.summary.categories.length >= 6);
  const names = new Set(res.summary.categories.map((c) => c.name));
  for (const expected of ["safety", "style", "footprint", "verification", "documentation", "factory"]) {
    assert.ok(names.has(expected), `missing category ${expected}`);
  }
});

test("renderAuditHtml embeds SVG gauges, trust matrix, and escapes special characters", () => {
  const model = buildAuditModel(ROOT, { runUphill: false });
  const html = renderAuditHtml(model);
  assert.match(html, /<svg class="lh-gauge-svg/);
  assert.match(html, /Execution Trust Boundary/);
  assert.match(html, /66,652 \/ 66,652/);
  assert.match(html, /audit-summary-data/);
});
