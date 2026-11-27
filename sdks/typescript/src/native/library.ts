import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { GuillotineError } from '../errors.js'
import type { NativeBackend } from './backend.js'
import { loadBunBackend } from './bun-backend.js'
import { loadNapiBackend } from './napi-backend.js'

export const LIBRARY_ENV = 'GUILLOTINE_LIB_PATH'
export const NAPI_ENV = 'GUILLOTINE_NAPI_PATH'

function sharedLibSuffix(): string {
	if (process.platform === 'darwin') return 'dylib'
	if (process.platform === 'win32') return 'dll'
	return 'so'
}

const LIBRARY_FILE = `libguillotine_ffi.${sharedLibSuffix()}`
const NAPI_FILE = 'guillotine.node'

function isBunRuntime(): boolean {
	return typeof (globalThis as { Bun?: unknown }).Bun !== 'undefined'
}

function prebuildDir(): string {
	const here = dirname(fileURLToPath(import.meta.url))
	// dist/index.js is one level below the package root; src/native/library.ts is two.
	const root = existsSync(join(here, '..', 'package.json')) ? join(here, '..') : join(here, '..', '..')
	return join(root, 'prebuilds', `${process.platform}-${process.arch}`)
}

/** Resolve the native shared library (`libguillotine_ffi`) or Node-API addon (`guillotine.node`). */
export function resolveLibraryPath(explicit?: string): string {
	if (explicit !== undefined) return explicit
	const fromNapi = process.env[NAPI_ENV]
	if (fromNapi !== undefined && fromNapi !== '') return fromNapi
	const fromEnv = process.env[LIBRARY_ENV]
	if (fromEnv !== undefined && fromEnv !== '') return fromEnv
	const dir = prebuildDir()
	const napiCandidate = join(dir, NAPI_FILE)
	if (!isBunRuntime() || existsSync(napiCandidate)) return napiCandidate
	return join(dir, LIBRARY_FILE)
}

/** Resolve the Node-API addon path (`guillotine.node`). */
export function resolveNapiPath(explicit?: string): string {
	if (explicit !== undefined) return explicit
	const fromNapi = process.env[NAPI_ENV]
	if (fromNapi !== undefined && fromNapi !== '') return fromNapi
	return join(prebuildDir(), NAPI_FILE)
}

let loaded: NativeBackend | null = null

/**
 * Load the Guillotine native engine once per process.
 * - On Node.js (and whenever a `.node` path is given): loads `guillotine.node` via Node-API.
 * - On Bun with a shared library (`.dylib`/`.so`/`.dll`): loads `libguillotine_ffi` via `bun:ffi`.
 */
export async function loadNativeBackend(libraryPath?: string): Promise<NativeBackend> {
	let path = resolveLibraryPath(libraryPath)
	if (loaded !== null) {
		if (libraryPath !== undefined && loaded.path !== path) {
			throw GuillotineError.initializationFailed(
				`Guillotine native library is already loaded from ${loaded.path}; cannot load a second copy from ${path}`,
			)
		}
		return loaded
	}
	if (new Uint8Array(new Uint16Array([1]).buffer)[0] !== 1) {
		throw GuillotineError.initializationFailed('Guillotine FFI requires a little-endian host')
	}

	// If running on Node.js and caller pointed GUILLOTINE_LIB_PATH at libguillotine_ffi.*,
	// look for sibling guillotine.node in the same directory before failing.
	if (!isBunRuntime() && !path.endsWith('.node')) {
		const sibling = join(dirname(path), NAPI_FILE)
		if (existsSync(sibling)) {
			path = sibling
		} else {
			throw GuillotineError.initializationFailed(
				`Node.js requires the Node-API addon (${NAPI_FILE}), not ${path}. Build it with \`zig build napi\` and set ${NAPI_ENV}.`,
			)
		}
	}

	if (!existsSync(path)) {
		const buildHint = path.endsWith('.node')
			? `Build it with \`zig build napi\` and set ${NAPI_ENV}`
			: `Build it with \`zig build shared\` and set ${LIBRARY_ENV}`
		throw GuillotineError.initializationFailed(
			`Native library not found at ${path}. ${buildHint}, or install a package with prebuilds for ${process.platform}-${process.arch}.`,
		)
	}

	const backend = path.endsWith('.node') ? loadNapiBackend(path) : await loadBunBackend(path)
	loaded = backend
	return backend
}
