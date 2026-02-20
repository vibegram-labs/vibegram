export type AIProvider = 'claude' | 'gemini';

export interface AgentConfig {
    provider: AIProvider;
    apiKey: string;
    claudeApiKey?: string;
    geminiApiKey?: string;
    model?: string;
    maxTokens?: number;
    temperature?: number;
    systemPrompt?: string;
}

export interface ToolResult {
    tool: string;
    success: boolean;
    data?: any;
    error?: string;
}

export interface AgentMessage {
    id: string;
    role: 'user' | 'assistant';
    content: string;
    timestamp: number;
    provider?: AIProvider;
    latencyMs?: number;
    isStreaming?: boolean;
    images?: string[]; // For image attachments
    toolResults?: ToolResult[]; // Results from tool executions
    error?: string; // Error message if the response failed
    tokens?: {
        input?: number;
        output?: number;
    };
}

export interface AgentConversation {
    id: string;
    title: string;
    messages: AgentMessage[];
    createdAt: number;
    updatedAt: number;
}

// Music search result from the AI agent
export interface MusicTrack {
    video_id?: string;
    id?: string; // Some providers use id
    source?: 'chat-voice' | 'chat-music' | 'music';
    title: string;
    artist: string;
    album?: string;
    duration?: string;
    preview_url?: string;
    cover?: string;
    links: {
        deezer?: string;
        spotify?: string;
        youtube_music?: string;
    };
}

export interface MusicSearchResult {
    source: 'deezer' | 'youtube';
    count: number;
    tracks: MusicTrack[];
}

// Web search result
export interface SearchResult {
    title: string;
    url: string;
    snippet: string;
    thumbnail?: string;
    favicon?: string;
}

export interface WebSearchResult {
    source: 'brave' | 'google' | 'serpapi';
    count: number;
    results: SearchResult[];
}

// Image/Document analysis
export interface AnalysisResult {
    success: boolean;
    analysis: string;
    image_url?: string;
    error?: string;
}
