---
title: Trust Model, Shared Cache, and Smithers Cloud Factory
tags: [smithers, security, ci, mcp]
---

# Trust Model, Shared Cache, and Smithers Cloud Factory

Guillotine runs publicly on Smithers Cloud at `https://smithers.sh/evmts/guillotine`, mirroring to `https://github.com/evmts/guillotine`. Every design decision below protects build integrity while keeping contribution completely open.

## Execution Trust Boundary

We actively encourage non-maintainers and external contributors to run builds, tests, Uphill audits, and local agents freely. At the same time, untrusted execution can never poison shared caches or bypass merge gates.

| Execution Context | Cache Read (`build.smithers.sh`) | Cache Write (`build.smithers.sh`) | Secrets | Can Satisfy Merge / Release Gate |
| --- | --- | --- | --- | --- |
| External contributor laptop / fork PR | Allowed (`SMITHERS_CACHE_READ_TOKEN`) | Denied (empty / refused 403) | None (`secrets: false`) | No (advisory evidence only) |
| Smithers-controlled sandbox on untrusted PR | Allowed (read-only) | Denied | None (`secrets: false`) | Re-verified in trusted gate |
| Maintainer run or trusted `main` push | Allowed | Allowed (`SMITHERS_CACHE_WRITE_TOKEN`) | Scoped release/CI secrets | Yes (person approves and merges) |

### How Cache Poisoning Is Prevented

1. `.smithers/WORKSPACE.ts` splits remote cache credentials into `SMITHERS_CACHE_READ_TOKEN` and `SMITHERS_CACHE_WRITE_TOKEN`.
2. `.github/workflows/ci.yml` withholds `SMITHERS_CACHE_WRITE_TOKEN` on every pull request and grants it only on trusted pushes to `refs/heads/main`.
3. `scripts/smithers-auth.mjs sandbox-env --trust untrusted` strips all write credentials and secrets before launching an untrusted agent sandbox.
4. `FACTORY.ts` lists critical consensus, build, workflow, and Uphill paths in `protectedPaths`, and enforces `approvals: { approve: "person", merge: "person" }`.

## Public Cloud MCP and One-Time-Use Authentication

- **Public MCP endpoint**: `https://smithers.sh/evmts/guillotine/mcp` (Streamable HTTP + OAuth 2.1 DCR with PKCE `S256`).
- **One-time BYOA attach**: Maintainers and contributors mint single-use 10-minute attach references (`XXXX-XXXX`), which an agent claims with a PKCE `S256` challenge and 6-digit pairing verification via `scripts/smithers-auth.mjs`. Redeeming yields an attenuated 8-hour `smat_...` bearer token written strictly to a mode-`0600` file (never passed on `argv`, never holding `person_only` authority).
- **Attribution**: Every MCP write is attributed as `<login> (agent)`. Merging, approving, committing TODOs, and rotating secrets remain strictly person-only.

## Personalized Factory UI

`.smithers/FACTORY.ts` projects `.smithers/home.json` with three audience-scoped views (`contributors: "role"`):

- **Maintainer**: New branch action (`b`), live triage and PR board, TODO and changeset stack, recent factory runs, and operations links.
- **Contributor**: Local verification commands, 4-step contribution workflow, public TODO stack, featured flows, and workspace prompt.
- **Viewer (`everyone`)**: Public showcase hero, runnable Zig example, verified EEST/benchmark/proof stats, ecosystem cards, releases, MCP endpoint, Wiki, Mythical History, and Lighthouse Audit Report.

## Automated Releases and Docs Publishing

Merging a change from Smithers Cloud to GitHub `main` triggers `.github/workflows/release.yml`:

- If `build.zig.zon` and `sdks/typescript/package.json` advance to an untagged version, GitHub Actions waits for green CI, builds stripped `ReleaseFast` macOS arm64 and Linux x86_64 (`glibc >= 2.28`) shared libraries, runs C and TypeScript SDK tests, creates the GitHub Release with `SHA256SUMS.txt`, and publishes `@tevm/guillotine` to npm with OIDC provenance.
- Whenever docs, wiki, or audit assets change on `main`, Vocs rebuilds `guillotine.tevm.sh` (including `llms.txt`, `audit.html`, and `wiki.html`) and deploys automatically when `VERCEL_TOKEN` is configured.

## Related Pages

- [[Overview]]
- [[Mythical-History]]
- [[TigerStyle-and-Safety]]
- [[Decisions]]
