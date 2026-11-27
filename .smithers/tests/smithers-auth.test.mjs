import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  S256_CHALLENGE_PATTERN,
  UNTRUSTED_FORBIDDEN_ENV_KEYS,
  buildSandboxEnv,
  computeS256Challenge,
  formatAttachPrompt,
  generatePkce,
  normalizeReference,
  writeSecretFile,
} from "../../scripts/smithers-auth.mjs";

test("PKCE S256 verifier and challenge conform to RFC 7636 and Attach.vibe pattern", () => {
  const pkce = generatePkce();
  assert.equal(pkce.method, "S256");
  assert.ok(pkce.verifier.length >= 43 && pkce.verifier.length <= 128);
  assert.match(pkce.challenge, S256_CHALLENGE_PATTERN);
  assert.equal(computeS256Challenge(pkce.verifier), pkce.challenge);
});

test("normalizeReference accepts Crockford base32 and rejects I, L, O, U", () => {
  assert.equal(normalizeReference("k7qf2mxd"), "K7QF-2MXD");
  assert.equal(normalizeReference(" K7QF-2MXD "), "K7QF-2MXD");
  assert.throws(() => normalizeReference("ILOU-1234"));
  assert.throws(() => normalizeReference("SHORT"));
});

test("buildSandboxEnv strictly strips write/release secrets in untrusted mode", () => {
  const dirtyEnv = {
    SMITHERS_CACHE_READ_TOKEN: "read-secret",
    SMITHERS_CACHE_WRITE_TOKEN: "write-secret",
    NPM_TOKEN: "npm-secret",
    VERCEL_TOKEN: "vercel-secret",
    GH_TOKEN: "gh-secret",
    SMITHERS_FEED_KEY: "feed-secret",
  };

  const untrusted = buildSandboxEnv({ trust: "untrusted", env: dirtyEnv });
  assert.equal(untrusted.cacheMode, "read-only");
  assert.equal(untrusted.env.SMITHERS_CACHE_READ_TOKEN, "read-secret");
  for (const key of UNTRUSTED_FORBIDDEN_ENV_KEYS) {
    assert.equal(key in untrusted.env, false, `untrusted env leaked ${key}`);
  }
  assert.ok(untrusted.strippedKeys.includes("SMITHERS_CACHE_WRITE_TOKEN"));
  assert.ok(untrusted.strippedKeys.includes("NPM_TOKEN"));

  const trusted = buildSandboxEnv({ trust: "trusted", env: dirtyEnv });
  assert.equal(trusted.cacheMode, "read-write");
  assert.equal(trusted.env.SMITHERS_CACHE_WRITE_TOKEN, "write-secret");
});

test("writeSecretFile writes credentials with strict 0600 permissions", () => {
  const dir = mkdtempSync(join(tmpdir(), "smithers-auth-test-"));
  try {
    const file = join(dir, "token.json");
    writeSecretFile(file, { token: "smat_test_redacted" });
    const mode = statSync(file).mode & 0o777;
    assert.equal(mode, 0o600);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("formatAttachPrompt produces clean MCP endpoint and one-time claim instructions", () => {
  const prompt = formatAttachPrompt({ ref: "K7QF-2MXD", client: "sandbox-ci" });
  assert.match(prompt, /https:\/\/smithers\.sh\/evmts\/guillotine\/mcp/);
  assert.match(prompt, /K7QF-2MXD/);
  assert.match(prompt, /act="agent"/);
});
