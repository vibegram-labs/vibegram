import React, { useCallback, useEffect, useMemo } from 'react';
import { Linking, Text, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import * as Clipboard from 'expo-clipboard';

import { useChatStore } from '../src/lib/ChatStore';
import { useAuthStore } from '../src/lib/stores/auth-store';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { resolveThemeVariant, useWallpaperStore } from '../src/lib/stores/wallpaper-store';
import {
  getNativeChatEngineModule,
  mapMessagesToNativeRows,
  NativeChatProfileSurface,
} from '../src/native/chat';
import type { RuntimeChatMessage } from '../src/native/chat/mapper';

const getParamString = (value: unknown): string | null => {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  }
  if (Array.isArray(value)) {
    for (const entry of value) {
      if (typeof entry === 'string') {
        const trimmed = entry.trim();
        if (trimmed.length > 0) return trimmed;
      }
    }
  }
  return null;
};

const toNumber = (value: unknown): number | undefined => {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return undefined;
};

const toTimestampMs = (value: unknown): number => {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value < 2_000_000_000 ? value * 1000 : value;
  }
  if (typeof value === 'string') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed < 2_000_000_000 ? parsed * 1000 : parsed;
    const fromDate = Date.parse(value);
    if (Number.isFinite(fromDate)) return fromDate;
  }
  return Date.now();
};

export default function ChatProfileScreen() {
  const params = useLocalSearchParams();
  const router = useRouter();

  const chats = useChatStore((s) => s.chats);
  const activeChatId = useChatStore((s) => s.activeChatId);
  const setActiveChat = useChatStore((s) => s.setActiveChat);
  const loadMessages = useChatStore((s) => s.loadMessages);
  const loadChats = useChatStore((s) => s.loadChats);
  const deleteChat = useChatStore((s) => s.deleteChat);
  const initSocket = useChatStore((s) => s.initSocket);
  const uploadProgress = useChatStore((s) => s.uploadProgress);
  const onlineUsers = useChatStore((s) => s.onlineUsers);
  const typingUsers = useChatStore((s) => s.typingUsers);

  const { user } = useAuthStore();
  const { colors, effectiveTheme } = useThemeStore();
  const activeWallpaperTheme = useWallpaperStore((s) => s.activeTheme);

  const nativeEngineModule = useMemo(() => getNativeChatEngineModule(), []);

  const chatIdFromParams = getParamString(params?.chatId) || getParamString((params as any)?.id);
  const effectiveChatId = chatIdFromParams || activeChatId || chats[0]?.chatId || null;
  const activeChat = useMemo(
    () => chats.find((chat) => chat.chatId === effectiveChatId),
    [chats, effectiveChatId],
  );

  useEffect(() => {
    initSocket();
  }, [initSocket]);

  useEffect(() => {
    if (!effectiveChatId) return;
    setActiveChat(effectiveChatId);
    void loadMessages(effectiveChatId);
  }, [effectiveChatId, loadMessages, setActiveChat]);

  const surfaceId = useMemo(
    () => `chat-native-profile-${effectiveChatId || 'none'}`,
    [effectiveChatId],
  );

  const isGroupOrChannel = activeChat?.type === 'group' || activeChat?.type === 'channel';
  const displayName = isGroupOrChannel
    ? (activeChat?.name || 'Group')
    : (activeChat?.friendName || activeChat?.name || 'Chat');
  const friendIdUpper = (activeChat?.friendId || '').trim().toUpperCase();
  const isTyping = !isGroupOrChannel && !!friendIdUpper && typingUsers.has(friendIdUpper);
  const isOnline = !isGroupOrChannel && !!friendIdUpper && onlineUsers.has(friendIdUpper);

  const groupMembers = useMemo(() => {
    if (!isGroupOrChannel) return [] as Array<{ userId: string; name?: string }>;
    const byId = new Map<string, { userId: string; name?: string }>();
    const addMember = (rawId: unknown, rawName?: unknown) => {
      if (typeof rawId !== 'string') return;
      const id = rawId.trim();
      if (!id) return;
      const normalized = id.toUpperCase();
      const name =
        typeof rawName === 'string' && rawName.trim().length > 0
          ? rawName.trim()
          : undefined;
      if (!byId.has(normalized)) {
        byId.set(normalized, { userId: normalized, name });
        return;
      }
      if (name && !byId.get(normalized)?.name) {
        byId.set(normalized, { userId: normalized, name });
      }
    };

    const explicitMembers = (activeChat as any)?.members;
    if (Array.isArray(explicitMembers)) {
      explicitMembers.forEach((member: any) => {
        addMember(
          member?.userId ?? member?.id ?? member?.memberId,
          member?.name ?? member?.username ?? member?.label,
        );
      });
    }

    if (Array.isArray(activeChat?.messages)) {
      activeChat.messages.forEach((message: any) => {
        addMember(message?.fromId, message?.fromName ?? message?.username);
      });
    }

    addMember(activeChat?.friendId, activeChat?.friendName);
    addMember(user?.userId, 'You');

    return Array.from(byId.values());
  }, [activeChat, isGroupOrChannel, user?.userId]);

  const groupMemberCount = useMemo(() => {
    const raw = (activeChat as any)?.memberCount;
    if (typeof raw === 'number' && Number.isFinite(raw) && raw > 0) return raw;
    return groupMembers.length > 0 ? groupMembers.length : undefined;
  }, [activeChat, groupMembers.length]);

  const subtitle = isGroupOrChannel
    ? (groupMemberCount ? `${groupMemberCount} members` : 'group chat')
    : (isTyping ? 'typing...' : (isOnline ? 'online' : 'last seen recently'));

  const resolvedWallpaperTheme = useMemo(() => {
    const resolved = resolveThemeVariant(activeWallpaperTheme, effectiveTheme === 'dark');
    const bg = Array.isArray(resolved.backgroundGradient) ? resolved.backgroundGradient : [];
    return {
      ...resolved,
      backgroundGradient: bg.length >= 2 ? bg : [colors.background, colors.background],
    };
  }, [activeWallpaperTheme, colors.background, effectiveTheme]);

  const nativeRows = useMemo(() => {
    const sourceMessages = Array.isArray(activeChat?.messages) ? (activeChat?.messages as any[]) : [];
    const myUserIdUpper = (user?.userId || '').trim().toUpperCase();

    const runtimeMessages: RuntimeChatMessage[] = sourceMessages.map((message: any) => {
      const messageId = typeof message?.id === 'string' ? message.id : String(message?.id || '');
      const fromId = typeof message?.fromId === 'string' ? message.fromId : undefined;
      const isMe = !!fromId && !!myUserIdUpper && fromId.trim().toUpperCase() === myUserIdUpper;
      const text =
        (typeof message?.plaintext === 'string' && message.plaintext)
        || (typeof message?.text === 'string' && message.text)
        || '';
      const timestampMs = toTimestampMs(message?.timestampMs ?? message?.timestamp);
      const messageUploadProgress =
        messageId && Object.prototype.hasOwnProperty.call(uploadProgress, messageId)
          ? uploadProgress[messageId]
          : undefined;
      return {
        id: messageId,
        chatId: message?.chatId || effectiveChatId || undefined,
        fromId,
        timestamp: typeof message?.timestamp === 'string' ? message.timestamp : undefined,
        text,
        type: typeof message?.type === 'string' ? message.type : 'text',
        status: typeof message?.status === 'string' ? message.status : undefined,
        mediaUrl: typeof message?.mediaUrl === 'string' ? message.mediaUrl : undefined,
        fileName: typeof message?.fileName === 'string' ? message.fileName : undefined,
        duration: toNumber(message?.duration),
        metadata: message?.extra && typeof message.extra === 'object' ? message.extra : undefined,
        waveform: Array.isArray(message?.waveform)
          ? message.waveform.filter((n: any) => typeof n === 'number')
          : undefined,
        isVideoNote: message?.isVideoNote === true,
        uploadProgress: typeof messageUploadProgress === 'number' ? messageUploadProgress : undefined,
        isMe,
        timestampMs,
        isEdited: message?.isEdited === true,
        editedAt: toNumber(message?.editedAt),
        replyToId: typeof message?.replyToId === 'string' ? message.replyToId : undefined,
        reactionEmoji: typeof message?.reactionEmoji === 'string' ? message.reactionEmoji : undefined,
        encryptedContent: typeof message?.encryptedContent === 'string' ? message.encryptedContent : undefined,
      };
    });

    runtimeMessages.sort((a, b) => a.timestampMs - b.timestampMs);
    return mapMessagesToNativeRows(runtimeMessages);
  }, [activeChat?.messages, effectiveChatId, uploadProgress, user?.userId]);

  const callNativeEngine = useCallback(async (
    methodName: 'setChatMuted' | 'clearChat' | 'blockUser',
    payload: Record<string, unknown>,
  ) => {
    const method = nativeEngineModule?.[methodName] as ((input: Record<string, unknown>) => unknown) | undefined;
    if (typeof method !== 'function') return null;
    try {
      return (await Promise.resolve(method(payload))) as Record<string, unknown> | null;
    } catch {
      return null;
    }
  }, [nativeEngineModule]);

  const handleNativeEvent = useCallback((event: { nativeEvent?: Record<string, unknown> } | Record<string, unknown>) => {
    const eventPayload = (event as any)?.nativeEvent || (event as Record<string, unknown>) || {};
    const payload =
      eventPayload && typeof eventPayload.payload === 'object' && eventPayload.payload
        ? (eventPayload.payload as Record<string, unknown>)
        : eventPayload;
    const type = typeof payload.type === 'string' ? payload.type : '';

    if (type === 'mainPageChanged') return;

    if (type === 'headerBack') {
      router.back();
      return;
    }

    if (type === 'headerSearchPressed') {
      if (effectiveChatId) {
        router.push({ pathname: '/chat', params: { id: effectiveChatId, openSearch: '1' } });
      }
      return;
    }

    if (type === 'profileContentSectionPressed') {
      const section = typeof payload.section === 'string' ? payload.section.trim() : '';
      if (effectiveChatId && section) {
        const routeParams: Record<string, string> = {
          chatId: effectiveChatId,
          username: displayName,
          profileImage: isGroupOrChannel
            ? ((((activeChat as any)?.avatarUrl as string | undefined) || ''))
            : (activeChat?.friendImage || ''),
          isOnline: isOnline ? '1' : '0',
          initialTab: section,
        };

        if (!isGroupOrChannel && activeChat?.friendId) {
          routeParams.userId = activeChat.friendId;
        }

        router.push({ pathname: '/user-profile', params: routeParams });
      }
      return;
    }

    if (type === 'profileContentPressed') {
      const url = typeof payload.url === 'string' ? payload.url.trim() : '';
      if (url) {
        Linking.openURL(url).catch(() => {});
      }
      return;
    }

    if (type === 'profileMembersPressed') {
      if (effectiveChatId) {
        router.push({ pathname: '/group-info', params: { groupId: effectiveChatId } });
      }
      return;
    }

    if (type === 'profileIdPressed') {
      const idValue = typeof payload.id === 'string' ? payload.id.trim() : '';
      if (idValue) {
        Clipboard.setStringAsync(idValue).catch(() => {});
      }
      return;
    }

    if (type === 'profileUsernamePressed') {
      const handle = typeof payload.handle === 'string' ? payload.handle.trim() : '';
      if (handle) {
        const normalized = handle.startsWith('@') ? handle : `@${handle}`;
        Clipboard.setStringAsync(normalized).catch(() => {});
      }
      return;
    }

    if (type === 'headerMenuAction') {
      const action = typeof payload.action === 'string' ? payload.action : '';
      if (!effectiveChatId) return;
      if (action === 'muteToggle') {
        const nextMuted = !(activeChat?.muted === true);
        void callNativeEngine('setChatMuted', {
          chatId: effectiveChatId,
          userId: user?.userId || undefined,
          muted: nextMuted,
        }).finally(() => {
          void loadChats();
        });
        return;
      }
      if (action === 'clearChat') {
        void callNativeEngine('clearChat', {
          chatId: effectiveChatId,
          userId: user?.userId || undefined,
        }).finally(() => {
          void loadChats();
          router.replace({ pathname: '/chat', params: { id: effectiveChatId } });
        });
        return;
      }
      if (action === 'blockUser') {
        void callNativeEngine('blockUser', {
          chatId: effectiveChatId,
          userId: user?.userId || undefined,
          blockedUserId: activeChat?.friendId || undefined,
        }).finally(() => {
          void loadChats();
          router.replace({ pathname: '/chat', params: { id: effectiveChatId } });
        });
        return;
      }
      if (action === 'delete') {
        void Promise.resolve(deleteChat(effectiveChatId)).finally(() => {
          void loadChats();
          router.replace('/chat');
        });
        return;
      }
    }

    if (type === 'headerAudioCallPressed' || type === 'headerVideoCallPressed') {
      // Keep parity with JS profile action buttons; call wiring can be added to native call flow.
      return;
    }

    if (type === 'headerAgentPressed') {
      return;
    }
  }, [
    activeChat,
    activeChat?.friendId,
    activeChat?.friendImage,
    activeChat?.muted,
    callNativeEngine,
    deleteChat,
    displayName,
    effectiveChatId,
    isGroupOrChannel,
    isOnline,
    loadChats,
    router,
    user?.userId,
  ]);

  if (!effectiveChatId || !activeChat) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background, justifyContent: 'center', alignItems: 'center', paddingHorizontal: 24 }}>
        <Text style={{ color: colors.text, textAlign: 'center' }}>
          No chat selected.
        </Text>
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: 'transparent' }}>
      <NativeChatProfileSurface
        forceRender
        surfaceId={surfaceId}
        rows={nativeRows}
        engineSurfaceId={surfaceId}
        chatId={effectiveChatId}
        myUserId={user?.userId || undefined}
        peerUserId={isGroupOrChannel ? undefined : (activeChat?.friendId || undefined)}
        statusAuthorityEnabled
        appearance={{
          backgroundMode: 'gradient',
          nativeThemeId: `chat-profile-${effectiveTheme}`,
          nativeThemeIsDark: effectiveTheme === 'dark',
          wallpaperGradient: resolvedWallpaperTheme.backgroundGradient,
          wallpaperOpacity: 1,
          wallpaperPatternGradient: resolvedWallpaperTheme.patternGradientColors || [],
          wallpaperPatternLocations: resolvedWallpaperTheme.patternGradientLocations || undefined,
          wallpaperPatternOpacity: resolvedWallpaperTheme.patternOpacity || 0,
          wallpaperMaskKey: resolvedWallpaperTheme.maskedImage || resolvedWallpaperTheme.patternType || undefined,
          bubbleMeGradient: resolvedWallpaperTheme.bubbleMeGradient || [resolvedWallpaperTheme.bubbleMe, resolvedWallpaperTheme.bubbleMe],
          bubbleThemColor: resolvedWallpaperTheme.bubbleThem || colors.card,
          textColorMe: resolvedWallpaperTheme.textColorMe || colors.text,
          textColorThem: resolvedWallpaperTheme.textColorThem || colors.text,
          timeColorThem: colors.textSecondary,
        }}
        headerTitle={displayName}
        headerSubtitle={subtitle}
        profileName={displayName}
        profileHandle={
          isGroupOrChannel
            ? (groupMemberCount ? `${groupMemberCount} members` : subtitle)
            : (
                activeChat?.friendName
                  ? `@${activeChat.friendName}`
                  : (activeChat?.friendId ? `id: ${activeChat.friendId}` : subtitle)
              )
        }
        profileBio={activeChat?.description || ''}
        avatarUri={
          isGroupOrChannel
            ? (((activeChat as any)?.avatarUrl as string | undefined) || undefined)
            : (activeChat?.friendImage || undefined)
        }
        isOnline={isOnline}
        isChatMuted={activeChat?.muted === true}
        isGroupOrChannel={isGroupOrChannel}
        groupMembers={groupMembers}
        groupMemberCount={groupMemberCount}
        agentConfig={(activeChat as any)?.agentConfig as Record<string, unknown> | undefined}
        page="profile"
        onNativeEvent={handleNativeEvent}
        onNativeError={(error, context) => {
          console.warn('[chat/native-profile]', context, error);
        }}
      />
    </View>
  );
}
