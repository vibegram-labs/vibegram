import React, { useMemo, useEffect, useCallback, useRef, useState } from 'react';
import {
    Platform,
    View,
    StyleSheet,
    Text,
    TextInput,
    TouchableOpacity,
} from 'react-native';
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import Animated, {
    cancelAnimation,
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    withRepeat,
    Easing,
    SharedValue,
} from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';
import { Search, X } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

const MaskedViewAny = MaskedView as any;

import { useChatStore } from '../src/lib/ChatStore';
import ChatScreenHeader from '../src/components/chat/ChatScreenHeader';
import WallpaperBackground from '../src/components/chat/WallpaperBackground';
import { useThemeStore } from '../src/lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../src/lib/stores/wallpaper-store';
import { getUserChannel } from '../src/lib/ChatStore';
import { useCallStore } from '../src/lib/stores/CallStore';
import { useAuthStore } from '../src/lib/stores/auth-store';
import ChatListScreen from './chatlist';
import { VideoNoteOverlay } from '../src/components/chat/VideoNoteOverlay';
import { haptics } from '../src/lib/haptics';
import SafeLiquidGlass from '../src/components/native/SafeLiquidGlass';
import { getNativeChatRuntimeInfo } from '../src/native/chat';

const withAlpha = (color: string, alpha: number) => {
    if (!color) return `rgba(255, 255, 255, ${alpha})`;
    if (color.startsWith('#')) {
        const r = parseInt(color.slice(1, 3), 16);
        const g = parseInt(color.slice(3, 5), 16);
        const b = parseInt(color.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    return color;
};

const waitForUserChannel = async (timeoutMs = 12000): Promise<any | null> => {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
        const channel = getUserChannel();
        const state = (channel as any)?.state;
        const canPush =
            typeof (channel as any)?.canPush === 'function'
                ? !!(channel as any).canPush()
                : state === 'joined';
        const ready =
            channel &&
            typeof channel.push === 'function' &&
            canPush;
        if (ready) return channel;
        await new Promise((resolve) => setTimeout(resolve, 120));
    }
    return null;
};

const TYPING_MASK_WIDTH = 84;
const TYPING_SHIMMER_BAND_WIDTH = 120;
const TYPING_SHIMMER_START = -TYPING_SHIMMER_BAND_WIDTH;
const TYPING_SHIMMER_END = TYPING_MASK_WIDTH + TYPING_SHIMMER_BAND_WIDTH;
const CHAT_PROFILE_PERF_LOG = __DEV__;
const chatProfilePerfLog = (...args: any[]) => {
    if (!CHAT_PROFILE_PERF_LOG) return;
    console.log('[ChatProfilePerf]', ...args);
};

const parseTimestampMs = (value: unknown): number | undefined => {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return value > 1_000_000_000_000 ? value : value * 1000;
    }
    if (typeof value === 'string') {
        const trimmed = value.trim();
        if (/^-?\d+(\.\d+)?$/.test(trimmed)) {
            const numeric = Number(trimmed);
            if (Number.isFinite(numeric)) {
                return numeric > 1_000_000_000_000 ? numeric : numeric * 1000;
            }
        }
        const parsed = new Date(value).getTime();
        if (Number.isFinite(parsed)) return parsed;
    }
    if (value instanceof Date) {
        const parsed = value.getTime();
        if (Number.isFinite(parsed)) return parsed;
    }
    return undefined;
};

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

const normalizeChatType = (value: unknown): 'dm' | 'group' | 'channel' => {
    const raw = String(value || '').trim().toLowerCase();
    if (raw === 'group') return 'group';
    if (raw === 'channel') return 'channel';
    return 'dm';
};

const pickLatestTimestamp = (...values: Array<number | undefined>): number | undefined => {
    let latest: number | undefined;
    values.forEach((value) => {
        if (!Number.isFinite(value)) return;
        if (latest === undefined || (value as number) > latest) {
            latest = value as number;
        }
    });
    return latest;
};

const formatLastSeen = (timestampMs?: number) => {
    if (!timestampMs) return 'last seen recently';
    const deltaMs = Date.now() - timestampMs;
    if (!Number.isFinite(deltaMs)) return 'last seen recently';
    if (deltaMs < 0) return 'last seen just now';

    const minutes = Math.floor(deltaMs / 60_000);
    if (minutes < 1) return 'last seen just now';
    if (minutes < 60) return `last seen ${minutes}m ago`;

    const hours = Math.floor(deltaMs / 3_600_000);
    if (hours < 24) return `last seen ${hours}h ago`;

    const days = Math.floor(deltaMs / 86_400_000);
    if (days < 7) return `last seen ${days}d ago`;
    if (days < 30) return 'last seen last week';
    return 'last seen long time ago';
};

const TypingShimmer = ({
    baseColor,
    sweepColor,
    shimmerX
}: {
    baseColor: string;
    sweepColor: string;
    shimmerX: SharedValue<number>;
}) => {
    const shimmerStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: shimmerX.value }],
    }));

    return (
        <MaskedViewAny
            style={styles.typingMask}
            maskElement={
                <View style={styles.typingMaskInner}>
                    <Text style={styles.typingTextMask}>typing...</Text>
                </View>
            }
        >
            <View style={[StyleSheet.absoluteFill, { backgroundColor: baseColor }]} />
            <Animated.View style={[styles.typingShimmerBand, shimmerStyle]}>
                <LinearGradient
                    colors={['transparent', sweepColor, 'transparent']}
                    start={{ x: 0, y: 0.5 }}
                    end={{ x: 1, y: 0.5 }}
                    style={styles.typingShimmerBandFill}
                />
            </Animated.View>
        </MaskedViewAny>
    );
};

export default function ChatScreen() {
    const params = useLocalSearchParams();
    const router = useRouter();
    const insets = useSafeAreaInsets();
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme } = useWallpaperStore();

    // Store access
    const chats = useChatStore(s => s.chats);
    const activeChatId = useChatStore(s => s.activeChatId);
    const setActiveChat = useChatStore(s => s.setActiveChat);
    const startChat = useChatStore(s => s.startChat);
    const onlineUsers = useChatStore(s => s.onlineUsers);
    const typingUsers = useChatStore(s => s.typingUsers);
    const sendTyping = useChatStore(s => s.sendTyping);
    const sendStopTyping = useChatStore(s => s.sendStopTyping);
    const isConnected = useChatStore(s => s.isConnected);
    const initSocket = useChatStore(s => s.initSocket);

    const callStatus = useCallStore(s => s.callStatus);
    const checkWebRTCAvailability = useCallStore(s => s.checkWebRTCAvailability);
    const startCall = useCallStore(s => s.startCall);

    const { user } = useAuthStore();

    const chatIdFromParams = getParamString(params?.id) || getParamString((params as any)?.chatId);
    const friendIdFromParams = getParamString((params as any)?.friendId);
    const friendNameFromParams = getParamString((params as any)?.friendName);
    const friendImageFromParams = getParamString((params as any)?.friendImage);
    const friendPublicKeyFromParams = getParamString((params as any)?.friendPublicKey);
    const chatTypeFromParams = getParamString((params as any)?.chatType);
    const openSearchParam = getParamString((params as any)?.openSearch);
    const initialSearchParam = getParamString((params as any)?.search);
    const effectiveChatId = chatIdFromParams || activeChatId || chats[0]?.chatId || null;
    const activeChat = chats.find(c => c.chatId === effectiveChatId);
    const effectiveChatType = normalizeChatType(activeChat?.type ?? chatTypeFromParams);
    const isDirectChat = effectiveChatType === 'dm';
    const [isResolvingRouteChat, setIsResolvingRouteChat] = useState(false);
    const [chatSearchOpen, setChatSearchOpen] = useState(openSearchParam === '1' || openSearchParam === 'true');
    const [chatSearchQuery, setChatSearchQuery] = useState(initialSearchParam || '');
    const searchInputRef = useRef<TextInput>(null);
    const displayName = activeChat?.friendName || activeChat?.name || friendNameFromParams || friendIdFromParams || 'Chat';

    // Typing shimmer animation
    const typingShimmerX = useSharedValue(0);
    const [videoNoteVisible, setVideoNoteVisible] = useState(false);
    const [incomingVideoNote, setIncomingVideoNote] = useState<{ uri: string; duration?: number; token: number } | null>(null);
    const [friendApiPresence, setFriendApiPresence] = useState<{ lastSeenMs?: number; online?: boolean } | null>(null);
    const [androidWallpaperRefreshKey, setAndroidWallpaperRefreshKey] = useState(0);
    const nativeChatRuntime = useMemo(() => getNativeChatRuntimeInfo(), []);
    const videoNoteCanceledRef = useRef(false);
    const profileNavInFlightRef = useRef(false);

    useFocusEffect(
        useCallback(() => {
            if (Platform.OS !== 'android') return;
            // Android MaskedView can lose its mask after navigating back from stacked screens.
            // Force a lightweight remount so the wallpaper pattern restores reliably.
            setAndroidWallpaperRefreshKey((current) => current + 1);
        }, [])
    );

    useEffect(() => {
        const shouldOpenSearch = openSearchParam === '1' || openSearchParam === 'true';
        if (shouldOpenSearch) setChatSearchOpen(true);
    }, [openSearchParam]);

    useEffect(() => {
        if (chatSearchOpen) {
            setTimeout(() => {
                searchInputRef.current?.focus();
            }, 50);
        } else {
            searchInputRef.current?.blur();
        }
    }, [chatSearchOpen]);

    useEffect(() => {
        if (initialSearchParam !== null) {
            setChatSearchQuery(initialSearchParam);
        }
    }, [initialSearchParam]);

    useEffect(() => {
        if (chatIdFromParams && chatIdFromParams !== activeChatId) {
            setActiveChat(chatIdFromParams);
        }
    }, [chatIdFromParams, activeChatId, setActiveChat]);

    useEffect(() => {
        if (chatIdFromParams || !friendIdFromParams) return;

        const normalizedFriendId = friendIdFromParams.toUpperCase();
        const existing = chats.find((chat) => (chat.friendId || '').toUpperCase() === normalizedFriendId);
        if (existing?.chatId) {
            if (existing.chatId !== activeChatId) {
                setActiveChat(existing.chatId);
            }
            router.replace({ pathname: '/chat', params: { id: existing.chatId } });
            return;
        }

        let cancelled = false;
        setIsResolvingRouteChat(true);

        void (async () => {
            try {
                const chatId = await startChat(friendIdFromParams, {
                    username: friendNameFromParams || undefined,
                    profileImage: friendImageFromParams || undefined,
                    publicKey: friendPublicKeyFromParams || undefined,
                });
                if (cancelled || !chatId) return;
                setActiveChat(chatId);
                router.replace({ pathname: '/chat', params: { id: chatId } });
            } catch (error) {
                if (!cancelled) {
                    console.warn('[ChatScreen] Failed to resolve friend chat route:', error);
                }
            } finally {
                if (!cancelled) setIsResolvingRouteChat(false);
            }
        })();

        return () => {
            cancelled = true;
        };
    }, [
        chatIdFromParams,
        friendIdFromParams,
        friendNameFromParams,
        friendImageFromParams,
        friendPublicKeyFromParams,
        chats,
        activeChatId,
        setActiveChat,
        startChat,
        router,
    ]);

    const friendIdUpper = isDirectChat ? (activeChat?.friendId || '').toUpperCase() : '';
    const isFriendTyping = !!friendIdUpper && typingUsers.has(friendIdUpper);

    useEffect(() => {
        cancelAnimation(typingShimmerX);
        if (!isFriendTyping) {
            typingShimmerX.value = TYPING_SHIMMER_START;
            return;
        }
        typingShimmerX.value = TYPING_SHIMMER_START;
        typingShimmerX.value = withRepeat(
            withTiming(TYPING_SHIMMER_END, { duration: 1150, easing: Easing.linear }),
            -1,
            false
        );
        return () => {
            cancelAnimation(typingShimmerX);
        };
    }, [isFriendTyping, typingShimmerX]);
    const fallbackLastSeenMs = useMemo(() => {
        if (!activeChat) return undefined;
        if (!friendIdUpper) {
            return pickLatestTimestamp(
                parseTimestampMs((activeChat as any).updatedAt),
                parseTimestampMs((activeChat as any).updated_at)
            );
        }
        let latestFriendMessageMs: number | undefined;
        const messages = Array.isArray(activeChat.messages) ? activeChat.messages : [];
        // Avoid scanning entire chat history on header renders; a small tail window
        // is enough for last-seen fallback and prevents JS-thread stalls on large chats.
        let inspected = 0;
        for (let i = messages.length - 1; i >= 0 && inspected < 120; i -= 1, inspected += 1) {
            const m = messages[i] as any;
            if ((m?.fromId || '').toUpperCase() !== friendIdUpper) continue;
            const ts = parseTimestampMs(m?.timestamp);
            if (!ts) continue;
            latestFriendMessageMs = ts;
            break;
        }

        const lastMessageFromFriendMs =
            (activeChat.lastMessage?.fromId || '').toUpperCase() === friendIdUpper
                ? parseTimestampMs(activeChat.lastMessage?.timestamp)
                : undefined;

        return pickLatestTimestamp(
            latestFriendMessageMs,
            lastMessageFromFriendMs,
            parseTimestampMs((activeChat as any).updatedAt),
            parseTimestampMs((activeChat as any).updated_at)
        );
    }, [
        activeChat?.messages?.length,
        activeChat?.lastMessage?.fromId,
        activeChat?.lastMessage?.timestamp,
        (activeChat as any)?.updatedAt,
        (activeChat as any)?.updated_at,
        friendIdUpper,
    ]);

    const headerIsOnline =
        isDirectChat && (((!!friendIdUpper && onlineUsers.has(friendIdUpper)) || friendApiPresence?.online === true));

    const handlePressAvatar = useCallback(() => {
        if (profileNavInFlightRef.current) return;
        const tapTs = Date.now();
        const activeMessageCount = Array.isArray(activeChat?.messages) ? activeChat.messages.length : 0;
        chatProfilePerfLog('avatarTap:start', {
            chatId: activeChat?.chatId,
            type: effectiveChatType,
            activeMessageCount,
            ts: tapTs,
        });

        if (activeChat?.chatId && effectiveChatType === 'channel') {
            profileNavInFlightRef.current = true;
            chatProfilePerfLog('avatarTap:push:channel-info', { chatId: activeChat.chatId, dt: Date.now() - tapTs });
            router.push({
                pathname: '/channel-info',
                params: { channelId: activeChat.chatId }
            });
            requestAnimationFrame(() => {
                chatProfilePerfLog('avatarTap:postPush:rAF', { dt: Date.now() - tapTs });
            });
            setTimeout(() => { profileNavInFlightRef.current = false; }, 400);
            return;
        }

        if (activeChat?.chatId && effectiveChatType === 'group') {
            profileNavInFlightRef.current = true;
            chatProfilePerfLog('avatarTap:push:group-info', { chatId: activeChat.chatId, dt: Date.now() - tapTs });
            router.push({
                pathname: '/group-info',
                params: { groupId: activeChat.chatId }
            });
            requestAnimationFrame(() => {
                chatProfilePerfLog('avatarTap:postPush:rAF', { dt: Date.now() - tapTs });
            });
            setTimeout(() => { profileNavInFlightRef.current = false; }, 400);
            return;
        }

        if (!activeChat?.friendId) return;

        profileNavInFlightRef.current = true;
        chatProfilePerfLog('avatarTap:push:user-profile', {
            chatId: activeChat.chatId,
            friendId: activeChat.friendId,
            dt: Date.now() - tapTs,
        });
        router.push({
            pathname: '/user-profile',
            params: {
                userId: activeChat.friendId,
                chatId: activeChat.chatId,
                username: activeChat.friendName || displayName,
                profileImage: activeChat.friendImage || '',
                isOnline: headerIsOnline ? '1' : '0',
            }
        });
        requestAnimationFrame(() => {
            chatProfilePerfLog('avatarTap:postPush:rAF', { dt: Date.now() - tapTs });
        });
        setTimeout(() => {
            chatProfilePerfLog('avatarTap:postPush:timeout16', { dt: Date.now() - tapTs });
        }, 16);
        setTimeout(() => { profileNavInFlightRef.current = false; }, 400);
    }, [activeChat, effectiveChatType, router, displayName, headerIsOnline]);

    useEffect(() => {
        let cancelled = false;
        if (!isDirectChat) {
            setFriendApiPresence(null);
            return;
        }
        const friendId = activeChat?.friendId;
        if (!friendId) {
            setFriendApiPresence(null);
            return;
        }

        (async () => {
            try {
                const { apiClient } = await import('../src/lib/api-client');
                const user = await apiClient.getUser(friendId);
                if (cancelled) return;
                setFriendApiPresence({
                    online: typeof user?.online === 'boolean' ? user.online : undefined,
                    lastSeenMs: parseTimestampMs(user?.lastSeen ?? user?.last_seen),
                });
            } catch {
                if (!cancelled) {
                    setFriendApiPresence(null);
                }
            }
        })();

        return () => {
            cancelled = true;
        };
    }, [activeChat?.friendId, isDirectChat]);

    const subtitle = useMemo(() => {
        if (effectiveChatType === 'channel') {
            const memberCount = Number(activeChat?.memberCount || 0);
            return memberCount > 0 ? `${memberCount} subscribers` : 'Channel';
        }
        if (effectiveChatType === 'group') {
            const memberCount = Number(activeChat?.memberCount || 0);
            return memberCount > 0 ? `${memberCount} members` : 'Group';
        }
        if (isResolvingRouteChat && friendIdFromParams) return 'Opening chat...';
        if (!effectiveChatId) return 'No chat selected';
        if (isFriendTyping) return 'typing...';
        const isFriendOnline =
            (!!friendIdUpper && onlineUsers.has(friendIdUpper)) ||
            friendApiPresence?.online === true;
        if (isFriendOnline) return 'online';
        const lastSeenMs = pickLatestTimestamp(friendApiPresence?.lastSeenMs, fallbackLastSeenMs);
        return formatLastSeen(lastSeenMs);
    }, [effectiveChatType, activeChat?.memberCount, isResolvingRouteChat, friendIdFromParams, effectiveChatId, friendApiPresence?.lastSeenMs, friendApiPresence?.online, fallbackLastSeenMs, friendIdUpper, isFriendTyping, onlineUsers]);

    const resolvedTheme = useMemo(() => {
        const theme = resolveThemeVariant(activeTheme, effectiveTheme === 'dark');
        if (!theme.backgroundGradient) {
            return {
                ...theme,
                backgroundGradient: [colors.background, colors.background],
            };
        }
        return theme;
    }, [activeTheme, colors.background, effectiveTheme]);

    const bubbleTheme = useMemo(() => ({
        meGradient: (
            resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
                ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
                : [resolvedTheme.bubbleMe, resolvedTheme.bubbleMe]
        ) as [string, string],
    }), [resolvedTheme]);

    const handleTypingStatusChange = useCallback((isTyping: boolean) => {
        if (!effectiveChatId) return;
        if (isTyping) sendTyping(effectiveChatId);
        else sendStopTyping(effectiveChatId);
    }, [effectiveChatId, sendTyping, sendStopTyping]);

    const handleReplySwipeHaptic = useCallback(() => {
        haptics.selection();
    }, []);

    const typingInlineIndicator = useMemo(() => {
        if (!isFriendTyping) return null;

        const typingBaseColor = effectiveTheme === 'dark'
            ? withAlpha(colors.text, 0.4)
            : withAlpha(colors.text, 0.3);
        const typingSweepColor = effectiveTheme === 'dark'
            ? withAlpha(colors.text, 0.8)
            : withAlpha(colors.text, 0.7);

        return (
            <View pointerEvents="none" style={styles.typingInlineRow}>
                <TypingShimmer
                    baseColor={typingBaseColor}
                    sweepColor={typingSweepColor}
                    shimmerX={typingShimmerX}
                />
            </View>
        );
    }, [isFriendTyping, effectiveTheme, colors.text]);

    const handleVideoNoteStart = useCallback(() => {
        videoNoteCanceledRef.current = false;
        setVideoNoteVisible(true);
    }, []);

    const handleVideoNoteStop = useCallback((canceled: boolean) => {
        videoNoteCanceledRef.current = canceled;
        setVideoNoteVisible(false);
    }, []);

    const handleVideoRecorded = useCallback((file?: { uri?: string; duration?: number } | null) => {
        if (videoNoteCanceledRef.current) return;
        if (!file?.uri) return;
        setIncomingVideoNote({
            uri: file.uri,
            duration: file.duration,
            token: Date.now(),
        });
    }, []);

    const handleStartCall = useCallback(async (type: 'voice' | 'video') => {
        console.log('[ChatScreen] handleStartCall invoked', {
            type,
            hasActiveChat: !!activeChat,
            friendId: activeChat?.friendId,
            selfUserId: user?.userId,
            callStatus,
            isConnected,
        });
        if (!activeChat || !activeChat.friendId) {
            console.warn('[ChatScreen] handleStartCall aborted: missing activeChat/friendId', { type });
            return;
        }
        const userId = activeChat.friendId;
        if ((user?.userId || '').toUpperCase() === userId.toUpperCase()) {
            // Can't call yourself
            console.warn('[ChatScreen] handleStartCall aborted: attempted self-call', { type, userId });
            return;
        }
        if (callStatus !== 'idle') {
            // Call in progress
            console.warn('[ChatScreen] handleStartCall aborted: call not idle', { type, callStatus });
            return;
        }

        const available = await checkWebRTCAvailability();
        console.log('[ChatScreen] checkWebRTCAvailability result', { type, available });
        if (!available) {
            console.warn('[ChatScreen] handleStartCall aborted: WebRTC unavailable', { type });
            return;
        }

        if (!isConnected) {
            console.log('[ChatScreen] initSocket requested before call', { type });
            initSocket();
        }

        const channel = await waitForUserChannel();
        console.log('[ChatScreen] waitForUserChannel result', {
            type,
            hasChannel: !!channel,
            canPush: !!channel && typeof channel.push === 'function',
        });
        if (!channel) {
            console.warn('[ChatScreen] handleStartCall aborted: no signaling channel', { type });
            return;
        }

        const started = await startCall(
            {
                userId,
                userName: activeChat.friendName || displayName,
                userImage: activeChat.friendImage,
            },
            type,
            channel,
        );
        console.log('[ChatScreen] startCall completed', { type, started });
    }, [
        activeChat,
        user?.userId,
        callStatus,
        checkWebRTCAvailability,
        isConnected,
        initSocket,
        startCall,
        displayName
    ]);

    const handleAudioCall = useCallback(() => {
        console.log('[ChatScreen] handleAudioCall pressed');
        void handleStartCall('voice');
    }, [handleStartCall]);

    const handleVideoCall = useCallback(() => {
        console.log('[ChatScreen] handleVideoCall pressed');
        void handleStartCall('video');
    }, [handleStartCall]);

    const headerShiftStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: withTiming(chatSearchOpen ? -(insets.top + 86) : 0, { duration: 230 }) }],
    }), [chatSearchOpen, insets.top]);
    const searchShiftStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: withTiming(chatSearchOpen ? 0 : -(insets.top + 72), { duration: 230 }) }],
    }), [chatSearchOpen, insets.top]);
    const nativeOwnsWallpaper = nativeChatRuntime.enabled && chatSearchQuery.trim().length === 0;

    return (
        <View style={styles.screen}>
            {!nativeOwnsWallpaper && (
                <WallpaperBackground
                    key={Platform.OS === 'android' ? `wallpaper-${androidWallpaperRefreshKey}` : undefined}
                    theme={resolvedTheme}
                />
            )}

            <Animated.View
                pointerEvents={chatSearchOpen ? 'none' : 'auto'}
                style={[
                    styles.chatHeaderWrap,
                    headerShiftStyle,
                ]}
            >
                <ChatScreenHeader
                    title={displayName}
                    subtitle={subtitle}
                    isOnline={headerIsOnline}
                    avatarUri={activeChat?.friendImage || undefined}
                    colors={colors}
                    effectiveTheme={effectiveTheme as 'light' | 'dark'}
                    wallpaperGradient={resolvedTheme.backgroundGradient || [colors.background, colors.background]}
                    bubbleTheme={bubbleTheme}
                    onPressAvatar={handlePressAvatar}
                    onAudioCall={handleAudioCall}
                    onVideoCall={handleVideoCall}
                />
            </Animated.View>

            <Animated.View
                pointerEvents={chatSearchOpen ? 'auto' : 'none'}
                style={[
                    styles.searchOverlay,
                    {
                        top: insets.top + 6,
                    },
                    searchShiftStyle,
                ]}
            >
                <SafeLiquidGlass
                    style={styles.searchGlass}
                    blurIntensity={24}
                    tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                >
                    <View style={[styles.searchInner, { backgroundColor: withAlpha(colors.card, effectiveTheme === 'dark' ? 0.42 : 0.66) }]}>
                        <Search size={16} color={withAlpha(colors.text, 0.62)} />
                        <TextInput
                            ref={searchInputRef}
                            value={chatSearchQuery}
                            onChangeText={setChatSearchQuery}
                            placeholder="Search in chat"
                            placeholderTextColor={withAlpha(colors.text, 0.45)}
                            style={[styles.searchInput, { color: colors.text }]}
                        />
                        <TouchableOpacity
                            onPress={() => {
                                setChatSearchOpen(false);
                            }}
                            style={styles.searchCloseButton}
                        >
                            <X size={16} color={withAlpha(colors.text, 0.72)} />
                        </TouchableOpacity>
                    </View>
                </SafeLiquidGlass>
            </Animated.View>

            <View style={styles.listContainer}>
                <ChatListScreen
                    onTypingStatusChange={handleTypingStatusChange}
                    onReplySwipeHaptic={handleReplySwipeHaptic}
                    ListHeaderComponent={typingInlineIndicator}
                    searchQuery={chatSearchQuery}
                    topContentOffset={chatSearchOpen ? 58 : 0}
                    onVideoNoteStart={handleVideoNoteStart}
                    onVideoNoteStop={handleVideoNoteStop}
                    incomingVideoNote={incomingVideoNote}
                    onIncomingVideoNoteConsumed={() => setIncomingVideoNote(null)}
                />
            </View>

            <VideoNoteOverlay
                visible={videoNoteVisible}
                onVideoRecorded={handleVideoRecorded}
            />
        </View>
    );
}

const styles = StyleSheet.create({
    screen: {
        flex: 1,
        backgroundColor: '#000',
    },
    chatHeaderWrap: {
        zIndex: 130,
    },
    listContainer: {
        flex: 1,
    },
    searchOverlay: {
        position: 'absolute',
        left: 14,
        right: 14,
        zIndex: 140,
    },
    searchGlass: {
        borderRadius: 10,
        overflow: 'hidden',
    },
    searchInner: {
        height: 40,
        borderRadius: 10,
        paddingHorizontal: 12,
        flexDirection: 'row',
        alignItems: 'center',
        gap: 8,
    },
    searchInput: {
        flex: 1,
        fontSize: 15,
        fontWeight: '500',
        paddingVertical: 0,
    },
    searchCloseButton: {
        width: 28,
        height: 28,
        borderRadius: 14,
        alignItems: 'center',
        justifyContent: 'center',
    },
    typingInlineRow: {
        width: '100%',
        alignItems: 'flex-start',
        paddingLeft: 14,
        marginTop: 0,
        marginBottom: 8,
    },
    typingMask: {
        width: TYPING_MASK_WIDTH,
        height: 16,
    },
    typingMaskInner: {
        flex: 1,
        justifyContent: 'center',
    },
    typingTextMask: {
        fontSize: 13,
        fontWeight: '600',
        letterSpacing: 0.2,
        color: '#000',
    },
    typingShimmerBand: {
        position: 'absolute',
        top: 0,
        bottom: 0,
        left: TYPING_SHIMMER_START,
        width: TYPING_SHIMMER_BAND_WIDTH,
    },
    typingShimmerBandFill: {
        flex: 1,
    },
});
