# Guillotine Smithers Cloud Factory

Guillotine runs as a public Smithers Cloud coding factory at [smithers.sh/evmts/guillotine](https://smithers.sh/evmts/guillotine), mirroring to [github.com/evmts/guillotine](https://github.com/evmts/guillotine) and publishing documentation at [guillotine.tevm.sh](https://guillotine.tevm.sh).

## Architecture

| Surface | Path | Purpose |
| --- | --- | --- |
| Workspace & Shared Cache | `.smithers/WORKSPACE.ts` | Wires `https://build.smithers.sh` with split `SMITHERS_CACHE_READ_TOKEN` and `SMITHERS_CACHE_WRITE_TOKEN` |
| Incremental Build Graph | `.smithers/PACKAGE.ts` | 10 surgical filegroups and 39 content-addressed targets across Zig, Rust, C SDK, TS SDK, docs, wiki, and audit |
| Personalized Factory & Home | `.smithers/FACTORY.ts` | Generates `.smithers/factory.json` and `.smithers/home.json` tailored for Maintainers, Contributors, and Viewers |
| Cloud Workflows | `.smithers/workflows/*.ts` | QuickJS-safe workflows for CI, Uphill audit, wiki refresh, and release readiness |
| Agent Flows | `.smithers/flows/**/flow.mdx` | Bounded review, repro, PoC, PR triage, wiki refresh, release check, and playground execution flows |
| EVM Playground | `.smithers/playground/` | CSP-hardened interactive bytecode analyzer and sandboxed runner |
| Lighthouse Audit Report | `.smithers/reports/audit.mjs` | Renders Uphill backpressure telemetry into `docs/public/audit.html` and `.smithers/reports/lighthouse-audit.html` |
| Engineering Wiki & History | `.smithers/wiki/` | Obsidian-compatible knowledge base, `Mythical-History.md`, feed validator, and `docs/public/wiki.html` |
| Cloud MCP & One-Time Auth | `.smithers/mcp/`, `scripts/smithers-auth.mjs` | Live MCP verification, PKCE S256 BYOA attach claim/redeem (mode-`0600`), and attenuated sandbox env isolation |

## Common Commands

Always run from the repository root using the toolchain-aware wrapper (`scripts/smthrs` pins Zig `0.17.1`):

```bash
# List all 39 incremental build/test/lint/docs/factory targets
scripts/smthrs targets

# Validate factory.json and home.json against FACTORY.ts
scripts/smthrs target //.smithers:factory-check

# Regenerate factory.json and home.json after editing FACTORY.ts
scripts/smthrs target //.smithers:factory-write --write

# Run fast local factory, wiki, and Lighthouse backpressure checks
node .smithers/wiki/build-feed.mjs --write --check
node .smithers/reports/audit.mjs --write --run-uphill --check
node --test .smithers/tests/*.test.mjs

# Verify live Smithers Cloud MCP, OAuth, shared cache, and docs endpoints
node scripts/smithers-auth.mjs verify
```

## Execution Trust Boundaries

- **Community & fork PRs (untrusted)** are encouraged to run the full build, test, differential, and Uphill audit suites locally and in CI with **read-only** cache access (`SMITHERS_CACHE_READ_TOKEN`). They never receive `SMITHERS_CACHE_WRITE_TOKEN`, release tokens, or gate-bypass permissions.
- **Smithers Cloud sandboxes** execute deterministic checks under scoped one-time PKCE tokens (`act: "agent"`) and cannot approve or merge changes.
- **Maintainers (`roninjin10`, `fucory`) and `main`** hold person-only `approve` and `merge` gates, populate the shared cache on `main` pushes, and trigger automated GitHub Releases, npm provenance publishing, and Vocs docs deploys.
