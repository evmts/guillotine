import type { Component } from "solid-js";
import { Badge } from "~/components/ui/badge";
import { Card } from "~/components/ui/card";
import type { EvmState } from "~/lib/types";

interface StateSummaryProps {
	state: EvmState;
	isUpdating: boolean;
}

const StateSummary: Component<StateSummaryProps> = (props) => {
	return (
		<Card class={`overflow-hidden ${props.isUpdating ? "animate-pulse" : ""}`}>
			<div class="grid grid-cols-2 md:grid-cols-4">
				<div class="flex flex-col items-center justify-center border-r border-b p-4 md:border-b-0">
					<div class="mb-1 font-medium text-muted-foreground text-xs uppercase tracking-wider">
						Instr Idx
					</div>
					<div class="font-mono font-semibold text-2xl">
						{props.state.currentInstructionIndex}
					</div>
				</div>
				<div class="flex flex-col items-center justify-center border-b p-4 md:border-r md:border-b-0">
					<div class="mb-1 font-medium text-muted-foreground text-xs uppercase tracking-wider">
						Block Start
					</div>
					<Badge
						variant="secondary"
						class="px-2.5 py-0.5 font-mono font-semibold text-lg"
					>
						{props.state.currentBlockStartIndex}
					</Badge>
				</div>
				<div class="flex flex-col items-center justify-center border-r p-4">
					<div class="mb-1 font-medium text-muted-foreground text-xs uppercase tracking-wider">
						Gas Left
					</div>
					<div class="font-mono font-semibold text-2xl">
						{props.state.gasLeft}
					</div>
				</div>
				<div class="flex flex-col items-center justify-center p-4">
					<div class="mb-1 font-medium text-muted-foreground text-xs uppercase tracking-wider">
						Depth
					</div>
					<div class="font-mono font-semibold text-2xl">
						{props.state.depth}
					</div>
				</div>
			</div>
		</Card>
	);
};

export default StateSummary;
