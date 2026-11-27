# Smithers Cloud MCP & One-Time Sandbox Auth

Guillotine runs a public, authenticated Smithers Cloud MCP server at:

```text
https://smithers.sh/evmts/guillotine/mcp
```

Agents working on Guillotine, ZEVM, and Voltaire interact with Smithers Cloud through MCP to inspect repository files, read documentation, list and trigger flows, manage TODOs, issues, pull requests, and stacked changesets, and publish engineering artifacts.

## 1. Connect Your Coding Agent (OAuth 2.1 DCR + PKCE)

- **Claude Code**:
  ```bash
  claude mcp add --transport http smithers-guillotine https://smithers.sh/evmts/guillotine/mcp
  ```
- **Codex CLI**:
  ```bash
  codex mcp add smithers-guillotine --url https://smithers.sh/evmts/guillotine/mcp
  ```
- **Cursor / Antigravity / generic MCP clients**:
  Import `.smithers/mcp/clients.json` or point your Streamable HTTP client at `https://smithers.sh/evmts/guillotine/mcp`.

Verify live connectivity at any time:

```bash
node scripts/smithers-auth.mjs verify
```

## 2. One-Time-Use Sandbox & BYOA Agent Authentication

For ephemeral sandboxes and one-off agent runs, Smithers Cloud mints a single-use, 10-minute Crockford base32 attach reference (`XXXX-XXXX`). The reference carries zero authority by itself until the human verifies the 6-digit pairing code in their browser session.

```bash
# Print a ready-to-paste attach prompt for an agent or sandbox
node scripts/smithers-auth.mjs print-prompt --ref K7QF-2MXD --client guillotine-sandbox

# Step 1 (inside sandbox): claim the reference with an RFC 7636 PKCE S256 challenge
node scripts/smithers-auth.mjs claim --ref K7QF-2MXD --client guillotine-sandbox

# Step 2 (human in browser): enter the 6-digit pairing code on smithers.sh/evmts/guillotine

# Step 3 (inside sandbox): redeem the one-time code into a mode-0600 token file
node scripts/smithers-auth.mjs redeem --code <ONE_TIME_CODE>
```

Security invariants enforced by the protocol and `scripts/smithers-auth.mjs`:

1. Bearer tokens (`sma_...` / `smat_...`) are written strictly to mode-`0600` files under `.smithers/.auth/` (gitignored) and never printed to stdout or passed on `argv`.
2. Every agent grant carries `act: "agent"`. Person-only actions (`approve`, `merge`, `secret` writes, token minting, and role changes) are always refused with `403 person_only`.
3. Untrusted sandboxes and fork PRs run with attenuated environments (`node scripts/smithers-auth.mjs sandbox-env --trust untrusted`) that strip `SMITHERS_CACHE_WRITE_TOKEN`, `NPM_TOKEN`, `VERCEL_TOKEN`, `SMITHERS_FEED_KEY`, and `GH_TOKEN` while keeping read-only cache access enabled.

## 3. Dogfooding Across the Stack (Guillotine, ZEVM, Voltaire)

`.smithers/mcp/clients.json` registers all three repositories so an agent working on `evmts/zevm` or `evmts/voltaire` can query Guillotine's docs, issues, PRs, flows, and TODOs directly over MCP without ad-hoc scraping.
