import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Archive a thread so it no longer appears in the active session list. */
export const POST: RequestHandler = async ({ params }) => {
	await codex.start();
	const result = await codex.request('thread/archive', { threadId: params.id });
	return json(result);
};
