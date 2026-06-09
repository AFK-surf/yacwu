import { json } from '@sveltejs/kit';
import { codex } from '$lib/server/codex';
import type { RequestHandler } from './$types';

/** Account + rate-limit info backing the /status command. */
export const GET: RequestHandler = async () => {
	await codex.start();
	const [account, rate] = await Promise.allSettled([
		codex.request('account/read', { refreshToken: false }),
		codex.request('account/rateLimits/read', {})
	]);
	return json({
		account: account.status === 'fulfilled' ? (account.value as any)?.account ?? null : null,
		rateLimits: rate.status === 'fulfilled' ? (rate.value as any)?.rateLimits ?? null : null
	});
};
