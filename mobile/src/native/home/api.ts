import { apiClient } from '../../lib/api-client';

import type { NativeHomeFetchInput } from './types';
import { getNativeChatHomeModule } from './runtime';

const parseChatsResult = (result: unknown): Record<string, unknown>[] | null => {
  if (Array.isArray(result)) {
    return result as Record<string, unknown>[];
  }
  if (result && typeof result === 'object') {
    const chats = (result as { chats?: unknown }).chats;
    if (Array.isArray(chats)) {
      return chats as Record<string, unknown>[];
    }
  }
  return null;
};

export const fetchHomeChatsNativeFirst = async (
  input: NativeHomeFetchInput,
): Promise<Record<string, unknown>[]> => {
  const nativeHomeModule = getNativeChatHomeModule();

  if (nativeHomeModule?.supportsNativeHome?.() && nativeHomeModule.fetchChats) {
    try {
      const nativeResult = await nativeHomeModule.fetchChats(input);
      const nativeChats = parseChatsResult(nativeResult);
      if (nativeChats) {
        return nativeChats;
      }
      console.warn('[NativeHome] Invalid native fetch payload, falling back to JS');
    } catch (error) {
      console.warn('[NativeHome] fetchChats failed, falling back to JS', error);
    }
  }

  return apiClient.getChats(input.userId);
};
