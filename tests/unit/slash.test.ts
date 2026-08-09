/// <reference types="bun" />
import { expect, test } from 'bun:test';
import { parseSlash } from '../../src/lib/slash';

test('/fast toggles Fast mode without arguments', () => {
	expect(parseSlash('/fast')).toEqual({ kind: 'fast' });
	expect(parseSlash('/FAST')).toEqual({ kind: 'fast' });
	expect(parseSlash('/fast on')).toEqual({ kind: 'unknown', command: '/fast' });
});

test('/model shows model choices without arguments', () => {
	expect(parseSlash('/model')).toEqual({ kind: 'model-show' });
});

test('/model accepts a model and optional effort', () => {
	expect(parseSlash('/model gpt-5.4')).toEqual({ kind: 'model-set', model: 'gpt-5.4' });
	expect(parseSlash('/model gpt-5.4 high')).toEqual({
		kind: 'model-set',
		model: 'gpt-5.4',
		effort: 'high'
	});
	expect(parseSlash('/model gpt-5.4 --effort HIGH')).toEqual({
		kind: 'model-set',
		model: 'gpt-5.4',
		effort: 'high'
	});
});

test('/model can change only the effort and rejects extra arguments', () => {
	expect(parseSlash('/model --effort xhigh')).toEqual({ kind: 'model-set', effort: 'xhigh' });
	expect(parseSlash('/model gpt-5.4 high extra')).toEqual({
		kind: 'unknown',
		command: '/model'
	});
});

test('/profile shows the current profile without arguments', () => {
	expect(parseSlash('/profile')).toEqual({ kind: 'profile-show' });
});

test('/profile selects a named profile', () => {
	expect(parseSlash('/profile fast')).toEqual({ kind: 'profile-set', profile: 'fast' });
	expect(parseSlash('/profile deep review')).toEqual({
		kind: 'profile-set',
		profile: 'deep review'
	});
});

test('/profile clear (or default) reverts to the base config', () => {
	expect(parseSlash('/profile clear')).toEqual({ kind: 'profile-clear' });
	expect(parseSlash('/profile DEFAULT')).toEqual({ kind: 'profile-clear' });
});

test('/btw starts an empty side conversation without arguments', () => {
	expect(parseSlash('/btw')).toEqual({ kind: 'btw' });
});

test('/btw carries the question as the first side-conversation message', () => {
	expect(parseSlash('/btw what does parseSlash do?')).toEqual({
		kind: 'btw',
		message: 'what does parseSlash do?'
	});
	expect(parseSlash('/side quick question')).toEqual({ kind: 'btw', message: 'quick question' });
});

test('SLASH_COMMANDS derives one popup entry per command with arg hints', async () => {
	const { SLASH_COMMANDS } = await import('../../src/lib/slash');
	const names = SLASH_COMMANDS.map((c) => c.name);
	expect(new Set(names).size).toBe(names.length);
	expect(names[0]).toBe('/status');
	const model = SLASH_COMMANDS.find((c) => c.name === '/model');
	expect(model?.args).toBe('<model> [effort]');
	expect(model?.description).toBe('show the current model and available choices');
	const goal = SLASH_COMMANDS.find((c) => c.name === '/goal');
	expect(goal?.args).toBe('<objective>');
});

test('filterSlashCommands lists all for an empty fragment and prefix-matches otherwise', async () => {
	const { SLASH_COMMANDS, filterSlashCommands } = await import('../../src/lib/slash');
	expect(filterSlashCommands('')).toEqual([...SLASH_COMMANDS]);
	expect(filterSlashCommands('mo').map((c) => c.name)).toEqual(['/model']);
	expect(filterSlashCommands('f').map((c) => c.name)).toEqual(['/fast', '/fork']);
	expect(filterSlashCommands('FAST').map((c) => c.name)).toEqual(['/fast']);
	expect(filterSlashCommands('zzz')).toEqual([]);
});
