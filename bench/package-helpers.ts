import { Smithers as S } from "@smthrs/targets"
import { fileURLToPath } from "node:url"

export const zigEnv = {
  ZIG_GLOBAL_CACHE_DIR: fileURLToPath(new URL("../.smithers/cache/tools/zig/global", import.meta.url)),
  ZIG_LOCAL_CACHE_DIR: fileURLToPath(new URL("../.smithers/cache/tools/zig/local", import.meta.url)),
  CARGO_TARGET_DIR: "target"
}

export const zigTools = [S.Host.bin("cargo"), S.Host.bin("rustc"), S.Host.bin("cc")]

/**
 * Declares an incremental subsystem benchmark pair:
 * - `benchBuild`: ReleaseFast `Shell.Build` compiling ONLY this suite's binary into its own prefix
 * - `bench`: exclusive, cacheable `Shell.Test` executing the compiled binary and caching its JSON report
 */
export const zigMicroBench = (options: {
  readonly name: string
  readonly data: ReadonlyArray<any>
  readonly iterations?: number
  readonly warmup?: number
  readonly needsNativeTools?: boolean
  readonly timeout?: string
}) => {
  const prefix = `zig-out/bench-${options.name}`
  const binPath = `//${prefix}/bin/bench-${options.name}`
  const jsonPath = `//bench/results/${options.name}.json`
  const benchBuild = S.Shell.Build({
    bin: S.Host.bin("zig"),
    tools: options.needsNativeTools === false ? [] : zigTools,
    env: zigEnv,
    args: ["build", `bench-${options.name}-build`, "--prefix", prefix],
    data: [...options.data],
    outFiles: [binPath],
    sandbox: "none",
    timeout: "1h"
  })
  const bench = S.Shell.Test({
    bin: benchBuild,
    args: [
      "--iterations",
      String(options.iterations ?? 40),
      "--warmup",
      String(options.warmup ?? 8),
      "--json",
      `bench/results/${options.name}.json`
    ],
    exclusive: true,
    sandbox: "none",
    timeout: (options.timeout ?? "10m") as "10m",
    outFiles: [jsonPath]
  })
  return { benchBuild, bench }
}
