// Copy the native libraries built by `zig build shared napi` into prebuilds/<platform>-<arch>/.
import { copyFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const suffix = process.platform === 'darwin' ? 'dylib' : process.platform === 'win32' ? 'dll' : 'so'
const libDir = join(here, '..', '..', '..', 'zig-out', 'lib')
const target = join(here, '..', 'prebuilds', `${process.platform}-${process.arch}`)
mkdirSync(target, { recursive: true })

const files = [`libguillotine_ffi.${suffix}`, 'guillotine.node']
let copied = 0
for (const file of files) {
	const source = join(libDir, file)
	if (existsSync(source)) {
		copyFileSync(source, join(target, file))
		console.log(`copied ${file} to ${target}`)
		copied++
	}
}
if (copied === 0) {
	console.error(`no native libraries found in ${libDir}; run \`zig build shared napi -Doptimize=ReleaseFast\` first`)
	process.exit(1)
}
