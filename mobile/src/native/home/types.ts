export interface NativeHomeFetchInput {
  userId: string;
  apiBaseUrl?: string;
  authToken?: string;
}

export interface NativeHomeFetchResult {
  chats: Record<string, unknown>[];
}

export interface NativeHomeNewChatInput {
  userId?: string;
  apiBaseUrl?: string;
  authToken?: string;
  theme?: {
    isDark?: boolean;
    background?: string;
    surface?: string;
    text?: string;
    textSecondary?: string;
    primary?: string;
  };
}

export interface NativeHomeNewChatResult {
  action: 'select' | 'cancel' | 'busy' | 'error';
  user?: {
    id?: string;
    userId?: string;
    username?: string;
    profileImage?: string;
    phoneNumber?: string;
    publicKey?: string;
  };
  error?: string;
}

export interface NativeChatHomeModule {
  isSupported?: () => boolean;
  supportsNativeHome?: () => boolean;
  fetchChats?: (payload: NativeHomeFetchInput) => Promise<NativeHomeFetchResult>;
  presentNativeNewChat?: (
    payload: NativeHomeNewChatInput
  ) => Promise<NativeHomeNewChatResult | null>;
}
