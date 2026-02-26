import { requireOptionalNativeModule } from 'expo-modules-core';

export type ChatNativeGifModule = {
  isSupported?: () => boolean;
  supportsNativeGifPanel?: () => boolean;
  setApiKey?: (apiKey: string) => void;
  getApiKey?: () => string;
  openPanel?: (keyboardHeight?: number) => Promise<void>;
  closePanel?: () => void;
};

export const ChatNativeGif = requireOptionalNativeModule<ChatNativeGifModule>('ChatNativeGif');

export type ChatNativeHomeModule = {
  isSupported?: () => boolean;
  supportsNativeHome?: () => boolean;
  fetchChats?: (payload: {
    userId: string;
    apiBaseUrl?: string;
    authToken?: string;
  }) => Promise<{ chats: Record<string, unknown>[] }>;
};

export const ChatNativeHome = requireOptionalNativeModule<ChatNativeHomeModule>('ChatNativeHome');

export const isNativeGifPanelAvailable = (): boolean => {
  return !!ChatNativeGif?.isSupported?.() && !!ChatNativeGif?.supportsNativeGifPanel?.();
};
