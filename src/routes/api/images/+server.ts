import { error } from '@sveltejs/kit';
import { readFile, stat } from 'node:fs/promises';
import { extname, isAbsolute } from 'node:path';
import type { RequestHandler } from './$types';

const MIME_BY_EXT: Record<string, string> = {
	'.gif': 'image/gif',
	'.jpg': 'image/jpeg',
	'.jpeg': 'image/jpeg',
	'.png': 'image/png',
	'.webp': 'image/webp'
};

export const GET: RequestHandler = async ({ url }) => {
	const path = url.searchParams.get('path') ?? '';
	if (!isAbsolute(path)) throw error(400, 'absolute image path required');

	const info = await stat(path).catch(() => null);
	if (!info?.isFile()) throw error(404, 'image not found');

	const type = MIME_BY_EXT[extname(path).toLowerCase()];
	if (!type) throw error(415, 'unsupported image type');

	return new Response(await readFile(path), {
		headers: {
			'content-type': type,
			'cache-control': 'no-store'
		}
	});
};
