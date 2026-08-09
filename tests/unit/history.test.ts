/// <reference types="bun" />
import { expect, test } from 'bun:test';
import { ComposerHistory } from '../../src/lib/history';

test('up recalls newest first, then older, and stays at the oldest', () => {
	const history = new ComposerHistory();
	history.record('first');
	history.record('second');

	expect(history.navigateUp()).toEqual({ kind: 'recall', text: 'second' });
	expect(history.navigateUp()).toEqual({ kind: 'recall', text: 'first' });
	expect(history.navigateUp()).toEqual({ kind: 'ignored' });
});

test('down moves toward newer entries and clears past the newest', () => {
	const history = new ComposerHistory();
	history.record('first');
	history.record('second');
	history.navigateUp();
	history.navigateUp();

	expect(history.navigateDown()).toEqual({ kind: 'recall', text: 'second' });
	expect(history.navigateDown()).toEqual({ kind: 'clear' });
	// Browsing has ended; Down does nothing until Up re-enters it.
	expect(history.navigateDown()).toEqual({ kind: 'ignored' });
});

test('down without browsing is ignored', () => {
	const history = new ComposerHistory();
	history.record('first');
	expect(history.navigateDown()).toEqual({ kind: 'ignored' });
});

test('navigation is gated on empty text or an unedited recalled entry at a boundary', () => {
	const history = new ComposerHistory();
	history.record('hello world');

	// Empty composer always navigates.
	expect(history.shouldHandleNavigation('', 0)).toBe(true);

	// A typed draft never navigates, at any caret position.
	expect(history.shouldHandleNavigation('draft', 0)).toBe(false);
	expect(history.shouldHandleNavigation('draft', 5)).toBe(false);

	// A recalled entry navigates from its boundaries only.
	history.navigateUp();
	expect(history.shouldHandleNavigation('hello world', 0)).toBe(true);
	expect(history.shouldHandleNavigation('hello world', 11)).toBe(true);
	expect(history.shouldHandleNavigation('hello world', 4)).toBe(false);

	// Editing the recalled entry exits history navigation.
	expect(history.shouldHandleNavigation('hello world!', 12)).toBe(false);
});

test('empty history never navigates', () => {
	const history = new ComposerHistory();
	expect(history.shouldHandleNavigation('', 0)).toBe(false);
	expect(history.navigateUp()).toEqual({ kind: 'ignored' });
});

test('recording skips empties, collapses adjacent duplicates, and resets the cursor', () => {
	const history = new ComposerHistory();
	history.record('a');
	history.record('a');
	history.record('');
	history.record('b');
	history.record('a');

	expect(history.navigateUp()).toEqual({ kind: 'recall', text: 'a' });
	expect(history.navigateUp()).toEqual({ kind: 'recall', text: 'b' });
	expect(history.navigateUp()).toEqual({ kind: 'recall', text: 'a' });
	expect(history.navigateUp()).toEqual({ kind: 'ignored' });

	// A new submission resumes recall from the newest entry.
	history.record('c');
	expect(history.navigateUp()).toEqual({ kind: 'recall', text: 'c' });
});

test('seeding fills an empty history once and never overwrites', () => {
	const history = new ComposerHistory();
	history.seed(['one', 'two']);
	history.seed(['three']);
	expect(history.navigateUp()).toEqual({ kind: 'recall', text: 'two' });
	expect(history.navigateUp()).toEqual({ kind: 'recall', text: 'one' });

	const recorded = new ComposerHistory();
	recorded.record('local');
	recorded.seed(['persisted']);
	expect(recorded.navigateUp()).toEqual({ kind: 'recall', text: 'local' });
	expect(recorded.navigateUp()).toEqual({ kind: 'ignored' });
});

test('resetNavigation restarts recall from the newest entry', () => {
	const history = new ComposerHistory();
	history.record('first');
	history.record('second');
	history.navigateUp();
	history.navigateUp();
	history.resetNavigation();
	expect(history.navigateUp()).toEqual({ kind: 'recall', text: 'second' });
});
