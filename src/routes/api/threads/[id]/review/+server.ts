import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/**
 * Start a Codex review (the TUI's /review). With no instructions it reviews the
 * uncommitted changes; with free-form text it runs a custom review.
 */
export const POST: RequestHandler = async ({ params, request }) => {
	await codex.start();
	const body = await request.json().catch(() => ({}));
	const instructions = (body?.instructions ?? '').toString().trim();

	const target = instructions
		? { type: 'custom', instructions }
		: { type: 'uncommittedChanges' };

	const result = await codex.request('review/start', {
		threadId: params.id,
		delivery: 'inline',
		target
	});
	return json(result);
};
