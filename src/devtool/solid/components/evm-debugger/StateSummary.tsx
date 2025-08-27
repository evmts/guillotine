import type { Component } from 'solid-js'
import { Badge } from '~/components/ui/badge'
import { Card } from '~/components/ui/card'
import type { EvmState } from '~/lib/types'

interface StateSummaryProps {
	state: EvmState
	isUpdating: boolean
}

const StateSummary: Component<StateSummaryProps> = (props) => {
	const totalInstructions = () => {
		if (!props.state.preanalyzedBlocks || props.state.preanalyzedBlocks.length === 0) return 0
		let maxIndex = 0
		for (const b of props.state.preanalyzedBlocks) {
			const end = (b.firstInstructionIndex || 0) + (b.instructions?.length || 0)
			if (end > maxIndex) maxIndex = end
		}
		return maxIndex
	}

	const currentBlock = () =>
		props.state.preanalyzedBlocks.find((b) => b.firstInstructionIndex === props.state.currentPreanalyzedBlockStartIndex)

	const currentOffset = () =>
		Math.max(0, props.state.currentInstructionIndex - props.state.currentPreanalyzedBlockStartIndex - 1)

	const currentOpcode = () => {
		const blk = currentBlock()
		const idx = currentOffset()
		if (!blk || idx < 0 || idx >= blk.instructions.length) return 'UNKNOWN'
		return blk.instructions[idx].opcode
	}

	return (
		<Card class={`overflow-hidden ${props.isUpdating ? 'animate-pulse' : ''}`}>
			<div class="grid grid-cols-2 md:grid-cols-4">
				<div class="flex flex-col items-center justify-center border-r border-b p-4 md:border-b-0">
					<div class="mb-1 font-medium text-muted-foreground text-xs uppercase tracking-wider">Instr</div>
					<div class="flex items-baseline gap-2 font-mono font-semibold text-2xl">
						{Math.min(props.state.currentInstructionIndex, totalInstructions())}
						<span class="font-normal text-muted-foreground text-sm">/ {totalInstructions()}</span>
					</div>
				</div>
				<div class="flex flex-col items-center justify-center border-b p-4 md:border-r md:border-b-0">
					<div class="mb-1 font-medium text-muted-foreground text-xs uppercase tracking-wider">Opcode</div>
					<Badge
						variant="secondary"
						class="bg-gradient-to-r from-amber-500/10 to-amber-500/10 px-2.5 py-0.5 font-mono font-semibold text-amber-700 text-lg dark:from-amber-500/20 dark:to-amber-500/20 dark:text-amber-300"
					>
						{props.state.currentInstructionIndex <= totalInstructions() ? currentOpcode() : '-'}
					</Badge>
				</div>
				<div class="flex flex-col items-center justify-center border-r p-4">
					<div class="mb-1 font-medium text-muted-foreground text-xs uppercase tracking-wider">Gas Left</div>
					<div class="font-mono font-semibold text-2xl">{props.state.gasLeft}</div>
				</div>
				<div class="flex flex-col items-center justify-center p-4">
					<div class="mb-1 font-medium text-muted-foreground text-xs uppercase tracking-wider">Depth</div>
					<div class="font-mono font-semibold text-2xl">{props.state.depth}</div>
				</div>
			</div>
		</Card>
	)
}

export default StateSummary
