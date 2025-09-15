import { defineConfig } from 'tsup'

export default defineConfig({
	entry: ['src/index.ts'],
	format: ['cjs', 'esm'],
	dts: true,
	splitting: false,
	sourcemap: true,
	clean: true,
	outDir: 'dist',
	platform: 'neutral',
	target: 'es2020',
	minify: false,
	treeshake: true,
	external: [],
	noExternal: [],
	esbuildOptions(options) {
		options.mainFields = ['module', 'main']
	},
})