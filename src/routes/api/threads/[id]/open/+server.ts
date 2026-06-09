import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import { THREAD_DEFAULTS } from '$lib/server/defaults';
import type { RequestHandler } from './$types';

/**
 * Open a session: resume it (loads it into memory + subscribes this connection
 * to its live events) and return its full prior history so the UI can render it.
 */
export const POST: RequestHandler = async ({ params }) => {
	await codex.start();
	const threadId = params.id;
	await codex.request('thread/resume', { threadId, ...THREAD_DEFAULTS });
	const read = await codex.request('thread/read', { threadId, includeTurns: true });
	return json(read);
};
