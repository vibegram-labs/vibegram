import { create } from 'zustand';

import AuthManager from '../AuthManager';
import ProxyManager from '../ProxyManager';

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
    voiceProvider?: string | null;
    voiceProfile?: string | null;
    callbackUrl?: string | null;
    secretHint?: string | null;
    publishedAt?: string | null;
    lastInvokedAt?: string | null;
    attachedChats?: Array<Record<string, unknown>>;
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
    isLoading: boolean;
    isSending: boolean;
    error: string | null;
    load: () => Promise<void>;
    refreshAgents: () => Promise<void>;
    sendMessage: (message: string) => Promise<void>;
    createAgent: (displayName?: string) => Promise<void>;
    selectAgent: (agentId: string) => Promise<void>;
    publishActive: () => Promise<void>;
    toggleDisableActive: () => Promise<void>;
    rotateSecretActive: () => Promise<void>;
    clearLatestSecret: () => void;
    clearError: () => void;
}

const defaultSuggestions = [
    'Create an agent that answers customer questions and can send voice replies.',
    'How do I call this agent from my backend and webhook?',
    'Write the prompt for a recruiting assistant.',
    'Create a product copilot agent.',
];

const createLocalMessageId = (prefix: 'user' | 'assistant') => {
    return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
};

const chunkReplyText = (value: string) => {
    const tokens = value.split(/(\s+)/).filter(Boolean);
    const chunks: string[] = [];
    let current = '';

    for (const token of tokens) {
        const nextValue = `${current}${token}`;
        if (nextValue.length > 42 && current.trim().length > 0) {
            chunks.push(current);
            current = token;
        } else {
            current = nextValue;
        }
    }

    if (current.length > 0) {
        chunks.push(current);
    }

    return chunks.length > 0 ? chunks : [value];
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const resolveAuthToken = async (): Promise<string | null> => {
    const existing = AuthManager.getInstance().getSession();
    if (existing?.loginToken) return existing.loginToken;
    if ((existing as any)?.token) return (existing as any).token;

    const restored = await AuthManager.getInstance().init();
    if (restored?.loginToken) return restored.loginToken;
    if ((restored as any)?.token) return (restored as any).token;
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
});

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

    sendMessage: async (message: string) => {
        const trimmed = message.trim();
        if (!trimmed) return;

        const { activeAgentId, conversationId } = get();
        const sentAt = Date.now();
        const userMessageId = createLocalMessageId('user');
        const assistantMessageId = createLocalMessageId('assistant');

        set((state) => ({
            isSending: true,
            error: null,
            messages: [
                ...state.messages,
                {
                    id: userMessageId,
                    role: 'user',
                    content: trimmed,
                    timestamp: sentAt,
                },
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
            const payload = await apiRequest('/api/vibeagent/chat', {
                method: 'POST',
                body: JSON.stringify({
                    conversationId,
                    message: trimmed,
                    activeAgentId,
                }),
            });

            await get().refreshAgents();

            const reply = typeof payload?.reply === 'string' && payload.reply.trim().length > 0
                ? payload.reply.trim()
                : 'Configured.';
            const chunks = chunkReplyText(reply);

            set((state) => ({
                conversationId: payload?.conversationId || state.conversationId,
                activeAgentId: payload?.activeAgentId || state.activeAgentId,
                draftPatch: payload?.draftPatch || {},
                agent: payload?.agent || state.agent,
                latestSecret: typeof payload?.latestSecret === 'string' ? payload.latestSecret : state.latestSecret,
                suggestions: Array.isArray(payload?.suggestions) && payload.suggestions.length > 0
                    ? payload.suggestions
                    : state.suggestions,
                isSending: false,
                messages: state.messages.map((entry) => (
                    entry.id === assistantMessageId
                        ? {
                            ...entry,
                            content: '',
                            timestamp: Date.now(),
                            isStreaming: true,
                        }
                        : entry
                )),
            }));

            let streamed = '';
            for (let index = 0; index < chunks.length; index += 1) {
                streamed += chunks[index];
                const isLast = index === chunks.length - 1;

                set((state) => ({
                    messages: state.messages.map((entry) => (
                        entry.id === assistantMessageId
                            ? {
                                ...entry,
                                content: streamed,
                                isStreaming: !isLast,
                            }
                            : entry
                    )),
                }));

                if (!isLast) {
                    await sleep(index === 0 ? 70 : 26);
                }
            }
        } catch (error: any) {
            set({
                isSending: false,
                messages: get().messages.filter((entry) => entry.id !== assistantMessageId),
                error: error?.message || 'Failed to send builder message',
            });
        }
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
