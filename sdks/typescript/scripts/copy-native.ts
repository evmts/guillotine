// Copy the native library built by `zig build shared` into prebuilds/<platform>-<arch>/.
import { suffix } from 'bun:ffi'
import { copyFileSync, existsSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'

const file = `libguillotine_ffi.${suffix}`
const source = join(import.meta.dir, '..', '..', '..', 'zig-out', 'lib', file)
if (!existsSync(source)) {
	console.error(`missing ${source}; run \`zig build shared -Doptimize=ReleaseFast\` from the repository root`)
	process.exit(1)
}
const target = join(import.meta.dir, '..', 'prebuilds', `${process.platform}-${process.arch}`)
mkdirSync(target, { recursive: true })
copyFileSync(source, join(target, file))
console.log(`copied ${file} to ${target}`)
