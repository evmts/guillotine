import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import { execFileSync } from "node:child_process";

const ROOT = resolve(import.meta.dirname, "..", "..");

test("wiki build-feed.mjs --check passes with 8 grounded pages and zero broken wikilinks", () => {
  const out = execFileSync("node", [".smithers/wiki/build-feed.mjs", "--check"], {
    cwd: ROOT,
    encoding: "utf8",
  });
  assert.match(out, /Wiki ok: 8 pages/i);
});

test("wiki config lists Mythical-History and Overview and docs/public/wiki.html is generated", () => {
  const cfg = JSON.parse(readFileSync(resolve(ROOT, ".smithers/wiki/coding-project.json"), "utf8"));
  assert.equal(cfg.repository, "evmts/guillotine");
  assert.ok(cfg.pages.length >= 8);
  const paths = new Set(cfg.pages.map((p) => p.path));
  assert.ok(paths.has("Overview.md"));
  assert.ok(paths.has("Mythical-History.md"));
  assert.ok(paths.has("Trust-Model-and-Factory.md"));

  const htmlPath = resolve(ROOT, "docs/public/wiki.html");
  assert.ok(existsSync(htmlPath));
  const html = readFileSync(htmlPath, "utf8");
  assert.ok(html.length > 5000);
  assert.match(html, /Mythical History/);
  assert.doesNotMatch(html, /\/Users\/[A-Za-z0-9_.-]+\//);
  assert.doesNotMatch(html, /ghp_[A-Za-z0-9]{20,}/);
});
