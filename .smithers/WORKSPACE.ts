// Guillotine Smithers Cloud workspace declaration.
// Connects local builds and CI to the shared Smithers Cloud object store
// (https://build.smithers.sh) with split read/write trust credentials:
//   - Untrusted contributor runs and fork PRs receive SMITHERS_CACHE_READ_TOKEN only.
//   - Only trusted main-branch or maintainer-controlled sandbox runs receive
//     SMITHERS_CACHE_WRITE_TOKEN to publish cache results.
import { Smithers as S } from "@smthrs/targets"

export const Workspace = S.Workspace("evmts-guillotine", {
  repository: "evmts/guillotine",
  cache: S.Cache({
    directory: ".smithers/cache",
    hostDirectories: ["target", ".zig-cache", "zig-out", "docs/node_modules", "sdks/typescript/node_modules"],
    remote: S.RemoteCache.make({
      endpoint: "https://build.smithers.sh",
      read: S.Secret("SMITHERS_CACHE_READ_TOKEN"),
      write: S.Secret("SMITHERS_CACHE_WRITE_TOKEN")
    })
  }),
  toolchains: [
    S.Rust.Toolchain({
      workspace: S.file("//Cargo.toml"),
      channel: "stable",
      lockfile: S.file("//Cargo.lock")
    })
  ],
  host: S.Host({ bins: ["zig", "cargo", "rustc", "cc", "make", "node", "bun", "python3", "sh"] }),
  discovery: {
    prune: [
      "target",
      ".zig-cache",
      "zig-out",
      "zig-pkg",
      ".cache",
      ".flows",
      ".uphill",
      ".fuzz-crashes",
      ".smithers/cache",
      ".smithers/reports",
      ".smithers/node_modules",
      "docs/node_modules",
      "docs/dist",
      "docs/.vocs",
      "sdks/typescript/node_modules",
      "sdks/typescript/dist",
      "sdks/typescript/prebuilds",
      "sdks/c/build",
      "verify/lean/.lake",
      "bench/blocks/runners/revm/target",
      "bench/compare/engines",
      "profile_results"
    ]
  }
})
