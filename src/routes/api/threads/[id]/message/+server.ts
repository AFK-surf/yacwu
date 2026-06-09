import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Send user input, starting a new turn on the thread. */
export const POST: RequestHandler = async ({ params, request }) => {
	await codex.start();
	const body = await request.json().catch(() => ({}));
	const text = (body.text ?? '').toString();
	if (!text.trim()) return json({ error: 'empty message' }, { status: 400 });

	const result = await codex.request('turn/start', {
		threadId: params.id,
		input: [{ type: 'text', text }]
	});
	return json(result);
};
