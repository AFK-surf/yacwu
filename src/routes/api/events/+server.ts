import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Server-Sent Events stream of every codex notification (all sessions). */
export const GET: RequestHandler = async () => {
	await codex.start();

	let unsubscribe = () => {};
	let ping: ReturnType<typeof setInterval>;

	const stream = new ReadableStream({
		start(controller) {
			const enc = new TextEncoder();
			const send = (obj: unknown) => {
				try {
					controller.enqueue(enc.encode(`data: ${JSON.stringify(obj)}\n\n`));
				} catch {
					/* stream closed */
				}
			};

			send({ method: 'yacwu/connected', params: {} });
			unsubscribe = codex.subscribe(send);
			ping = setInterval(() => {
				try {
					controller.enqueue(enc.encode(`: ping\n\n`));
				} catch {
					/* ignore */
				}
			}, 15000);
		},
		cancel() {
			clearInterval(ping);
			unsubscribe();
		}
	});

	return new Response(stream, {
		headers: {
			'content-type': 'text/event-stream',
			'cache-control': 'no-cache',
			connection: 'keep-alive'
		}
	});
};
