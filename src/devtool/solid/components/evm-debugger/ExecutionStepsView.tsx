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
						<For each={props.blocks}>
							{(blk) => (
								<TableRow class={blk.beginIndex === props.currentBlockStartIndex ? 'bg-accent/50' : ''}>
									<TableCell class="align-top font-mono text-xs">
										<span class="inline-block py-2">{blk.beginIndex}</span>
									</TableCell>
									<TableCell class="align-top font-mono text-xs">
										<span class="inline-block py-2">{blk.gasCost}</span>
									</TableCell>
									<TableCell class="py-2" colSpan={1}>
										<div class="flex flex-col gap-1">
											<For each={blk.pcs}>
												{(pc, idx) => {
													const isActive =
														blk.beginIndex === props.currentBlockStartIndex &&
														idx() === Math.max(0, props.currentInstructionIndex - blk.beginIndex - 1)
													return (
														<div
															class={cn(
																'grid grid-cols-[100px_100px_140px_100px_auto] gap-3 py-1',
																idx() !== blk.pcs.length - 1 && 'border-border/40 border-b',
															)}
														>
															<span />
															<Code class="inline-block w-fit text-xs">0x{pc.toString(16)}</Code>
															<Badge
																variant={isActive ? 'default' : 'secondary'}
																class={`inline-flex w-fit font-mono text-xs transition-colors duration-150 ${
																	isActive
																		? 'bg-amber-500 text-black hover:bg-amber-400'
																		: 'bg-amber-500/15 text-amber-700 hover:bg-amber-500/20 dark:text-amber-300 dark:hover:bg-amber-400/20'
																}`}
															>
																{blk.opcodes[idx()]}
															</Badge>
															<Code class="inline-block w-fit text-xs">{blk.hex[idx()]}</Code>
															{blk.data[idx()] ? (
																<Code class="inline-block w-fit text-xs">{blk.data[idx()]}</Code>
															) : null}
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
