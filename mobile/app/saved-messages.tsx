import React, { useCallback, useState, useEffect, useRef, useMemo } from 'react';
import {
    View, Text, FlatList, TouchableOpacity,
    StyleSheet, InteractionManager, ActivityIndicator,
    Keyboard, Platform, Dimensions, TextInput, Linking
} from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft, Search, Bookmark, Trash2, X } from 'lucide-react-native';
import { Swipeable, GestureHandlerRootView } from 'react-native-gesture-handler';
import Animated, {
    FadeIn,
    useSharedValue,
    useAnimatedStyle,
    withSpring,
} from 'react-native-reanimated';
import { KeyboardStickyView, useReanimatedKeyboardAnimation } from 'react-native-keyboard-controller';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { BlurView } from 'expo-blur';

import { useSavedMessagesStore } from '../src/lib/stores/saved-messages-store';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useAuthStore } from '../src/lib/stores/auth-store';
import { useChatStore } from '../src/lib/ChatStore';
import { Message } from '../src/lib/types';
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';
import ChatInput from '../src/components/chat/ChatInput';
import { MessageBubbleBody } from '../src/components/chat/bubbles';
import WallpaperBackground from '../src/components/chat/WallpaperBackground';
import { useWallpaperStore, resolveThemeVariant } from '../src/lib/stores/wallpaper-store';
import EmptyChatState from '../src/components/chat/EmptyChatState';
import * as Haptics from 'expo-haptics';
import MessageContextMenu from '../src/components/chat/MessageContextMenu';
import {
    getNativeChatEngineModule,
    getNativeChatMainModule,
    mapMessagesToNativeRows,
    NativeSavedMessagesSurface,
    type NativeChatMainSurfaceRef,
    type RuntimeChatMessage,
} from '../src/native/chat';

const { width: SCREEN_WIDTH } = Dimensions.get('window');
const MaskedViewAny = MaskedView as any;

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16)
        const g = parseInt(color.slice(3, 5), 16)
        const b = parseInt(color.slice(5, 7), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    return color
}

const toNumber = (value: unknown): number | undefined => {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string') {
        const parsed = Number(value);
        if (Number.isFinite(parsed)) return parsed;
    }
    return undefined;
}

const normalizeOpenFileUrl = (value: string): string => {
    let normalized = value.trim();
    normalized = normalized.replace(/^https?:\/\/\[(https?:\/\/[^\]]+)\](\/.*)?$/i, '$1$2');
    normalized = normalized.replace(/^\[(https?:\/\/[^\]]+)\](\/.*)?$/i, '$1$2');
    normalized = normalized.replace(/^https:\/\/https:\/\//i, 'https://');
    normalized = normalized.replace(/^http:\/\/http:\/\//i, 'http://');
    return normalized;
}

const extractNativeSavedMessages = (result: unknown): any[] => {
    if (!result || typeof result !== 'object') return [];
    const payload = result as Record<string, unknown>;
    if (Array.isArray(payload.messages)) return payload.messages as any[];
    if (Array.isArray(payload.data)) return payload.data as any[];
    return [];
};

const normalizeSavedMessageText = (message: any) => {
    const rawText =
        (typeof message?.plaintext === 'string' && message.plaintext)
        || (typeof message?.text === 'string' && message.text)
        || (typeof message?.caption === 'string' && message.caption)
        || '';
    const trimmed = rawText.trim();
    if (!trimmed) return '';

    const type = typeof message?.type === 'string' ? message.type : '';
    const normalized = trimmed.toLowerCase();
    const hasMediaUrl = typeof message?.mediaUrl === 'string' && message.mediaUrl.trim().length > 0;
    const hasLocation =
        toNumber(message?.latitude ?? message?.extra?.latitude) != null
        && toNumber(message?.longitude ?? message?.extra?.longitude) != null;
    const isGenericMediaLabel =
        (type === 'image' && normalized === 'image' && hasMediaUrl)
        || (type === 'video' && (normalized === 'video' || normalized === 'video note') && hasMediaUrl)
        || (type === 'voice' && normalized === 'voice message' && hasMediaUrl)
        || (type === 'location' && normalized === 'location' && hasLocation);

    return isGenericMediaLabel ? '' : rawText;
};

const buildNativeSavedRetryPayload = (message: any) => ({
    messageId: typeof message?.id === 'string' ? message.id : undefined,
    type: typeof message?.type === 'string' ? message.type : 'text',
    text: normalizeSavedMessageText(message),
    metadata: {
        mediaUrl: typeof message?.mediaUrl === 'string' ? message.mediaUrl : undefined,
        fileName: typeof message?.fileName === 'string' ? message.fileName : undefined,
        fileSize: toNumber(message?.fileSize),
        latitude: toNumber(message?.latitude),
        longitude: toNumber(message?.longitude),
        width: toNumber(message?.width ?? message?.extra?.width),
        height: toNumber(message?.height ?? message?.extra?.height),
        duration: toNumber(message?.duration),
        replyToId: typeof message?.replyToId === 'string' ? message.replyToId : undefined,
        contact: message?.contact,
        isVideoNote: message?.isVideoNote === true,
        waveform: Array.isArray(message?.waveform)
            ? message.waveform.filter((value: unknown) => typeof value === 'number')
            : Array.isArray(message?.extra?.waveform)
                ? message.extra.waveform.filter((value: unknown) => typeof value === 'number')
                : undefined,
    },
});

const sortSavedMessagesDesc = (messages: any[]) => {
    return [...messages].sort((a, b) => {
        const aTs = typeof a?.timestamp === 'number' ? a.timestamp : 0;
        const bTs = typeof b?.timestamp === 'number' ? b.timestamp : 0;
        return bTs - aTs;
    });
};

export default function SavedMessagesScreen() {
    const { savedMessages, sync, removeMessage, retryMessage, sendMessage } = useSavedMessagesStore();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme } = useWallpaperStore();
    const { user } = useAuthStore();
    const uploadProgress = useChatStore((s) => s.uploadProgress);
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const nativeMainModule = useMemo(() => getNativeChatMainModule(), []);
    const nativeEngineModule = useMemo(() => getNativeChatEngineModule(), []);
    const nativeMainAvailable = !!nativeMainModule && (nativeMainModule.isSupported?.() ?? true);
    const nativeSavedMessagesEnabled =
        nativeMainAvailable
        && !!nativeEngineModule?.fetchSavedMessages
        && !!nativeEngineModule?.sendSavedMessage
        && !!nativeEngineModule?.deleteSavedMessage;
    const nativeSurfaceRef = useRef<NativeChatMainSurfaceRef>(null);
    const [nativeSavedMessages, setNativeSavedMessages] = useState<any[]>(() => [...(savedMessages || [])]);
    const [nativeSavedLoading, setNativeSavedLoading] = useState(false);
    const [nativeSavedLoaded, setNativeSavedLoaded] = useState(() => (savedMessages?.length || 0) > 0);

    const resolvedTheme = useMemo(() => {
        return resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
    }, [activeTheme, effectiveTheme]);

    const nativeWallpaperGradient = useMemo(() => {
        const gradient = Array.isArray(resolvedTheme.backgroundGradient) ? resolvedTheme.backgroundGradient : [];
        return gradient.length >= 2 ? gradient : [colors.background, colors.background];
    }, [colors.background, resolvedTheme.backgroundGradient]);

    const bubbleTheme = useMemo(() => ({
        meGradient: (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
            ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
            : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]) as [string, string],
        themGradient: (resolvedTheme.bubbleThemGradient && resolvedTheme.bubbleThemGradient.length >= 2
            ? [resolvedTheme.bubbleThemGradient[0], resolvedTheme.bubbleThemGradient[1]]
            : [resolvedTheme.bubbleThem, resolvedTheme.bubbleThem]) as [string, string],
    }), [resolvedTheme]);
    const [text, setText] = useState('');
    const flatListRef = useRef<FlatList>(null);

    // Context Menu State
    const [contextMenuVisible, setContextMenuVisible] = useState(false);
    const [selectedMessageInfo, setSelectedMessageInfo] = useState<any>(null);
    const [menuPosition, setMenuPosition] = useState<{ x: number, y: number, width: number, height: number } | null>(null);

    // Search state
    const [isSearching, setIsSearching] = useState(false);
    const [searchQuery, setSearchQuery] = useState('');
    const searchInputRef = useRef<TextInput>(null);

    // Keyboard handling
    const { height: keyboardHeight } = useReanimatedKeyboardAnimation();
    const footerHeight = insets.bottom + 60;

    const fakeViewStyle = useAnimatedStyle(() => {
        const kbHeight = Math.abs(keyboardHeight.value);
        return {
            height: footerHeight + kbHeight,
        };
    });

    const scheduleNativeScrollToBottom = useCallback(() => {
        setTimeout(() => {
            void nativeSurfaceRef.current?.scrollToBottom(true);
        }, 100);
    }, []);

    const upsertNativeSavedMessage = useCallback((nextMessage: any) => {
        const nextId = typeof nextMessage?.id === 'string' ? nextMessage.id : '';
        if (!nextId) return;
        setNativeSavedMessages((previous) => {
            const existingIndex = previous.findIndex((item) => item?.id === nextId);
            if (existingIndex === -1) {
                return sortSavedMessagesDesc([nextMessage, ...previous]);
            }
            const merged = [...previous];
            const existing = merged[existingIndex] ?? {};
            merged[existingIndex] = {
                ...existing,
                ...nextMessage,
                extra: {
                    ...(existing?.extra ?? {}),
                    ...(nextMessage?.extra ?? {}),
                },
            };
            return sortSavedMessagesDesc(merged);
        });
        setNativeSavedLoaded(true);
    }, []);

    const removeNativeSavedMessageLocal = useCallback((messageId: string) => {
        setNativeSavedMessages((previous) => previous.filter((item) => item?.id !== messageId));
    }, []);

    const buildOptimisticNativeSavedMessage = useCallback((payload: Record<string, unknown>) => {
        const messageId =
            (typeof payload.messageId === 'string' && payload.messageId.trim())
            || `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
        const metadata =
            payload.metadata && typeof payload.metadata === 'object'
                ? (payload.metadata as Record<string, unknown>)
                : {};
        const timestampMs = toNumber(payload.timestampMs ?? payload.timestamp) ?? Date.now();
        const textValue = typeof payload.text === 'string' ? payload.text : '';
        const extra: Record<string, unknown> = {};
        if (toNumber(metadata.width) != null) extra.width = toNumber(metadata.width) as number;
        if (toNumber(metadata.height) != null) extra.height = toNumber(metadata.height) as number;
        if (typeof metadata.stickerId === 'string') extra.stickerId = metadata.stickerId;
        if (typeof metadata.stickerPackId === 'string') extra.stickerPackId = metadata.stickerPackId;
        if (typeof metadata.packId === 'string' && extra.stickerPackId == null) {
            extra.stickerPackId = metadata.packId;
        }
        if (typeof metadata.stickerBundleFileName === 'string') {
            extra.stickerBundleFileName = metadata.stickerBundleFileName;
        }
        if (typeof metadata.bundleFileName === 'string' && extra.stickerBundleFileName == null) {
            extra.stickerBundleFileName = metadata.bundleFileName;
        }
        if (typeof metadata.emoji === 'string') extra.emoji = metadata.emoji;
        if (Array.isArray(metadata.waveform)) {
            extra.waveform = metadata.waveform.filter((value): value is number => typeof value === 'number');
        }
        return {
            id: messageId,
            fromId: user?.userId,
            chatId: 'saved_messages',
            timestamp: timestampMs,
            plaintext: textValue,
            text: textValue,
            type: typeof payload.type === 'string' ? payload.type : 'text',
            status: 'sent',
            mediaUrl: typeof metadata.mediaUrl === 'string' ? metadata.mediaUrl : undefined,
            fileName: typeof metadata.fileName === 'string' ? metadata.fileName : undefined,
            fileSize: toNumber(metadata.fileSize),
            latitude: toNumber(metadata.latitude),
            longitude: toNumber(metadata.longitude),
            duration: toNumber(metadata.duration),
            replyToId: typeof metadata.replyToId === 'string' ? metadata.replyToId : undefined,
            extra,
            waveform: Array.isArray(extra.waveform) ? extra.waveform : undefined,
            isVideoNote: metadata.isVideoNote === true,
            contact: metadata.contact,
        };
    }, [user?.userId]);

    const loadNativeSavedMessages = useCallback(async () => {
        if (!nativeSavedMessagesEnabled || !nativeEngineModule?.fetchSavedMessages || !user?.userId) {
            setNativeSavedMessages([]);
            setNativeSavedLoaded(false);
            return;
        }
        setNativeSavedLoading(true);
        try {
            const result = await Promise.resolve(nativeEngineModule.fetchSavedMessages({ userId: user.userId }));
            const fetchedMessages = extractNativeSavedMessages(result);
            setNativeSavedMessages((previous) => {
                const pendingLocalMessages = previous.filter((item) => {
                    const status = typeof item?.status === 'string' ? item.status : '';
                    if (!['sent', 'sending', 'error'].includes(status)) return false;
                    const itemId = typeof item?.id === 'string' ? item.id : '';
                    return !!itemId && !fetchedMessages.some((fetched) => fetched?.id === itemId);
                });
                return sortSavedMessagesDesc([...fetchedMessages, ...pendingLocalMessages]);
            });
            setNativeSavedLoaded(true);
        } catch (error) {
            console.warn('[saved-messages/native-engine] fetchSavedMessages failed', error);
            setNativeSavedMessages([]);
            setNativeSavedLoaded(true);
        } finally {
            setNativeSavedLoading(false);
        }
    }, [nativeEngineModule, nativeSavedMessagesEnabled, user?.userId]);

    useEffect(() => {
        if (nativeSavedMessagesEnabled) {
            void loadNativeSavedMessages();
            return;
        }
        void sync();
    }, [loadNativeSavedMessages, nativeSavedMessagesEnabled, sync]);

    const handleSend = () => {
        if (!text.trim()) return;
        sendMessage(text.trim());
        setText('');
        setTimeout(() => {
            flatListRef.current?.scrollToOffset({ offset: 0, animated: true });
        }, 100);
    };

    const handleAttach = (data: any) => {
        if (data.type === 'location') {
            sendMessage('', 'location', { latitude: data.latitude, longitude: data.longitude });
        } else if (data.type === 'image') {
            const caption = typeof data.caption === 'string' ? data.caption.trim() : '';
            const mimeType = typeof data.mimeType === 'string' ? data.mimeType.trim() : '';
            const explicitVideo = data.isVideo === true || /^video\//i.test(mimeType);
            const attachmentType: 'video' | 'image' =
                explicitVideo || /\.(mp4|mov|m4v|avi|mkv|webm)(?:$|[?#])/i.test(data.uri)
                    ? 'video'
                    : 'image';
            sendMessage(caption, attachmentType, {
                mediaUrl: data.uri,
                width: data.width,
                height: data.height,
                mimeType: mimeType || undefined,
                duration: toNumber(data.duration),
                fileName: typeof data.name === 'string' ? data.name : undefined,
            });
        } else if (data.type === 'contact') {
            sendMessage('Contact', 'contact', { contact: data.contact });
        } else if (data.type === 'file') {
            const isVoice = data.name.toLowerCase().endsWith('.m4a') && (data.duration !== undefined);
            if (isVoice) {
                sendMessage('', 'voice', {
                    mediaUrl: data.uri,
                    fileName: data.name,
                    duration: data.duration
                });
            } else {
                const isMusic = data.name.toLowerCase().endsWith('.mp3') || data.name.toLowerCase().endsWith('.wav') || data.name.toLowerCase().endsWith('.m4a');
                sendMessage(data.name, isMusic ? 'music' : 'file', { mediaUrl: data.uri, fileName: data.name });
            }
        }
    };

    const submitNativeSavedMessage = useCallback(async (payload: Record<string, unknown>) => {
        if (!nativeSavedMessagesEnabled || !nativeEngineModule?.sendSavedMessage) return;
        const optimisticMessage = buildOptimisticNativeSavedMessage(payload);
        const requestPayload = {
            ...payload,
            messageId: optimisticMessage.id,
            timestampMs: optimisticMessage.timestamp,
        };
        upsertNativeSavedMessage(optimisticMessage);
        scheduleNativeScrollToBottom();
        try {
            const result = await Promise.resolve(nativeEngineModule.sendSavedMessage(requestPayload));
            if ((result as Record<string, unknown> | undefined)?.success !== true) {
                console.warn('[saved-messages/native-engine] sendSavedMessage failed', result);
                upsertNativeSavedMessage({ id: optimisticMessage.id, status: 'error' });
            } else {
                upsertNativeSavedMessage({ id: optimisticMessage.id, status: 'sent' });
            }
        } catch (error) {
            console.warn('[saved-messages/native-engine] sendSavedMessage threw', error);
            upsertNativeSavedMessage({ id: optimisticMessage.id, status: 'error' });
        } finally {
            void loadNativeSavedMessages();
        }
    }, [
        buildOptimisticNativeSavedMessage,
        loadNativeSavedMessages,
        nativeEngineModule,
        nativeSavedMessagesEnabled,
        scheduleNativeScrollToBottom,
        upsertNativeSavedMessage,
    ]);

    const deleteNativeSavedMessage = useCallback(async (messageId: string) => {
        if (!nativeSavedMessagesEnabled || !nativeEngineModule?.deleteSavedMessage || !user?.userId) return;
        removeNativeSavedMessageLocal(messageId);
        try {
            const result = await Promise.resolve(nativeEngineModule.deleteSavedMessage({
                userId: user.userId,
                messageId,
            }));
            if ((result as Record<string, unknown> | undefined)?.success !== true) {
                console.warn('[saved-messages/native-engine] deleteSavedMessage failed', result);
                void loadNativeSavedMessages();
            }
        } catch (error) {
            console.warn('[saved-messages/native-engine] deleteSavedMessage threw', error);
            void loadNativeSavedMessages();
        }
    }, [
        loadNativeSavedMessages,
        nativeEngineModule,
        nativeSavedMessagesEnabled,
        removeNativeSavedMessageLocal,
        user?.userId,
    ]);

    const retryNativeSavedMessage = useCallback(async (messageId: string) => {
        const message = nativeSavedMessages.find((item) => item?.id === messageId);
        if (!message) return;
        await submitNativeSavedMessage(buildNativeSavedRetryPayload(message));
    }, [nativeSavedMessages, submitNativeSavedMessage]);

    const messageSource = nativeSavedMessagesEnabled ? nativeSavedMessages : savedMessages;

    const messagesWithSequence = useMemo(() => {
        return messageSource.map((item, index) => {
            const newer = messageSource[index - 1];
            const older = messageSource[index + 1];

            const isSameAsNewer = newer && newer.fromId === item.fromId;
            const isSameAsOlder = older && older.fromId === item.fromId;

            const isNewerClose = isSameAsNewer && (Math.abs(newer.timestamp - item.timestamp) < 60000);
            const isOlderClose = isSameAsOlder && (Math.abs(item.timestamp - older.timestamp) < 60000);

            let showDateHeader = false;
            let dateHeaderText = '';

            const itemDate = new Date(item.timestamp);
            const olderDate = older ? new Date(older.timestamp) : null;

            if (!older || (olderDate && itemDate.toDateString() !== olderDate.toDateString())) {
                showDateHeader = true;
                const today = new Date();
                const yesterday = new Date();
                yesterday.setDate(today.getDate() - 1);

                if (itemDate.toDateString() === today.toDateString()) {
                    dateHeaderText = 'Today';
                } else if (itemDate.toDateString() === yesterday.toDateString()) {
                    dateHeaderText = 'Yesterday';
                } else {
                    dateHeaderText = itemDate.toLocaleDateString('en-US', {
                        month: 'long',
                        day: 'numeric',
                        year: itemDate.getFullYear() !== today.getFullYear() ? 'numeric' : undefined
                    });
                }
            }

            return {
                ...item,
                isSequenceStart: !isOlderClose,
                isSequenceEnd: !isNewerClose,
                isMiddle: isSameAsOlder && isSameAsNewer,
                showDateHeader,
                dateHeaderText,
            };
        });
    }, [messageSource]);

    // Filter messages based on search query
    const filteredMessages = useMemo(() => {
        if (!searchQuery.trim()) return messagesWithSequence;
        const query = searchQuery.toLowerCase().trim();
        return messagesWithSequence.filter(msg =>
            (msg.plaintext || '').toLowerCase().includes(query)
        );
    }, [messagesWithSequence, searchQuery]);

    const openSearch = useCallback(() => {
        if (isSearching) {
            searchInputRef.current?.focus();
            return;
        }
        setIsSearching(true);
        setTimeout(() => searchInputRef.current?.focus(), 100);
        void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    }, [isSearching]);

    const closeSearch = useCallback(() => {
        setIsSearching(false);
        setSearchQuery('');
        void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    }, []);

    const handleSearchToggle = () => {
        if (isSearching) {
            closeSearch();
            return;
        }
        openSearch();
    };

    const nativeRows = useMemo(() => {
        const myUserIdUpper = (user?.userId || '').trim().toUpperCase();
        const runtimeMessages: RuntimeChatMessage[] = filteredMessages.map((message: any) => {
            const fromId = typeof message?.fromId === 'string' ? message.fromId : undefined;
            const messageId = typeof message?.id === 'string' ? message.id : String(message?.id || '');
            const nativeUploadValue = [
                message?.uploadProgress,
                message?.upload_progress,
                message?.extra?.uploadProgress,
                message?.extra?.upload_progress,
            ].find((value: unknown): value is number => typeof value === 'number' && Number.isFinite(value));
            const storeUploadValue =
                messageId && Object.prototype.hasOwnProperty.call(uploadProgress, messageId)
                    ? uploadProgress[messageId]
                    : undefined;
            const uploadValue = typeof nativeUploadValue === 'number' ? nativeUploadValue : storeUploadValue;
            return {
                id: messageId,
                chatId: 'saved_messages',
                fromId,
                timestampMs: typeof message?.timestamp === 'number' ? message.timestamp : Date.now(),
                timestamp: typeof message?.timestamp === 'number'
                    ? new Date(message.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                    : undefined,
                text: normalizeSavedMessageText(message),
                type: typeof message?.type === 'string' ? message.type : 'text',
                status: typeof message?.status === 'string' ? message.status : undefined,
                mediaUrl: typeof message?.mediaUrl === 'string' ? message.mediaUrl : undefined,
                fileName: typeof message?.fileName === 'string' ? message.fileName : undefined,
                duration: typeof message?.duration === 'number' ? message.duration : undefined,
                metadata: message?.extra && typeof message.extra === 'object' ? message.extra : undefined,
                waveform: Array.isArray(message?.extra?.waveform)
                    ? message.extra.waveform.filter((n: unknown) => typeof n === 'number')
                    : undefined,
                isVideoNote: message?.isVideoNote === true,
                uploadProgress: typeof uploadValue === 'number' ? uploadValue : undefined,
                isMe: !!fromId && !!myUserIdUpper && fromId.trim().toUpperCase() === myUserIdUpper,
                isEdited: message?.isEdited === true,
                editedAt: typeof message?.editedAt === 'number' ? message.editedAt : undefined,
                replyToId: typeof message?.replyToId === 'string' ? message.replyToId : undefined,
                encryptedContent: typeof message?.encryptedContent === 'string' ? message.encryptedContent : undefined,
            };
        });

        runtimeMessages.sort((a, b) => a.timestampMs - b.timestampMs);
        return mapMessagesToNativeRows(runtimeMessages);
    }, [filteredMessages, uploadProgress, user?.userId]);

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

        if (type === 'headerSearchPressed') {
            if (Platform.OS === 'ios') {
                setIsSearching(true);
                void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            } else {
                openSearch();
            }
            return;
        }

        if (type === 'headerSearchChanged') {
            const nextQuery = typeof payload.text === 'string' ? payload.text : '';
            if (!isSearching) {
                setIsSearching(true);
            }
            setSearchQuery(nextQuery);
            return;
        }

        if (type === 'headerSearchDismissed') {
            closeSearch();
            return;
        }

        if (type === 'openFile') {
            const rawUrl = typeof payload.url === 'string' ? payload.url : '';
            const url = rawUrl ? normalizeOpenFileUrl(rawUrl) : '';
            if (!url || Platform.OS === 'ios') return;
            Linking.openURL(url).catch((error) => {
                console.warn('[saved-messages/native-main] failed to open file url', { url, error });
            });
            return;
        }

        if (type === 'sendMessage') {
            const textValue = typeof payload.text === 'string' ? payload.text.trim() : '';
            if (!textValue) return;
            if (nativeSavedMessagesEnabled) {
                void submitNativeSavedMessage({
                    type: 'text',
                    text: textValue,
                    messageId: typeof payload.messageId === 'string' ? payload.messageId : undefined,
                });
            } else {
                void sendMessage(textValue).finally(scheduleNativeScrollToBottom);
            }
            return;
        }

        if (type === 'attachmentImage') {
            const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
            if (!uri) return;
            const caption = typeof payload.caption === 'string' ? payload.caption.trim() : '';
            const mimeType = typeof payload.mimeType === 'string' ? payload.mimeType.trim() : '';
            const explicitVideo = payload.isVideo === true || /^video\//i.test(mimeType);
            const attachmentType: 'video' | 'image' =
                explicitVideo || /\.(mp4|mov|m4v|avi|mkv|webm)(?:$|[?#])/i.test(uri) ? 'video' : 'image';
            const metadata: Record<string, any> = {
                mediaUrl: uri,
                width: toNumber(payload.width),
                height: toNumber(payload.height),
            };
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
            if (nativeSavedMessagesEnabled) {
                void submitNativeSavedMessage({
                    type: attachmentType,
                    text: caption,
                    metadata,
                });
            } else {
                void sendMessage(caption, attachmentType, metadata).finally(scheduleNativeScrollToBottom);
            }
            return;
        }

        if (type === 'attachmentGif') {
            const mediaUrl =
                (typeof payload.url === 'string' && payload.url.trim())
                || (typeof payload.uri === 'string' && payload.uri.trim());
            if (!mediaUrl) return;
            if (nativeSavedMessagesEnabled) {
                void submitNativeSavedMessage({
                    type: 'gif',
                    text: '',
                    metadata: {
                        mediaUrl,
                        width: toNumber(payload.width),
                        height: toNumber(payload.height),
                    },
                });
            } else {
                void sendMessage('', 'gif', {
                    mediaUrl,
                    width: toNumber(payload.width),
                    height: toNumber(payload.height),
                }).finally(scheduleNativeScrollToBottom);
            }
            return;
        }

        if (type === 'attachmentSticker') {
            const stickerId =
                typeof payload.stickerId === 'string' ? payload.stickerId.trim() : '';
            const packId =
                typeof payload.packId === 'string' ? payload.packId.trim() : '';
            const bundleFileName =
                typeof payload.bundleFileName === 'string' ? payload.bundleFileName.trim() : '';
            if (!stickerId || !packId) return;
            const metadata = {
                stickerId,
                stickerPackId: packId,
                packId,
                stickerBundleFileName: bundleFileName || undefined,
                bundleFileName: bundleFileName || undefined,
                emoji: typeof payload.emoji === 'string' ? payload.emoji : undefined,
                width: toNumber(payload.width),
                height: toNumber(payload.height),
            };
            if (nativeSavedMessagesEnabled) {
                void submitNativeSavedMessage({
                    type: 'sticker',
                    text: '',
                    metadata,
                });
            } else {
                void sendMessage('', 'sticker', metadata).finally(scheduleNativeScrollToBottom);
            }
            return;
        }

        if (type === 'attachmentFile') {
            const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
            if (!uri) return;
            const fileName =
                (typeof payload.name === 'string' && payload.name.trim())
                || 'File';
            const lowerName = fileName.toLowerCase();
            const duration = toNumber(payload.duration);
            const isVoice = lowerName.endsWith('.m4a') && duration !== undefined;
            if (isVoice) {
                if (nativeSavedMessagesEnabled) {
                    void submitNativeSavedMessage({
                        type: 'voice',
                        text: '',
                        metadata: {
                            mediaUrl: uri,
                            fileName,
                            duration,
                            fileSize: toNumber(payload.size),
                        },
                    });
                } else {
                    void sendMessage('', 'voice', {
                        mediaUrl: uri,
                        fileName,
                        duration,
                        fileSize: toNumber(payload.size),
                    }).finally(scheduleNativeScrollToBottom);
                }
                return;
            }
            const isMusic = lowerName.endsWith('.mp3') || lowerName.endsWith('.wav') || lowerName.endsWith('.m4a');
            if (nativeSavedMessagesEnabled) {
                void submitNativeSavedMessage({
                    type: isMusic ? 'music' : 'file',
                    text: fileName,
                    metadata: {
                        mediaUrl: uri,
                        fileName,
                        fileSize: toNumber(payload.size),
                    },
                });
            } else {
                void sendMessage(fileName, isMusic ? 'music' : 'file', {
                    mediaUrl: uri,
                    fileName,
                    fileSize: toNumber(payload.size),
                }).finally(scheduleNativeScrollToBottom);
            }
            return;
        }

        if (type === 'attachmentLocation') {
            const latitude = toNumber(payload.latitude);
            const longitude = toNumber(payload.longitude);
            if (latitude == null || longitude == null) return;
            if (nativeSavedMessagesEnabled) {
                void submitNativeSavedMessage({
                    type: 'location',
                    text: '',
                    metadata: {
                        latitude,
                        longitude,
                    },
                });
            } else {
                void sendMessage('', 'location', {
                    latitude,
                    longitude,
                }).finally(scheduleNativeScrollToBottom);
            }
            return;
        }

        if (type === 'attachmentVoice') {
            const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
            if (!uri) return;
            if (nativeSavedMessagesEnabled) {
                void submitNativeSavedMessage({
                    type: 'voice',
                    text: '',
                    metadata: {
                        mediaUrl: uri,
                        fileName: typeof payload.name === 'string' ? payload.name : 'voice-message.m4a',
                        duration: toNumber(payload.duration),
                        waveform: Array.isArray(payload.waveform)
                            ? payload.waveform.filter((value: unknown): value is number => typeof value === 'number')
                            : undefined,
                    },
                });
            } else {
                void sendMessage('', 'voice', {
                    mediaUrl: uri,
                    fileName: typeof payload.name === 'string' ? payload.name : 'voice-message.m4a',
                    duration: toNumber(payload.duration),
                }).finally(scheduleNativeScrollToBottom);
            }
            return;
        }

        if (type === 'attachmentVideoNote') {
            const uri = typeof payload.uri === 'string' ? payload.uri.trim() : '';
            if (!uri) return;
            if (nativeSavedMessagesEnabled) {
                void submitNativeSavedMessage({
                    type: 'video',
                    text: '',
                    metadata: {
                        mediaUrl: uri,
                        fileName: typeof payload.name === 'string' ? payload.name : 'video-note.mov',
                        duration: toNumber(payload.duration),
                        isVideoNote: true,
                    },
                });
            } else {
                void sendMessage('', 'video', {
                    mediaUrl: uri,
                    fileName: typeof payload.name === 'string' ? payload.name : 'video-note.mov',
                    duration: toNumber(payload.duration),
                }).finally(scheduleNativeScrollToBottom);
            }
            return;
        }

        if (type === 'contextMenuAction') {
            const action = typeof payload.action === 'string' ? payload.action : '';
            const messageId = typeof payload.messageId === 'string' ? payload.messageId : '';
            if (!messageId) return;
            if (action === 'delete') {
                if (nativeSavedMessagesEnabled) {
                    void deleteNativeSavedMessage(messageId);
                } else {
                    void removeMessage(messageId);
                }
                return;
            }
            if (action === 'resend') {
                if (nativeSavedMessagesEnabled) {
                    void retryNativeSavedMessage(messageId);
                } else {
                    void retryMessage(messageId).finally(scheduleNativeScrollToBottom);
                }
            }
        }
    }, [
        deleteNativeSavedMessage,
        nativeSavedMessagesEnabled,
        closeSearch,
        isSearching,
        openSearch,
        removeMessage,
        retryMessage,
        retryNativeSavedMessage,
        router,
        scheduleNativeScrollToBottom,
        sendMessage,
        submitNativeSavedMessage,
    ]);

    if (nativeMainAvailable) {
        return (
            <View style={{ flex: 1, backgroundColor: 'transparent' }}>
                <Stack.Screen options={{ headerShown: false }} />
                <NativeSavedMessagesSurface
                    ref={nativeSurfaceRef}
                    forceRender
                    surfaceId="saved-messages-native-main"
                    rows={nativeRows}
                    engineSurfaceId="saved-messages-native-main"
                    myUserId={user?.userId || undefined}
                    appearance={{
                        backgroundMode: 'gradient',
                        nativeThemeId: `saved-messages-${effectiveTheme}`,
                        nativeThemeIsDark: effectiveTheme === 'dark',
                        wallpaperGradient: nativeWallpaperGradient,
                        wallpaperOpacity: 1,
                        wallpaperPatternGradient: resolvedTheme.patternGradientColors || [],
                        wallpaperPatternLocations: resolvedTheme.patternGradientLocations || undefined,
                        wallpaperPatternOpacity: resolvedTheme.patternOpacity || 0,
                        wallpaperMaskKey: resolvedTheme.maskedImage || resolvedTheme.patternType || undefined,
                        bubbleMeGradient: resolvedTheme.bubbleMeGradient || [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe],
                        bubbleThemGradient:
                            resolvedTheme.bubbleThemGradient
                            || [resolvedTheme.bubbleThem, resolvedTheme.bubbleThem],
                        bubbleThemColor:
                            resolvedTheme.bubbleThemGradient?.[0]
                            || resolvedTheme.bubbleThem
                            || colors.card,
                        textColorMe: resolvedTheme.textColorMe || colors.text,
                        textColorThem: resolvedTheme.textColorThem || colors.text,
                        timeColorThem: colors.textSecondary,
                    }}
                    contentPaddingTop={16}
                    contentPaddingBottom={Math.max(14, insets.bottom + 8)}
                    inputBarEnabled
                    inputPlaceholder="Saved Message"
                    nativeSendEnabled
                    onNativeEvent={handleNativeEvent}
                    onNativeError={(error, context) => {
                        console.warn('[saved-messages/native-main]', context, error);
                    }}
                />

                {nativeRows.length === 0 && (!nativeSavedMessagesEnabled || nativeSavedLoaded) && !nativeSavedLoading && (
                    <View
                        pointerEvents="none"
                        style={{
                            ...StyleSheet.absoluteFillObject,
                            top: insets.top + 60,
                            bottom: 0,
                            alignItems: 'center',
                            justifyContent: 'center',
                            paddingHorizontal: 24,
                        }}
                    >
                        <Text style={{ color: colors.textSecondary, textAlign: 'center', fontSize: 16 }}>
                            {searchQuery ? 'No matching messages' : 'No saved messages yet'}
                        </Text>
                    </View>
                )}

                {Platform.OS !== 'ios' && isSearching && (
                    <View
                        style={{
                            position: 'absolute',
                            top: 0,
                            left: 0,
                            right: 0,
                            zIndex: 40,
                            paddingTop: insets.top + 10,
                            paddingHorizontal: 16,
                            paddingBottom: 10,
                        }}
                    >
                        <SafeLiquidGlass
                            style={{
                                height: 44,
                                borderRadius: 22,
                                overflow: 'hidden',
                                flexDirection: 'row',
                                alignItems: 'center',
                                paddingHorizontal: 12,
                            }}
                            blurIntensity={25}
                            tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        >
                            <Search size={18} color={withAlpha(colors.text, 0.5)} />
                            <TextInput
                                ref={searchInputRef}
                                style={{ flex: 1, color: colors.text, fontSize: 15, paddingLeft: 8, height: '100%' }}
                                placeholder="Search messages..."
                                placeholderTextColor={withAlpha(colors.text, 0.4)}
                                value={searchQuery}
                                onChangeText={setSearchQuery}
                                autoCorrect={false}
                            />
                            <TouchableOpacity onPress={closeSearch}>
                                <Text style={{ color: colors.primary, fontWeight: '600' }}>Cancel</Text>
                            </TouchableOpacity>
                        </SafeLiquidGlass>
                    </View>
                )}
            </View>
        );
    }

    return (
        <View style={{ flex: 1, backgroundColor: colors.background }}>
            <Stack.Screen options={{ headerShown: false }} />

            <GestureHandlerRootView style={{ flex: 1 }}>
                {/* Background */}
                <WallpaperBackground />

                {/* Header Mask */}
                <View style={[styles.headerContainer, { height: insets.top + 60, zIndex: 60, pointerEvents: 'none' }]}>
                    <MaskedViewAny
                        style={StyleSheet.absoluteFill}
                        maskElement={<LinearGradient colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']} locations={[0.6, 1]} style={StyleSheet.absoluteFill} />}
                    >
                        <BlurView intensity={10} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { backgroundColor: 'transparent' }]} />
                    </MaskedViewAny>
                </View>

                {/* Header Content */}
                <View style={[
                    styles.headerContentContainer,
                    {
                        height: insets.top + 60,
                        paddingTop: insets.top + 10,
                        zIndex: 130,
                        flexDirection: 'row',
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        paddingHorizontal: 16
                    }
                ]} pointerEvents="box-none">

                    {/* Left: Back + Badge + Title */}
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
                        <SafeLiquidGlass style={{ borderRadius: 20, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                            <TouchableOpacity
                                onPress={() => router.back()}
                                style={{
                                    width: 40,
                                    height: 40,
                                    justifyContent: 'center',
                                    alignItems: 'center',
                                }}
                            >
                                <ArrowLeft color={colors.text} size={28} />
                            </TouchableOpacity>
                        </SafeLiquidGlass>

                        {/* Profile Info styled like chat.tsx */}
                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
                            <View style={{ width: 40, height: 40, borderRadius: 20, overflow: 'hidden', backgroundColor: colors.primary + '20', justifyContent: 'center', alignItems: 'center' }}>
                                <Bookmark size={20} color={colors.primary} fill={colors.primary} />
                            </View>

                            {!isSearching && (
                                <View>
                                    <Text style={{ color: colors.text, fontSize: 16, fontWeight: '600' }} numberOfLines={1}>
                                        Saved Messages
                                    </Text>

                                </View>
                            )}
                        </View>
                    </View>

                    {/* Right Area: Search Icon & Input */}
                    <View style={{ flexDirection: 'row', alignItems: 'center', flex: isSearching ? 1 : 0, justifyContent: 'flex-end', marginLeft: isSearching ? 10 : 0 }}>
                        {isSearching ? (
                            <SafeLiquidGlass style={{ flex: 1, height: 40, borderRadius: 20, overflow: 'hidden', flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12 }} blurIntensity={25} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                <Search size={18} color={withAlpha(colors.text, 0.5)} />
                                <TextInput
                                    ref={searchInputRef}
                                    style={{ flex: 1, color: colors.text, fontSize: 15, paddingLeft: 8, height: '100%' }}
                                    placeholder="Search messages..."
                                    placeholderTextColor={withAlpha(colors.text, 0.4)}
                                    value={searchQuery}
                                    onChangeText={setSearchQuery}
                                    autoCorrect={false}
                                />
                                <TouchableOpacity onPress={() => setIsSearching(false)}>
                                    <Text style={{ color: colors.primary, fontWeight: '600' }}>Cancel</Text>
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        ) : (
                            <SafeLiquidGlass style={{ borderRadius: 20, overflow: 'hidden' }} blurIntensity={20} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                <TouchableOpacity
                                    onPress={handleSearchToggle}
                                    style={{ width: 40, height: 40, justifyContent: 'center', alignItems: 'center' }}
                                >
                                    <Search color={colors.text} size={22} />
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        )}
                    </View>
                </View>

                {/* List */}
                <FlatList
                    ref={flatListRef}
                    data={filteredMessages}
                    keyExtractor={item => item.id}
                    renderItem={({ item, index }) => {
                        const isMe = item.fromId === user?.userId;
                        const displayText = normalizeSavedMessageText(item);
                        return (
                            <Animated.View entering={FadeIn.duration(200)} style={{ marginBottom: 2 }}>
                                {item.showDateHeader && (
                                    <View style={styles.dateHeaderContainer}>
                                        <SafeLiquidGlass style={styles.dateHeaderGlass} blurIntensity={15} tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                            <Text style={[styles.dateHeaderText, { color: colors.text }]}>{item.dateHeaderText}</Text>
                                        </SafeLiquidGlass>
                                    </View>
                                )}
                                <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: isMe ? 'flex-end' : 'flex-start', paddingHorizontal: 16 }}>
                                    <LinearGradient
                                        colors={isMe ? bubbleTheme.meGradient : bubbleTheme.themGradient}
                                        start={{ x: 0, y: 0 }}
                                        end={{ x: 1, y: 1 }}
                                        style={[
                                            {
                                                padding: (item.type === 'image' || item.type === 'sticker') && !displayText ? 0 : 8,
                                                paddingHorizontal: (item.type === 'image' || item.type === 'sticker') && !displayText ? 0 : 12,
                                                borderRadius: 18,
                                                maxWidth: '85%',
                                            },
                                            isMe ? { borderBottomRightRadius: 4 } : { borderBottomLeftRadius: 4 },
                                        ]}
                                    >
                                        <MessageBubbleBody item={{
                                            ...item,
                                            isMe,
                                            caption: displayText,
                                            text: displayText,
                                            timestamp: new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
                                        } as any} />
                                    </LinearGradient>
                                </View>
                            </Animated.View>
                        );
                    }}
                    extraData={filteredMessages.length}
                    inverted
                    contentContainerStyle={{ paddingTop: insets.top + 70, paddingBottom: 10 }}
                    showsVerticalScrollIndicator={false}
                    keyboardDismissMode="interactive"
                    keyboardShouldPersistTaps="handled"
                    ListHeaderComponent={<Animated.View style={[fakeViewStyle]} />}
                    ListEmptyComponent={
                        <View style={{ flex: 1, transform: [{ scaleY: -1 }], alignItems: 'center', marginTop: 100 }}>
                            <Text style={{ color: colors.textSecondary }}>
                                {searchQuery ? 'No matching messages' : 'No saved messages yet'}
                            </Text>
                        </View>
                    }
                />

                {/* Input Container */}
                <KeyboardStickyView offset={{ closed: 0, opened: 25 }} style={{ position: 'absolute', bottom: 0, left: 0, right: 0, zIndex: 65 }}>
                    <View style={{ paddingBottom: Math.max(insets.bottom, 10), paddingTop: 10, paddingHorizontal: 16 }}>
                        <ChatInput
                            text={text}
                            setText={setText}
                            onSend={handleSend}
                            onAttach={handleAttach}
                        />
                    </View>
                </KeyboardStickyView>

                {/* Context Menu */}
                <MessageContextMenu
                    visible={contextMenuVisible}
                    onClose={() => setContextMenuVisible(false)}
                    position={menuPosition}
                    isMe={selectedMessageInfo?.item?.fromId === user?.userId}
                    messageText={selectedMessageInfo?.item?.plaintext}
                    onReply={() => setContextMenuVisible(false)}
                    onDelete={() => { removeMessage(selectedMessageInfo?.item?.id); setContextMenuVisible(false); }}
                    colors={colors}
                    displayContent={selectedMessageInfo?.displayContent}
                    item={selectedMessageInfo?.item}
                    isSequenceStart={selectedMessageInfo?.isSequenceStart}
                    isSequenceEnd={selectedMessageInfo?.isSequenceEnd}
                    isMiddle={selectedMessageInfo?.isMiddle}
                />
            </GestureHandlerRootView>
        </View>
    );
}

const styles = StyleSheet.create({
    headerContainer: { position: 'absolute', top: 0, left: 0, right: 0, zIndex: 50 },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingBottom: 4 },
    headerBtnWrapper: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', zIndex: 140 },
    headerGlassBtn: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
    headerTouchArea: { width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center', zIndex: 150 },
    headerCenterWrapper: { flex: 1, alignItems: 'center', justifyContent: 'center', marginHorizontal: 10, height: 44 },
    headerCenterGlass: { flex: 1, borderRadius: 22, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 20 },
    headerTitle: { fontSize: 16, fontWeight: '700', textAlign: 'center' },
    headerGlassGroup: { flexDirection: 'row', alignItems: 'center', borderRadius: 22, height: 44, paddingHorizontal: 4 },
    headerIconBtn: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
    separator: { width: 1, height: 20, marginHorizontal: 2 },

    dateHeaderContainer: {
        alignItems: 'center',
        marginVertical: 12,
        marginTop: 20,
    },
    dateHeaderGlass: {
        paddingHorizontal: 16,
        paddingVertical: 4,
        borderRadius: 12,
        minWidth: 80,
        alignItems: 'center',
    },
    dateHeaderText: {
        fontSize: 12,
        fontWeight: '600',
        opacity: 0.8,
    },
});
