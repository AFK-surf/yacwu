import { test, expect } from '@playwright/test';
import { spawn, type ChildProcess } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));

/** Start the holder helper (optionally resuming `resumeId`); resolve when ready. */
function startHolder(resumeId?: string): Promise<{ proc: ChildProcess; threadId: string }> {
	return new Promise((resolve, reject) => {
		const proc = spawn('node', [join(here, 'holder.mjs'), ...(resumeId ? [resumeId] : [])], {
			stdio: ['ignore', 'pipe', 'inherit']
		});
		let buf = '';
		const t = setTimeout(() => reject(new Error('holder did not start')), 30_000);
		proc.stdout!.on('data', (d) => {
			buf += d.toString();
			const m = buf.match(/READY (\S+)/);
			if (m) {
				clearTimeout(t);
				resolve({ proc, threadId: m[1] });
			}
		});
		proc.on('error', reject);
	});
}

// Sessions created during a test are real codex sessions in the shared
// ~/.codex store — visible to every other codex client on this machine. Track
// each one (by sniffing successful POST /api/threads responses) and archive
// them when the test ends, so runs don't pollute the user's session list.
const createdIds: string[] = [];

test.beforeEach(async ({ page }) => {
	createdIds.length = 0;
	await page.route('**/api/threads', async (route) => {
		if (route.request().method() !== 'POST') return route.fallback();
		const response = await route.fetch();
		try {
			const data = await response.json();
			if (data?.thread?.id) createdIds.push(data.thread.id);
			await route.fulfill({ response, json: data });
		} catch {
			await route.fulfill({ response });
		}
	});
});

test.afterEach(async ({ request }) => {
	for (const id of createdIds) {
		// Clear any goal first: a goal left active (e.g. by a mid-test failure)
		// is a real instruction codex's goal engine may autonomously pursue.
		await request
			.post(`/api/threads/${id}/goal`, { data: { clear: true } })
			.catch(() => {});
		await request.post(`/api/threads/${id}/archive`).catch(() => {});
	}
});

test('loads CLI-style dark UI', async ({ page }) => {
	await page.goto('/');
	await expect(page.locator('.brand')).toContainText('yacwu');
	// Dark background.
	const bg = await page.evaluate(() =>
		getComputedStyle(document.body).backgroundColor
	);
	expect(bg).toBe('rgb(10, 14, 20)');
	// Connection indicator turns on (SSE established).
	await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });
});

test('multi-session: create two, stream a reply, switch between them', async ({ page }) => {
	await page.goto('/');
	await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });

	// The session list loads asynchronously (thread/list can take seconds once
	// many sessions accumulate); wait for the sidebar to be fully loaded before
	// capturing the baseline count.
	await expect(page.locator('nav.sessions[data-loaded="true"]')).toBeVisible({
		timeout: 30_000
	});
	const sessionsBefore = await page.locator('.session').count();

	// Session A (default working directory via the picker).
	await page.locator('button.new').click();
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.composer')).toBeVisible();
	await expect(page.locator('.session')).toHaveCount(sessionsBefore + 1);

	// Send a deterministic prompt and watch the streamed agent reply arrive.
	await page
		.locator('.composer textarea')
		.fill('Reply with exactly the single word: PONG');
	await page.locator('button.send').click();

	// Running status appears, then an agent message containing PONG.
	await expect(page.locator('.item.agent .body').last()).toContainText('PONG', {
		timeout: 90_000
	});
	await expect(page.locator('.topbar .status')).toContainText('idle', {
		timeout: 90_000
	});

	const sessionAItems = await page.locator('.item.agent').count();
	expect(sessionAItems).toBeGreaterThan(0);

	// Session B — independent, should start empty.
	await page.locator('button.new').click();
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.session')).toHaveCount(sessionsBefore + 2);
	await expect(page.locator('.item.agent')).toHaveCount(0);

	// Switch back to Session A — its transcript (with PONG) is restored.
	await page.locator('.session').nth(1).click();
	await expect(page.locator('.item.agent .body').last()).toContainText('PONG', {
		timeout: 30_000
	});

	await page.screenshot({ path: 'tests/yacwu.png', fullPage: true });
});

test('new session can target a specific working directory', async ({ page }) => {
	await page.goto('/');
	await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });

	// Open the picker and create a session rooted at /tmp.
	await page.locator('button.new').click();
	await expect(page.locator('.cwd-input')).toBeVisible();
	await page.locator('.cwd-input').fill('/tmp');
	await page.locator('.create button.mini', { hasText: 'start' }).click();

	// Composer opens and the topbar reflects the chosen cwd.
	await expect(page.locator('.composer')).toBeVisible();
	await expect(page.locator('.topbar .meta').first()).toContainText('/tmp', {
		timeout: 15_000
	});

	// A bad directory surfaces an error instead of creating a session.
	await page.locator('button.new').click();
	await page.locator('.cwd-input').fill('/no/such/dir/xyz');
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.create-err')).toContainText('does not exist', {
		timeout: 15_000
	});
});

test('slash commands: /goal sets, shows, and clears the goal', async ({ page }) => {
	await page.goto('/');
	await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });

	await page.locator('button.new').click();
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.composer')).toBeVisible();

	const ta = page.locator('.composer textarea');

	// Unknown command is rejected client-side (no model turn).
	await ta.fill('/bogus');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note.err').last()).toContainText('unknown command');

	// /goal sets a goal -> header shows it, a note confirms.
	await ta.fill('/goal Placeholder e2e goal (not an instruction)');
	await page.locator('button.send').click();
	await expect(page.locator('.topbar .goal')).toContainText('Placeholder e2e goal (not an instruction)', {
		timeout: 15_000
	});
	await expect(page.locator('.goal-tracker')).toContainText('Placeholder e2e goal (not an instruction)');
	await expect(page.locator('.goal-tracker')).toContainText('active');
	await expect(page.locator('.item.note').last()).toContainText('goal set');

	// /goal with no arguments reads and displays the current goal.
	await ta.fill('/goal');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note').last()).toContainText(
		'goal: Placeholder e2e goal (not an instruction)',
		{ timeout: 15_000 }
	);

	// /goal clear removes it.
	await ta.fill('/goal clear');
	await page.locator('button.send').click();
	await expect(page.locator('.topbar .goal')).toHaveCount(0, { timeout: 15_000 });
	await expect(page.locator('.goal-tracker')).toHaveCount(0);
	await expect(page.locator('.item.note').last()).toContainText('goal cleared');

	let compactCalls = 0;
	await page.route('**/api/threads/*/compact', async (route) => {
		compactCalls += 1;
		await route.fulfill({ json: {} });
	});

	let reviewBody: any = null;
	await page.route('**/api/threads/*/review', async (route) => {
		reviewBody = route.request().postDataJSON();
		await route.fulfill({ json: { reviewThreadId: 'thr_test' } });
	});

	// /compact dispatches to the dedicated RPC route and marks the thread active.
	await ta.fill('/compact');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note').last()).toContainText('compacting history');
	await expect(page.locator('.topbar .status')).toContainText('running');
	expect(compactCalls).toBe(1);

	// /review forwards optional instructions to the review route.
	await ta.fill('/review focus on regressions');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note').last()).toContainText('review started');
	expect(reviewBody).toEqual({ instructions: 'focus on regressions' });

	let shellBody: any = null;
	await page.route('**/api/threads/*/shell', async (route) => {
		shellBody = route.request().postDataJSON();
		await route.fulfill({ json: {} });
	});

	// /shell forwards the command text to the shell route.
	await ta.fill('/shell git status --short');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note').last()).toContainText('shell command started');
	expect(shellBody).toEqual({ command: 'git status --short' });

	let rollbackBody: any = null;
	await page.route('**/api/threads/*/rollback', async (route) => {
		rollbackBody = route.request().postDataJSON();
		await route.fulfill({ json: { thread: { turns: [] } } });
	});

	// /rollback defaults to one turn and accepts an explicit positive integer.
	await ta.fill('/rollback');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note').last()).toContainText('rolled back 1 turn');
	expect(rollbackBody).toEqual({ numTurns: 1 });

	await ta.fill('/rollback 3');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note').last()).toContainText('rolled back 3 turns');
	expect(rollbackBody).toEqual({ numTurns: 3 });

	// Invalid arguments are rejected before hitting the RPC route.
	await ta.fill('/rollback nope');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note.err').last()).toContainText('unknown command');

	let forkedId = '';
	await page.route('**/api/threads/*/fork', async (route) => {
		forkedId = `thr_fork_${Date.now()}`;
		await route.fulfill({ json: { thread: { id: forkedId, forkedFromId: 'source' } } });
	});
	await page.route('**/api/threads/thr_fork_*/open', async (route) => {
		await route.fulfill({ json: { thread: { id: forkedId, turns: [] } } });
	});
	await page.route('**/api/threads/thr_fork_*/goal', async (route) => {
		await route.fulfill({ json: { goal: null } });
	});

	// /fork creates and selects the returned session.
	await ta.fill('/fork');
	await page.locator('button.send').click();
	await expect(page.locator(`.session[data-id="${forkedId}"]`)).toHaveClass(/active/, {
		timeout: 15_000
	});

	let archiveCalls = 0;
	await page.route('**/api/threads/thr_fork_*/archive', async (route) => {
		archiveCalls += 1;
		await route.fulfill({ json: {} });
	});

	// /archive removes the active session from the list.
	await page.locator('.composer textarea').fill('/archive');
	await page.locator('button.send').click();
	await expect(page.locator(`.session[data-id="${forkedId}"]`)).toHaveCount(0, {
		timeout: 15_000
	});
	expect(archiveCalls).toBe(1);
});

test('slash command: /status reports account, limits & session info', async ({ page }) => {
	// Deterministic account/limit data.
	await page.route('**/api/account', async (route) => {
		await route.fulfill({
			json: {
				account: { type: 'chatgpt', email: 'dev@example.com', planType: 'pro' },
				rateLimits: {
					primary: { usedPercent: 42, windowDurationMins: 300, resetsAt: 9999999999 },
					secondary: { usedPercent: 7, windowDurationMins: 10080, resetsAt: 9999999999 },
					credits: { unlimited: false, balance: '0' }
				}
			}
		});
	});
	await page.route('**/api/threads/*/model', async (route) => {
		await route.fulfill({
			json: {
				model: 'gpt-5.4',
				effort: 'high',
				models: [
					{
						id: 'gpt-5.4',
						displayName: 'GPT-5.4',
						defaultEffort: 'medium',
						efforts: ['low', 'medium', 'high']
					}
				]
			}
		});
	});

	await page.goto('/');
	await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });
	await page.locator('button.new').click();
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.composer')).toBeVisible();

	await page.locator('.composer textarea').fill('/status');
	await page.locator('button.send').click();

	const note = page.locator('.item.note .body').last();
	await expect(note).toContainText('model     gpt-5.4', { timeout: 15_000 });
	await expect(note).toContainText('effort    high');
	await expect(note).toContainText('account   dev@example.com · pro', { timeout: 15_000 });
	await expect(note).toContainText('5h limit  42% used');
	await expect(note).toContainText('7d limit  7% used');
});

test('slash command: /model lists and changes model settings', async ({ page }) => {
	let current = { model: 'gpt-5.4', effort: 'medium' };
	let posted: any = null;
	const models = [
		{
			id: 'gpt-5.4',
			displayName: 'GPT-5.4',
			defaultEffort: 'medium',
			efforts: ['low', 'medium', 'high']
		},
		{
			id: 'gpt-5.4-mini',
			displayName: 'GPT-5.4 mini',
			defaultEffort: 'low',
			efforts: ['low', 'medium']
		}
	];
	await page.route('**/api/threads/*/model', async (route) => {
		if (route.request().method() === 'POST') {
			posted = route.request().postDataJSON();
			current = { model: posted.model ?? current.model, effort: posted.effort ?? current.effort };
		}
		await route.fulfill({ json: { ...current, models } });
	});

	await page.goto('/');
	await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });
	await page.locator('button.new').click();
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.composer')).toBeVisible();

	const textarea = page.locator('.composer textarea');
	await textarea.fill('/model');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note .body').last()).toContainText('model: gpt-5.4');
	await expect(page.locator('.item.note .body').last()).toContainText('gpt-5.4-mini');

	await textarea.fill('/model gpt-5.4-mini high');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note .body').last()).toContainText(
		'model set: gpt-5.4-mini · effort high'
	);
	expect(posted).toEqual({ model: 'gpt-5.4-mini', effort: 'high' });
});

test('new transcript output preserves scroll when not at the bottom', async ({ page }) => {
	await page.goto('/');
	await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });
	await page.locator('button.new').click();
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.composer')).toBeVisible();

	const ta = page.locator('.composer textarea');
	for (let i = 0; i < 30; i += 1) {
		await ta.fill(`/bogus-${i}`);
		await page.locator('button.send').click();
		await expect(page.locator('.item.note.err').last()).toContainText('unknown command');
	}

	const transcript = page.locator('.transcript');
	await transcript.evaluate((el) => {
		el.scrollTop = 0;
	});
	const before = await transcript.evaluate((el) => el.scrollTop);

	await ta.fill('/bogus-no-scroll');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note.err').last()).toContainText('unknown command');

	const after = await transcript.evaluate((el) => el.scrollTop);
	expect(after).toBe(before);
});

test('warns when a session is in use by another codex instance', async ({ page, request }) => {
	// Pick an existing stored session and have a separate codex instance open it.
	const list = await (await request.get('/api/threads')).json();
	const target = list.data?.at(-1); // oldest — least likely already loaded by our server
	test.skip(!target, 'no existing sessions to test against');

	const { proc } = await startHolder(target.id);
	try {
		await page.goto('/');
		await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });

		const session = page.locator(`.session[data-id="${target.id}"]`);
		await expect(session).toBeVisible({ timeout: 15_000 });

		// Opening it is blocked with the conflict banner naming the holding process.
		await session.click();
		await expect(page.locator('.conflict')).toBeVisible({ timeout: 15_000 });
		await expect(page.locator('.conflict')).toContainText('another codex instance');
		await expect(page.locator('.composer')).toHaveCount(0);

		// "open anyway" overrides and loads the session.
		await page.locator('.conflict button.danger').click();
		await expect(page.locator('.conflict')).toHaveCount(0, { timeout: 15_000 });
		await expect(page.locator('.composer')).toBeVisible();
	} finally {
		proc.kill('SIGTERM');
	}
});

test('session id is reflected in the URL and the sidebar uses links', async ({ page }) => {
	await page.goto('/');
	await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });
	await expect(page).toHaveURL(/\/$/); // welcome at the root

	// Creating a session navigates to /s/<id>.
	await page.locator('button.new').click();
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.composer')).toBeVisible();
	await expect(page).toHaveURL(/\/s\/[0-9a-f-]{36}$/);
	const id = page.url().split('/s/')[1];

	// Sidebar entries are real links pointing at /s/<id>.
	const link = page.locator(`.session[data-id="${id}"]`);
	await expect(link).toHaveAttribute('href', `/s/${id}`);
	expect(await link.evaluate((el) => el.tagName)).toBe('A');

	// Deep-linking: a full reload to /s/<id> restores the session view.
	await page.goto(`/s/${id}`);
	await expect(page.locator('.composer')).toBeVisible({ timeout: 15_000 });
	await expect(page.locator('.topbar .tid')).toHaveText(id.slice(0, 8));
});

test('slash command & picker: /profile selects codex profiles', async ({ page }) => {
	const profiles = [
		{ name: 'deep', model: 'gpt-5.4' },
		{ name: 'fast', model: 'gpt-5.4-mini' }
	];
	await page.route('**/api/profiles', async (route) => {
		await route.fulfill({ json: { profiles } });
	});
	let current: string | null = null;
	let posted: any = null;
	await page.route('**/api/threads/*/profile', async (route) => {
		if (route.request().method() === 'POST') {
			posted = route.request().postDataJSON();
			current = posted.clear ? null : (posted.profile ?? null);
		}
		await route.fulfill({ json: { profile: current, profiles } });
	});
	let createBody: any = null;
	await page.route('**/api/threads', async (route) => {
		if (route.request().method() === 'POST') createBody = route.request().postDataJSON();
		await route.fallback();
	});

	await page.goto('/');
	await expect(page.locator('.brand .dot.on')).toBeVisible({ timeout: 15_000 });

	// The picker lists profiles (from the stub) with the base config default.
	await page.locator('button.new').click();
	await expect(page.locator('.profile-input')).toBeVisible();
	await expect(page.locator('.profile-input option')).toHaveCount(3);
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.composer')).toBeVisible();
	expect(createBody).toEqual({});

	// /profile shows the current selection and the available profiles.
	const ta = page.locator('.composer textarea');
	await ta.fill('/profile');
	await page.locator('button.send').click();
	const note = page.locator('.item.note .body').last();
	await expect(note).toContainText('profile: (base config)');
	await expect(note).toContainText('fast');
	await expect(note).toContainText('gpt-5.4-mini');

	// /profile <name> posts the selection; /profile clear reverts.
	await ta.fill('/profile fast');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note .body').last()).toContainText('profile set: fast');
	expect(posted).toEqual({ profile: 'fast' });

	await ta.fill('/profile clear');
	await page.locator('button.send').click();
	await expect(page.locator('.item.note .body').last()).toContainText('profile cleared');
	expect(posted).toEqual({ clear: true });

	// Creating via the picker sends the profile; the real backend rejects the
	// stub-only name, proving validation runs against the profiles on disk.
	await page.locator('button.new').click();
	await page.locator('.profile-input').selectOption('fast');
	await page.locator('.create button.mini', { hasText: 'start' }).click();
	await expect(page.locator('.create-err')).toContainText('unknown profile: fast', {
		timeout: 15_000
	});
	expect(createBody).toEqual({ profile: 'fast' });
});
