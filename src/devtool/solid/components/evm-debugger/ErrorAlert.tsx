import AlertCircleIcon from 'lucide-solid/icons/alert-circle'
import XIcon from 'lucide-solid/icons/x'
import { type Component, createEffect, createSignal, Show } from 'solid-js'
import { Button } from '~/components/ui/button'
import { Card } from '~/components/ui/card'
import type { EvmState } from '~/lib/types'

interface ErrorAlertProps {
	state: EvmState
}

const ErrorAlert: Component<ErrorAlertProps> = (props) => {
	// Local state to track if user has dismissed the current error
	const [dismissedError, setDismissedError] = createSignal<string | null>(null)

	// Reset dismissed state when error changes
	createEffect(() => {
		const currentError = props.state.error
		if (currentError && dismissedError() !== currentError.message) {
			setDismissedError(null)
		}
	})

	// Check if we should show the error
	const shouldShowError = () => {
		const error = props.state.error
		return error && dismissedError() !== error.message
	}

	const handleDismiss = () => {
		if (props.state.error) {
			setDismissedError(props.state.error.message)
		}
	}

	// Determine styling based on error type
	const getErrorStyles = () => {
		if (!props.state.error) return ''

		switch (props.state.error.kind) {
			case 'ExecutionError':
				// Red for execution errors - these are fatal
				return 'border-red-100 bg-red-50 text-red-800 dark:border-red-500/20 dark:bg-red-500/10 dark:text-red-300'
			case 'Revert':
				// Orange for reverts - these are controlled failures
				return 'border-orange-100 bg-orange-50 text-orange-800 dark:border-orange-500/20 dark:bg-orange-500/10 dark:text-orange-300'
			case 'BytecodeError':
				// Yellow/amber for bytecode loading errors
				return 'border-yellow-100 bg-yellow-50 text-yellow-800 dark:border-yellow-500/20 dark:bg-yellow-500/10 dark:text-yellow-300'
			default:
				return 'border-gray-100 bg-gray-50 text-gray-800 dark:border-gray-500/20 dark:bg-gray-500/10 dark:text-gray-300'
		}
	}

	const getIconColor = () => {
		if (!props.state.error) return 'text-gray-500 dark:text-gray-400'

		switch (props.state.error.kind) {
			case 'ExecutionError':
				return 'text-red-500 dark:text-red-400'
			case 'Revert':
				return 'text-orange-500 dark:text-orange-400'
			case 'BytecodeError':
				return 'text-yellow-500 dark:text-yellow-400'
			default:
				return 'text-gray-500 dark:text-gray-400'
		}
	}

	const getButtonStyles = () => {
		if (!props.state.error) return ''

		switch (props.state.error.kind) {
			case 'ExecutionError':
				return 'text-red-500 hover:bg-red-100 hover:text-red-600 dark:text-red-400 dark:hover:bg-red-500/20 dark:hover:text-red-300'
			case 'Revert':
				return 'text-orange-500 hover:bg-orange-100 hover:text-orange-600 dark:text-orange-400 dark:hover:bg-orange-500/20 dark:hover:text-orange-300'
			case 'BytecodeError':
				return 'text-yellow-500 hover:bg-yellow-100 hover:text-yellow-600 dark:text-yellow-400 dark:hover:bg-yellow-500/20 dark:hover:text-yellow-300'
			default:
				return 'text-gray-500 hover:bg-gray-100 hover:text-gray-600 dark:text-gray-400 dark:hover:bg-gray-500/20 dark:hover:text-gray-300'
		}
	}

	const getErrorTitle = () => {
		if (!props.state.error) return ''

		switch (props.state.error.kind) {
			case 'ExecutionError':
				return 'Execution Error: '
			case 'Revert':
				return 'Revert: '
			case 'BytecodeError':
				return 'Bytecode Error: '
			default:
				return 'Error: '
		}
	}

	const getErrorDescription = () => {
		if (!props.state.error) return ''
		return ''
	}

	return (
		<Show when={shouldShowError()}>
			<Card class={getErrorStyles()}>
				<div class="flex items-center justify-between p-4">
					<div class="flex items-start">
						<AlertCircleIcon class={`mt-0.5 mr-3 h-5 w-5 flex-shrink-0 ${getIconColor()}`} />
						<div class="flex-1">
							<span class="font-medium">{getErrorTitle()}</span>
							<span>{props.state.error?.message}</span>
							<span class="text-sm opacity-80">{getErrorDescription()}</span>
						</div>
					</div>
					<Button
						variant="ghost"
						size="icon"
						onClick={handleDismiss}
						class={`h-8 w-8 ${getButtonStyles()}`}
						aria-label="Dismiss error"
					>
						<XIcon class="h-5 w-5" />
					</Button>
				</div>
			</Card>
		</Show>
	)
}

export default ErrorAlert
