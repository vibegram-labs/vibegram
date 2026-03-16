import AsyncStorage from '@react-native-async-storage/async-storage';

import { getNativeChatEngineModule } from '../native/chat/runtime';
import { useChatStore } from './ChatStore';
import { useSavedMessagesStore } from './stores/saved-messages-store';

const SAVED_MESSAGES_STORAGE_KEY = 'saved-messages-storage';

const normalizeSessionUserId = (value: string | null | undefined): string | null => {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim().toUpperCase();
  return trimmed.length > 0 ? trimmed : null;
};

export const clearSessionScopedClientCaches = async (nextUserId?: string | null): Promise<void> => {
  const normalizedNextUserId = normalizeSessionUserId(nextUserId);

  try {
    const nativeChatEngine = getNativeChatEngineModule();
    if (typeof nativeChatEngine?.disconnectChatEngine === 'function') {
      await Promise.resolve(nativeChatEngine.disconnectChatEngine());
    }
  } catch (error) {
    console.warn('[SessionCache] Failed to disconnect native chat engine:', error);
  }

  try {
    await useChatStore.getState().resetSessionCache(normalizedNextUserId);
  } catch (error) {
    console.warn('[SessionCache] Failed to reset chat store cache:', error);
  }

  try {
    await AsyncStorage.removeItem(SAVED_MESSAGES_STORAGE_KEY);
  } catch (error) {
    console.warn('[SessionCache] Failed to clear saved messages storage:', error);
  }

  try {
    useSavedMessagesStore.setState({ savedMessages: [] });
  } catch (error) {
    console.warn('[SessionCache] Failed to reset saved messages store:', error);
  }
};
