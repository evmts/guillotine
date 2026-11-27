import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

const ROOT = resolve(import.meta.dirname, "..", "..");

function readJson(rel) {
  return JSON.parse(readFileSync(resolve(ROOT, rel), "utf8"));
}

function walkProse(value, key = "", acc = []) {
  if (key === "code" || key === "url" || key === "href" || key === "docs") return acc;
  if (typeof value === "string") {
    if (!value.startsWith("http://") && !value.startsWith("https://")) acc.push(value);
  } else if (Array.isArray(value)) {
    for (const item of value) walkProse(item, key, acc);
  } else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) walkProse(v, k, acc);
  }
  return acc;
}

test("factory.json has apiVersion 1, person-only approvals, flows, rules, and views", () => {
  const f = readJson(".smithers/factory.json");
  assert.equal(f.apiVersion, 1);
  assert.ok(Array.isArray(f.flows) && f.flows.length >= 8, `expected >= 8 flows, got ${f.flows?.length}`);
  assert.ok(Array.isArray(f.on) && f.on.length >= 6, `expected >= 6 dispatch rules, got ${f.on?.length}`);
  assert.ok(Array.isArray(f.issueViews) && f.issueViews.length >= 5);
  assert.ok(Array.isArray(f.issueTransitions) && f.issueTransitions.length >= 3);
  assert.equal(f.policy?.approvals?.approve, "person");
  assert.equal(f.policy?.approvals?.merge, "person");
  assert.equal(f.github?.mirror, "pull");
  assert.equal(f.github?.issues, "two-way");
  assert.ok(f.github?.maintainers?.includes("roninjin10"));
});

test("home.json configures docs llms.txt, role-based contributors, and all three audiences", () => {
  const h = readJson(".smithers/home.json");
  assert.equal(h.docs, "https://guillotine.tevm.sh/llms.txt");
  assert.equal(h.contributors, "role");
  const audiences = new Set((h.sections ?? []).map((s) => s.audience));
  assert.deepEqual([...audiences].sort(), ["contributor", "everyone", "maintainer"]);

  for (const section of h.sections) {
    assert.ok(Array.isArray(section.blocks) && section.blocks.length >= 4, `section ${section.audience} too sparse`);
  }

  const prose = walkProse(h);
  assert.ok(prose.length > 20);
  for (const text of prose) {
    assert.doesNotMatch(text, /[;\u2014]/, `forbidden semicolon or em dash in home.json prose: ${text}`);
    assert.doesNotMatch(text, /jjhub/i, `forbidden jjhub mention in home.json prose: ${text}`);
    assert.doesNotMatch(text, /<\/?[a-z][^>]*>/i, `raw HTML in home.json prose: ${text}`);
  }
});

test("WORKSPACE.ts configures shared Smithers Cloud object store with split read/write secrets", () => {
  const ws = readFileSync(resolve(ROOT, ".smithers/WORKSPACE.ts"), "utf8");
  assert.match(ws, /https:\/\/build\.smithers\.sh/);
  assert.match(ws, /SMITHERS_CACHE_READ_TOKEN/);
  assert.match(ws, /SMITHERS_CACHE_WRITE_TOKEN/);
});

test("ci.yml never exposes SMITHERS_CACHE_WRITE_TOKEN to pull_request jobs", () => {
  const ci = readFileSync(resolve(ROOT, ".github/workflows/ci.yml"), "utf8");
  const writeLines = ci
    .split("\n")
    .filter((l) => l.includes("SMITHERS_CACHE_WRITE_TOKEN") && !l.trim().startsWith("#"));
  assert.ok(writeLines.length >= 2, "expected SMITHERS_CACHE_WRITE_TOKEN gating in ci.yml");
  for (const line of writeLines) {
    assert.match(line, /github\.event_name == 'push' && github\.ref == 'refs\/heads\/main'/);
  }
});
