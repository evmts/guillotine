import { copyFileSync, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"
import { spawnSync } from "node:child_process"

// Voltaire is a path dependency nested under Guillotine's Cargo workspace but
// is not a member or exclusion. Stage its unchanged sources as a standalone
// Cargo workspace, without editing either repository's manifests.
mkdirSync(".smithers/cache", { recursive: true })
const stage = mkdtempSync(resolve(".smithers/cache/voltaire-"))
try {
  const manifest = readFileSync("lib/voltaire/Cargo.toml", "utf8")
  const stagedManifest = /^\s*\[workspace\]/m.test(manifest) ? manifest : `${manifest}\n[workspace]\n`
  writeFileSync(`${stage}/Cargo.toml`, stagedManifest)
  cpSync("lib/voltaire/Cargo.lock", `${stage}/Cargo.lock`)
  cpSync("lib/voltaire/src/crypto", `${stage}/src/crypto`, { recursive: true })
  const result = spawnSync("cargo", ["build", "--manifest-path", `${stage}/Cargo.toml`,
    "--release", "--locked", "--target-dir", resolve(".smithers/cache/cargo/voltaire")], { stdio: "inherit", timeout: 3600000 })
  if (result.error) throw result.error
  if (result.signal) throw new Error(`Voltaire Cargo build terminated by ${result.signal}`)
  if (result.status === 0) {
    mkdirSync("lib/voltaire/target/release", { recursive: true })
    copyFileSync(".smithers/cache/cargo/voltaire/release/libcrypto_wrappers.a",
      "lib/voltaire/target/release/libcrypto_wrappers.a")
  }
  process.exitCode = result.status
} finally {
  rmSync(stage, { recursive: true, force: true })
}
