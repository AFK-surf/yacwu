/// <reference types="bun" />
import { test, expect, afterEach } from 'bun:test';
import { checkRemoteUser } from '../../src/lib/server/auth';

afterEach(() => {
	delete process.env.YACWU_REMOTE_USERS;
});

test('auth disabled when no allowlist is configured', () => {
	expect(checkRemoteUser(new Headers())).toBeNull();
	expect(checkRemoteUser(new Headers({ 'remote-user': 'anyone' }))).toBeNull();
});

test('missing Remote-User header is rejected with 401', () => {
	process.env.YACWU_REMOTE_USERS = 'alice,bob';
	expect(checkRemoteUser(new Headers())).toEqual({
		status: 401,
		message: 'Missing Remote-User header'
	});
});

test('unknown user is rejected with 403', () => {
	process.env.YACWU_REMOTE_USERS = 'alice,bob';
	expect(checkRemoteUser(new Headers({ 'remote-user': 'carol' }))).toEqual({
		status: 403,
		message: 'Forbidden'
	});
});

test('listed user is allowed (and the allowlist is trimmed)', () => {
	process.env.YACWU_REMOTE_USERS = ' alice , bob ';
	expect(checkRemoteUser(new Headers({ 'remote-user': 'bob' }))).toBeNull();
});

test('the incoming Remote-User value is trimmed before matching', () => {
	process.env.YACWU_REMOTE_USERS = 'alice';
	expect(checkRemoteUser(new Headers({ 'remote-user': '  alice  ' }))).toBeNull();
});
