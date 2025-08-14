import { For, Show, createMemo } from "solid-js";
import InfoTooltip from "~/components/InfoTooltip";
import { cn } from "~/lib/cn";
import type { BlockJson } from "~/lib/types";

interface BytecodeBlocksMapProps {
	codeHex: string;
	blocks: BlockJson[];
	currentBlockStartIndex: number;
}

export default function BytecodeBlocksMap(props: BytecodeBlocksMapProps) {
	// Parse hex string into bytes (no 0x prefix)
	const hex = createMemo(() =>
		props.codeHex?.startsWith("0x")
			? props.codeHex.slice(2)
			: props.codeHex || "",
	);
	const bytes = createMemo(() => {
		const out: string[] = [];
		const h = hex();
		for (let i = 0; i < h.length; i += 2) out.push(h.slice(i, i + 2));
		return out;
	});

	// Map each pc to its block index (sorted by start pc), for coloring
	const sortedBlocks = createMemo(() =>
		[...props.blocks].sort((a, b) => a.blockStartPc - b.blockStartPc),
	);
	const pcMaps = createMemo(() => {
		const len = bytes().length;
		const idx: number[] = Array(len).fill(-1);
		const begin: number[] = Array(len).fill(-1);
		const blocks = sortedBlocks();
		for (let si = 0; si < blocks.length; si++) {
			const b = blocks[si];
			for (let pc = b.blockStartPc; pc < b.blockEndPcExclusive; pc++) {
				if (pc >= 0 && pc < len) {
					idx[pc] = si;
					begin[pc] = b.beginIndex;
				}
			}
		}
		return { idx, begin };
	});

	// Current block position among blocks (1-based)
	const currentSortedPos = createMemo(() => {
		const idx = sortedBlocks().findIndex(
			(b) => b.beginIndex === props.currentBlockStartIndex,
		);
		return idx >= 0 ? idx + 1 : 0;
	});

	const cols = 16;

	return (
		<div class="rounded-sm border border-border/40 bg-muted/30 p-3">
			<div class="mb-2 flex items-center justify-between">
				<div class="text-sm font-medium">Bytecode</div>
				<InfoTooltip>
					Each cell is one byte of the original bytecode. Cells are grouped by
					preanalized blocks. The current block being executed is highlighted.
				</InfoTooltip>
			</div>
			<div
				class="grid gap-0 font-mono text-xs tabular-nums border border-border/30 rounded-sm overflow-hidden"
				style={{ "grid-template-columns": `repeat(${cols}, minmax(0, 1fr))` }}
			>
				<For each={bytes()}>
					{(b, pc) => {
						const sidx = createMemo(() => pcMaps().idx[pc()]);
						const beginIndex = createMemo(() => pcMaps().begin[pc()]);
						const isCurrent = createMemo(
							() => beginIndex() === props.currentBlockStartIndex,
						);
						const isBlockStart = createMemo(() => {
							const si = sidx();
							if (si < 0) return false;
							const sb = sortedBlocks();
							return pc() === sb[si].blockStartPc;
						});

						return (
							<div
								class={cn(
									"relative flex items-center justify-center px-1.5 py-1 border border-border/20",
									isCurrent()
										? "bg-amber-500/80 text-black"
										: sidx() >= 0
											? sidx() % 2 === 0
												? "bg-amber-100/50 dark:bg-amber-900/50"
												: "bg-amber-100/20 dark:bg-amber-900/20"
											: "text-foreground/70",
								)}
								title={`pc=0x${pc().toString(16)}${
									beginIndex() >= 0 ? ` • block @${beginIndex()}` : ""
								}`}
							>
								{isBlockStart() && sidx() >= 0 && (
									<span class="absolute left-0.5 top-0.5 text-[9px] leading-none text-muted-foreground">
										{(sidx() + 1).toString()}
									</span>
								)}
								<span>{b}</span>
							</div>
						);
					}}
				</For>
			</div>
			<Show when={props.blocks.length > 0}>
				<div class="mt-2 text-xs text-muted-foreground">
					Block {currentSortedPos()}/{props.blocks.length}
				</div>
			</Show>
		</div>
	);
}
