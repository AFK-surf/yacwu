/// <reference types="bun" />
import { expect, test } from 'bun:test';
import { currentContextTokens } from '../../src/lib/protocol';

test('context usage comes from the last request, not cumulative thread usage', () => {
	expect(
		currentContextTokens({
			total: { totalTokens: 5_367_933 },
			last: { totalTokens: 53_679 },
			modelContextWindow: 258_400
		})
	).toBe(53_679);
});

test('context usage ignores missing or invalid last-request totals', () => {
	expect(currentContextTokens({ total: { totalTokens: 5_367_933 } })).toBeNull();
	expect(currentContextTokens({ last: { totalTokens: -1 } })).toBeNull();
});
