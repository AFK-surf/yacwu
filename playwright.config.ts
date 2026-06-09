import { defineConfig, devices } from '@playwright/test';

const port = Number(process.env.YACWU_PORT ?? 5173);
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
	testDir: './tests',
	timeout: 120_000,
	expect: { timeout: 60_000 },
	fullyParallel: false,
	workers: 1,
	reporter: [['list']],
	use: {
		baseURL,
		trace: 'off',
		screenshot: 'only-on-failure'
	},
	projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
	webServer: {
		command: `bun run dev --port ${port}`,
		url: baseURL,
		reuseExistingServer: true,
		timeout: 60_000
	}
});
