#!/usr/bin/env node
/**
 * Smithers Cloud MCP & One-Time Sandbox Auth CLI for evmts/guillotine.
 *
 * Implements:
 *   - RFC 7636 PKCE S256 generation
 *   - BYOA one-time attach claim & redeem (/api/attach/claim, /api/attach/redeem)
 *     with mode-0600 credential storage (never echoes bearer tokens to stdout)
 *   - Ready-to-paste BYOA prompts for Claude Code, Codex, Cursor, and Antigravity
 *   - Attenuated sandbox environment isolation (--trust untrusted|trusted)
 *   - Live verification of Smithers Cloud MCP, OAuth metadata, cache, and docs
 */

import { createHash, randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..");

export const DEFAULT_HOST = "https://smithers.sh";
export const DEFAULT_REPO = "evmts/guillotine";
export const DEFAULT_CACHE_ENDPOINT = "https://build.smithers.sh";
export const DEFAULT_DOCS_LLMS = "https://guillotine.tevm.sh/llms.txt";

// Crockford base32 without I, L, O, U (matches smithers Attach.vibe)
export const REFERENCE_PATTERN = /^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/;
export const S256_CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/;

export const UNTRUSTED_FORBIDDEN_ENV_KEYS = [
  "SMITHERS_CACHE_WRITE_TOKEN",
  "SMITHERS_FEED_KEY",
  "NPM_TOKEN",
  "NODE_AUTH_TOKEN",
  "VERCEL_TOKEN",
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "ANTHROPIC_API_KEY",
  "OPENAI_API_KEY",
  "AWS_SECRET_ACCESS_KEY",
];

function base64Url(buf) {
  return buf.toString("base64").replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function generatePkce() {
  const verifier = base64Url(randomBytes(32));
  const challenge = computeS256Challenge(verifier);
  if (!S256_CHALLENGE_PATTERN.test(challenge)) {
    throw new Error("Generated PKCE S256 challenge failed canonical RFC 7636 check");
  }
  return { verifier, challenge, method: "S256" };
}

export function computeS256Challenge(verifier) {
  if (typeof verifier !== "string" || verifier.length < 43 || verifier.length > 128) {
    throw new Error("PKCE verifier must be 43 to 128 characters");
  }
  return base64Url(createHash("sha256").update(verifier, "ascii").digest());
}

export function normalizeReference(raw) {
  const cleaned = String(raw ?? "")
    .trim()
    .toUpperCase()
    .replace(/\s+/g, "");
  const formatted =
    cleaned.length === 8 && !cleaned.includes("-")
      ? `${cleaned.slice(0, 4)}-${cleaned.slice(4)}`
      : cleaned;
  if (!REFERENCE_PATTERN.test(formatted)) {
    throw new Error(
      `Invalid attach reference "${raw}". Expected Crockford base32 format XXXX-XXXX (excluding I, L, O, U).`,
    );
  }
  return formatted;
}

export function writeSecretFile(filePath, payload) {
  mkdirSync(dirname(filePath), { recursive: true });
  const content = typeof payload === "string" ? payload : JSON.stringify(payload, null, 2) + "\n";
  writeFileSync(filePath, content, { encoding: "utf8", mode: 0o600 });
  chmodSync(filePath, 0o600);
  return filePath;
}

export function buildSandboxEnv({ trust = "untrusted", env = process.env, host = DEFAULT_HOST, repo = DEFAULT_REPO } = {}) {
  if (trust !== "untrusted" && trust !== "trusted") {
    throw new Error(`Invalid trust tier "${trust}". Expected "untrusted" or "trusted".`);
  }

  const strippedKeys = [];
  const allowed = {
    SMITHERS_TRUST: trust,
    SMITHERS_REPO: repo,
    SMITHERS_MCP_URL: `${host}/${repo}/mcp`,
    SMITHERS_CACHE_ENDPOINT: DEFAULT_CACHE_ENDPOINT,
    SMITHERS_CACHE_MODE: trust === "trusted" ? "read-write" : "read-only",
  };

  if (env.SMITHERS_CACHE_READ_TOKEN) {
    allowed.SMITHERS_CACHE_READ_TOKEN = env.SMITHERS_CACHE_READ_TOKEN;
  }

  if (trust === "trusted") {
    if (env.SMITHERS_CACHE_WRITE_TOKEN) {
      allowed.SMITHERS_CACHE_WRITE_TOKEN = env.SMITHERS_CACHE_WRITE_TOKEN;
    }
  } else {
    for (const key of UNTRUSTED_FORBIDDEN_ENV_KEYS) {
      if (key in env && env[key]) {
        strippedKeys.push(key);
      }
      delete allowed[key];
    }
  }

  return {
    trust,
    cacheMode: allowed.SMITHERS_CACHE_MODE,
    env: allowed,
    strippedKeys,
  };
}

export function formatAttachPrompt({
  host = DEFAULT_HOST,
  repo = DEFAULT_REPO,
  ref = null,
  client = "agent",
} = {}) {
  const mcpUrl = `${host}/${repo}/mcp`;
  const lines = [
    `Connect to the Smithers Cloud MCP server for ${repo}:`,
    `  Endpoint: ${mcpUrl}`,
    `  Auth: OAuth 2.1 DCR + PKCE S256 (or one-time BYOA attach reference)`,
    `  Trust boundary: Agent grants carry act="agent". Person-only gates (approve, merge, secrets, role grants) stay human-only.`,
  ];

  if (ref) {
    const normalized = normalizeReference(ref);
    lines.push(
      ``,
      `One-time attach reference: ${normalized}`,
      `1. Claim the reference with PKCE S256:`,
      `   node scripts/smithers-auth.mjs claim --ref ${normalized} --client ${client}`,
      `2. Show the 6-digit pairing code to the maintainer in the Smithers Cloud browser UI.`,
      `3. Redeem the one-time approval code into a mode-0600 token file:`,
      `   node scripts/smithers-auth.mjs redeem --code <ONE_TIME_CODE>`,
    );
  } else {
    lines.push(
      ``,
      `Quick client registration:`,
      `  Claude Code: claude mcp add --transport http smithers-guillotine ${mcpUrl}`,
      `  Codex CLI:   codex mcp add smithers-guillotine --url ${mcpUrl}`,
      `  Cursor / IDE: add {"url": "${mcpUrl}"} in .smithers/mcp/clients.json`,
      `  Sandbox one-time attach: open ${host}/${repo} -> Attach Agent -> mint a 10-minute XXXX-XXXX reference`,
    );
  }

  return lines.join("\n");
}

function parseFlags(argv) {
  const flags = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith("--")) {
      const key = arg.slice(2);
      const next = argv[i + 1];
      if (!next || next.startsWith("--")) {
        flags[key] = true;
      } else {
        flags[key] = next;
        i++;
      }
    } else {
      positional.push(arg);
    }
  }
  return { flags, positional };
}

async function runClaim(flags) {
  const host = String(flags.host || DEFAULT_HOST).replace(/\/$/, "");
  const reference = normalizeReference(flags.ref);
  const client = String(flags.client || "guillotine-sandbox").slice(0, 128);
  const statePath = resolve(String(flags.state || join(REPO_ROOT, ".smithers/.auth/claim-state.json")));

  const pkce = generatePkce();
  const res = await fetch(`${host}/api/attach/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ reference, client, challenge: pkce.challenge }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`Claim failed (${res.status}): ${body.error || JSON.stringify(body)}`);
  }

  writeSecretFile(statePath, {
    host,
    reference,
    client,
    claim: body.claim,
    verifier: pkce.verifier,
    createdAt: new Date().toISOString(),
  });

  console.log(
    JSON.stringify(
      {
        status: "claimed",
        pairingCode: body.pairing,
        stateFile: statePath,
        nextStep: "Enter the 6-digit pairingCode in your Smithers Cloud browser session, then run redeem --code <CODE>.",
      },
      null,
      2,
    ),
  );
}

async function runRedeem(flags) {
  const code = String(flags.code || "").trim();
  if (!code) throw new Error("Missing --code <one-time-code>");
  const statePath = resolve(String(flags.state || join(REPO_ROOT, ".smithers/.auth/claim-state.json")));
  const outPath = resolve(String(flags.out || join(REPO_ROOT, ".smithers/.auth/token.json")));
  if (!existsSync(statePath)) {
    throw new Error(`Missing claim state file: ${statePath}. Run claim first.`);
  }

  const state = JSON.parse(readFileSync(statePath, "utf8"));
  const host = String(flags.host || state.host || DEFAULT_HOST).replace(/\/$/, "");

  const res = await fetch(`${host}/api/attach/redeem`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      claim: state.claim,
      code,
      verifier: state.verifier,
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`Redeem failed (${res.status}): ${body.error || JSON.stringify(body)}`);
  }

  const mcpUrl = body.mcpPath ? `${host}${body.mcpPath}` : `${host}/${DEFAULT_REPO}/mcp`;
  writeSecretFile(outPath, {
    host,
    mcpUrl,
    token: body.token,
    grant: body.grant ?? null,
    redeemedAt: new Date().toISOString(),
  });

  // Burn spent PKCE verifier immediately
  try {
    unlinkSync(statePath);
  } catch {
    // Already removed
  }

  console.log(
    JSON.stringify(
      {
        status: "redeemed",
        mcpUrl,
        act: body.grant?.act ?? "agent",
        expiresAt: body.grant?.expiresAt ?? null,
        tokenFile: outPath,
        fileMode: "0600",
      },
      null,
      2,
    ),
  );
}

async function probe(name, url, init) {
  try {
    const res = await fetch(url, init);
    const text = await res.text();
    return {
      name,
      url,
      status: res.status,
      ok: res.ok,
      contract: res.headers.get("smithers-cache-contract") || undefined,
      sample: text.slice(0, 180),
    };
  } catch (err) {
    return {
      name,
      url,
      status: 0,
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

async function runVerify(flags) {
  const host = String(flags.host || DEFAULT_HOST).replace(/\/$/, "");
  const repo = String(flags.repo || DEFAULT_REPO);

  const checks = await Promise.all([
    probe("mcp-tools-list", `${host}/${repo}/mcp`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
    }),
    probe("oauth-protected-resource", `${host}/.well-known/oauth-protected-resource`),
    probe("oauth-authorization-server", `${host}/.well-known/oauth-authorization-server`),
    probe("repo-role", `${host}/api/repos/${repo}/role`),
    probe("docs-llms-txt", DEFAULT_DOCS_LLMS),
    probe("remote-cache", DEFAULT_CACHE_ENDPOINT),
  ]);

  const summary = checks.map((c) => {
    const pass =
      c.name === "remote-cache"
        ? Boolean(c.contract) || c.status === 401 || c.status === 200 || c.status === 404
        : c.ok;
    return {
      name: c.name,
      url: c.url,
      status: c.status,
      pass,
      ...(c.contract ? { contract: c.contract } : {}),
      ...(c.error ? { error: c.error } : {}),
    };
  });

  console.log(JSON.stringify({ host, repo, checks: summary }, null, 2));
  if (summary.some((c) => !c.pass)) {
    process.exit(1);
  }
}

function runSandboxEnv(flags) {
  const trust = String(flags.trust || "untrusted");
  const result = buildSandboxEnv({ trust });
  if (flags.out) {
    const outPath = resolve(String(flags.out));
    const lines = Object.entries(result.env).map(([k, v]) => `${k}=${v}`);
    writeSecretFile(outPath, lines.join("\n") + "\n");
    console.log(
      JSON.stringify(
        {
          trust: result.trust,
          cacheMode: result.cacheMode,
          writtenKeys: Object.keys(result.env),
          strippedKeys: result.strippedKeys,
          outFile: outPath,
          fileMode: "0600",
        },
        null,
        2,
      ),
    );
    return;
  }

  // Never print raw token values to stdout; redact secrets while showing key availability
  const redacted = Object.fromEntries(
    Object.entries(result.env).map(([k, v]) => [k, k.includes("TOKEN") ? "<redacted>" : v]),
  );
  console.log(
    JSON.stringify(
      {
        trust: result.trust,
        cacheMode: result.cacheMode,
        env: redacted,
        strippedKeys: result.strippedKeys,
      },
      null,
      2,
    ),
  );
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const { flags } = parseFlags(rest);

  switch (cmd) {
    case "pkce":
      console.log(JSON.stringify(generatePkce(), null, 2));
      return;
    case "print-prompt":
      console.log(
        formatAttachPrompt({
          host: flags.host ? String(flags.host) : DEFAULT_HOST,
          repo: flags.repo ? String(flags.repo) : DEFAULT_REPO,
          ref: flags.ref ? String(flags.ref) : null,
          client: flags.client ? String(flags.client) : "agent",
        }),
      );
      return;
    case "claim":
      await runClaim(flags);
      return;
    case "redeem":
      await runRedeem(flags);
      return;
    case "sandbox-env":
      runSandboxEnv(flags);
      return;
    case "verify":
      await runVerify(flags);
      return;
    default:
      console.log(`Guillotine Smithers Cloud Auth & MCP CLI

Commands:
  pkce                                    Generate RFC 7636 PKCE S256 verifier + challenge
  print-prompt [--ref XXXX-XXXX]          Print BYOA MCP attach instructions and client commands
  claim --ref XXXX-XXXX [--client NAME]   Claim a 10-minute attach reference with PKCE S256
  redeem --code CODE [--out FILE]         Redeem approval code into a mode-0600 token file
  sandbox-env --trust untrusted|trusted   Inspect or write attenuated sandbox environment bindings
  verify [--host URL] [--repo ORG/REPO]   Live-check Smithers Cloud MCP, OAuth, cache, and docs`);
      process.exit(cmd ? 1 : 0);
  }
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
