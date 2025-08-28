import { isMobile } from '@solid-primitives/platform'
import AlertTriangleIcon from 'lucide-solid/icons/alert-triangle'
import type { JSX } from 'solid-js'
import { Popover, PopoverContent, PopoverTrigger } from './ui/popover'
import { Tooltip, TooltipContent, TooltipTrigger } from './ui/tooltip'

interface AlertTooltipProps {
	children: JSX.Element
}

const AlertTooltip = (props: AlertTooltipProps) => {
	if (isMobile)
		return (
			<Popover>
				<PopoverTrigger class="text-orange-500 transition-colors hover:text-orange-600 dark:text-orange-400 dark:hover:text-orange-300">
					<AlertTriangleIcon class="h-4 w-4" />
				</PopoverTrigger>
				<PopoverContent class="px-4 py-3">{props.children}</PopoverContent>
			</Popover>
		)
	return (
		<Tooltip openDelay={0}>
			<TooltipTrigger class="text-orange-500 transition-colors hover:text-orange-600 dark:text-orange-400 dark:hover:text-orange-300">
				<AlertTriangleIcon class="h-4 w-4" />
			</TooltipTrigger>
			<TooltipContent>{props.children}</TooltipContent>
		</Tooltip>
	)
}

export default AlertTooltip
