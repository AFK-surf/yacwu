import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
	testDir: './tests',
	timeout: 120_000,
	expect: { timeout: 60_000 },
	fullyParallel: false,
	workers: 1,
	reporter: [['list']],
	use: {
		baseURL: 'http://127.0.0.1:5173',
		trace: 'off',
		screenshot: 'only-on-failure'
	},
	projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
	webServer: {
		command: 'bun run dev',
		url: 'http://127.0.0.1:5173',
		reuseExistingServer: true,
		timeout: 60_000
	}
});
