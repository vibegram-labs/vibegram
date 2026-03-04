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
    const data = (result as { data?: unknown }).data;
    if (Array.isArray(data)) {
      return data as Record<string, unknown>[];
    }
  }
  return null;
};

/**
 * Full-native home fetch. No JS API fallback.
 * The native module (ChatNativeHomeModule) handles the HTTP request
 * via its own URLSession with cert pinning.
 */
export const fetchHomeChatsNativeFirst = async (
  input: NativeHomeFetchInput,
): Promise<Record<string, unknown>[]> => {
  const nativeHomeModule = getNativeChatHomeModule();
  const hasNative = nativeHomeModule?.supportsNativeHome?.() && nativeHomeModule.fetchChats;

  if (!hasNative) {
    // No native module available — this should never happen on iOS, but
    // provide an empty fallback so the app doesn't crash.
    console.warn('[NativeHome] native module unavailable — returning empty chats');
    return [];
  }

  try {
    const nativeResult = await nativeHomeModule!.fetchChats!(input);
    const parsed = parseChatsResult(nativeResult);
    if (parsed) {
      console.log('[NativeHome] native fetchChats succeeded, count:', parsed.length);
      return parsed;
    }

    console.warn('[NativeHome] fetchChats returned invalid payload:', nativeResult);
    return [];
  } catch (error) {
    console.error('[NativeHome] native fetchChats threw an error:', error);
    return [];
  }
};
