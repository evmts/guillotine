import { defineConfig } from 'tsup';

export default defineConfig({
	entry: ['src/index.ts'],
	format: ['esm'],
	dts: true,
	sourcemap: true,
	clean: true,
	outDir: 'dist',
	tsconfig: 'tsconfig.build.json',
	platform: 'node',
	target: 'es2022',
	external: ['bun:ffi'],
});
