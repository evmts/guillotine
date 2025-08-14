import ArrowDownToDot from 'lucide-solid/icons/arrow-down-to-dot'
import PlusIcon from 'lucide-solid/icons/plus'
import Trash2Icon from 'lucide-solid/icons/trash-2'
import XIcon from 'lucide-solid/icons/x'
import { type Component, createEffect, createMemo, createSignal, For, Show } from 'solid-js'
import InfoTooltip from '~/components/InfoTooltip'
import { Badge } from '~/components/ui/badge'
import { Button } from '~/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '~/components/ui/card'
import { Combobox, ComboboxContent, ComboboxInput, ComboboxItem, ComboboxTrigger } from '~/components/ui/combobox'
import type { EvmState, PreanalyzedBlockJson } from '~/lib/types'
import { addBreakpoint, clearBreakpoints, removeBreakpoint } from '~/lib/utils'

interface BreakpointsProps {
	bytecode: string
	state: EvmState
	breakpoints: number[]
	refreshBreakpoints: () => Promise<void>
	togglePcBreakpoint: (pc: number) => Promise<void>
}

const Breakpoints: Component<BreakpointsProps> = (props) => {
	const [availableOpcodes, setAvailableOpcodes] = createSignal<string[]>([])
	const [selectedOpcode, setSelectedOpcode] = createSignal<string>('')

	// Build opcode -> PCs mapping from preanalyzed blocks
	const opToPcs = createMemo(() => {
		const map = new Map<string, number[]>()
		for (const blk of props.state.preanalyzedBlocks as PreanalyzedBlockJson[]) {
			for (const ins of blk.instructions) {
				const list = map.get(ins.opcode) ?? []
				list.push(ins.pc)
				map.set(ins.opcode, list)
			}
		}
		return map
	})

	const refresh = async () => {
		const set = new Set<string>()
		for (const blk of props.state.preanalyzedBlocks as PreanalyzedBlockJson[]) {
			for (const ins of blk.instructions) set.add(ins.opcode)
		}
		setAvailableOpcodes(Array.from(set).sort())
		await props.refreshBreakpoints()
	}

	createEffect(() => {
		void props.bytecode
		void props.state.currentPreanalyzedBlockStartIndex
		void refresh()
	})

	const groupedOpcodes = createMemo(() => {
		const res: string[] = []
		const bps = new Set(props.breakpoints)
		for (const [op, pcs] of opToPcs()) {
			if (pcs.length > 0 && pcs.every((pc) => bps.has(pc))) res.push(op)
		}
		return res.sort()
	})

	const customPcs = createMemo(() => {
		const bps = new Set(props.breakpoints)
		const covered = new Set<number>()
		for (const op of groupedOpcodes()) {
			for (const pc of opToPcs().get(op) ?? []) covered.add(pc)
		}
		const out: number[] = []
		for (const pc of bps) if (!covered.has(pc)) out.push(pc)
		return out.sort((a, b) => a - b)
	})

	const onAddOpcode = async () => {
		const op = selectedOpcode()
		if (!op) return
		for (const pc of opToPcs().get(op) ?? []) if (!props.breakpoints.includes(pc)) await addBreakpoint(pc)
		await props.refreshBreakpoints()
	}

	const onRemovePc = async (pc: number) => {
		await removeBreakpoint(pc)
		await props.refreshBreakpoints()
	}

	const onClear = async () => {
		await clearBreakpoints()
		await props.refreshBreakpoints()
	}

	return (
		<Card class="max-w-7xl rounded-sm border-none bg-transparent shadow-none">
			<CardHeader class="flex flex-col justify-between gap-2 p-0 pb-2 sm:flex-row sm:items-center">
				<div class="space-y-1">
					<CardTitle>Breakpoints</CardTitle>
				</div>
				<div class="flex items-center gap-2">
					<Button
						size="sm"
						variant="ghost"
						class="mr-4 h-7 px-2 text-xs"
						onClick={onClear}
						aria-label="Clear breakpoints"
					>
						<Trash2Icon class="mr-1 h-3.5 w-3.5" />
						Clear all
					</Button>
					<Combobox
						value={selectedOpcode()}
						onChange={(value) => setSelectedOpcode(value || '')}
						options={availableOpcodes()}
						placeholder="Add opcode breakpoint"
						itemComponent={(props) => (
							<ComboboxItem item={props.item}>
								<div class="flex flex-col items-start">
									<span class="font-medium">{props.item.rawValue}</span>
								</div>
							</ComboboxItem>
						)}
					>
						<ComboboxTrigger class="w-[260px]" aria-label="Add opcode breakpoint">
							<div class="flex items-center gap-2">
								<ArrowDownToDot class="h-4 w-4" />
								<ComboboxInput placeholder="Select opcode" />
							</div>
						</ComboboxTrigger>
						<ComboboxContent />
					</Combobox>
					<Button size="sm" variant="secondary" onClick={onAddOpcode} aria-label="Add opcode breakpoint" class="gap-2">
						<PlusIcon class="h-4 w-4" />
						Add
					</Button>
					<InfoTooltip>
						Add a breakpoint for an opcode or use the execution steps to add a breakpoint at a specific PC.
					</InfoTooltip>
				</div>
			</CardHeader>
			<CardContent class="flex flex-col gap-3 p-0">
				<div class="flex flex-col gap-2">
					<div class="font-medium text-xs">Opcode breakpoints</div>
					<Show when={groupedOpcodes().length > 0} fallback={<div class="text-muted-foreground text-sm">None</div>}>
						<div class="flex flex-wrap gap-2">
							<For each={groupedOpcodes()}>
								{(op) => (
									<Badge variant="secondary" class="h-8 gap-1">
										{op}
										<Button
											variant="ghost"
											size="icon"
											class="ml-1 inline-flex items-center"
											onClick={async () => {
												for (const pc of opToPcs().get(op) ?? []) await removeBreakpoint(pc)
												await props.refreshBreakpoints()
											}}
											aria-label={`Remove opcode breakpoint ${op}`}
										>
											<XIcon class="h-3.5 w-3.5 opacity-70" />
										</Button>
									</Badge>
								)}
							</For>
						</div>
					</Show>
				</div>
				<div class="flex flex-col gap-2">
					<div class="font-medium text-xs">Custom</div>
					<Show when={customPcs().length > 0} fallback={<div class="text-muted-foreground text-sm">None</div>}>
						<div class="flex flex-wrap gap-2">
							<For each={customPcs()}>
								{(pc) => (
									<Badge variant="secondary" class="h-8 gap-1 font-mono">
										0x{pc.toString(16)}
										<Button
											variant="ghost"
											size="icon"
											class="ml-1 inline-flex items-center"
											onClick={() => onRemovePc(pc)}
											aria-label={`Remove breakpoint at 0x${pc.toString(16)}`}
										>
											<XIcon class="h-3.5 w-3.5 opacity-70" />
										</Button>
									</Badge>
								)}
							</For>
						</div>
					</Show>
				</div>
			</CardContent>
		</Card>
	)
}

export default Breakpoints
