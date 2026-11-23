// Test preload: use the library built by `zig build shared` unless GUILLOTINE_LIB_PATH is set.
import { suffix } from 'bun:ffi'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

if (process.env.GUILLOTINE_LIB_PATH === undefined || process.env.GUILLOTINE_LIB_PATH === '') {
	const built = join(import.meta.dir, '..', '..', '..', 'zig-out', 'lib', `libguillotine_ffi.${suffix}`)
	if (!existsSync(built)) {
		throw new Error(`missing ${built}; run \`zig build shared\` from the repository root first`)
	}
	process.env.GUILLOTINE_LIB_PATH = built
}
