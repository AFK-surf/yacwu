/// <reference types="bun" />
import { expect, test } from 'bun:test';
import { splitNotices } from '../../src/lib/notices';

test('plain prose passes through as one text segment', () => {
	expect(splitNotices('Hello there.\nSecond line.')).toEqual([
		{ type: 'text', text: 'Hello there.\nSecond line.' }
	]);
});

test('a trailing warning is lifted out of the message', () => {
	expect(splitNotices('Hi! What are you working on today?\n[Claude warning] rate limit\n')).toEqual([
		{ type: 'text', text: 'Hi! What are you working on today?' },
		{ type: 'notice', level: 'warning', text: 'rate limit' }
	]);
});

test('warning glued to prose without a preceding newline is lifted out', () => {
	// The adapter appends "[Claude warning] …\n" directly onto whatever text
	// the agent already produced — no separating newline.
	expect(splitNotices('Hi! What are you working on today?[Claude warning] rate limit\n')).toEqual([
		{ type: 'text', text: 'Hi! What are you working on today?' },
		{ type: 'notice', level: 'warning', text: 'rate limit' }
	]);
});

test('error and event levels are recognized and interleave with prose', () => {
	expect(
		splitNotices('[Claude event] compacting\nStill working.\n[Claude error] boom')
	).toEqual([
		{ type: 'notice', level: 'event', text: 'compacting' },
		{ type: 'text', text: 'Still working.' },
		{ type: 'notice', level: 'error', text: 'boom' }
	]);
});

test('a notice-only message yields no empty text segments', () => {
	expect(splitNotices('[Claude warning] rate limit\n')).toEqual([
		{ type: 'notice', level: 'warning', text: 'rate limit' }
	]);
});

test('unknown bracket prefixes are left alone', () => {
	expect(splitNotices('[Claude something] x')).toEqual([
		{ type: 'text', text: '[Claude something] x' }
	]);
});
