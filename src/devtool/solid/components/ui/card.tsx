import type { ComponentProps, ParentComponent } from 'solid-js'
import { splitProps } from 'solid-js'
import { cn } from '~/lib/cn'

export const Card = (props: ComponentProps<'div'>) => {
	const [local, rest] = splitProps(props, ['class'])

	return <div class={cn('rounded-sm border bg-card text-card-foreground shadow-sm', local.class)} {...rest} />
}

export const CardHeader = (props: ComponentProps<'div'>) => {
	const [local, rest] = splitProps(props, ['class'])

	return <div class={cn('flex flex-col space-y-1.5 p-6', local.class)} {...rest} />
}

export const CardTitle: ParentComponent<ComponentProps<'h1'>> = (props) => {
	const [local, rest] = splitProps(props, ['class'])

	return <h1 class={cn('font-semibold leading-none tracking-tight', local.class)} {...rest} />
}

export const CardDescription: ParentComponent<ComponentProps<'h3'>> = (props) => {
	const [local, rest] = splitProps(props, ['class'])

	return <h3 class={cn('text-muted-foreground text-sm', local.class)} {...rest} />
}

export const CardContent = (props: ComponentProps<'div'>) => {
	const [local, rest] = splitProps(props, ['class'])

	return <div class={cn('p-6 pt-0', local.class)} {...rest} />
}

export const CardFooter = (props: ComponentProps<'div'>) => {
	const [local, rest] = splitProps(props, ['class'])

	return <div class={cn('flex items-center p-6 pt-0', local.class)} {...rest} />
}
