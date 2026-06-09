// Entry point for the single-file `yacwu` executable.
//
// `bun build --compile` bundles the SvelteKit SSR handler, but the static client
// assets are normally read off disk by the adapter. We instead embed them into
// the binary (see .gen-assets.js, produced by build-binary.ts) and serve them
// ahead of the SSR handler so the executable is fully self-contained.
import { getHandler } from '../build/handler.js';
import { ASSETS } from './.gen-assets.js';

const USAGE = `yacwu — minimalist Codex web UI

Usage: yacwu [options] [address]

Options:
  -H, --host <host>   listening host (default: 127.0.0.1, or $HOST)
  -p, --port <port>   listening port (default: 3000, or $PORT)
      --unix <path>   listen on a Unix domain socket instead of host:port
  -h, --help          show this help and exit

Address:
  A positional host:port may be given instead of -H/-p, e.g.
    yacwu 0.0.0.0:8080      yacwu :8080      yacwu 192.168.1.5

Environment:
  HOST, PORT          fallbacks for --host / --port
  YACWU_CWD           working directory for new Codex sessions
`;

/** Split a "host:port" / ":port" / "host" / "port" token. */
function parseAddress(addr) {
	const result = {};
	if (addr.includes(':')) {
		const idx = addr.lastIndexOf(':');
		const host = addr.slice(0, idx);
		const port = addr.slice(idx + 1);
		if (host) result.host = host;
		if (port) result.port = port;
	} else if (/^\d+$/.test(addr)) {
		result.port = addr;
	} else {
		result.host = addr;
	}
	return result;
}

function parseArgs(argv) {
	const opts = {};
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		const eq = a.indexOf('=');
		const flag = a.startsWith('--') && eq !== -1 ? a.slice(0, eq) : a;
		const inlineVal = a.startsWith('--') && eq !== -1 ? a.slice(eq + 1) : undefined;
		const next = () => inlineVal ?? argv[++i];

		switch (flag) {
			case '-h':
			case '--help':
				opts.help = true;
				break;
			case '-H':
			case '--host':
				opts.host = next();
				break;
			case '-p':
			case '--port':
				opts.port = next();
				break;
			case '--unix':
				opts.unix = next();
				break;
			default:
				if (a.startsWith('-')) {
					console.error(`yacwu: unknown option '${a}'\n`);
					process.stderr.write(USAGE);
					process.exit(1);
				}
				Object.assign(opts, parseAddress(a)); // positional address
		}
	}
	return opts;
}

const opts = parseArgs(process.argv.slice(2));
if (opts.help) {
	process.stdout.write(USAGE);
	process.exit(0);
}

const host = opts.host ?? process.env.HOST ?? '127.0.0.1';
const portRaw = opts.port ?? process.env.PORT ?? '3000';
const port = Number(portRaw);
if (!opts.unix && (!Number.isInteger(port) || port < 0 || port > 65535)) {
	console.error(`yacwu: invalid port '${portRaw}'`);
	process.exit(1);
}

const { fetch: ssr, websocket } = getHandler();
const IMMUTABLE = '/_app/immutable/';

const serve = {
	...(opts.unix ? { unix: opts.unix } : { hostname: host, port }),
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
};

const server = Bun.serve(serve);

const where = opts.unix ? `unix:${opts.unix}` : `http://${server.hostname}:${server.port}`;
console.log(`yacwu listening on ${where}`);
console.log(`  working directory for new sessions: ${process.env.YACWU_CWD ?? '(home)'}`);
