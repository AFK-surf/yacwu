# Design — yacwu

A locked design system for the yacwu app. Every route shares this system; extend
this file when the interface needs a new visual role instead of overriding it in
one page.

## Product context

- Audience: developers who use Codex regularly and need long working sessions to remain readable.
- Primary action: start or resume a session, then follow and direct the work.
- Tone: warm editorial utility — literary in hierarchy, restrained in controls.
- Light-mode policy: the application canvas is always light. Charcoal is reserved for bounded code and command-output surfaces, never used as a page theme.

## Genre

Modern-minimal, softened with an editorial display face and Claude-derived warm surfaces.

## Macrostructure family

- Marketing pages: not currently applicable.
- App pages: **Workbench** — persistent session library, functional document header, focused reading column, anchored composer.
- Content pages: **Long Document** — cream canvas, editorial measure, minimal chrome.

## Theme

- `--color-paper` oklch(98% 0.007 88)
- `--color-paper-2` oklch(96% 0.014 82)
- `--color-paper-3` oklch(93% 0.021 78)
- `--color-ink` oklch(18% 0.009 68)
- `--color-ink-2` oklch(27% 0.012 68)
- `--color-rule` oklch(86% 0.021 76)
- `--color-accent` oklch(54% 0.14 42)
- `--color-focus` oklch(46% 0.15 40)

Coral is reserved for primary actions, current-location marks, focus, and small status signals. It should occupy less than five percent of a typical viewport.

## Typography

- Display: Newsreader, optical sizing enabled, weight 400, roman.
- Body: Inter, weight 400; 500–600 only for labels and controls.
- Mono: JetBrains Mono, weight 400; commands, paths, identifiers, and token counts only.
- Codex-sent prose: Newsreader, optical sizing enabled, weight 400, roman. Technical output and image captions retain their body or mono roles.
- Codex Markdown headings remain at prose size. Their hierarchy comes from bold weight plus visible `#`, `##`, or deeper prefixes, not enlargement.
- Display tracking: -0.026em.
- Type scale anchor: `--text-display: clamp(2.75rem, 5vw + 1rem, 5.25rem)`.

## Message identity

- User prompts are unlabelled; their tinted surface is the identity cue.
- Codex messages use no avatar or text label; their content spans the full transcript row.
- Codex replies render GitHub-flavored Markdown on the client through structured tokens; raw HTML is inert and user prompts remain plain text.
- The composer keeps a single row with icon-only attach and send controls at every width. Their accessible names remain available to assistive technology.

## Spacing

A four-point named scale lives in `tokens.css`. Components use named tokens; raw spacing values are reserved for geometry that cannot be expressed by the scale.

## Density

- Productivity surfaces use a compact desktop rhythm: 36 px controls, 8–12 px transcript gaps, and shallow tool-output padding.
- Coarse-pointer controls retain a 44 px minimum hit target even when their visual treatment is compact.
- The session rail is 17 rem wide; the transcript may use up to 68 rem so commands, plans, and diffs consume horizontal space before vertical space.
- Running prose stays at 16 px. Labels, metadata, paths, and status values may use the 12–14 px technical register.
- Persistent chrome should consume no more vertical space than its content requires. Goal state, session metadata, and composer help remain inline where the viewport permits.
- Session creation in the rail uses an icon-only plus control with a persistent accessible name; it follows the same 24 px stroke language as composer actions.
- Conversation state is icon-only: a quiet dot for idle and a pulsing activity glyph for running, always paired with an accessible name and tooltip.
- Operational transcript events are flat activity-log rows separated by hairlines. Commands, file changes, plans, reasoning, reviews, and collaboration events never receive rounded card shells or tinted fills; dark surfaces are reserved for authored fenced code.

## Motion

- Easings: `--ease-out`, `--ease-in`, and `--ease-in-out` from `tokens.css`.
- Reveal pattern: none. Working content appears immediately.
- State motion: background, opacity, and transforms only; no decorative motion.
- Reduced-motion fallback: functional changes remain, spatial transitions collapse to at most 150 ms.

## Microinteractions stance

- Silent success; errors remain visible near the action that failed.
- Keyboard focus is immediate and never animated.
- Hover is subordinate to focus and only applies on fine pointers.
- Running indicators may pulse slowly; reduced motion freezes them.

## CTA voice

- Primary CTA: coral fill, cream text, 8 px radius, concise verb-first label.
- Secondary CTA: cream surface, warm-ink text, visible hairline, same height and radius.

## Per-page allowances

- Welcome state: a spare editorial introduction and a single session-start action.
- Session state: no enrichment; conversation and tool output are the artifact.
- Content pages: typography only.

## What pages MUST share

- The yacwu wordmark and coral connection mark.
- Cream canvas, warm ink, and restrained coral placement.
- Newsreader display and Codex prose, Inter body, JetBrains Mono technical register.
- Button height, radius, focus treatment, and composer rhythm.
- Workbench shell: session rail, document header, reading column, anchored composer.

## What pages MAY differ on

- Header metadata based on session state.
- Presence of goal, conflict, side-conversation, and attachment surfaces.
- Density of technical output inside the reading column.

## Exports

### tokens.css

`tokens.css` at the project root is the canonical source. It contains the full palette, type, space, motion, radius, shadow, and z-index tokens used by the app.

### Tailwind v4 `@theme`

```css
@theme {
  --color-paper: oklch(98% 0.007 88);
  --color-paper-2: oklch(96% 0.014 82);
  --color-paper-3: oklch(93% 0.021 78);
  --color-rule: oklch(86% 0.021 76);
  --color-rule-2: oklch(73% 0.025 72);
  --color-muted: oklch(48% 0.013 72);
  --color-neutral: oklch(36% 0.014 70);
  --color-ink-2: oklch(27% 0.012 68);
  --color-ink: oklch(18% 0.009 68);
  --color-accent: oklch(54% 0.14 42);
  --color-focus: oklch(46% 0.15 40);
  --font-display: 'Newsreader', ui-serif, Georgia, serif;
  --font-body: 'Inter', ui-sans-serif, system-ui, sans-serif;
  --font-outlier: 'JetBrains Mono', ui-monospace, monospace;
  --spacing-3xs: 0.25rem;
  --spacing-2xs: 0.5rem;
  --spacing-xs: 0.75rem;
  --spacing-sm: 1rem;
  --spacing-md: 1.5rem;
  --spacing-lg: 2rem;
  --spacing-xl: 3rem;
  --spacing-2xl: 4.5rem;
	--spacing-rail: 17rem;
	--spacing-reading: 68rem;
	--spacing-control-compact: 2.25rem;
  --text-xs: 0.75rem;
  --text-sm: 0.875rem;
  --text-base: 1rem;
  --text-md: 1.125rem;
  --text-lg: 1.375rem;
  --text-xl: 1.75rem;
  --text-2xl: 2.25rem;
  --radius-card: 0.75rem;
  --radius-pill: 999rem;
  --radius-input: 0.5rem;
  --ease-out: cubic-bezier(0.16, 1, 0.3, 1);
  --ease-in: cubic-bezier(0.7, 0, 0.84, 0);
  --ease-in-out: cubic-bezier(0.65, 0, 0.35, 1);
}
```

### DTCG `tokens.json`

```json
{
  "$schema": "https://design-tokens.github.io/community-group/format/",
  "color": {
    "paper": { "$value": "oklch(98% 0.007 88)", "$type": "color" },
    "paper-2": { "$value": "oklch(96% 0.014 82)", "$type": "color" },
    "paper-3": { "$value": "oklch(93% 0.021 78)", "$type": "color" },
    "rule": { "$value": "oklch(86% 0.021 76)", "$type": "color" },
    "ink": { "$value": "oklch(18% 0.009 68)", "$type": "color" },
    "accent": { "$value": "oklch(54% 0.14 42)", "$type": "color" },
    "focus": { "$value": "oklch(46% 0.15 40)", "$type": "color" }
  },
  "font": {
    "display": { "$value": "Newsreader, ui-serif, Georgia, serif", "$type": "fontFamily" },
    "body": { "$value": "Inter, ui-sans-serif, system-ui, sans-serif", "$type": "fontFamily" },
    "outlier": { "$value": "JetBrains Mono, ui-monospace, monospace", "$type": "fontFamily" }
  },
  "space": {
    "xs": { "$value": "0.75rem", "$type": "dimension" },
    "sm": { "$value": "1rem", "$type": "dimension" },
    "md": { "$value": "1.5rem", "$type": "dimension" },
    "lg": { "$value": "2rem", "$type": "dimension" },
    "xl": { "$value": "3rem", "$type": "dimension" }
  },
	"density": {
		"rail": { "$value": "17rem", "$type": "dimension" },
		"reading": { "$value": "68rem", "$type": "dimension" },
		"control-compact": { "$value": "2.25rem", "$type": "dimension" }
	},
  "duration": {
    "micro": { "$value": "120ms", "$type": "duration" },
    "short": { "$value": "220ms", "$type": "duration" },
    "long": { "$value": "420ms", "$type": "duration" }
  }
}
```

### shadcn/ui CSS variables

```css
:root {
  --background: 98% 0.007 88;
  --foreground: 18% 0.009 68;
  --card: 96% 0.014 82;
  --card-foreground: 18% 0.009 68;
  --popover: 98% 0.007 88;
  --popover-foreground: 18% 0.009 68;
  --primary: 54% 0.14 42;
  --primary-foreground: 98% 0.007 88;
  --secondary: 93% 0.021 78;
  --secondary-foreground: 27% 0.012 68;
  --muted: 86% 0.021 76;
  --muted-foreground: 48% 0.013 72;
  --accent: 54% 0.14 42;
  --accent-foreground: 98% 0.007 88;
  --destructive: 51% 0.18 28;
  --destructive-foreground: 98% 0.007 88;
  --border: 86% 0.021 76;
  --input: 86% 0.021 76;
  --ring: 46% 0.15 40;
  --radius: 0.75rem;
}
```
