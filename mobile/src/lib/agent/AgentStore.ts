import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Crypto from 'expo-crypto';
import { Socket as PhxSocket, Channel } from 'phoenix';
import ProxyManager from '../ProxyManager';
import AuthManager from '../AuthManager';
import { AgentConfig, AgentConversation, AgentMessage } from './types';



/**
 * Tool execution event from the AI agent
 */
interface ToolEvent {
    tool: string;
    status: 'running' | 'completed' | 'failed';
    label?: string;
    result?: any;
}

interface OptimisticSendOptions {
    messageId?: string;
    timestamp?: number;
}

interface AgentState {
    conversations: AgentConversation[];
    activeConversationId: string | null;
    isLoading: boolean;
    isStreaming: boolean;
    streamingContent: string;
    currentTool: ToolEvent | null;
    error: string | null;
    isConnected: boolean;
    isSyncing: boolean;
    _hasHydrated: boolean;

    // Actions
    connect: () => void;
    disconnect: () => void;
    createConversation: (title?: string) => string;
    deleteConversation: (id: string) => void;
    setActiveConversation: (id: string | null) => void;
    sendMessage: (
        text: string,
        images?: string[],
        isRegenerate?: boolean,
        truncateAtId?: string,
        optimistic?: OptimisticSendOptions,
    ) => void;
    stopStreaming: () => void;
    regenerateLastMessage: () => void;
    clearHistory: () => void;
    loadFromStorage: () => Promise<void>;
    syncFromServer: () => Promise<void>;
    loadConversation: (id: string) => Promise<void>;
    setHasHydrated: (state: boolean) => void;
}

// Module-level channel reference
let agentChannel: Channel | null = null;
let socket: PhxSocket | null = null;
let streamingTimeoutId: NodeJS.Timeout | null = null;
let lastUserMessage: { text: string; images?: string[] } | null = null;

export const useAgentStore = create<AgentState>()(
    persist(
        (set, get) => ({
            // State
            conversations: [],
            activeConversationId: null,
            isLoading: false,
            isStreaming: false,
            streamingContent: '',
            currentTool: null,
            error: null,
            isConnected: false,
            isSyncing: false,
            _hasHydrated: false,

            setHasHydrated: (state: boolean) => {
                set({ _hasHydrated: state });
            },

            // Connect to the Agent channel
            connect: () => {
                // Cleanup existing connection first
                if (agentChannel) {
                    try { agentChannel.leave(); } catch (e) { }
                    agentChannel = null;
                }
                if (socket) {
                    try { socket.disconnect(); } catch (e) { }
                    socket = null;
                }

                const proxy = ProxyManager.getInstance();
                const baseUrl = proxy.getBestUrl();
                const socketUrl = baseUrl.replace(/^http/, 'ws') + '/socket';

                const auth = AuthManager.getInstance().getSession();
                if (!auth) {
                    console.log('[AgentStore] No auth session');
                    set({ error: 'Please login first' });
                    return;
                }

                console.log('[AgentStore] Connecting to:', socketUrl);

                socket = new PhxSocket(socketUrl, {
                    params: { token: auth.loginToken || auth.userId },
                    reconnectAfterMs: (tries: number) => Math.min(tries * 1000, 10000),
                    timeout: 20000,
                });

                socket.connect();

                socket.onOpen(() => {
                    console.log('[AgentStore] Socket connected');
                    set({ isConnected: true, error: null });

                    // Join agent channel
                    if (!agentChannel) {
                        agentChannel = socket!.channel(`agent:${auth.userId}`, {});

                        agentChannel.join()
                            .receive('ok', () => {
                                console.log('[AgentStore] Joined agent channel');
                                // Sync conversations from server after connecting
                                get().syncFromServer();
                            })
                            .receive('error', (err) => {
                                console.error('[AgentStore] Failed to join agent channel:', err);
                                set({ error: 'Failed to connect to AI agent' });
                            });

                        // Handle streaming text chunks
                        agentChannel.on('chunk', (payload: { text: string }) => {
                            const { streamingContent, activeConversationId, conversations } = get();
                            const newContent = streamingContent + (payload.text || '');
                            set({ streamingContent: newContent, isStreaming: true });

                            // Update the assistant message in real-time
                            if (activeConversationId) {
                                const convIndex = conversations.findIndex(c => c.id === activeConversationId);
                                if (convIndex > -1) {
                                    const conv = conversations[convIndex];
                                    const lastMsg = conv.messages[conv.messages.length - 1];
                                    if (lastMsg && lastMsg.role === 'assistant' && lastMsg.isStreaming) {
                                        const updatedConvs = [...conversations];
                                        updatedConvs[convIndex] = {
                                            ...conv,
                                            messages: [
                                                ...conv.messages.slice(0, -1),
                                                { ...lastMsg, content: newContent }
                                            ]
                                        };
                                        set({ conversations: updatedConvs });
                                    }
                                }
                            }
                        });

                        // Handle tool progress
                        agentChannel.on('progress', (payload: { label: string; tool?: string; status?: string }) => {
                            console.log('[AgentStore] Tool progress:', payload.label);
                            set({
                                currentTool: {
                                    tool: payload.tool || payload.label.replace('Using ', '').replace('...', ''),
                                    status: (payload.status as any) || 'running',
                                    label: payload.label
                                }
                            });
                        });

                        // Handle tool results
                        agentChannel.on('tool_result', (payload: { tool: string; result: any; status?: string; duration_ms?: number }) => {
                            console.log('[AgentStore] Tool result:', payload.tool, 'in', payload.duration_ms, 'ms');

                            // Update current tool status
                            set({
                                currentTool: {
                                    tool: payload.tool,
                                    status: 'completed',
                                    result: payload.result
                                }
                            });

                            // Persist tool result to the current message
                            const { activeConversationId, conversations } = get();
                            if (activeConversationId) {
                                const convIndex = conversations.findIndex(c => c.id === activeConversationId);
                                if (convIndex > -1) {
                                    const conv = conversations[convIndex];
                                    const lastMsg = conv.messages[conv.messages.length - 1];

                                    if (lastMsg && lastMsg.role === 'assistant') {
                                        // Create specific tool result object based on tool type
                                        const toolResult = {
                                            tool: payload.tool,
                                            success: true,
                                            data: payload.result
                                        };

                                        const currentToolResults = lastMsg.toolResults || [];
                                        const updatedConvs = [...conversations];
                                        updatedConvs[convIndex] = {
                                            ...conv,
                                            messages: [
                                                ...conv.messages.slice(0, -1),
                                                {
                                                    ...lastMsg,
                                                    toolResults: [...currentToolResults, toolResult]
                                                }
                                            ]
                                        };
                                        set({ conversations: updatedConvs });
                                    }
                                }
                            }
                        });

                        // Handle acknowledgment with conversation ID
                        agentChannel.on('ack', (payload: { status: string; conversation_id?: string }) => {
                            console.log('[AgentStore] Message acknowledged, conv:', payload.conversation_id);
                            if (payload.conversation_id) {
                                const { activeConversationId, conversations } = get();

                                // If we have a temporary ID that doesn't match the server's acknowledged ID, 
                                // we need to update our local record to match the server ID.
                                if (activeConversationId && activeConversationId !== payload.conversation_id) {
                                    const activeConvIndex = conversations.findIndex(c => c.id === activeConversationId);

                                    if (activeConvIndex > -1) {
                                        console.log('[AgentStore] Updating conversation ID from', activeConversationId, 'to', payload.conversation_id);
                                        const updatedConvs = [...conversations];
                                        updatedConvs[activeConvIndex] = {
                                            ...updatedConvs[activeConvIndex],
                                            id: payload.conversation_id
                                        };
                                        set({
                                            conversations: updatedConvs,
                                            activeConversationId: payload.conversation_id
                                        });
                                        return;
                                    }
                                }

                                set({ activeConversationId: payload.conversation_id });
                            }
                        });

                        // Handle completion
                        agentChannel.on('done', (payload: { success: boolean; conversation_id?: string }) => {
                            console.log('[AgentStore] Stream complete:', payload.success);
                            const { activeConversationId, conversations, streamingContent } = get();

                            // Finalize the assistant message
                            if (activeConversationId) {
                                const convIndex = conversations.findIndex(c => c.id === activeConversationId);
                                if (convIndex > -1) {
                                    const conv = conversations[convIndex];
                                    const lastMsg = conv.messages[conv.messages.length - 1];
                                    if (lastMsg && lastMsg.role === 'assistant') {
                                        const updatedConvs = [...conversations];
                                        updatedConvs[convIndex] = {
                                            ...conv,
                                            messages: [
                                                ...conv.messages.slice(0, -1),
                                                {
                                                    ...lastMsg,
                                                    content: streamingContent,
                                                    isStreaming: false
                                                }
                                            ],
                                            updatedAt: Date.now()
                                        };
                                        set({ conversations: updatedConvs });

                                    }
                                }
                            }

                            set({
                                isLoading: false,
                                isStreaming: false,
                                streamingContent: '',
                                currentTool: null
                            });
                        });

                        // Handle errors
                        agentChannel.on('error', (payload: { message: string }) => {
                            console.error('[AgentStore] Error:', payload.message);

                            // Clear timeout
                            if (streamingTimeoutId) {
                                clearTimeout(streamingTimeoutId);
                                streamingTimeoutId = null;
                            }

                            // Finalize the message with error state
                            const { activeConversationId, conversations, streamingContent } = get();
                            if (activeConversationId) {
                                const convIndex = conversations.findIndex(c => c.id === activeConversationId);
                                if (convIndex > -1) {
                                    const conv = conversations[convIndex];
                                    const lastMsg = conv.messages[conv.messages.length - 1];
                                    if (lastMsg && lastMsg.role === 'assistant' && lastMsg.isStreaming) {
                                        const updatedConvs = [...conversations];
                                        updatedConvs[convIndex] = {
                                            ...conv,
                                            messages: [
                                                ...conv.messages.slice(0, -1),
                                                {
                                                    ...lastMsg,
                                                    content: streamingContent || 'Sorry, something went wrong.',
                                                    isStreaming: false,
                                                    error: payload.message
                                                }
                                            ]
                                        };
                                        set({ conversations: updatedConvs });
                                    }
                                }
                            }

                            set({
                                isLoading: false,
                                isStreaming: false,
                                error: payload.message,
                                currentTool: null,
                                streamingContent: ''
                            });
                        });

                        // Handle title updates from AI-generated titles
                        agentChannel.on('title_updated', (payload: { conversation_id: string; title: string }) => {
                            console.log('[AgentStore] Title updated:', payload.conversation_id, payload.title);
                            const { conversations } = get();
                            const convIndex = conversations.findIndex(c => c.id === payload.conversation_id);
                            if (convIndex > -1) {
                                const updatedConvs = [...conversations];
                                updatedConvs[convIndex] = {
                                    ...updatedConvs[convIndex],
                                    title: payload.title
                                };
                                set({ conversations: updatedConvs });
                            }
                        });
                    }
                });

                socket.onClose(() => {
                    console.log('[AgentStore] Socket disconnected');
                    agentChannel = null;

                    // If we were streaming, finalize the message with error
                    const { isStreaming, activeConversationId, conversations, streamingContent } = get();
                    if (isStreaming && activeConversationId) {
                        const convIndex = conversations.findIndex(c => c.id === activeConversationId);
                        if (convIndex > -1) {
                            const conv = conversations[convIndex];
                            const lastMsg = conv.messages[conv.messages.length - 1];
                            if (lastMsg && lastMsg.role === 'assistant' && lastMsg.isStreaming) {
                                const updatedConvs = [...conversations];
                                updatedConvs[convIndex] = {
                                    ...conv,
                                    messages: [
                                        ...conv.messages.slice(0, -1),
                                        {
                                            ...lastMsg,
                                            content: streamingContent || 'Connection lost. Please try again.',
                                            isStreaming: false,
                                            error: 'Connection lost'
                                        }
                                    ]
                                };
                                set({
                                    conversations: updatedConvs,
                                    isLoading: false,
                                    isStreaming: false,
                                    streamingContent: '',
                                    currentTool: null
                                });
                            }
                        }
                    }

                    set({ isConnected: false });
                });

                socket.onError((e) => {
                    console.error('[AgentStore] Socket error:', e);

                    // If we were streaming, finalize the message with error
                    const { isStreaming, activeConversationId, conversations, streamingContent } = get();
                    if (isStreaming && activeConversationId) {
                        const convIndex = conversations.findIndex(c => c.id === activeConversationId);
                        if (convIndex > -1) {
                            const conv = conversations[convIndex];
                            const lastMsg = conv.messages[conv.messages.length - 1];
                            if (lastMsg && lastMsg.role === 'assistant' && lastMsg.isStreaming) {
                                const updatedConvs = [...conversations];
                                updatedConvs[convIndex] = {
                                    ...conv,
                                    messages: [
                                        ...conv.messages.slice(0, -1),
                                        {
                                            ...lastMsg,
                                            content: streamingContent || 'Connection error. Please try again.',
                                            isStreaming: false,
                                            error: 'Connection error'
                                        }
                                    ]
                                };
                                set({
                                    conversations: updatedConvs,
                                    isLoading: false,
                                    isStreaming: false,
                                    streamingContent: '',
                                    currentTool: null
                                });
                            }
                        }
                    }

                    set({ isConnected: false, error: 'Connection error' });
                });
            },

            disconnect: () => {
                if (agentChannel) {
                    agentChannel.leave();
                    agentChannel = null;
                }
                if (socket) {
                    socket.disconnect();
                    socket = null;
                }
                set({ isConnected: false });
            },

            // Sync conversations from server
            syncFromServer: async () => {
                if (!agentChannel) return;

                set({ isSyncing: true });

                agentChannel.push('list_conversations', {})
                    .receive('ok', (response: { conversations: any[] }) => {
                        console.log('[AgentStore] Synced', response.conversations.length, 'conversations from server');

                        const { conversations: localConversations, activeConversationId } = get();

                        // Convert server format to local format, PRESERVING local messages
                        const mergedConversations: AgentConversation[] = response.conversations.map(c => {
                            const existing = localConversations.find(lc => lc.id === c.id);
                            return {
                                id: c.id,
                                title: c.title,
                                messages: existing ? existing.messages : [], // Preserve messages or default to empty
                                createdAt: new Date(c.inserted_at).getTime(),
                                updatedAt: new Date(c.updated_at).getTime()
                            };
                        });

                        // Critical Fix: Ensure we don't lose the currently active conversation if it hasn't synced yet
                        // (e.g. newly created local conversation that isn't in the list_conversations response yet)
                        if (activeConversationId) {
                            const activeIsMissing = !mergedConversations.find(c => c.id === activeConversationId);
                            if (activeIsMissing) {
                                const localActive = localConversations.find(c => c.id === activeConversationId);
                                if (localActive) {
                                    console.log('[AgentStore] Preserving active conversation not in sync list:', activeConversationId);
                                    mergedConversations.unshift(localActive);
                                }
                            }
                        }

                        set({ conversations: mergedConversations, isSyncing: false });
                        // Persist handled automatically by middleware
                    })
                    .receive('error', (err: any) => {
                        console.error('[AgentStore] Failed to sync:', err);
                        set({ isSyncing: false });
                    });
            },

            // Load full conversation from server
            loadConversation: async (id: string) => {
                if (!agentChannel) return;

                set({ isLoading: true });

                agentChannel.push('get_conversation', { id })
                    .receive('ok', (conv: any) => {
                        console.log('[AgentStore] Loaded conversation:', conv.id, 'with', conv.messages.length, 'messages');

                        const { conversations } = get();
                        const convIndex = conversations.findIndex(c => c.id === id);

                        if (convIndex > -1) {
                            const updatedConvs = [...conversations];
                            updatedConvs[convIndex] = {
                                ...updatedConvs[convIndex],
                                messages: conv.messages.map((m: any) => ({
                                    id: m.id,
                                    role: m.role,
                                    content: m.content,
                                    timestamp: m.timestamp,
                                    toolResults: m.toolResults
                                }))
                            };
                            set({ conversations: updatedConvs, isLoading: false });
                        } else {
                            set({ isLoading: false });
                        }
                    })
                    .receive('error', () => {
                        set({ isLoading: false });
                    });
            },

            createConversation: (title?: string) => {
                const id = Crypto.randomUUID();
                const newConv: AgentConversation = {
                    id,
                    title: title || 'New Chat',
                    messages: [],
                    createdAt: Date.now(),
                    updatedAt: Date.now()
                };

                // Create on server if connected
                if (agentChannel) {
                    agentChannel.push('create_conversation', { title: title || 'New Chat' })
                        .receive('ok', (response: { id: string; title: string }) => {
                            // Update local ID with server ID
                            const { conversations } = get();
                            const convIndex = conversations.findIndex(c => c.id === id);
                            if (convIndex > -1) {
                                const updatedConvs = [...conversations];
                                updatedConvs[convIndex] = { ...updatedConvs[convIndex], id: response.id };
                                set({ conversations: updatedConvs, activeConversationId: response.id });
                            }
                        });
                }

                const currentConversations = get().conversations || [];
                const updated = [newConv, ...currentConversations];
                set({ conversations: updated, activeConversationId: id });
                return id;
            },

            deleteConversation: (id: string) => {
                const { conversations, activeConversationId } = get();
                const updated = conversations.filter(c => c.id !== id);

                // Delete on server if connected
                if (agentChannel) {
                    agentChannel.push('delete_conversation', { id });
                }

                // If we're deleting the active conversation, switch to another or null
                let newActiveId = activeConversationId;
                if (activeConversationId === id) {
                    newActiveId = updated.length > 0 ? updated[0].id : null;
                }

                set({ conversations: updated, activeConversationId: newActiveId });

            },

            setActiveConversation: (id: string | null) => {
                set({ activeConversationId: id });

                // Load full conversation from server if needed
                if (id) {
                    const { conversations } = get();
                    const conv = conversations.find(c => c.id === id);
                    if (conv && conv.messages.length === 0) {
                        get().loadConversation(id);
                    }
                }
            },

            sendMessage: (
                text: string,
                images?: string[],
                isRegenerate = false,
                truncateAtId?: string,
                optimistic?: OptimisticSendOptions,
            ) => {
                const { activeConversationId, conversations, isConnected } = get();

                // Ensure connected
                if (!isConnected || !agentChannel) {
                    get().connect();
                    // Retry after a short delay
                    setTimeout(() => {
                        if (get().isConnected) {
                            get().sendMessage(text, images, isRegenerate, truncateAtId, optimistic);
                        } else {
                            set({ error: 'Failed to connect to AI agent' });
                        }
                    }, 1000);
                    return;
                }

                let convId = activeConversationId;
                if (!convId) {
                    convId = get().createConversation(text.substring(0, 30));
                }

                // 1. Track last message for regenerate
                lastUserMessage = { text, images };
                const optimisticTimestamp =
                    typeof optimistic?.timestamp === 'number' && Number.isFinite(optimistic.timestamp)
                        ? optimistic.timestamp
                        : Date.now();

                const convIndex = conversations.findIndex(c => c.id === convId);
                if (convIndex === -1) return;

                const currentConv = conversations[convIndex];

                // 2. Truncate if requested
                let baseMessages = currentConv.messages;
                if (truncateAtId) {
                    const idx = baseMessages.findIndex(m => m.id === truncateAtId);
                    if (idx !== -1) {
                        baseMessages = baseMessages.slice(0, idx);
                    }
                }

                // 3. Add placeholder Assistant Message (for streaming)
                const assistantMsg: AgentMessage = {
                    id: Crypto.randomUUID(),
                    role: 'assistant',
                    content: '',
                    timestamp: optimisticTimestamp + 1,
                    isStreaming: true
                };

                let newMessages;
                if (isRegenerate) {
                    // Just add the assistant placeholder, don't re-add user message
                    newMessages = [...baseMessages, assistantMsg];
                } else {
                    // Add both User and Assistant messages locally
                    const userMsg: AgentMessage = {
                        id: optimistic?.messageId || Crypto.randomUUID(),
                        role: 'user',
                        content: text,
                        timestamp: optimisticTimestamp,
                        images
                    };
                    newMessages = [...baseMessages, userMsg, assistantMsg];
                }

                const updatedConversations = [...conversations];
                updatedConversations[convIndex] = {
                    ...currentConv,
                    messages: newMessages,
                    updatedAt: Date.now()
                };

                set({
                    conversations: updatedConversations,
                    isLoading: true,
                    isStreaming: true,
                    streamingContent: '',
                    error: null,
                    currentTool: null
                });

                // 4. Send via Phoenix Channel with conversation ID
                agentChannel.push('message', {
                    text,
                    images: images || [],
                    conversation_id: convId,
                    truncate_at_id: truncateAtId
                });

                // 5. Set timeout to prevent stuck loading (30 seconds)
                if (streamingTimeoutId) clearTimeout(streamingTimeoutId);
                streamingTimeoutId = setTimeout(() => {
                    const { isStreaming } = get();
                    if (isStreaming) {
                        console.log('[AgentStore] Streaming timeout - forcing completion');
                        get().stopStreaming();
                    }
                }, 30000);
            },

            stopStreaming: () => {
                console.log('[AgentStore] Stopping stream');

                // Clear timeout
                if (streamingTimeoutId) {
                    clearTimeout(streamingTimeoutId);
                    streamingTimeoutId = null;
                }

                const { activeConversationId, conversations, streamingContent } = get();

                // Finalize the current message
                if (activeConversationId) {
                    const convIndex = conversations.findIndex(c => c.id === activeConversationId);
                    if (convIndex > -1) {
                        const conv = conversations[convIndex];
                        const lastMsg = conv.messages[conv.messages.length - 1];
                        if (lastMsg && lastMsg.role === 'assistant' && lastMsg.isStreaming) {
                            const updatedConvs = [...conversations];
                            updatedConvs[convIndex] = {
                                ...conv,
                                messages: [
                                    ...conv.messages.slice(0, -1),
                                    {
                                        ...lastMsg,
                                        content: streamingContent || 'Response stopped.',
                                        isStreaming: false
                                    }
                                ]
                            };
                            set({ conversations: updatedConvs });

                        }
                    }
                }

                set({
                    isLoading: false,
                    isStreaming: false,
                    streamingContent: '',
                    currentTool: null
                });
            },

            regenerateLastMessage: () => {
                const { activeConversationId, conversations } = get();
                if (!activeConversationId) return;

                const convIndex = conversations.findIndex(c => c.id === activeConversationId);
                if (convIndex === -1) return;

                const conv = conversations[convIndex];

                // Find the last assistant message and its matching user message
                const lastAssistantIdx = [...conv.messages].reverse().findIndex(m => m.role === 'assistant');
                if (lastAssistantIdx === -1) return;

                const realIdx = conv.messages.length - 1 - lastAssistantIdx;
                const assistantMsg = conv.messages[realIdx];

                // Find user message before it
                let userText = '';
                let userImages: string[] | undefined;

                for (let i = realIdx - 1; i >= 0; i--) {
                    if (conv.messages[i].role === 'user') {
                        userText = conv.messages[i].content;
                        userImages = conv.messages[i].images;
                        break;
                    }
                }

                if (!userText) return;

                // Call sendMessage with truncation at the assistant message
                get().sendMessage(userText, userImages, true, assistantMsg.id);
            },

            clearHistory: () => {
                if (agentChannel) {
                    agentChannel.push('clear_history', {});
                }
                const { activeConversationId, conversations } = get();
                if (activeConversationId) {
                    const convIndex = conversations.findIndex(c => c.id === activeConversationId);
                    if (convIndex > -1) {
                        const updatedConvs = [...conversations];
                        updatedConvs[convIndex] = {
                            ...updatedConvs[convIndex],
                            messages: [],
                            updatedAt: Date.now()
                        };
                        set({ conversations: updatedConvs });

                    }
                }
            },

            loadFromStorage: async () => {
                // Handled by persist middleware
                return;
            }
        }),
        {
            name: 'vibe_agent_conversations_v2', // New key to avoid schema conflict
            storage: createJSONStorage(() => AsyncStorage),
            partialize: (state) => ({
                conversations: state.conversations,
                // activeConversationId: state.activeConversationId, // Don't persist active conversation to foster fresh start
            }),
            onRehydrateStorage: () => (state) => {
                state?.setHasHydrated(true);
            },
        }
    )
);
