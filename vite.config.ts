import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// `vite dev` serves only the frontend; API requests are proxied to the Gleam
// backend (server/), which must be running separately (`bun run dev:server`).
const apiTarget = process.env.YACWU_API ?? 'http://127.0.0.1:3000';

export default defineConfig({
	plugins: [sveltekit()],
	server: {
		host: '127.0.0.1',
		port: 5173,
		proxy: {
			'/api': {
				target: apiTarget,
				// /api/events is SSE; disable idle timeouts so the stream stays up.
				proxyTimeout: 0,
				timeout: 0
			}
		}
	}
});
