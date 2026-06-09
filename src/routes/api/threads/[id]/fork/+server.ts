import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Fork a stored thread into a new session. */
export const POST: RequestHandler = async ({ params }) => {
	await codex.start();
	const result = await codex.request('thread/fork', { threadId: params.id });
	return json(result);
};
