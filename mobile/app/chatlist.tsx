import React, { useCallback, useEffect, useMemo } from 'react';
import { Text, View } from 'react-native';
import { useLocalSearchParams } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useChatStore } from '../src/lib/ChatStore';
import { useAuthStore } from '../src/lib/stores/auth-store';
import { useThemeStore } from '../src/lib/stores/theme-store';
import {
  getNativeChatEngineModule,
  NativeChatSurface,
  getNativeChatRuntimeInfo,
  mapMessagesToNativeRows,
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
    // Server timestamps are expected in ms; guard against seconds epoch.
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

export default function ChatListRoute() {
  const params = useLocalSearchParams();
  const insets = useSafeAreaInsets();
  const chats = useChatStore((s) => s.chats);
  const activeChatId = useChatStore((s) => s.activeChatId);
  const setActiveChat = useChatStore((s) => s.setActiveChat);
  const loadMessages = useChatStore((s) => s.loadMessages);
  const initSocket = useChatStore((s) => s.initSocket);
  const uploadProgress = useChatStore((s) => s.uploadProgress);
  const { user } = useAuthStore();
  const { colors } = useThemeStore();

  const runtime = useMemo(() => getNativeChatRuntimeInfo(), []);
  const nativeEngineModule = useMemo(() => getNativeChatEngineModule(), []);
  const nativeEngineAvailable = !!nativeEngineModule && (nativeEngineModule.isSupported?.() ?? true);
  const nativeAvailable = !!(
    runtime.moduleAvailable
    && runtime.listModuleAvailable
    && !runtime.isExpoGo
    && nativeEngineAvailable
  );
  const chatIdFromParams = getParamString(params?.id) || getParamString((params as any)?.chatId);
  const effectiveChatId = chatIdFromParams || activeChatId || chats[0]?.chatId || null;
  const activeChat = useMemo(
    () => chats.find((chat) => chat.chatId === effectiveChatId),
    [chats, effectiveChatId],
  );
  const surfaceId = useMemo(
    () => `chatlist-native-${effectiveChatId || 'none'}`,
    [effectiveChatId],
  );

  useEffect(() => {
    initSocket();
  }, [initSocket]);

  useEffect(() => {
    if (!effectiveChatId) return;
    setActiveChat(effectiveChatId);
    void loadMessages(effectiveChatId);
  }, [effectiveChatId, setActiveChat, loadMessages]);

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
      };
    });

    runtimeMessages.sort((a, b) => a.timestampMs - b.timestampMs);
    return mapMessagesToNativeRows(runtimeMessages);
  }, [activeChat?.messages, effectiveChatId, uploadProgress, user?.userId]);

  const callNativeEngine = useCallback(async (
    methodName: 'sendMessage' | 'retryOutgoingMessage' | 'deleteMessage',
    payload: Record<string, unknown>,
  ) => {
    const collectDebugSnapshot = async (
      label: string,
      extra: Record<string, unknown>,
    ) => {
      try {
        const getStatus = nativeEngineModule?.getChatEngineStatus;
        const getJournal = nativeEngineModule?.getChatJournal;
        const status =
          typeof getStatus === 'function'
            ? await Promise.resolve(getStatus())
            : null;
        const journalRaw =
          typeof getJournal === 'function'
            ? await Promise.resolve(getJournal())
            : null;
        const journalTail = Array.isArray(journalRaw) ? journalRaw.slice(-6) : null;
        console.warn('[chatlist/native-engine-debug]', {
          label,
          ...extra,
          status,
          journalTail,
        });
      } catch (snapshotError) {
        console.warn('[chatlist/native-engine-debug] snapshot failed', {
          label,
          ...extra,
          snapshotError,
        });
      }
    };

    const method = nativeEngineModule?.[methodName] as ((input: Record<string, unknown>) => unknown) | undefined;
    if (typeof method !== 'function') {
      console.warn('[chatlist/native-engine] method unavailable', { methodName, payload });
      await collectDebugSnapshot('method_unavailable', { methodName, payload });
      return null;
    }
    try {
      const result = await Promise.resolve(method(payload));
      if (result && typeof result === 'object' && (result as any).accepted === false) {
        console.warn('[chatlist/native-engine] rejected', { methodName, payload, result });
        await collectDebugSnapshot('rejected', { methodName, payload, result });
      }
      return result as Record<string, unknown> | null;
    } catch (error) {
      console.warn('[chatlist/native-engine] call failed', { methodName, payload, error });
      await collectDebugSnapshot('call_failed', { methodName, payload, error: String(error) });
      return null;
    }
  }, [nativeEngineModule]);

  const handleNativeEvent = useCallback((event: { nativeEvent?: Record<string, unknown> }) => {
    const payload = event?.nativeEvent || {};
    const type = typeof payload.type === 'string' ? payload.type : '';
    if (!effectiveChatId) return;
    const basePayload: Record<string, unknown> = {
      chatId: effectiveChatId,
      myUserId: user?.userId || undefined,
      peerUserId: activeChat?.friendId || undefined,
      isGroup: activeChat?.type === 'group' || activeChat?.type === 'channel',
    };

    if (type === 'sendMessage') {
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
      });
      return;
    }

    if (type === 'attachmentImage') {
      const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
      const caption = typeof payload.caption === 'string' ? payload.caption : '';
      if (uri) {
        void callNativeEngine('sendMessage', {
          ...basePayload,
          type: 'image',
          text: caption,
          metadata: { mediaUrl: uri },
        });
      }
      return;
    }

    if (type === 'attachmentGif') {
      const mediaUrl = (
        (typeof payload.url === 'string' && payload.url.trim())
        || (typeof payload.uri === 'string' && payload.uri.trim())
      );
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
      const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
      if (!uri) return;
      const duration = toNumber(payload.duration) ?? 0;
      const waveform = Array.isArray(payload.waveform) ? payload.waveform.filter((n) => typeof n === 'number') : undefined;
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
      const action = typeof payload.action === 'string' ? payload.action : '';
      const messageId = typeof payload.messageId === 'string' ? payload.messageId : '';
      if (!messageId) return;
      if (action === 'resend') {
        void callNativeEngine('retryOutgoingMessage', { chatId: effectiveChatId, messageId });
        return;
      }
      if (action === 'delete') {
        void callNativeEngine('deleteMessage', { chatId: effectiveChatId, messageId, forEveryone: true });
        return;
      }
    }
  }, [activeChat?.friendId, callNativeEngine, effectiveChatId, user?.userId]);

  if (!nativeAvailable) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background, justifyContent: 'center', alignItems: 'center', paddingHorizontal: 24 }}>
        <Text style={{ color: colors.text, textAlign: 'center' }}>
          Native chat list is unavailable on this build.
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
    <View style={{ flex: 1, backgroundColor: colors.background }}>
      <NativeChatSurface
        forceRender
        surfaceId={surfaceId}
        rows={nativeRows}
        engineSurfaceId={surfaceId}
        chatId={effectiveChatId}
        myUserId={user?.userId || undefined}
        peerUserId={activeChat?.friendId || undefined}
        statusAuthorityEnabled
        contentPaddingTop={insets.top + 8}
        contentPaddingBottom={Math.max(14, insets.bottom + 8)}
        inputBarEnabled
        inputPlaceholder="Message"
        nativeSendEnabled
        onNativeEvent={handleNativeEvent}
        onNativeError={(error, context) => {
          console.warn('[chatlist/native]', context, error);
        }}
      />
    </View>
  );
}
