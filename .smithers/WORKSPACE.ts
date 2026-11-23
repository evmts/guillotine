// Current smthrs discovers this file; WORKSPACE.smithers is a compatibility entry.
import { Smithers as S } from "@smthrs/targets"

export const Workspace = S.Workspace("evmts-guillotine", {
  repository: "evmts/guillotine",
  cache: S.Cache({
    directory: ".smithers/cache",
    hostDirectories: ["target", ".zig-cache", "zig-out", "bench/results"]
  }),
  toolchains: [S.Rust.Toolchain({ workspace: S.file("//Cargo.toml"), channel: "stable", lockfile: S.file("//Cargo.lock") })],
  host: S.Host({ bins: ["zig", "cargo", "rustc", "cc", "node"] }),
  discovery: { prune: ["target", ".zig-cache", "zig-out", "bench/results"] }
})
