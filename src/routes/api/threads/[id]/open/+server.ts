import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import { THREAD_DEFAULTS } from '$lib/server/defaults';
import { detectExternalHolders } from '$lib/server/sessionLock';
import type { RequestHandler } from './$types';

/**
 * Open a session: resume it (loads it into memory + subscribes this connection
 * to its live events) and return its full prior history so the UI can render it.
 *
 * Before resuming, we check whether another codex instance on this machine
 * already has the session's rollout file open. If so we refuse with 409 unless
 * the caller passes `{ force: true }`, so two codex processes don't drive the
 * same conversation concurrently (which would diverge / corrupt its history).
 */
export const POST: RequestHandler = async ({ params, request }) => {
	await codex.start();
	const threadId = params.id;
	const body = await request.json().catch(() => ({}));
	const force = body?.force === true;

	// thread/read returns the rollout path WITHOUT loading the thread into memory.
	const read = await codex.request<{ thread?: { path?: string } }>('thread/read', {
		threadId,
		includeTurns: true
	});
	const rolloutPath = read?.thread?.path ?? '';

	if (!force) {
		const holders = detectExternalHolders(rolloutPath, codex.pid);
		if (holders.length > 0) {
			return json({ conflict: true, holders, thread: read?.thread }, { status: 409 });
		}
	}

	await codex.request('thread/resume', { threadId, ...THREAD_DEFAULTS });
	return json(read);
};
