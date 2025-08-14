import { type Component, For, createMemo } from "solid-js";
import Code from "~/components/Code";
import { Badge } from "~/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "~/components/ui/card";
import {
	Table,
	TableBody,
	TableCell,
	TableHead,
	TableHeader,
	TableRow,
} from "~/components/ui/table";
import { cn } from "~/lib/cn";
import type { BlockJson } from "~/lib/types";

interface BlocksViewProps {
	blocks: BlockJson[];
	currentInstructionIndex: number;
	currentBlockStartIndex: number;
	rawBytecode: string;
}

const ExecutionStepsView: Component<BlocksViewProps> = (props) => {
	const byteLen = createMemo(
		() =>
			(props.rawBytecode?.startsWith("0x")
				? (props.rawBytecode.length - 2) / 2
				: props.rawBytecode.length / 2) || 0,
	);
	return (
		<Card class="overflow-hidden">
			<CardHeader class="border-b p-3">
				<div class="flex items-center justify-between">
					<CardTitle class="text-sm">Execution Steps</CardTitle>
					<div class="text-muted-foreground text-xs">
						{props.blocks.length} blocks • {byteLen()} bytes
					</div>
				</div>
			</CardHeader>
			<CardContent class="max-h-[400px] overflow-y-auto p-0">
				<Table>
					<TableHeader class="sticky top-0 z-10 bg-background">
						<TableRow>
							<TableHead class="text-xs uppercase">Begin</TableHead>
							<TableHead class="text-xs uppercase">Gas</TableHead>
							<TableHead class="text-xs uppercase">
								<div class="flex items-center gap-4 leading-tight">
									<span>Instructions</span>
									<span class="text-[10px] text-muted-foreground">
										PC • Opcode • Hex • Data
									</span>
								</div>
							</TableHead>
						</TableRow>
					</TableHeader>
					<TableBody>
						<For each={props.blocks}>
							{(blk) => (
								<TableRow
									class={
										blk.beginIndex === props.currentBlockStartIndex
											? "bg-accent/50"
											: ""
									}
								>
									<TableCell class="font-mono text-xs align-top">
										<span class="py-2 inline-block">{blk.beginIndex}</span>
									</TableCell>
									<TableCell class="font-mono text-xs align-top">
										<span class="py-2 inline-block">{blk.gasCost}</span>
									</TableCell>
									<TableCell class="p-2" colSpan={1}>
										<div class="flex flex-col gap-1">
											<For each={blk.pcs}>
												{(pc, idx) => {
													const isActive =
														blk.beginIndex === props.currentBlockStartIndex &&
														idx() ===
															Math.max(
																0,
																props.currentInstructionIndex -
																	blk.beginIndex -
																	1,
															);
													return (
														<div
															class={cn(
																"grid items-center gap-3 px-2 py-1",
																idx() !== blk.pcs.length - 1 &&
																	"border-b border-border/40 ",
															)}
															style={{
																"grid-template-columns":
																	"140px 120px 100px auto",
															}}
														>
															<Code class="text-xs inline-block w-fit">
																0x{pc.toString(16)}
															</Code>
															<Badge
																variant={isActive ? "default" : "secondary"}
																class={`font-mono text-xs inline-flex w-fit transition-colors duration-150 ${
																	isActive
																		? "bg-amber-500 text-black hover:bg-amber-400"
																		: "bg-amber-500/15 text-amber-700 dark:text-amber-300 hover:bg-amber-500/20 dark:hover:bg-amber-400/20"
																}`}
															>
																{blk.opcodes[idx()]}
															</Badge>
															<Code class="text-xs inline-block w-fit">
																{blk.hex[idx()]}
															</Code>
															{blk.data[idx()] ? (
																<Code class="text-xs inline-block w-fit">
																	{blk.data[idx()]}
																</Code>
															) : null}
														</div>
													);
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
	);
};

export default ExecutionStepsView;
