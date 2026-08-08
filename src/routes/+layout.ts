// Pure SPA: no SSR, no prerendered pages — the static adapter emits a single
// index.html fallback that boots the client router for every path.
export const ssr = false;
export const prerender = false;
