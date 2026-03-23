import { create } from 'zustand';

import AuthManager from '../AuthManager';
import ProxyManager from '../ProxyManager';
import type {
    BuilderActivityItem,
    BuilderReviewSection,
    BuilderSetupState,
    BuilderUiField,
    BuilderUiRequest,
    BuilderUiResponsePayload,
} from './builder-types';

export interface VibeAgentBuilderMessage {
    id?: string;
    role: 'user' | 'assistant';
    content: string;
    timestamp?: number;
    isStreaming?: boolean;
}

export interface VibeStandaloneAgent {
    id: string;
    userId?: string;
    username?: string;
    displayName?: string;
    status?: string;
    systemPrompt?: string;
    persona?: string | null;
    avatarUrl?: string | null;
    welcomeMessage?: string | null;
    enabledTools?: string[];
    outputModes?: string[];
    autonomyMode?: string | null;
    defaultDestinationChatId?: string | null;
    eventTypesEnabled?: string[];
    costBudgetDaily?: number | null;
    costBudgetMonthly?: number | null;
    approvalRules?: Record<string, unknown> | null;
    runbookIds?: string[];
    voiceProvider?: string | null;
    voiceProfile?: string | null;
    callbackUrl?: string | null;
    secretHint?: string | null;
    publishedAt?: string | null;
    lastInvokedAt?: string | null;
    attachedChats?: Array<Record<string, unknown>>;
    integrations?: Array<Record<string, unknown>>;
}

interface VibeAgentQuota {
    used: number;
    limit: number;
    remaining: number;
}

interface BuilderSessionPayload {
    conversationId?: string | null;
    activeAgentId?: string | null;
    messages?: VibeAgentBuilderMessage[];
    draftPatch?: Record<string, unknown>;
    agent?: VibeStandaloneAgent | null;
    suggestions?: string[];
    latestSecret?: string | null;
    setupState?: BuilderSetupState | null;
    pendingUiRequest?: BuilderUiRequest | null;
    reviewSections?: BuilderReviewSection[];
    activity?: BuilderActivityItem[];
}

interface BuilderStreamDonePayload extends BuilderSessionPayload {
    reply?: string | null;
}

interface BuilderOptimisticMessageOptions {
    messageId?: string;
    timestamp?: number;
}

interface BuilderInputConfig {
    message?: string | null;
    uiResponse?: BuilderUiResponsePayload | null;
    optimisticUserContent?: string | null;
    optimistic?: BuilderOptimisticMessageOptions;
}

interface VibeAgentBuilderState {
    agents: VibeStandaloneAgent[];
    quota: VibeAgentQuota | null;
    conversationId: string | null;
    activeAgentId: string | null;
    messages: VibeAgentBuilderMessage[];
    draftPatch: Record<string, unknown>;
    agent: VibeStandaloneAgent | null;
    suggestions: string[];
    latestSecret: string | null;
    setupState: BuilderSetupState | null;
    pendingUiRequest: BuilderUiRequest | null;
    reviewSections: BuilderReviewSection[];
    activity: BuilderActivityItem[];
    isLoading: boolean;
    isSending: boolean;
    error: string | null;
    load: () => Promise<void>;
    refreshAgents: () => Promise<void>;
    sendMessage: (message: string, optimistic?: BuilderOptimisticMessageOptions) => Promise<void>;
    submitUiResponse: (
        requestId: string,
        answers: Record<string, unknown>,
        optimisticUserContent?: string,
    ) => Promise<void>;
    createDraftFromReview: () => Promise<void>;
    createAgent: (displayName?: string) => Promise<void>;
    selectAgent: (agentId: string) => Promise<void>;
    publishActive: () => Promise<void>;
    toggleDisableActive: () => Promise<void>;
    rotateSecretActive: () => Promise<void>;
    clearLatestSecret: () => void;
    clearError: () => void;
}

const defaultSuggestions = [
    'I need an agent for my shoes store.',
    'Set up an order operations agent and ask only what you need.',
    'Create a customer support agent with a publish-ready draft.',
    'How do I call this agent from my backend and webhook?',
];

const createLocalMessageId = (prefix: 'user' | 'assistant') => {
    return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
};

const normalizeString = (value: unknown): string | null => {
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
};

const normalizeStringArray = (value: unknown): string[] => {
    if (!Array.isArray(value)) return [];
    return value
        .map((item) => normalizeString(item))
        .filter((item): item is string => !!item);
};

const normalizeFieldOptions = (value: unknown) => {
    if (!Array.isArray(value)) return [];
    return value
        .map((entry) => {
            if (!entry || typeof entry !== 'object') return null;
            const option = entry as Record<string, unknown>;
            const id = normalizeString(option.id);
            const label = normalizeString(option.label);
            if (!id || !label) return null;
            return {
                id,
                label,
                hint: normalizeString(option.hint),
            };
        })
        .filter((entry): entry is { id: string; label: string; hint?: string | null } => !!entry);
};

const normalizeUiField = (value: unknown): BuilderUiField | null => {
    if (!value || typeof value !== 'object') return null;
    const raw = value as Record<string, unknown>;
    const key = normalizeString(raw.key);
    const label = normalizeString(raw.label);
    const type = normalizeString(raw.type);
    if (!key || !label || !type) return null;

    if (type === 'single_select' || type === 'multi_select') {
        const options = normalizeFieldOptions(raw.options);
        if (options.length === 0) return null;
        return {
            key,
            label,
            type,
            required: raw.required === true,
            options,
            renderHint: raw.renderHint === 'tabs' ? 'tabs' : 'chips',
            allowCustom: raw.allowCustom === true,
            placeholder: normalizeString(raw.placeholder),
            value: raw.value,
        };
    }

    if (type === 'text' || type === 'long_text') {
        return {
            key,
            label,
            type,
            required: raw.required === true,
            placeholder: normalizeString(raw.placeholder),
            value: raw.value,
        };
    }

    if (type === 'chat_picker') {
        return {
            key,
            label,
            type,
            required: raw.required === true,
            value: raw.value,
        };
    }

    return null;
};

const normalizeUiRequest = (value: unknown): BuilderUiRequest | null => {
    if (!value || typeof value !== 'object') return null;
    const raw = value as Record<string, unknown>;
    const id = normalizeString(raw.id);
    const title = normalizeString(raw.title);
    if (!id || !title) return null;

    const fields = Array.isArray(raw.fields)
        ? raw.fields.map((field) => normalizeUiField(field)).filter((field): field is BuilderUiField => !!field)
        : [];

    if (fields.length === 0) return null;

    return {
        id,
        presentation: 'sheet',
        title,
        description: normalizeString(raw.description),
        submitLabel: normalizeString(raw.submitLabel) || 'Continue',
        allowSkip: raw.allowSkip === true,
        fields,
    };
};

const normalizeReviewSections = (value: unknown): BuilderReviewSection[] => {
    if (!Array.isArray(value)) return [];
    return value
        .map((entry) => {
            if (!entry || typeof entry !== 'object') return null;
            const raw = entry as Record<string, unknown>;
            const id = normalizeString(raw.id);
            const title = normalizeString(raw.title);
            if (!id || !title) return null;
            const fields = Array.isArray(raw.fields)
                ? raw.fields.map((field) => normalizeUiField(field)).filter((field): field is BuilderUiField => !!field)
                : [];
            return {
                id,
                title,
                summary: normalizeString(raw.summary) || '',
                editable: raw.editable !== false,
                requestId: normalizeString(raw.requestId) || `setup:edit:${id}`,
                fields,
            };
        })
        .filter((entry): entry is BuilderReviewSection => !!entry);
};

const normalizeSetupState = (value: unknown): BuilderSetupState | null => {
    if (!value || typeof value !== 'object') return null;
    const raw = value as Record<string, unknown>;
    const status = normalizeString(raw.status);
    const phase = normalizeString(raw.phase);
    if (!status || !phase) return null;

    return {
        status: status as BuilderSetupState['status'],
        phase: phase as BuilderSetupState['phase'],
        summary: normalizeString(raw.summary),
        confidence: typeof raw.confidence === 'number' ? raw.confidence : null,
    };
};

const normalizeActivity = (value: unknown): BuilderActivityItem[] => {
    if (!Array.isArray(value)) return [];
    return value
        .map((entry) => {
            if (!entry || typeof entry !== 'object') return null;
            const raw = entry as Record<string, unknown>;
            const id = normalizeString(raw.id);
            const title = normalizeString(raw.title);
            if (!id || !title) return null;
            const status = normalizeString(raw.status) || 'pending';
            return {
                id,
                title,
                status: status as BuilderActivityItem['status'],
                detail: normalizeString(raw.detail),
                agentLabel: normalizeString(raw.agentLabel ?? raw.agent_label),
                prompt: normalizeString(raw.prompt),
                parentId: normalizeString(raw.parentId ?? raw.parent_id),
                depth:
                    typeof raw.depth === 'number' && Number.isFinite(raw.depth)
                        ? raw.depth
                        : null,
            };
        })
        .filter((entry): entry is BuilderActivityItem => !!entry);
};

const resolveAuthToken = async (): Promise<string | null> => {
    const existing = AuthManager.getInstance().getSession();
    if (existing?.loginToken) return existing.loginToken;
    if ((existing as { token?: string } | null)?.token) return (existing as { token?: string }).token || null;

    const restored = await AuthManager.getInstance().init();
    if (restored?.loginToken) return restored.loginToken;
    if ((restored as { token?: string } | null)?.token) return (restored as { token?: string }).token || null;
    return null;
};

const apiRequest = async (path: string, init: RequestInit = {}) => {
    const token = await resolveAuthToken();
    if (!token) throw new Error('Not authenticated');

    const proxy = ProxyManager.getInstance();
    const response = await proxy.relayFetch(path, {
        ...init,
        headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
            ...(init.headers || {}),
        },
    });

    const text = await response.text();
    const json = text ? JSON.parse(text) : {};

    if (!response.ok) {
        throw new Error(json?.error || json?.message || `HTTP ${response.status}`);
    }

    return json;
};

const sortAgents = (items: VibeStandaloneAgent[]) => {
    return [...items].sort((a, b) => {
        const aName = (a.displayName || a.username || '').toLowerCase();
        const bName = (b.displayName || b.username || '').toLowerCase();
        return aName.localeCompare(bName);
    });
};

const applySession = (payload: BuilderSessionPayload) => ({
    conversationId: payload.conversationId || null,
    activeAgentId: payload.activeAgentId || null,
    messages: Array.isArray(payload.messages) ? payload.messages : [],
    draftPatch: payload.draftPatch || {},
    agent: payload.agent || null,
    latestSecret: typeof payload.latestSecret === 'string' ? payload.latestSecret : null,
    suggestions: Array.isArray(payload.suggestions) && payload.suggestions.length > 0
        ? payload.suggestions
        : defaultSuggestions,
    setupState: normalizeSetupState(payload.setupState),
    pendingUiRequest: normalizeUiRequest(payload.pendingUiRequest),
    reviewSections: normalizeReviewSections(payload.reviewSections),
    activity: normalizeActivity(payload.activity),
});

const applyBuilderPayload = (
    current: Pick<VibeAgentBuilderState, 'activeAgentId' | 'draftPatch' | 'agent' | 'latestSecret' | 'suggestions' | 'setupState' | 'pendingUiRequest' | 'reviewSections' | 'activity' | 'conversationId'>,
    payload: BuilderSessionPayload | null | undefined,
) => {
    if (!payload) return current;

    return {
        conversationId: payload.conversationId || current.conversationId,
        activeAgentId: payload.activeAgentId || current.activeAgentId,
        draftPatch: payload.draftPatch || current.draftPatch,
        agent: payload.agent || current.agent,
        latestSecret: typeof payload.latestSecret === 'string' ? payload.latestSecret : current.latestSecret,
        suggestions: Array.isArray(payload.suggestions) && payload.suggestions.length > 0
            ? payload.suggestions
            : current.suggestions,
        setupState: normalizeSetupState(payload.setupState) || current.setupState,
        pendingUiRequest:
            payload.pendingUiRequest !== undefined
                ? normalizeUiRequest(payload.pendingUiRequest)
                : current.pendingUiRequest,
        reviewSections:
            payload.reviewSections !== undefined
                ? normalizeReviewSections(payload.reviewSections)
                : current.reviewSections,
        activity:
            payload.activity !== undefined
                ? normalizeActivity(payload.activity)
                : current.activity,
    };
};

const parseSSEBuffer = (buffer: string): { events: Array<{ type: string; data: any }>; remaining: string } => {
    const normalized = buffer.replace(/\r\n/g, '\n');
    const events: Array<{ type: string; data: any }> = [];
    const eventChunks = normalized.split('\n\n');
    const hasCompleteTail = normalized.endsWith('\n\n');
    const completeChunks = hasCompleteTail ? eventChunks.filter(Boolean) : eventChunks.slice(0, -1).filter(Boolean);
    const remaining = hasCompleteTail ? '' : (eventChunks[eventChunks.length - 1] || '');

    for (const chunk of completeChunks) {
        let eventType = 'message';
        const dataLines: string[] = [];

        for (const line of chunk.split('\n')) {
            if (line.startsWith('event:')) {
                eventType = line.slice(6).trim();
            } else if (line.startsWith('data:')) {
                dataLines.push(line.slice(5).trim());
            }
        }

        const rawData = dataLines.join('\n');
        if (!rawData || rawData === '[DONE]') continue;

        try {
            events.push({ type: eventType, data: JSON.parse(rawData) });
        } catch {
            // Ignore malformed partial chunks and keep parsing.
        }
    }

    return { events, remaining };
};

const streamBuilderChat = async (
    request: {
        message?: string | null;
        uiResponse?: BuilderUiResponsePayload | null;
        conversationId: string | null;
        activeAgentId: string | null;
    },
    handlers: {
        onChunk: (chunk: string) => void;
        onState: (payload: BuilderSessionPayload) => void;
        onUiRequest: (payload: BuilderSessionPayload) => void;
        onDraftPatch: (payload: BuilderSessionPayload) => void;
        onReviewReady: (payload: BuilderSessionPayload) => void;
        onDone: (payload: BuilderStreamDonePayload) => void;
    },
) => {
    const token = await resolveAuthToken();
    if (!token) throw new Error('Not authenticated');

    const proxy = ProxyManager.getInstance();
    const response = await proxy.relayFetch('/api/vibeagent/chat/stream', {
        method: 'POST',
        headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
            Accept: 'application/json, text/event-stream',
        },
        body: JSON.stringify({
            conversationId: request.conversationId,
            activeAgentId: request.activeAgentId,
            message: request.message,
            uiResponse: request.uiResponse,
        }),
    });

    if (!response.ok) {
        const errorText = await response.text();
        let message = errorText || `HTTP ${response.status}`;

        try {
            const parsed = errorText ? JSON.parse(errorText) : {};
            message = parsed?.error || parsed?.message || message;
        } catch {
            // Ignore JSON parse failures for error responses.
        }

        throw new Error(message);
    }

    let completedPayload: BuilderStreamDonePayload | null = null;

    const processEvent = (eventType: string, data: any) => {
        if (eventType === 'chunk') {
            handlers.onChunk(typeof data?.text === 'string' ? data.text : '');
            return;
        }

        if (eventType === 'state') {
            handlers.onState((data || {}) as BuilderSessionPayload);
            return;
        }

        if (eventType === 'ui_request') {
            handlers.onUiRequest((data || {}) as BuilderSessionPayload);
            return;
        }

        if (eventType === 'draft_patch') {
            handlers.onDraftPatch((data || {}) as BuilderSessionPayload);
            return;
        }

        if (eventType === 'review_ready') {
            handlers.onReviewReady((data || {}) as BuilderSessionPayload);
            return;
        }

        if (eventType === 'done') {
            completedPayload = (data || {}) as BuilderStreamDonePayload;
            handlers.onDone(completedPayload);
            return;
        }

        if (eventType === 'error') {
            throw new Error(data?.message || 'Builder stream failed');
        }
    };

    // @ts-ignore React Native fetch may expose a stream reader at runtime.
    const reader = response.body?.getReader ? response.body.getReader() : null;

    if (reader) {
        const decoder = new TextDecoder();
        let buffer = '';

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            buffer += decoder.decode(value, { stream: true });
            const parsed = parseSSEBuffer(buffer);
            buffer = parsed.remaining;

            for (const event of parsed.events) {
                processEvent(event.type, event.data);
            }
        }

        if (buffer.trim()) {
            const parsed = parseSSEBuffer(`${buffer}\n\n`);
            for (const event of parsed.events) {
                processEvent(event.type, event.data);
            }
        }
    } else {
        const text = await response.text();
        const parsed = parseSSEBuffer(text.endsWith('\n\n') ? text : `${text}\n\n`);
        for (const event of parsed.events) {
            processEvent(event.type, event.data);
        }
    }

    if (!completedPayload) {
        throw new Error('Builder stream ended without a completion payload');
    }
};

const updateFromPayload = (
    state: VibeAgentBuilderState,
    payload: BuilderSessionPayload | null | undefined,
) => {
    const next = applyBuilderPayload(state, payload);
    return {
        conversationId: next.conversationId,
        activeAgentId: next.activeAgentId,
        draftPatch: next.draftPatch,
        agent: next.agent,
        latestSecret: next.latestSecret,
        suggestions: next.suggestions,
        setupState: next.setupState,
        pendingUiRequest: next.pendingUiRequest,
        reviewSections: next.reviewSections,
        activity: next.activity,
    };
};

export const useVibeAgentBuilderStore = create<VibeAgentBuilderState>((set, get) => ({
    agents: [],
    quota: null,
    conversationId: null,
    activeAgentId: null,
    messages: [],
    draftPatch: {},
    agent: null,
    suggestions: defaultSuggestions,
    latestSecret: null,
    setupState: null,
    pendingUiRequest: null,
    reviewSections: [],
    activity: [],
    isLoading: false,
    isSending: false,
    error: null,

    clearLatestSecret: () => set({ latestSecret: null }),
    clearError: () => set({ error: null }),

    refreshAgents: async () => {
        const payload = await apiRequest('/api/agents');
        set({
            agents: sortAgents(Array.isArray(payload?.items) ? payload.items : []),
            quota: payload?.quota || null,
        });
    },

    load: async () => {
        set({ isLoading: true, error: null });
        try {
            const [sessionPayload, agentsPayload] = await Promise.all([
                apiRequest('/api/vibeagent/session'),
                apiRequest('/api/agents'),
            ]);

            set({
                ...applySession(sessionPayload),
                agents: sortAgents(Array.isArray(agentsPayload?.items) ? agentsPayload.items : []),
                quota: agentsPayload?.quota || null,
                isLoading: false,
            });
        } catch (error: any) {
            set({
                isLoading: false,
                error: error?.message || 'Failed to load agent builder',
            });
        }
    },

    sendMessage: async (message: string, optimistic?: BuilderOptimisticMessageOptions) => {
        const trimmed = message.trim();
        if (!trimmed) return;

        const senderConfig: BuilderInputConfig = {
            message: trimmed,
            optimistic,
            optimisticUserContent: trimmed,
        };

        const sendInput = async () => {
            const { activeAgentId, conversationId } = get();
            const sentAt = typeof optimistic?.timestamp === 'number' && Number.isFinite(optimistic.timestamp)
                ? optimistic.timestamp
                : Date.now();
            const userMessageId = optimistic?.messageId || createLocalMessageId('user');
            const assistantMessageId = createLocalMessageId('assistant');
            const userContent = senderConfig.optimisticUserContent?.trim() || null;

            set((state) => ({
                isSending: true,
                error: null,
                messages: [
                    ...state.messages,
                    ...(userContent
                        ? [{
                            id: userMessageId,
                            role: 'user' as const,
                            content: userContent,
                            timestamp: sentAt,
                        }]
                        : []),
                    {
                        id: assistantMessageId,
                        role: 'assistant',
                        content: '',
                        timestamp: sentAt + 1,
                        isStreaming: true,
                    },
                ],
            }));

            try {
                let streamedReply = '';
                let completionPayload: BuilderStreamDonePayload | null = null;

                await streamBuilderChat({
                    message: senderConfig.message || null,
                    uiResponse: senderConfig.uiResponse || null,
                    conversationId,
                    activeAgentId,
                }, {
                    onChunk: (chunk) => {
                        if (!chunk) return;
                        streamedReply += chunk;

                        set((state) => ({
                            messages: state.messages.map((entry) => (
                                entry.id === assistantMessageId
                                    ? { ...entry, content: streamedReply, isStreaming: true }
                                    : entry
                            )),
                        }));
                    },
                    onState: (payload) => {
                        set((state) => updateFromPayload(state, payload));
                    },
                    onUiRequest: (payload) => {
                        set((state) => updateFromPayload(state, payload));
                    },
                    onDraftPatch: (payload) => {
                        set((state) => updateFromPayload(state, payload));
                    },
                    onReviewReady: (payload) => {
                        set((state) => updateFromPayload(state, payload));
                    },
                    onDone: (payload) => {
                        completionPayload = payload;
                    },
                });

                void get().refreshAgents().catch((error) => {
                    console.warn('[VibeAgentBuilderStore] Failed to refresh agents after stream', error);
                });

                const reply = typeof completionPayload?.reply === 'string' && completionPayload.reply.trim().length > 0
                    ? completionPayload.reply.trim()
                    : (streamedReply.trim().length > 0 ? streamedReply : 'Configured.');

                set((state) => ({
                    ...updateFromPayload(state, completionPayload),
                    isSending: false,
                    messages: state.messages.map((entry) => (
                        entry.id === assistantMessageId
                            ? {
                                ...entry,
                                content: reply,
                                timestamp: Date.now(),
                                isStreaming: false,
                            }
                            : entry
                    )),
                }));
            } catch (error: any) {
                set((state) => ({
                    isSending: false,
                    messages: state.messages.filter((entry) => entry.id !== assistantMessageId),
                    error: error?.message || 'Failed to send builder message',
                }));
            }
        };

        await sendInput();
    },

    submitUiResponse: async (requestId: string, answers: Record<string, unknown>, optimisticUserContent?: string) => {
        const normalizedRequestId = normalizeString(requestId);
        if (!normalizedRequestId) return;

        const { activeAgentId, conversationId } = get();
        const sentAt = Date.now();
        const userContent = normalizeString(optimisticUserContent);
        const userMessageId = createLocalMessageId('user');
        const assistantMessageId = createLocalMessageId('assistant');

        set((state) => ({
            isSending: true,
            error: null,
            pendingUiRequest:
                state.pendingUiRequest?.id === normalizedRequestId ? null : state.pendingUiRequest,
            messages: [
                ...state.messages,
                ...(userContent
                    ? [{
                        id: userMessageId,
                        role: 'user' as const,
                        content: userContent,
                        timestamp: sentAt,
                    }]
                    : []),
                {
                    id: assistantMessageId,
                    role: 'assistant',
                    content: '',
                    timestamp: sentAt + 1,
                    isStreaming: true,
                },
            ],
        }));

        try {
            let streamedReply = '';
            let completionPayload: BuilderStreamDonePayload | null = null;

            await streamBuilderChat({
                message: null,
                uiResponse: {
                    requestId: normalizedRequestId,
                    answers,
                },
                conversationId,
                activeAgentId,
            }, {
                onChunk: (chunk) => {
                    if (!chunk) return;
                    streamedReply += chunk;
                    set((state) => ({
                        messages: state.messages.map((entry) => (
                            entry.id === assistantMessageId
                                ? { ...entry, content: streamedReply, isStreaming: true }
                                : entry
                        )),
                    }));
                },
                onState: (payload) => {
                    set((state) => updateFromPayload(state, payload));
                },
                onUiRequest: (payload) => {
                    set((state) => updateFromPayload(state, payload));
                },
                onDraftPatch: (payload) => {
                    set((state) => updateFromPayload(state, payload));
                },
                onReviewReady: (payload) => {
                    set((state) => updateFromPayload(state, payload));
                },
                onDone: (payload) => {
                    completionPayload = payload;
                },
            });

            const reply = typeof completionPayload?.reply === 'string' && completionPayload.reply.trim().length > 0
                ? completionPayload.reply.trim()
                : (streamedReply.trim().length > 0 ? streamedReply : 'Updated the setup.');

            set((state) => ({
                ...updateFromPayload(state, completionPayload),
                isSending: false,
                messages: state.messages.map((entry) => (
                    entry.id === assistantMessageId
                        ? {
                            ...entry,
                            content: reply,
                            timestamp: Date.now(),
                            isStreaming: false,
                        }
                        : entry
                )),
            }));
        } catch (error: any) {
            set((state) => ({
                isSending: false,
                messages: state.messages.filter((entry) => entry.id !== assistantMessageId),
                error: error?.message || 'Failed to update setup',
            }));
        }
    },

    createDraftFromReview: async () => {
        await get().submitUiResponse('setup:create_draft', {}, 'Create draft');
    },

    createAgent: async (displayName?: string) => {
        set({ isLoading: true, error: null });
        try {
            const payload = await apiRequest('/api/agents', {
                method: 'POST',
                body: JSON.stringify({
                    display_name: displayName?.trim() || 'New Agent',
                }),
            });

            const createdAgent = payload?.agent || null;
            await get().refreshAgents();

            set((state) => ({
                isLoading: false,
                latestSecret: typeof payload?.secret === 'string' ? payload.secret : null,
                activeAgentId: createdAgent?.id || state.activeAgentId,
                agent: createdAgent || state.agent,
                draftPatch: createdAgent || state.draftPatch,
                messages: createdAgent
                    ? [
                        ...state.messages,
                        {
                            role: 'assistant',
                            content: `Created ${createdAgent.displayName || 'agent'}${createdAgent.username ? ` as @${createdAgent.username}` : ''}.`,
                            timestamp: Date.now(),
                        },
                    ]
                    : state.messages,
            }));
        } catch (error: any) {
            set({
                isLoading: false,
                error: error?.message || 'Failed to create agent',
            });
        }
    },

    selectAgent: async (agentId: string) => {
        if (!agentId) return;
        set({ isLoading: true, error: null });
        try {
            const payload = await apiRequest(`/api/agents/${agentId}`);
            set((state) => ({
                isLoading: false,
                activeAgentId: payload?.id || agentId,
                agent: payload || null,
                draftPatch: payload || state.draftPatch,
            }));
        } catch (error: any) {
            set({
                isLoading: false,
                error: error?.message || 'Failed to load agent',
            });
        }
    },

    publishActive: async () => {
        const { activeAgentId } = get();
        if (!activeAgentId) return;
        set({ isLoading: true, error: null });
        try {
            const payload = await apiRequest(`/api/agents/${activeAgentId}/publish`, {
                method: 'POST',
            });
            await get().refreshAgents();
            set((state) => ({
                isLoading: false,
                agent: payload || state.agent,
                draftPatch: payload || state.draftPatch,
            }));
        } catch (error: any) {
            set({
                isLoading: false,
                error: error?.message || 'Failed to publish agent',
            });
        }
    },

    toggleDisableActive: async () => {
        const { activeAgentId, agent } = get();
        if (!activeAgentId || !agent) return;

        const nextStatus = agent.status === 'disabled' ? 'published' : 'disabled';

        set({ isLoading: true, error: null });
        try {
            const payload = await apiRequest(`/api/agents/${activeAgentId}`, {
                method: 'PUT',
                body: JSON.stringify({ status: nextStatus }),
            });
            await get().refreshAgents();
            set((state) => ({
                isLoading: false,
                agent: payload || state.agent,
                draftPatch: payload || state.draftPatch,
            }));
        } catch (error: any) {
            set({
                isLoading: false,
                error: error?.message || 'Failed to update agent status',
            });
        }
    },

    rotateSecretActive: async () => {
        const { activeAgentId } = get();
        if (!activeAgentId) return;

        set({ isLoading: true, error: null });
        try {
            const payload = await apiRequest(`/api/agents/${activeAgentId}/secret/rotate`, {
                method: 'POST',
            });
            await get().refreshAgents();
            set((state) => ({
                isLoading: false,
                latestSecret: typeof payload?.secret === 'string' ? payload.secret : null,
                agent: payload?.agent || state.agent,
                draftPatch: payload?.agent || state.draftPatch,
            }));
        } catch (error: any) {
            set({
                isLoading: false,
                error: error?.message || 'Failed to rotate agent secret',
            });
        }
    },
}));
