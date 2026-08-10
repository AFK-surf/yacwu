/// <reference types="bun" />
import { expect, test } from 'bun:test';
import { currentContextTokens, hostQuery, isRemoteHost, LOCAL_HOST } from '../../src/lib/protocol';

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

test('local and unknown hosts add no routing hint, remote hosts do', () => {
	expect(hostQuery(undefined)).toBe('');
	expect(hostQuery(null)).toBe('');
	expect(hostQuery('')).toBe('');
	expect(hostQuery(LOCAL_HOST)).toBe('');
	expect(hostQuery('devbox')).toBe('?host=devbox');
	expect(hostQuery('user@host.example')).toBe('?host=user%40host.example');
});

test('isRemoteHost treats only concrete non-local names as remote', () => {
	expect(isRemoteHost('devbox')).toBe(true);
	expect(isRemoteHost(LOCAL_HOST)).toBe(false);
	expect(isRemoteHost('')).toBe(false);
	expect(isRemoteHost(undefined)).toBe(false);
	expect(isRemoteHost(null)).toBe(false);
});
