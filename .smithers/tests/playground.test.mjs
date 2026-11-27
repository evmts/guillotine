import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

const ROOT = resolve(import.meta.dirname, "..", "..");

test("playground index.html CSP SHA-256 hashes match inline style and script bytes exactly", () => {
  const html = readFileSync(resolve(ROOT, ".smithers/playground/index.html"), "utf8");
  assert.doesNotMatch(html, /unsafe-inline/);
  const styleMatch = /<style>([\s\S]*?)<\/style>/.exec(html);
  const scriptMatch = /<script>([\s\S]*?)<\/script>/.exec(html);
  assert.ok(styleMatch && scriptMatch);

  const styleHash = `sha256-${createHash("sha256").update(styleMatch[1], "utf8").digest("base64")}`;
  const scriptHash = `sha256-${createHash("sha256").update(scriptMatch[1], "utf8").digest("base64")}`;
  assert.ok(html.includes(`'${styleHash}'`), `missing exact style CSP hash ${styleHash}`);
  assert.ok(html.includes(`'${scriptHash}'`), `missing exact script CSP hash ${scriptHash}`);
});

test("playground run.mjs analyzes bytecode and detects PUSH_MSTORE fusion", () => {
  const input = JSON.stringify({
    mode: "analyze",
    bytecode: "0x602a60005260206000f3",
    hardfork: "OSAKA",
  });
  const out = execFileSync("node", [".smithers/playground/run.mjs", input], {
    cwd: ROOT,
    encoding: "utf8",
  });
  const parsed = JSON.parse(out);
  assert.equal(parsed.mode, "analyze");
  assert.equal(parsed.hardfork, "OSAKA");
  assert.equal(parsed.instructionCount, 6);
  assert.ok(Array.isArray(parsed.fusions));
  assert.ok(parsed.fusions.some((f) => f.pattern === "PUSH_MSTORE"));
});

test("playground run.mjs rejects malformed hex bytecode cleanly", () => {
  const out = execFileSync(
    "node",
    [".smithers/playground/run.mjs", JSON.stringify({ mode: "analyze", bytecode: "0xZZZZ" })],
    {
      cwd: ROOT,
      encoding: "utf8",
    },
  );
  const parsed = JSON.parse(out);
  assert.match(parsed.error || "", /hex|invalid/i);
});
