export interface NativeHomeFetchInput {
  userId: string;
  apiBaseUrl?: string;
  authToken?: string;
}

export interface NativeHomeFetchResult {
  chats: Record<string, unknown>[];
}

export interface NativeChatHomeModule {
  isSupported?: () => boolean;
  supportsNativeHome?: () => boolean;
  fetchChats?: (payload: NativeHomeFetchInput) => Promise<NativeHomeFetchResult>;
}
