// Entry point for the single-file `yacwu` executable.
//
// `bun build --compile` bundles the SvelteKit SSR handler, but the static client
// assets are normally read off disk by the adapter. We instead embed them into
// the binary (see .gen-assets.js, produced by build-binary.ts) and serve them
// ahead of the SSR handler so the executable is fully self-contained.
import { getHandler } from '../build/handler.js';
import { ASSETS } from './.gen-assets.js';

const { fetch: ssr, websocket } = getHandler();

const port = Number(process.env.PORT ?? 3000);
const hostname = process.env.HOST ?? '127.0.0.1';
const IMMUTABLE = '/_app/immutable/';

const server = Bun.serve({
	port,
	hostname,
	...(websocket ? { websocket } : {}),
	async fetch(req, srv) {
		const { pathname } = new URL(req.url);
		const asset = ASSETS.get(pathname);
		if (asset) {
			const headers = pathname.startsWith(IMMUTABLE)
				? { 'cache-control': 'public, max-age=31536000, immutable' }
				: {};
			// Content-Type is inferred from the embedded file's extension.
			return new Response(Bun.file(asset), { headers });
		}
		return ssr(req, srv);
	}
});

console.log(`yacwu listening on http://${server.hostname}:${server.port}`);
console.log(`  working directory for new sessions: ${process.env.YACWU_CWD ?? '(home)'}`);
