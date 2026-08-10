import { defineConfig, devices } from '@playwright/test';

const port = Number(process.env.YACWU_PORT ?? 5173);
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
	testDir: './tests',
	// e2e specs use *.spec.ts; *.test.ts under tests/unit runs via `bun test`.
	testMatch: '**/*.spec.ts',
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
		// Build the static SPA, then serve it (and the API) from the Gleam backend.
		// The server fails closed without auth; the e2e suite runs it open on loopback.
		command: `bun run build && cd server && YACWU_STATIC=../build YACWU_INSECURE_SKIP_AUTH=1 gleam run -- --host 127.0.0.1 --port ${port}`,
		url: baseURL,
		reuseExistingServer: true,
		timeout: 120_000
	}
});
