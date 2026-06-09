import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Interrupt the in-flight turn on a thread. */
export const POST: RequestHandler = async ({ params, request }) => {
	await codex.start();
	const body = await request.json().catch(() => ({}));
	const result = await codex.request('turn/interrupt', {
		threadId: params.id,
		turnId: body.turnId
	});
	return json(result);
};
