/**
 * Shell-style Up/Down message recall for the composer, mirroring the Codex
 * TUI's `ChatComposerHistory` (codex-rs/tui/src/bottom_pane/chat_composer_history.rs):
 *
 * - Arrows navigate history only when the composer is empty, or when its text
 *   exactly matches the last recalled entry and the caret sits at a boundary
 *   (start or end of the text). Any edit or interior caret position returns
 *   the arrows to normal cursor movement.
 * - Up recalls progressively older entries and stays put at the oldest.
 * - Down recalls newer entries; moving past the newest clears the composer
 *   and exits browsing.
 * - Submissions are recorded skipping empties and collapsing adjacent
 *   duplicates, and any recording resets the navigation cursor.
 */

export type HistoryNavigation =
	| { kind: 'ignored' }
	| { kind: 'recall'; text: string }
	| { kind: 'clear' };

export class ComposerHistory {
	private entries: string[] = [];
	private cursor: number | null = null;
	private lastRecalledText: string | null = null;

	/** Seed from a resumed thread's prior user messages (oldest first). */
	seed(texts: string[]) {
		if (this.entries.length > 0) return;
		for (const text of texts) this.push(text);
	}

	get isEmpty(): boolean {
		return this.entries.length === 0;
	}

	record(text: string) {
		this.push(text);
		this.resetNavigation();
	}

	resetNavigation() {
		this.cursor = null;
		this.lastRecalledText = null;
	}

	/**
	 * Whether an Up/Down press should navigate history rather than move the
	 * caret, given the composer's current text and caret offset.
	 */
	shouldHandleNavigation(text: string, cursor: number): boolean {
		if (this.entries.length === 0) return false;
		if (text === '') return true;
		if (cursor !== 0 && cursor !== text.length) return false;
		return this.lastRecalledText === text;
	}

	navigateUp(): HistoryNavigation {
		if (this.entries.length === 0) return { kind: 'ignored' };
		let next: number;
		if (this.cursor === null) next = this.entries.length - 1;
		else if (this.cursor === 0) return { kind: 'ignored' }; // already at oldest
		else next = this.cursor - 1;
		this.cursor = next;
		this.lastRecalledText = this.entries[next];
		return { kind: 'recall', text: this.entries[next] };
	}

	navigateDown(): HistoryNavigation {
		if (this.entries.length === 0 || this.cursor === null) return { kind: 'ignored' };
		if (this.cursor + 1 >= this.entries.length) {
			// Past newest — clear the composer and exit browsing.
			this.resetNavigation();
			return { kind: 'clear' };
		}
		this.cursor += 1;
		this.lastRecalledText = this.entries[this.cursor];
		return { kind: 'recall', text: this.entries[this.cursor] };
	}

	private push(text: string) {
		if (!text) return;
		if (this.entries[this.entries.length - 1] === text) return;
		this.entries.push(text);
	}
}
