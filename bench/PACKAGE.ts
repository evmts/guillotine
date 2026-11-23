import { Smithers as S } from "@smthrs/targets"
import { zigEnv, zigMicroBench, zigTools } from "./package-helpers.ts"
import { Package as shared } from "./shared/PACKAGE.ts"
import { Package as stackPkg } from "../src/stack/PACKAGE.ts"
import { Package as memoryPkg } from "../src/memory/PACKAGE.ts"
import { Package as bytecodePkg } from "../src/bytecode/PACKAGE.ts"
import { Package as layer2Pkg } from "../src/layer2/PACKAGE.ts"
import { Package as providerPkg } from "../src/provider/PACKAGE.ts"
import { Package as storagePkg } from "../src/storage/PACKAGE.ts"
import { Package as triePkg } from "../src/trie/PACKAGE.ts"
import { Package as eipsPkg } from "../src/eips_and_hardforks/PACKAGE.ts"
import { Package as tracerPkg } from "../src/tracer/PACKAGE.ts"
import { Package as preprocessorPkg } from "../src/preprocessor/PACKAGE.ts"

const cryptoBench = zigMicroBench({
  name: "crypto",
  iterations: 10,
  warmup: 2,
  data: [
    shared["micro-harness"],
    shared["voltaire-sources"],
    S.file("suites/crypto_bench.zig")
  ]
})

const ffiBench = zigMicroBench({
  name: "ffi",
  iterations: 20,
  warmup: 3,
  data: [
    shared["micro-harness"],
    shared["evm-root-sources"],
    S.file("//src/evm_c_api.zig"),
    S.file("//src/bytecode/bytecode_c.zig"),
    S.file("suites/ffi_bench.zig")
  ]
})

const benchEvmBuild = S.Shell.Build({
  bin: S.Host.bin("zig"),
  tools: zigTools,
  env: zigEnv,
  args: ["build", "bench-build", "--prefix", "zig-out/bench-evm"],
  data: [shared["evm-bench-harness"], shared["evm-root-sources"]],
  outFiles: ["//zig-out/bench-evm/bin/guillotine-bench"],
  sandbox: "none",
  timeout: "1h"
})

const benchEvmPragueBuild = S.Shell.Build({
  bin: S.Host.bin("zig"),
  tools: zigTools,
  env: zigEnv,
  args: ["build", "bench-build", "-Dbench-hardfork=PRAGUE", "--prefix", "zig-out/bench-evm-prague"],
  data: [shared["evm-bench-harness"], shared["evm-root-sources"]],
  outFiles: ["//zig-out/bench-evm-prague/bin/guillotine-bench"],
  sandbox: "none",
  timeout: "1h"
})

const benchOpcodes = S.Shell.Test({
  bin: benchEvmBuild,
  args: ["--filter", "opcode/", "--iterations", "40", "--warmup", "8", "--json", "bench/results/opcodes.json"],
  exclusive: true,
  sandbox: "none",
  timeout: "15m",
  outFiles: ["//bench/results/opcodes.json"]
})

const benchContracts = S.Shell.Test({
  bin: benchEvmPragueBuild,
  args: ["--filter", "contract/", "--iterations", "10", "--warmup", "2", "--json", "bench/results/contracts.json"],
  data: [shared["fixtures-sources"]],
  exclusive: true,
  sandbox: "none",
  timeout: "15m",
  outFiles: ["//bench/results/contracts.json"]
})

const benchPrecompiles = S.Shell.Test({
  bin: benchEvmBuild,
  args: [
    "--filter",
    "precompile/",
    "--allow-unavailable",
    "--iterations",
    "5",
    "--warmup",
    "1",
    "--json",
    "bench/results/precompiles.json"
  ],
  exclusive: true,
  sandbox: "none",
  timeout: "15m",
  outFiles: ["//bench/results/precompiles.json"]
})

const testBench = S.Shell.Test({
  bin: S.Host.bin("zig"),
  tools: zigTools,
  env: zigEnv,
  args: ["build", "test-bench", "test-micro-bench"],
  data: [shared["micro-harness"], shared["evm-bench-harness"]],
  sandbox: "none",
  timeout: "15m"
})

const allBenchTargets = [
  stackPkg.bench,
  memoryPkg.bench,
  bytecodePkg.bench,
  layer2Pkg.bench,
  providerPkg.bench,
  storagePkg.bench,
  triePkg.bench,
  eipsPkg.bench,
  tracerPkg.bench,
  tracerPkg["bench-minimal-evm"],
  preprocessorPkg.bench,
  cryptoBench.bench,
  ffiBench.bench,
  benchOpcodes,
  benchContracts,
  benchPrecompiles
]

const report = S.Shell.Test({
  bin: S.Host.bin("node"),
  args: [
    "bench/summary.mjs",
    "--results-dir",
    "bench/results",
    "--baseline",
    "bench/baseline.json",
    "--out-md",
    "bench/results/summary.md",
    "--out-json",
    "bench/results/all.json"
  ],
  data: [...allBenchTargets, S.file("summary.mjs"), S.file("baseline.json")],
  exclusive: true,
  sandbox: "none",
  timeout: "5m",
  outFiles: ["//bench/results/summary.md", "//bench/results/all.json"]
})

export const Package = S.Package({
  targets: {
    "test-bench": testBench,
    "bench-crypto-build": cryptoBench.benchBuild,
    "bench-crypto": cryptoBench.bench,
    "bench-ffi-build": ffiBench.benchBuild,
    "bench-ffi": ffiBench.bench,
    "bench-evm-build": benchEvmBuild,
    "bench-evm-prague-build": benchEvmPragueBuild,
    "bench-opcodes": benchOpcodes,
    "bench-contracts": benchContracts,
    "bench-precompiles": benchPrecompiles,
    report
  }
})
