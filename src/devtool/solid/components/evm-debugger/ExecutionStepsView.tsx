import { type Component, createMemo, For } from 'solid-js'
import Code from '~/components/Code'
import InfoTooltip from '~/components/InfoTooltip'
import { Badge } from '~/components/ui/badge'
import { Card, CardContent, CardHeader, CardTitle } from '~/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '~/components/ui/table'
import { cn } from '~/lib/cn'
import type { BlockJson } from '~/lib/types'

interface BlocksViewProps {
	blocks: BlockJson[]
	currentInstructionIndex: number
	currentBlockStartIndex: number
	rawBytecode: string
}

const ExecutionStepsView: Component<BlocksViewProps> = (props) => {
	const byteLen = createMemo(
		() =>
			(props.rawBytecode?.startsWith('0x') ? (props.rawBytecode.length - 2) / 2 : props.rawBytecode.length / 2) || 0,
	)
	return (
		<Card class="overflow-hidden">
			<CardHeader class="border-b p-3">
				<div class="flex items-center justify-between">
					<CardTitle class="text-sm">Execution Steps</CardTitle>
					<div class="flex items-center gap-2">
						<div class="text-muted-foreground text-xs">
							{props.blocks.length} blocks • {byteLen()} bytes
						</div>
						<InfoTooltip>
							Shows prenalyzed blocks and fused instructions. Columns: PC, opcode, hex, and any push data. The
							highlighted row is the current instruction.
						</InfoTooltip>
					</div>
				</div>
			</CardHeader>
			<CardContent class="max-h-[400px] overflow-y-auto p-0">
				<Table class="relative">
					<TableHeader class="sticky top-0 z-10 bg-background">
						<TableRow>
							<TableHead class="text-xs uppercase">Begin</TableHead>
							<TableHead class="text-xs uppercase">
								<div class="flex items-center gap-1">
									<span>Gas</span>
									<span class="text-[10px] text-muted-foreground">(static)</span>
									<InfoTooltip>
										Static per-block cost; excludes dynamic overhead like memory expansion, cold/warm storage, and
										per-word copy.
									</InfoTooltip>
								</div>
							</TableHead>
							<TableHead class="text-xs uppercase">
								<div class="flex items-center gap-1">
									<span>Gas</span>
									<span class="text-[10px] text-muted-foreground">(dynamic)</span>
									<InfoTooltip>
										Per-instruction runtime overhead. "-" until executed, then "+N" once known. "0" for ops with no
										dynamic overhead.
									</InfoTooltip>
								</div>
							</TableHead>
							<TableHead class="text-[10px] uppercase">PC</TableHead>
							<TableHead class="text-[10px] uppercase">Opcode</TableHead>
							<TableHead class="text-[10px] uppercase">Hex</TableHead>
							<TableHead class="text-[10px] uppercase">Data</TableHead>
						</TableRow>
					</TableHeader>
					<TableBody>
						<For each={props.blocks}>
							{(blk) => (
								<TableRow class={cn(blk.beginIndex === props.currentBlockStartIndex && 'bg-accent/50')}>
									<TableCell class="align-top font-mono text-xs">
										<span class="inline-block py-1">{blk.beginIndex}</span>
									</TableCell>
									<TableCell class="align-top font-mono text-xs">
										<span class="inline-block py-1">{blk.gasCost}</span>
									</TableCell>
									<TableCell class="align-top font-mono text-xs">
										<div class="flex flex-col gap-2">
											<For each={blk.dynamicGas}>
												{(v, idx) => {
													const canDyn = blk.dynCandidate?.[idx()] ?? false
													// Instruction index for this row is beginIndex + 1 + idx
													const insnIndex = blk.beginIndex + 1 + idx()
													const isPast = insnIndex < props.currentInstructionIndex
													const display = v > 0 ? `+${v}` : isPast ? '0' : canDyn ? '-' : '0'
													const muted = v === 0 && !isPast
													return (
														<span class={cn('flex h-5.5 items-center', muted && 'text-muted-foreground')}>
															{display}
														</span>
													)
												}}
											</For>
										</div>
									</TableCell>
									<TableCell class="align-top">
										<div class="flex flex-col gap-2">
											<For each={blk.pcs}>
												{(pc) => {
													return <Code class="inline-block w-fit text-xs">0x{pc.toString(16)}</Code>
												}}
											</For>
										</div>
									</TableCell>
									<TableCell class="align-top">
										<div class="flex flex-col gap-2">
											<For each={blk.opcodes}>
												{(opcode, idx) => {
													const isActive =
														blk.beginIndex === props.currentBlockStartIndex &&
														idx() === Math.max(0, props.currentInstructionIndex - blk.beginIndex - 1)

													return (
														<Badge
															variant={isActive ? 'default' : 'secondary'}
															class={`inline-flex w-fit font-mono text-xs transition-colors duration-150 ${
																isActive
																	? 'bg-amber-500 text-black hover:bg-amber-400'
																	: 'bg-amber-500/15 text-amber-700 hover:bg-amber-500/20 dark:text-amber-300 dark:hover:bg-amber-400/20'
															}`}
														>
															{opcode}
														</Badge>
													)
												}}
											</For>
										</div>
									</TableCell>
									<TableCell class="align-top">
										<div class="flex flex-col gap-2">
											<For each={blk.hex}>
												{(hex) => {
													return <Code class="inline-block w-fit text-xs">{hex}</Code>
												}}
											</For>
										</div>
									</TableCell>
									<TableCell class="align-top">
										<div class="flex flex-col gap-2">
											<For each={blk.data}>
												{(data) => {
													if (!data) return <span />
													return <Code class="inline-block w-fit text-xs">{data}</Code>
												}}
											</For>
										</div>
									</TableCell>
								</TableRow>
							)}
						</For>
					</TableBody>
				</Table>
			</CardContent>
		</Card>
	)
}

export default ExecutionStepsView
