/// <reference types="bun" />
import { afterEach, expect, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { readLatestTurnModel } from '../../src/lib/server/threadModel';

let testDir = '';

afterEach(async () => {
	if (testDir) await rm(testDir, { recursive: true, force: true });
	testDir = '';
});

test('reads model and effort from the latest persisted turn context', async () => {
	testDir = await mkdtemp(join(tmpdir(), 'yacwu-model-'));
	const path = join(testDir, 'rollout.jsonl');
	const filler = JSON.stringify({ type: 'event_msg', payload: { value: 'x'.repeat(70_000) } });
	await writeFile(
		path,
		[
			JSON.stringify({ type: 'turn_context', payload: { model: 'old', effort: 'low' } }),
			filler,
			JSON.stringify({ type: 'turn_context', payload: { model: 'gpt-5.4', effort: 'high' } }),
			''
		].join('\n')
	);

	expect(await readLatestTurnModel(path)).toEqual({ model: 'gpt-5.4', effort: 'high' });
});

test('reads a turn context that spans multiple chunks', async () => {
	testDir = await mkdtemp(join(tmpdir(), 'yacwu-model-'));
	const path = join(testDir, 'rollout.jsonl');
	await writeFile(
		path,
		JSON.stringify({
			type: 'turn_context',
			payload: {
				model: 'gpt-5.4',
				effort: 'xhigh',
				developer_instructions: `unicode → ${'x'.repeat(70_000)}`
			}
		})
	);

	expect(await readLatestTurnModel(path)).toEqual({ model: 'gpt-5.4', effort: 'xhigh' });
});

test('returns null for a missing rollout', async () => {
	expect(await readLatestTurnModel('/definitely/missing/yacwu-rollout.jsonl')).toBeNull();
});
