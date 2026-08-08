import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),
	kit: {
		// The app is a pure SPA: the Gleam server (server/) provides the API and
		// serves this build, using index.html as the fallback for /s/<id> routes.
		adapter: adapter({ fallback: 'index.html' })
	}
};

export default config;
