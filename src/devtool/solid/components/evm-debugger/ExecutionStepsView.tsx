import ArrowDownToDot from 'lucide-solid/icons/arrow-down-to-dot'
import { type Component, createMemo, For } from 'solid-js'
import Code from '~/components/Code'
import InfoTooltip from '~/components/InfoTooltip'
import { Badge } from '~/components/ui/badge'
import { Button } from '~/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '~/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '~/components/ui/table'
import { cn } from '~/lib/cn'
import type { PreanalyzedBlockJson } from '~/lib/types'

interface BlocksViewProps {
	preanalyzedBlocks: PreanalyzedBlockJson[]
	currentInstructionIndex: number
	currentPreanalyzedBlockStartIndex: number
	rawBytecode: string
	breakpoints: number[]
	togglePcBreakpoint: (pc: number) => Promise<void>
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
							{props.preanalyzedBlocks.length} blocks • {byteLen()} bytes
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
							<TableHead class="text-xs uppercase">Gas</TableHead>
							<TableHead class="text-xs uppercase">
								<div class="grid grid-cols-[100px_100px_140px_100px_auto] gap-3">
									<span class="leading-tight">Instructions</span>
									<span class="text-[10px] text-muted-foreground">PC</span>
									<span class="text-[10px] text-muted-foreground">Opcode</span>
									<span class="text-[10px] text-muted-foreground">Hex</span>
									<span class="text-[10px] text-muted-foreground">Data</span>
								</div>
							</TableHead>
						</TableRow>
					</TableHeader>
					<TableBody>
						<For each={props.preanalyzedBlocks}>
							{(blk) => (
								<TableRow
									class={blk.firstInstructionIndex === props.currentPreanalyzedBlockStartIndex ? 'bg-accent/50' : ''}
								>
									<TableCell class="align-top font-mono text-xs">
										<span class="inline-block py-2">{blk.firstInstructionIndex}</span>
									</TableCell>
									<TableCell class="align-top font-mono text-xs">
										<span class="inline-block py-2">{blk.gasCost}</span>
									</TableCell>
									<TableCell class="py-2" colSpan={1}>
										<div class="flex flex-col gap-1">
											<For each={blk.instructions}>
												{(instr, idx) => {
													const isActive =
														blk.firstInstructionIndex === props.currentPreanalyzedBlockStartIndex &&
														idx() === Math.max(0, props.currentInstructionIndex - blk.firstInstructionIndex - 1)
													return (
														<div
															class={cn(
																'grid grid-cols-[100px_100px_140px_100px_auto_28px] gap-3 py-1',
																idx() !== blk.instructions.length - 1 && 'border-border/40 border-b',
															)}
														>
															<span />
															<Code class="inline-block w-fit text-xs">0x{instr.pc.toString(16)}</Code>
															<Badge
																variant={isActive ? 'default' : 'secondary'}
																class={`inline-flex w-fit font-mono text-xs transition-colors duration-150 ${
																	isActive
																		? 'bg-amber-500 text-black hover:bg-amber-400'
																		: 'bg-amber-500/15 text-amber-700 hover:bg-amber-500/20 dark:text-amber-300 dark:hover:bg-amber-400/20'
																}`}
															>
																{instr.opcode}
															</Badge>
															<Code class="inline-block w-fit text-xs">{instr.hex}</Code>
															{instr.data ? <Code class="inline-block w-fit text-xs">{instr.data}</Code> : <div />}
															<Button
																variant="ghost"
																class={cn(
																	'h-5 w-5 p-0 hover:bg-amber-500/70 dark:hover:bg-amber-400/70',
																	props.breakpoints.includes(instr.pc)
																		? 'bg-amber-500 dark:bg-amber-400'
																		: 'text-muted-foreground',
																)}
																onClick={() => props.togglePcBreakpoint(instr.pc)}
															>
																<ArrowDownToDot class="h-3 w-3" />
															</Button>
														</div>
													)
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
