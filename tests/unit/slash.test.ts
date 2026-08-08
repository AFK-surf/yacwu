/// <reference types="bun" />
import { expect, test } from 'bun:test';
import { parseSlash } from '../../src/lib/slash';

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
