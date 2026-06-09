import adapterNode from '@sveltejs/adapter-node';
import adapterBun from 'svelte-adapter-bun';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

// `bun run build:bin` sets YACWU_BINARY=1 to emit a Bun-native server that we
// then compile into a single executable. The default build keeps adapter-node.
const useBun = !!process.env.YACWU_BINARY;

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),
	kit: {
		adapter: useBun ? adapterBun() : adapterNode()
	}
};

export default config;
