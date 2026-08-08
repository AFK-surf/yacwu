import { open } from 'node:fs/promises';
import { codex } from '$lib/server/codex';

export interface ThreadModelSettings {
	model: string;
	effort: string;
}

export interface ModelChoice {
	id: string;
	displayName: string;
	defaultEffort: string;
	efforts: string[];
}

interface RawModel {
	id?: unknown;
	model?: unknown;
	displayName?: unknown;
	defaultReasoningEffort?: unknown;
	supportedReasoningEfforts?: unknown;
	isDefault?: unknown;
}

const globalState = globalThis as typeof globalThis & {
	__yacwu_thread_models?: Map<string, ThreadModelSettings>;
};
const overrides =
	globalState.__yacwu_thread_models ?? (globalState.__yacwu_thread_models = new Map());

function effortName(value: unknown): string | null {
	if (typeof value === 'string' && value) return value;
	if (value && typeof value === 'object') {
		const effort = (value as Record<string, unknown>).reasoningEffort;
		if (typeof effort === 'string' && effort) return effort;
	}
	return null;
}

function normalizeModel(raw: RawModel): ModelChoice | null {
	const id =
		typeof raw.model === 'string' && raw.model
			? raw.model
			: typeof raw.id === 'string' && raw.id
				? raw.id
				: null;
	if (!id) return null;

	const efforts = Array.isArray(raw.supportedReasoningEfforts)
		? raw.supportedReasoningEfforts.map(effortName).filter((value): value is string => value !== null)
		: [];
	const defaultEffort = effortName(raw.defaultReasoningEffort) ?? efforts[0] ?? 'medium';
	return {
		id,
		displayName: typeof raw.displayName === 'string' ? raw.displayName : id,
		defaultEffort,
		efforts
	};
}

export async function listModelChoices(): Promise<{ models: ModelChoice[]; defaultModel: string | null }> {
	const models: ModelChoice[] = [];
	let defaultModel: string | null = null;
	let cursor: string | undefined;

	do {
		const result = await codex.request<{ data?: RawModel[]; nextCursor?: string | null }>('model/list', {
			limit: 100,
			includeHidden: false,
			...(cursor ? { cursor } : {})
		});
		for (const raw of result.data ?? []) {
			const model = normalizeModel(raw);
			if (!model) continue;
			models.push(model);
			if (raw.isDefault === true) defaultModel = model.id;
		}
		cursor = result.nextCursor ?? undefined;
	} while (cursor);

	return { models, defaultModel: defaultModel ?? models[0]?.id ?? null };
}

/** Read the latest persisted turn context without loading a whole rollout into memory. */
export async function readLatestTurnModel(path: string): Promise<Partial<ThreadModelSettings> | null> {
	if (!path) return null;
	let file;
	try {
		file = await open(path, 'r');
	} catch {
		return null;
	}

	try {
		const { size } = await file.stat();
		const chunkSize = 64 * 1024;
		let position = size;
		let partial = Buffer.alloc(0);

		while (position > 0) {
			const length = Math.min(chunkSize, position);
			position -= length;
			const bytes = Buffer.allocUnsafe(length);
			await file.read(bytes, 0, length, position);
			const combined = Buffer.concat([bytes, partial]);
			let lineEnd = combined.length;

			for (let i = combined.length - 1; i >= 0; i -= 1) {
				if (combined[i] !== 10) continue;
				const settings = parseTurnContext(combined.subarray(i + 1, lineEnd).toString('utf8'));
				if (settings) return settings;
				lineEnd = i;
			}
			partial = Buffer.from(combined.subarray(0, lineEnd));
		}

		return parseTurnContext(partial.toString('utf8'));
	} finally {
		await file.close();
	}
}

function parseTurnContext(line: string): Partial<ThreadModelSettings> | null {
	if (!line.includes('turn_context')) return null;
	try {
		const event = JSON.parse(line);
		if (event?.type !== 'turn_context') return null;
		const payload = event.payload ?? {};
		const model = typeof payload.model === 'string' ? payload.model : undefined;
		const effort =
			typeof payload.effort === 'string'
				? payload.effort
				: typeof payload.reasoning_effort === 'string'
					? payload.reasoning_effort
					: undefined;
		return model || effort ? { model, effort } : null;
	} catch {
		return null;
	}
}

async function configuredSettings(): Promise<Partial<ThreadModelSettings>> {
	try {
		const result = await codex.request<{ config?: Record<string, unknown> }>('config/read', {
			includeLayers: false
		});
		const config = result.config ?? {};
		return {
			model: typeof config.model === 'string' ? config.model : undefined,
			effort:
				typeof config.model_reasoning_effort === 'string'
					? config.model_reasoning_effort
					: typeof config.modelReasoningEffort === 'string'
						? config.modelReasoningEffort
						: undefined
		};
	} catch {
		return {};
	}
}

export async function getThreadModelState(
	threadId: string
): Promise<ThreadModelSettings & { models: ModelChoice[] }> {
	const catalog = await listModelChoices();
	const selected = overrides.get(threadId);
	if (selected) return { ...selected, models: catalog.models };

	let persisted: Partial<ThreadModelSettings> = {};
	try {
		const read = await codex.request<{ thread?: { path?: string } }>('thread/read', {
			threadId,
			includeTurns: false
		});
		persisted = (await readLatestTurnModel(read.thread?.path ?? '')) ?? {};
	} catch {
		// A new thread has no rollout until its first turn.
	}

	const config = await configuredSettings();
	const model = persisted.model ?? config.model ?? catalog.defaultModel;
	if (!model) throw new Error('no models are available');
	const choice = catalog.models.find((candidate) => candidate.id === model);
	const effort = persisted.effort ?? config.effort ?? choice?.defaultEffort ?? 'medium';
	return { model, effort, models: catalog.models };
}

export async function setThreadModelState(
	threadId: string,
	requested: Partial<ThreadModelSettings>
): Promise<ThreadModelSettings & { models: ModelChoice[] }> {
	const current = await getThreadModelState(threadId);
	const model = requested.model ?? current.model;
	const choice = current.models.find((candidate) => candidate.id === model);
	if (!choice) throw new Error(`unknown model: ${model}`);

	let effort = requested.effort;
	if (!effort) {
		effort = choice.efforts.includes(current.effort) ? current.effort : choice.defaultEffort;
	}
	if (choice.efforts.length > 0 && !choice.efforts.includes(effort)) {
		throw new Error(
			`unsupported effort for ${model}: ${effort} (choose ${choice.efforts.join(', ')})`
		);
	}

	const selected = { model, effort };
	overrides.set(threadId, selected);
	return { ...selected, models: current.models };
}

/** Overrides included on turns after the user explicitly runs /model. */
export function getThreadModelOverride(threadId: string): ThreadModelSettings | null {
	return overrides.get(threadId) ?? null;
}
