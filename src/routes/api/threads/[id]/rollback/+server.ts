import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Roll back the last N turns and return the updated thread history. */
export const POST: RequestHandler = async ({ params, request }) => {
	await codex.start();
	const body = await request.json().catch(() => ({}));
	const numTurns = Number(body?.numTurns ?? 1);
	if (!Number.isInteger(numTurns) || numTurns < 1) {
		return json({ error: 'numTurns must be a positive integer' }, { status: 400 });
	}

	const result = await codex.request('thread/rollback', {
		threadId: params.id,
		numTurns
	});
	return json(result);
};
