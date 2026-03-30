import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { InteractionManager, Linking, Platform, Text, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import * as Clipboard from 'expo-clipboard';

import { useChatStore } from '../src/lib/ChatStore';
import { useAuthStore } from '../src/lib/stores/auth-store';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { resolveThemeVariant, useWallpaperStore } from '../src/lib/stores/wallpaper-store';
import {
  getNativeChatEngineModule,
  getNativeChatMainModule,
  mapMessagesToNativeRows,
  NativeChatMainSurface,
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

const normalizeOpenFileUrl = (value: string): string => {
  let normalized = value.trim();
  normalized = normalized.replace(/^https?:\/\/\[(https?:\/\/[^\]]+)\](\/.*)?$/i, '$1$2');
  normalized = normalized.replace(/^\[(https?:\/\/[^\]]+)\](\/.*)?$/i, '$1$2');
  normalized = normalized.replace(/^https:\/\/https:\/\//i, 'https://');
  normalized = normalized.replace(/^http:\/\/http:\/\//i, 'http://');
  return normalized;
};

export default function ChatScreen() {
  const params = useLocalSearchParams();
  const router = useRouter();
  const insets = useSafeAreaInsets();

  const chats = useChatStore((s) => s.chats);
  const activeChatId = useChatStore((s) => s.activeChatId);
  const setActiveChat = useChatStore((s) => s.setActiveChat);
  const startChat = useChatStore((s) => s.startChat);
  const loadChats = useChatStore((s) => s.loadChats);
  const loadMessages = useChatStore((s) => s.loadMessages);
  const initSocket = useChatStore((s) => s.initSocket);
  const uploadProgress = useChatStore((s) => s.uploadProgress);
  const cancelUpload = useChatStore((s) => s.cancelUpload);
  const onlineUsers = useChatStore((s) => s.onlineUsers);
  const typingUsers = useChatStore((s) => s.typingUsers);

  const { user } = useAuthStore();
  const { colors, effectiveTheme } = useThemeStore();
  const activeWallpaperTheme = useWallpaperStore((s) => s.activeTheme);

  const [isTransitioning, setIsTransitioning] = useState(true);

  useEffect(() => {
    const task = InteractionManager.runAfterInteractions(() => {
      setIsTransitioning(false);
    });
    // Fallback if interactions take too long to settle
    const timeout = setTimeout(() => setIsTransitioning(false), 350);
    return () => {
      task.cancel();
      clearTimeout(timeout);
    };
  }, []);

  const nativeMainModule = useMemo(() => getNativeChatMainModule(), []);
  const nativeEngineModule = useMemo(() => getNativeChatEngineModule(), []);
  const nativeMainAvailable = !!nativeMainModule && (nativeMainModule.isSupported?.() ?? true);
  const nativeAvailable = nativeMainAvailable;

  const chatIdFromParams = getParamString(params?.id) || getParamString((params as any)?.chatId);
  const friendIdFromParams = getParamString((params as any)?.friendId);
  const friendNameFromParams = getParamString((params as any)?.friendName) ?? undefined;
  const friendImageFromParams = getParamString((params as any)?.friendImage) ?? undefined;
  const friendPublicKeyFromParams = getParamString((params as any)?.friendPublicKey) ?? undefined;
  const effectiveChatId = chatIdFromParams || (!friendIdFromParams ? (activeChatId || chats[0]?.chatId || null) : null);
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
    // When native engine is available, it handles message fetching via its own
    // URLSession HTTP call (ChatEngine.loadChatHistoryIfNeededLocked).
    // Skip the JS loadMessages to avoid redundant/timing-out JS-side fetch.
    if (nativeEngineModule) {
      console.log('[chat] native engine active — skipping JS loadMessages for', effectiveChatId);
    } else {
      void loadMessages(effectiveChatId);
    }
  }, [effectiveChatId, setActiveChat, loadMessages, nativeEngineModule]);

  useEffect(() => {
    if (chatIdFromParams || !friendIdFromParams) return;

    let isCancelled = false;
    (async () => {
      try {
        const createdChatId = await startChat(friendIdFromParams, {
          username: friendNameFromParams,
          profileImage: friendImageFromParams,
          publicKey: friendPublicKeyFromParams,
        });
        if (isCancelled || !createdChatId) return;
        setActiveChat(createdChatId);
        router.replace({ pathname: '/chat', params: { id: createdChatId } });
      } catch (error) {
        console.warn('[chat] failed to resolve friendId route', error);
      }
    })();

    return () => {
      isCancelled = true;
    };
  }, [
    chatIdFromParams,
    friendIdFromParams,
    friendImageFromParams,
    friendNameFromParams,
    friendPublicKeyFromParams,
    router,
    setActiveChat,
    startChat,
  ]);

  const surfaceId = useMemo(
    () => `chat-native-main-${effectiveChatId || 'none'}`,
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
        addMember(member?.userId ?? member?.id ?? member?.memberId, member?.name ?? member?.username ?? member?.label);
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
    if (isTransitioning) return [];

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
      const nativeUploadProgress = toNumber(
        message?.uploadProgress
          ?? message?.upload_progress
          ?? message?.extra?.uploadProgress
          ?? message?.extra?.upload_progress,
      );
      const storeUploadProgress =
        messageId && Object.prototype.hasOwnProperty.call(uploadProgress, messageId)
          ? uploadProgress[messageId]
          : undefined;
      const messageUploadProgress =
        typeof nativeUploadProgress === 'number' ? nativeUploadProgress : storeUploadProgress;
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
        waveform: Array.isArray(message?.waveform) ? message.waveform.filter((n: any) => typeof n === 'number') : undefined,
        isVideoNote: message?.isVideoNote === true,
        uploadProgress: typeof messageUploadProgress === 'number' ? messageUploadProgress : undefined,
        isMe,
        timestampMs,
        isEdited: message?.isEdited === true,
        editedAt: toNumber(message?.editedAt),
        replyToId: typeof message?.replyToId === 'string' ? message.replyToId : undefined,
        reactionEmoji: typeof message?.reactionEmoji === 'string' ? message.reactionEmoji : undefined,
        encryptedContent: typeof message?.encryptedContent === 'string' ? message.encryptedContent : undefined,
        plainContent:
          (typeof message?.plainContent === 'string' ? message.plainContent : undefined)
          || (typeof message?.plain_content === 'string' ? message.plain_content : undefined)
          || (typeof message?.plaintext === 'string' ? message.plaintext : undefined),
        agentName:
          (typeof message?.agentName === 'string' ? message.agentName : undefined)
          || (typeof message?.agent_name === 'string' ? message.agent_name : undefined)
          || (typeof message?.extra?.agentName === 'string' ? message.extra.agentName : undefined),
        agentId:
          (typeof message?.agentId === 'string' ? message.agentId : undefined)
          || (typeof message?.agent_id === 'string' ? message.agent_id : undefined)
          || (typeof message?.extra?.agentId === 'string' ? message.extra.agentId : undefined),
        isAgentMessage:
          message?.isAgentMessage === true
          || message?.is_agent_message === true
          || message?.extra?.isAgentMessage === true,
      };
    });

    runtimeMessages.sort((a, b) => a.timestampMs - b.timestampMs);
    return mapMessagesToNativeRows(runtimeMessages);
  }, [activeChat?.messages, effectiveChatId, isTransitioning, uploadProgress, user?.userId]);

  const callNativeEngine = useCallback(async (
    methodName:
      | 'sendMessage'
      | 'retryOutgoingMessage'
      | 'deleteMessage'
      | 'setChatMuted'
      | 'clearChat'
      | 'blockUser',
    payload: Record<string, unknown>,
  ) => {
    const method = nativeEngineModule?.[methodName] as ((input: Record<string, unknown>) => unknown) | undefined;
    if (typeof method !== 'function') {
      console.warn('[chat/native-engine] method unavailable', { methodName, payload });
      return null;
    }
    try {
      return (await Promise.resolve(method(payload))) as Record<string, unknown> | null;
    } catch (error) {
      console.warn('[chat/native-engine] call failed', { methodName, payload, error });
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

    if (type === 'mainPageChanged') {
      return;
    }

    if (type === 'headerBack') {
      router.back();
      return;
    }

    if (type === 'openVibeAgentBuilder') {
      router.push('/agent?mode=builder');
      return;
    }

    if (type === 'headerAvatarPressed') {
      if (!effectiveChatId) return;
      router.push({ pathname: '/chat-profile', params: { chatId: effectiveChatId } });
      return;
    }

    if (type === 'headerSearchPressed') {
      if (effectiveChatId) {
        router.push({ pathname: '/chat', params: { id: effectiveChatId, openSearch: '1' } });
      }
      return;
    }

    if (type === 'profileContentPressed') {
      const url = typeof payload.url === 'string' ? payload.url.trim() : '';
      if (url) {
        Linking.openURL(url).catch((error) => {
          console.warn('[chat/native-main] failed to open profile url', { url, error });
        });
      }
      return;
    }

    if (type === 'pinnedBannerPressed') {
      const rawUrl = typeof payload.url === 'string' ? payload.url : '';
      const url = rawUrl ? normalizeOpenFileUrl(rawUrl) : '';
      if (url && Platform.OS === 'android') {
        Linking.openURL(url).catch((error) => {
          console.warn('[chat/native-main] failed to open pinned file url', { url, error });
        });
      }
      return;
    }

    if (type === 'openFile') {
      const rawUrl = typeof payload.url === 'string' ? payload.url : '';
      const url = rawUrl ? normalizeOpenFileUrl(rawUrl) : '';
      if (!url) return;
      if (Platform.OS === 'ios') {
        console.warn('[chat/native-main] openFile ignored on iOS; native preview should handle file open', { url });
        return;
      }
      Linking.openURL(url).catch((error) => {
        console.warn('[chat/native-main] failed to open file url', { url, error });
      });
      return;
    }

    if (type === 'profileUsernamePressed') {
      const handle = typeof payload.handle === 'string' ? payload.handle.trim() : '';
      if (handle) {
        const normalized = handle.startsWith('@') ? handle : `@${handle}`;
        Clipboard.setStringAsync(normalized).catch((error) => {
          console.warn('[chat/native-main] failed to copy profile handle', { handle: normalized, error });
        });
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
          router.back();
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
          router.back();
        });
        return;
      }
      return;
    }

    if (!effectiveChatId) return;

    const basePayload: Record<string, unknown> = {
      chatId: effectiveChatId,
      myUserId: user?.userId || undefined,
      peerUserId: activeChat?.friendId || undefined,
      peerAgentId: activeChat?.friendAgentId || undefined,
      isGroup: isGroupOrChannel,
    };

    if (type === 'cancelOutgoingUpload') {
      const messageId = typeof payload.messageId === 'string' ? payload.messageId.trim() : '';
      if (!messageId) return;
      void callNativeEngine('cancelOutgoingMessage', {
        chatId: effectiveChatId,
        messageId,
      }).catch((error) => {
        console.warn('[chat/native-main] cancelOutgoingMessage failed', {
          chatId: effectiveChatId,
          messageId,
          error,
        });
      });
      cancelUpload(effectiveChatId, messageId);
      return;
    }

    if (type === 'mediaReplyRequested') {
      // Native side already sets the reply banner in the input bar.
      return;
    }

    if (type === 'mediaResendRequested' || type === 'mediaEditRequested') {
      const mediaUrl =
        (typeof payload.editedImageUri === 'string' && payload.editedImageUri.trim())
        || (typeof payload.mediaUrl === 'string' && payload.mediaUrl.trim());
      if (!mediaUrl) return;
      const caption = typeof payload.caption === 'string' ? payload.caption : '';
      const sourceMessageId = typeof payload.messageId === 'string' ? payload.messageId : undefined;
      void callNativeEngine('sendMessage', {
        ...basePayload,
        type: 'image',
        text: caption,
        metadata: {
          mediaUrl,
          sourceMessageId,
          editedFromMessage: type === 'mediaEditRequested',
        },
      });
      return;
    }

    if (type === 'sendMessage') {
      if (Platform.OS === 'android') {
        console.warn('[chat/native-main] ignoring JS sendMessage on Android; native send path should handle it', payload);
        return;
      }
      const text = typeof payload.text === 'string' ? payload.text : '';
      if (!text.trim()) return;
      const messageId = typeof payload.messageId === 'string' ? payload.messageId : undefined;
      void callNativeEngine('sendMessage', {
        ...basePayload,
        messageId,
        type: 'text',
        text,
        timestampMs: toNumber(payload.timestampMs ?? payload.timestamp) ?? Date.now(),
        replyToId: typeof payload.replyToMessageId === 'string' ? payload.replyToMessageId : undefined,
        agentMention: payload.agentMention === true,
        agentText: typeof payload.agentText === 'string' ? payload.agentText : undefined,
        mentionedAgentUsername:
          typeof payload.mentionedAgentUsername === 'string'
            ? payload.mentionedAgentUsername
            : undefined,
      });
      return;
    }

    if (type === 'attachmentImage') {
      if (Platform.OS === 'android') {
        console.log('[chat/native-main] Android attachmentImage handled via JS bridge', payload);
      }
      const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
      const caption = typeof payload.caption === 'string' ? payload.caption : '';
      if (uri) {
        const mimeType = typeof payload.mimeType === 'string' ? payload.mimeType.trim() : '';
        const explicitVideo = payload.isVideo === true || /^video\//i.test(mimeType);
        const attachmentType: 'video' | 'image' =
          explicitVideo || /\.(mp4|mov|m4v|avi|mkv|webm)(?:$|[?#])/i.test(uri) ? 'video' : 'image';
        const metadata: Record<string, any> = { mediaUrl: uri };
        if (mimeType) {
          metadata.mimeType = mimeType;
        }
        if (attachmentType === 'video') {
          const duration = toNumber(payload.duration);
          if (typeof duration === 'number' && Number.isFinite(duration) && duration > 0) {
            metadata.duration = duration;
          }
          const fileName =
            typeof payload.name === 'string' ? payload.name.trim()
              : typeof payload.fileName === 'string' ? payload.fileName.trim()
                : '';
          if (fileName) {
            metadata.fileName = fileName;
          }
          const thumbnailBase64 =
            typeof payload.thumbnailBase64 === 'string' ? payload.thumbnailBase64.trim() : '';
          if (thumbnailBase64) {
            metadata.thumbnailBase64 = thumbnailBase64;
          }
        }
        void callNativeEngine('sendMessage', {
          ...basePayload,
          type: attachmentType,
          text: caption,
          metadata,
        });
      }
      return;
    }

    if (type === 'attachmentGif') {
      if (Platform.OS === 'android') {
        console.log('[chat/native-main] Android attachmentGif handled via JS bridge', payload);
      }
      const mediaUrl =
        (typeof payload.url === 'string' && payload.url.trim())
        || (typeof payload.uri === 'string' && payload.uri.trim());
      if (mediaUrl) {
        void callNativeEngine('sendMessage', {
          ...basePayload,
          type: 'gif',
          text: '',
          metadata: {
            mediaUrl,
            previewUrl: typeof payload.previewUrl === 'string' ? payload.previewUrl : undefined,
            width: toNumber(payload.width),
            height: toNumber(payload.height),
          },
        });
      }
      return;
    }

    if (type === 'attachmentFile') {
      if (Platform.OS === 'android') {
        console.log('[chat/native-main] Android attachmentFile handled via JS bridge', payload);
      }
      const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
      if (!uri) return;
      const name = typeof payload.name === 'string' && payload.name.trim() ? payload.name : 'File';
      void callNativeEngine('sendMessage', {
        ...basePayload,
        type: 'file',
        text: name,
        metadata: {
          mediaUrl: uri,
          fileName: name,
          fileSize: toNumber(payload.size),
          mimeType: typeof payload.mimeType === 'string' ? payload.mimeType : undefined,
        },
      });
      return;
    }

    if (type === 'attachmentLocation') {
      if (Platform.OS === 'android') {
        console.log('[chat/native-main] Android attachmentLocation handled via JS bridge', payload);
      }
      const latitude = toNumber(payload.latitude);
      const longitude = toNumber(payload.longitude);
      if (latitude == null || longitude == null) return;
      void callNativeEngine('sendMessage', {
        ...basePayload,
        type: 'location',
        text: '',
        metadata: { latitude, longitude },
      });
      return;
    }

    if (type === 'attachmentVoice') {
      if (Platform.OS === 'android') {
        console.log('[chat/native-main] Android attachmentVoice handled via JS bridge', payload);
      }
      const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
      if (!uri) return;
      const duration = toNumber(payload.duration) ?? 0;
      const waveform = Array.isArray(payload.waveform)
        ? payload.waveform.filter((n: unknown) => typeof n === 'number')
        : undefined;
      void callNativeEngine('sendMessage', {
        ...basePayload,
        type: 'voice',
        text: '',
        metadata: {
          mediaUrl: uri,
          duration,
          waveform,
          fileName: 'voice-message.m4a',
        },
      });
      return;
    }

    if (type === 'attachmentVideoNote') {
      if (Platform.OS === 'android') {
        console.log('[chat/native-main] Android attachmentVideoNote handled via JS bridge', payload);
      }
      const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
      if (!uri) return;
      const duration = toNumber(payload.duration) ?? 0;
      void callNativeEngine('sendMessage', {
        ...basePayload,
        type: 'video',
        text: '',
        metadata: {
          mediaUrl: uri,
          duration,
          isVideoNote: true,
          fileName: 'video-note.mov',
        },
      });
      return;
    }

    if (type === 'contextMenuAction') {
      if (Platform.OS === 'android') {
        console.log('[chat/native-main] Android contextMenuAction handled via JS bridge', payload);
      }
      const action = typeof payload.action === 'string' ? payload.action : '';
      const messageId = typeof payload.messageId === 'string' ? payload.messageId : '';
      if (!messageId) return;
      if (action === 'resend') {
        void callNativeEngine('retryOutgoingMessage', { chatId: effectiveChatId, messageId });
        return;
      }
      if (action === 'delete') {
        void callNativeEngine('deleteMessage', { chatId: effectiveChatId, messageId, forEveryone: true });
      }
    }
  }, [
    activeChat?.friendId,
    activeChat?.muted,
    callNativeEngine,
    cancelUpload,
    effectiveChatId,
    loadChats,
    router,
    user?.userId,
  ]);

  if (!nativeAvailable) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background, justifyContent: 'center', alignItems: 'center', paddingHorizontal: 24 }}>
        <Text style={{ color: colors.text, textAlign: 'center' }}>
          Native main chat view is unavailable in this build. Rebuild the dev client after native module changes.
        </Text>
      </View>
    );
  }

  if (!effectiveChatId) {
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
      <NativeChatMainSurface
        forceRender
        surfaceId={surfaceId}
        rows={nativeRows}
        engineSurfaceId={surfaceId}
        chatId={effectiveChatId}
        myUserId={user?.userId || undefined}
        peerUserId={isGroupOrChannel ? undefined : (activeChat?.friendId || undefined)}
        peerAgentId={isGroupOrChannel ? undefined : (activeChat?.friendAgentId || undefined)}
        statusAuthorityEnabled
        appearance={{
          backgroundMode: 'gradient',
          nativeThemeId: `chat-${effectiveTheme}`,
          nativeThemeIsDark: effectiveTheme === 'dark',
          wallpaperGradient: resolvedWallpaperTheme.backgroundGradient,
          wallpaperOpacity: 1,
          wallpaperPatternGradient: resolvedWallpaperTheme.patternGradientColors || [],
          wallpaperPatternLocations: resolvedWallpaperTheme.patternGradientLocations || undefined,
          wallpaperPatternOpacity: resolvedWallpaperTheme.patternOpacity || 0,
          wallpaperMaskKey: resolvedWallpaperTheme.maskedImage || resolvedWallpaperTheme.patternType || undefined,
          bubbleMeGradient: resolvedWallpaperTheme.bubbleMeGradient || [resolvedWallpaperTheme.bubbleMe, resolvedWallpaperTheme.bubbleMe],
          bubbleThemGradient:
            resolvedWallpaperTheme.bubbleThemGradient
            || [resolvedWallpaperTheme.bubbleThem, resolvedWallpaperTheme.bubbleThem],
          bubbleThemColor:
            resolvedWallpaperTheme.bubbleThemGradient?.[0]
            || resolvedWallpaperTheme.bubbleThem
            || colors.card,
          textColorMe: resolvedWallpaperTheme.textColorMe || colors.text,
          textColorThem: resolvedWallpaperTheme.textColorThem || colors.text,
          timeColorThem: colors.textSecondary,
        }}
        contentPaddingBottom={Math.max(14, insets.bottom + 8)}
        inputBarEnabled={!activeChat?.friendIsAgent || activeChat?.acceptsIncomingChat !== false}
        inputPlaceholder={
          activeChat?.friendIsAgent && activeChat?.acceptsIncomingChat === false
            ? 'Messaging disabled for this agent'
            : 'Message'
        }
        nativeSendEnabled
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
        onNativeEvent={handleNativeEvent}
        onNativeError={(error, context) => {
          console.warn('[chat/native-main]', context, error);
        }}
      />
    </View>
  );
}
