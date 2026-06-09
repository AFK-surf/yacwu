import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Run a user-initiated shell command attached to the thread. */
export const POST: RequestHandler = async ({ params, request }) => {
	await codex.start();
	const body = await request.json().catch(() => ({}));
	const command = (body?.command ?? '').toString().trim();
	if (!command) return json({ error: 'shell command is required' }, { status: 400 });

	const result = await codex.request('thread/shellCommand', {
		threadId: params.id,
		command
	});
	return json(result);
};
