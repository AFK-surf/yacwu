export type SlashCommand =
	| { kind: 'help' }
	| { kind: 'status' }
	| { kind: 'model-show' }
	| { kind: 'model-set'; model?: string; effort?: string }
	| { kind: 'profile-show' }
	| { kind: 'profile-set'; profile: string }
	| { kind: 'profile-clear' }
	| { kind: 'goal-show' }
	| { kind: 'goal-clear' }
	| { kind: 'goal-set'; objective: string; tokenBudget?: number }
	| { kind: 'compact' }
	| { kind: 'review'; instructions?: string }
	| { kind: 'shell'; command: string }
	| { kind: 'rollback'; numTurns: number }
	| { kind: 'fork' }
	| { kind: 'btw'; message?: string }
	| { kind: 'archive' }
	| { kind: 'unknown'; command: string };

const COMMANDS: ReadonlyArray<readonly [string, string]> = [
	['/status', 'show account, limits & session info'],
	['/model', 'show the current model and available choices'],
	['/model <model> [effort]', 'change model and reasoning effort'],
	['/model --effort <effort>', 'change reasoning effort only'],
	['/profile', 'show the session profile and available choices'],
	['/profile <name>', 'switch this session to a codex profile'],
	['/profile clear', 'go back to the base codex config'],
	['/goal <objective>', 'set the thread goal'],
	['/goal --budget N <goal>', 'set the goal with a token budget'],
	['/goal', 'show the current goal'],
	['/goal clear', 'clear the goal'],
	['/compact', 'compact conversation history'],
	['/review [notes]', 'review uncommitted changes (or custom notes)'],
	['/shell <command>', 'run a shell command in the thread'],
	['/rollback [turns]', 'roll back recent turns (default: 1)'],
	['/fork', 'branch this thread into a new session'],
	['/btw [question]', 'start an ephemeral side conversation'],
	['/archive', 'archive this session'],
	['/help', 'show this help']
];

export const SLASH_HELP = COMMANDS.map(([cmd, desc]) => `${cmd.padEnd(25)}${desc}`).join('\n');

function parseGoal(arg: string): SlashCommand {
	if (!arg) return { kind: 'goal-show' };
	if (arg.toLowerCase() === 'clear') return { kind: 'goal-clear' };

	const budgetMatch = arg.match(/^--budget\s+(\d+)\s+(.+)$/i);
	if (budgetMatch) {
		const tokenBudget = Number(budgetMatch[1]);
		if (!Number.isSafeInteger(tokenBudget) || tokenBudget < 1) {
			return { kind: 'unknown', command: '/goal' };
		}
		return {
			kind: 'goal-set',
			tokenBudget,
			objective: budgetMatch[2].trim()
		};
	}

	return { kind: 'goal-set', objective: arg };
}

function parseModel(arg: string): SlashCommand {
	if (!arg) return { kind: 'model-show' };

	const parts = arg.split(/\s+/);
	if (parts.length === 2 && parts[0].toLowerCase() === '--effort') {
		return { kind: 'model-set', effort: parts[1].toLowerCase() };
	}
	if (parts.length === 1) return { kind: 'model-set', model: parts[0] };
	if (parts.length === 2) {
		return { kind: 'model-set', model: parts[0], effort: parts[1].toLowerCase() };
	}
	if (parts.length === 3 && parts[1].toLowerCase() === '--effort') {
		return { kind: 'model-set', model: parts[0], effort: parts[2].toLowerCase() };
	}

	return { kind: 'unknown', command: '/model' };
}

export function parseSlash(text: string): SlashCommand {
	const trimmed = text.trim();
	const space = trimmed.search(/\s/);
	const cmd = (space === -1 ? trimmed : trimmed.slice(0, space)).toLowerCase();
	const arg = space === -1 ? '' : trimmed.slice(space + 1).trim();

	switch (cmd) {
		case '/?':
		case '/help':
			return arg ? { kind: 'unknown', command: cmd } : { kind: 'help' };
		case '/status':
			return arg ? { kind: 'unknown', command: cmd } : { kind: 'status' };
		case '/model':
			return parseModel(arg);
		case '/profile': {
			if (!arg) return { kind: 'profile-show' };
			const lower = arg.toLowerCase();
			if (lower === 'clear' || lower === 'default') return { kind: 'profile-clear' };
			return { kind: 'profile-set', profile: arg };
		}
		case '/goal':
			return parseGoal(arg);
		case '/compact':
			return arg ? { kind: 'unknown', command: cmd } : { kind: 'compact' };
		case '/review':
			return arg ? { kind: 'review', instructions: arg } : { kind: 'review' };
		case '/shell':
		case '/exec':
			return arg ? { kind: 'shell', command: arg } : { kind: 'unknown', command: cmd };
		case '/rollback': {
			if (!arg) return { kind: 'rollback', numTurns: 1 };
			const numTurns = Number(arg);
			if (Number.isInteger(numTurns) && numTurns > 0) return { kind: 'rollback', numTurns };
			return { kind: 'unknown', command: cmd };
		}
		case '/fork':
			return arg ? { kind: 'unknown', command: cmd } : { kind: 'fork' };
		case '/btw':
		case '/side':
			return arg ? { kind: 'btw', message: arg } : { kind: 'btw' };
		case '/archive':
			return arg ? { kind: 'unknown', command: cmd } : { kind: 'archive' };
		default:
			return { kind: 'unknown', command: cmd };
	}
}
