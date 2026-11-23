/**
 * Feedback-Guided, Tape-Driven Mutational Fuzzer with Automatic Shrinking & Replay Tokens.
 *
 * Modeled after the Effect-Fuzz architecture (mutable word tape + structural/edge feedback +
 * corpus retention + havoc mutation + automatic delta shrinking + `gfuzz1:` replay tokens),
 * running natively in Bun and Node.js with zero native addon ABI friction.
 */

export interface FuzzFeedbackContext {
	/** Record hitting a named branch/outcome edge (e.g. "evm:revert", "u256:overflow"). */
	observe(label: string): void
	/** Record a numeric bucketed signal (log2-bucketed so monotonic progress expands corpus). */
	score(label: string, value: number): void
}

export class FuzzTape {
	private readonly words: number[]
	private pos = 0

	constructor(words: number[]) {
		this.words = words
	}

	/** Read next 32-bit unsigned word from the tape, extending lazily with deterministic PRNG if needed. */
	nextU32(fallbackRng: () => number): number {
		if (this.pos < this.words.length) {
			return this.words[this.pos++]! >>> 0
		}
		const w = fallbackRng() >>> 0
		this.words.push(w)
		this.pos++
		return w
	}

	bool(fallbackRng: () => number): boolean {
		return (this.nextU32(fallbackRng) & 1) === 1
	}

	nat(maxExclusive: number, fallbackRng: () => number): number {
		if (maxExclusive <= 1) return 0
		return this.nextU32(fallbackRng) % maxExclusive
	}

	int(min: number, maxInclusive: number, fallbackRng: () => number): number {
		if (maxInclusive <= min) return min
		const span = maxInclusive - min + 1
		return min + (this.nextU32(fallbackRng) % span)
	}

	bytes(minLen: number, maxLen: number, fallbackRng: () => number): Uint8Array {
		const len = this.int(minLen, maxLen, fallbackRng)
		const out = new Uint8Array(len)
		let i = 0
		while (i < len) {
			let w = this.nextU32(fallbackRng)
			for (let b = 0; b < 4 && i < len; b++, i++) {
				out[i] = w & 0xff
				w >>>= 8
			}
		}
		return out
	}

	pick<T>(items: readonly T[], fallbackRng: () => number): T {
		return items[this.nat(items.length, fallbackRng)]!
	}

	/** Compact slice of words actually consumed during generation. */
	consumedWords(): number[] {
		return this.words.slice(0, this.pos)
	}
}

export interface FuzzOptions {
	/** Total number of fuzz executions (default: 500, overridable via GUILLOTINE_FUZZ_EXECS). */
	executions?: number
	/** Deterministic PRNG seed (default: 1, overridable via GUILLOTINE_FUZZ_SEED). */
	seed?: number
	/** Maximum shrinking attempts after finding a failure (default: 200). */
	maxShrinks?: number
	/** Maximum corpus entries retained (default: 256). */
	maxCorpus?: number
	/** Initial seed word tapes. */
	seeds?: readonly (readonly number[])[]
}

export interface FuzzFinding<A> {
	readonly execution: number
	readonly shrinks: number
	readonly input: A
	readonly error: unknown
	readonly replayToken: string
	readonly tape: readonly number[]
}

export interface FuzzReport<A> {
	readonly passed: boolean
	readonly executions: number
	readonly corpusSize: number
	readonly featuresCount: number
	readonly seed: number
	readonly finding?: FuzzFinding<A>
}

function makeRng(seed: number): () => number {
	// Mulberry32 deterministic PRNG
	let s = seed >>> 0
	return () => {
		s = (s + 0x6d2b79f5) >>> 0
		let t = Math.imul(s ^ (s >>> 15), 1 | s)
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
		return ((t ^ (t >>> 14)) >>> 0)
	}
}

const INTERESTING_U32 = [
	0,
	1,
	2,
	3,
	4,
	7,
	8,
	15,
	16,
	19,
	20,
	21,
	31,
	32,
	33,
	63,
	64,
	127,
	128,
	255,
	256,
	0xffff,
	0x7fffffff,
	0xffffffff,
] as const

function mutateTape(base: readonly number[], rng: () => number, corpus: readonly (readonly number[])[]): number[] {
	const out = base.slice()
	if (out.length === 0) {
		const len = (rng() % 16) + 2
		for (let i = 0; i < len; i++) out.push(rng())
		return out
	}

	const ops = (rng() % 5) + 1
	for (let k = 0; k < ops; k++) {
		const choice = rng() % 8
		switch (choice) {
			case 0: {
				// Bit flip
				const idx = rng() % out.length
				out[idx] = (out[idx]! ^ (1 << (rng() % 32))) >>> 0
				break
			}
			case 1: {
				// Interesting boundary word
				const idx = rng() % out.length
				out[idx] = INTERESTING_U32[rng() % INTERESTING_U32.length]!
				break
			}
			case 2: {
				// Small arithmetic nudge +/- 1..16
				const idx = rng() % out.length
				const delta = (rng() % 16) + 1
				out[idx] = (rng() & 1 ? out[idx]! + delta : out[idx]! - delta) >>> 0
				break
			}
			case 3: {
				// Random word overwrite
				const idx = rng() % out.length
				out[idx] = rng()
				break
			}
			case 4: {
				// Insert words
				if (out.length < 192) {
					const pos = rng() % (out.length + 1)
					const count = (rng() % 4) + 1
					const ins: number[] = []
					for (let j = 0; j < count; j++) ins.push(rng())
					out.splice(pos, 0, ...ins)
				}
				break
			}
			case 5: {
				// Delete words
				if (out.length > 2) {
					const del = Math.min(out.length - 1, (rng() % 4) + 1)
					const pos = rng() % (out.length - del + 1)
					out.splice(pos, del)
				}
				break
			}
			case 6: {
				// Cross-over splice with another corpus entry
				if (corpus.length > 1) {
					const other = corpus[rng() % corpus.length]!
					if (other.length > 1) {
						const cutA = rng() % out.length
						const cutB = rng() % other.length
						const tail = other.slice(cutB, Math.min(other.length, cutB + 32))
						out.splice(cutA, out.length - cutA, ...tail)
					}
				}
				break
			}
			default: {
				// Duplicate a chunk
				if (out.length >= 2 && out.length < 192) {
					const len = Math.min(out.length, (rng() % 6) + 1)
					const src = rng() % (out.length - len + 1)
					out.push(...out.slice(src, src + len))
				}
				break
			}
		}
	}
	return out
}

export function encodeReplayToken(seed: number, tape: readonly number[]): string {
	const json = JSON.stringify([seed, tape])
	return `gfuzz1:${Buffer.from(json, 'utf8').toString('base64url')}`
}

export function decodeReplayToken(token: string): { seed: number; tape: number[] } {
	if (!token.startsWith('gfuzz1:')) {
		throw new Error(`Invalid replay token prefix: ${token}`)
	}
	const decoded = Buffer.from(token.slice('gfuzz1:'.length), 'base64url').toString('utf8')
	const parsed = JSON.parse(decoded) as [number, number[]]
	return { seed: parsed[0], tape: parsed[1] }
}

function log2Bucket(v: number): number {
	if (v <= 0) return 0
	return Math.floor(Math.log2(v)) + 1
}

/**
 * Run a feedback-guided mutational fuzzing campaign against `property`.
 * Returns a detailed report; throws nothing itself unless you call `assertFuzz`.
 */
export async function runFuzz<A>(
	generate: (tape: FuzzTape, fallbackRng: () => number) => A,
	property: (input: A, ctx: FuzzFeedbackContext) => void | boolean | Promise<void | boolean>,
	options: FuzzOptions = {},
): Promise<FuzzReport<A>> {
	const envExecs = process.env.GUILLOTINE_FUZZ_EXECS ? Number(process.env.GUILLOTINE_FUZZ_EXECS) : undefined
	const envSeed = process.env.GUILLOTINE_FUZZ_SEED ? Number(process.env.GUILLOTINE_FUZZ_SEED) : undefined
	const executions = options.executions ?? (envExecs && Number.isFinite(envExecs) ? envExecs : 500)
	const seed = options.seed ?? (envSeed && Number.isFinite(envSeed) ? envSeed : 1)
	const maxShrinks = options.maxShrinks ?? 200
	const maxCorpus = options.maxCorpus ?? 256

	const rng = makeRng(seed)
	const seenFeatures = new Set<string>()
	const corpus: number[][] = []

	if (options.seeds) {
		for (const s of options.seeds) corpus.push(Array.from(s))
	}

	const evaluate = async (
		tapeWords: number[],
		execSeed: number,
	): Promise<{ ok: true; input: A; used: number[]; newFeatures: number } | { ok: false; input: A; used: number[]; error: unknown }> => {
		const fallbackRng = makeRng(execSeed)
		const tape = new FuzzTape(tapeWords.slice())
		const input = generate(tape, fallbackRng)
		const used = tape.consumedWords()

		let newFeatures = 0
		const ctx: FuzzFeedbackContext = {
			observe(label: string) {
				if (!seenFeatures.has(label)) {
					seenFeatures.add(label)
					newFeatures++
				}
			},
			score(label: string, value: number) {
				const key = `${label}#b${log2Bucket(value)}`
				if (!seenFeatures.has(key)) {
					seenFeatures.add(key)
					newFeatures++
				}
			},
		}

		try {
			const res = await property(input, ctx)
			if (res === false) {
				return { ok: false, input, used, error: new Error('Fuzz property returned false') }
			}
			return { ok: true, input, used, newFeatures }
		} catch (err) {
			return { ok: false, input, used, error: err }
		}
	}

	for (let exec = 1; exec <= executions; exec++) {
		let candidate: number[]
		if (exec <= (options.seeds?.length ?? 0)) {
			candidate = corpus[exec - 1]!.slice()
		} else if (corpus.length > 0 && (rng() % 5) !== 0) {
			// 80% mutate an interesting corpus tape; 20% fresh random exploration
			const parent = corpus[rng() % corpus.length]!
			candidate = mutateTape(parent, rng, corpus)
		} else {
			const len = (rng() % 32) + 4
			candidate = []
			for (let j = 0; j < len; j++) candidate.push(rng())
		}

		const outcome = await evaluate(candidate, seed ^ exec)
		if (!outcome.ok) {
			// Automatic delta shrinking of the failing tape!
			let bestTape = outcome.used
			let bestInput = outcome.input
			let bestError = outcome.error
			let shrinks = 0

			const tryCandidate = async (next: number[]): Promise<boolean> => {
				const check = await evaluate(next, seed ^ exec)
				if (!check.ok) {
					bestTape = check.used.length < next.length ? check.used : next
					bestInput = check.input
					bestError = check.error
					shrinks++
					return true
				}
				return false
			}

			// Phase 1: Chunk deletion (ddmin-style)
			let chunk = Math.max(1, Math.floor(bestTape.length / 2))
			while (chunk >= 1 && shrinks < maxShrinks) {
				let improved = false
				for (let pos = 0; pos + chunk <= bestTape.length && shrinks < maxShrinks; pos += chunk) {
					const shorter = bestTape.slice(0, pos).concat(bestTape.slice(pos + chunk))
					if (await tryCandidate(shorter)) {
						improved = true
						break
					}
				}
				if (!improved) chunk = Math.floor(chunk / 2)
			}

			// Phase 2: Word value minimization (try 0, then binary halve)
			for (let idx = 0; idx < bestTape.length && shrinks < maxShrinks; idx++) {
				const cur = bestTape[idx]!
				if (cur === 0) continue
				const zeroed = bestTape.slice()
				zeroed[idx] = 0
				if (await tryCandidate(zeroed)) continue

				let val = cur
				while (val > 1 && shrinks < maxShrinks) {
					const half = val >>> 1
					const smaller = bestTape.slice()
					smaller[idx] = half
					if (await tryCandidate(smaller)) {
						val = half
					} else {
						break
					}
				}
			}

			return {
				passed: false,
				executions: exec,
				corpusSize: corpus.length,
				featuresCount: seenFeatures.size,
				seed,
				finding: {
					execution: exec,
					shrinks,
					input: bestInput,
					error: bestError,
					replayToken: encodeReplayToken(seed ^ exec, bestTape),
					tape: bestTape,
				},
			}
		}

		if (outcome.newFeatures > 0 || corpus.length < 8) {
			if (corpus.length < maxCorpus) {
				corpus.push(outcome.used)
			} else {
				corpus[rng() % maxCorpus] = outcome.used
			}
		}
	}

	return {
		passed: true,
		executions,
		corpusSize: corpus.length,
		featuresCount: seenFeatures.size,
		seed,
	}
}

/** Convenience assertion wrapper for bun:test that formats minimized counterexamples + replay tokens. */
export async function assertFuzz<A>(
	name: string,
	generate: (tape: FuzzTape, fallbackRng: () => number) => A,
	property: (input: A, ctx: FuzzFeedbackContext) => void | boolean | Promise<void | boolean>,
	options: FuzzOptions = {},
): Promise<FuzzReport<A>> {
	const report = await runFuzz(generate, property, options)
	if (!report.passed && report.finding) {
		const f = report.finding
		const msg = f.error instanceof Error ? f.error.message : String(f.error)
		throw new Error(
			`[FUZZ FAILED: ${name}] execution=${f.execution} shrinks=${f.shrinks} features=${report.featuresCount}\n` +
				`  Error: ${msg}\n` +
				`  Replay: ${f.replayToken}\n` +
				`  Input: ${JSON.stringify(f.input, (_k, v) => (typeof v === 'bigint' ? `${v}n` : v instanceof Uint8Array ? `0x${Buffer.from(v).toString('hex')}` : v))}`,
		)
	}
	return report
}
