/**
 * Backend notice lines embedded in agent-message text.
 *
 * Backends that bridge other agents into the app-server protocol stream
 * out-of-band events as plain text appended to the agent's message —
 * claude-codex, for one, emits "[Claude warning] rate limit" when the
 * provider throttles, glued directly onto whatever text the agent had
 * already produced. Lift those markers (through end-of-line) out of the
 * prose so the transcript renders them as distinct notice rows instead of
 * run-on message text.
 */

export type NoticeLevel = 'warning' | 'error' | 'event';

export type NoticeSegment =
	| { type: 'text'; text: string }
	| { type: 'notice'; level: NoticeLevel; text: string };

const NOTICE = /\[Claude (warning|error|event)\] ?([^\n]*)\n?/g;

/** Split agent-message text into prose and notice segments, in order. */
export function splitNotices(text: string): NoticeSegment[] {
	const segments: NoticeSegment[] = [];
	const pushText = (chunk: string) => {
		// Each text segment renders as its own block, so newline runs at the
		// notice boundaries are noise. Inner whitespace (indented code, blank
		// lines mid-prose) is preserved.
		const trimmed = chunk.replace(/^\n+|\n+$/g, '');
		if (trimmed.trim() !== '') segments.push({ type: 'text', text: trimmed });
	};
	let last = 0;
	NOTICE.lastIndex = 0;
	let match: RegExpExecArray | null;
	while ((match = NOTICE.exec(text))) {
		pushText(text.slice(last, match.index));
		segments.push({
			type: 'notice',
			level: match[1] as NoticeLevel,
			text: match[2]
		});
		last = NOTICE.lastIndex;
	}
	pushText(text.slice(last));
	return segments;
}
