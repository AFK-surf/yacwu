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
