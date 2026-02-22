import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Alert, View, ActivityIndicator, StyleSheet } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';

import UserProfile from '../src/components/chat/UserProfile';
import { useAuthStore } from '../src/lib/stores/auth-store';
import { getUserChannel, useChatStore } from '../src/lib/ChatStore';
import { apiClient } from '../src/lib/api-client';
import { useCallStore } from '../src/lib/stores/CallStore';
import type { Message } from '../src/lib/types';
import type { UserTier } from '../src/lib/stores/subscription-store';
import { useThemeStore } from '../src/lib/stores/theme-store';
import type {
    UserProfileMediaItem,
    UserProfileFileItem,
    UserProfileLinkItem,
    UserProfilePinnedItem,
} from '../src/components/chat/UserProfile';

const isValidTier = (value: unknown): value is UserTier => (
    value === 'free' ||
    value === 'bronze' ||
    value === 'silver' ||
    value === 'gold' ||
    value === 'admin' ||
    value === 'verified'
);

const toBool = (value: unknown): boolean | undefined => {
    if (typeof value === 'boolean') return value;
    if (typeof value !== 'string') return undefined;
    const v = value.trim().toLowerCase();
    if (v === '1' || v === 'true' || v === 'yes') return true;
    if (v === '0' || v === 'false' || v === 'no') return false;
    return undefined;
};

const waitForUserChannel = async (timeoutMs = 12000): Promise<any | null> => {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
        const channel = getUserChannel();
        const state = (channel as any)?.state;
        const ready =
            channel &&
            typeof channel.push === 'function' &&
            (state === 'joined' || state === 'joining' || !state);
        if (ready) return channel;
        await new Promise((resolve) => setTimeout(resolve, 120));
    }
    return null;
};

const toTimestamp = (value: unknown): number => {
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string') {
        const n = Number(value);
        if (Number.isFinite(n)) return n;
        const d = new Date(value).getTime();
        if (Number.isFinite(d)) return d;
    }
    return Date.now();
};

const toText = (m: Message): string => {
    return (m.plaintext || m.caption || '').toString();
};

const USER_PROFILE_PERF_LOG = __DEV__;
const userProfilePerfLog = (...args: any[]) => {
    if (!USER_PROFILE_PERF_LOG) return;
    console.log('[UserProfilePerf]', ...args);
};

type DerivedProfileContent = {
    mediaItems: UserProfileMediaItem[];
    videoItems: UserProfileMediaItem[];
    imageItems: UserProfileMediaItem[];
    fileItems: UserProfileFileItem[];
    linkItems: UserProfileLinkItem[];
};

const profileContentCache = new Map<string, { signature: string; data: DerivedProfileContent }>();
const pinnedItemsCache = new Map<string, { items: UserProfilePinnedItem[]; cachedAt: number }>();
const PINNED_CACHE_TTL_MS = 30_000;

const messageListSignature = (messages: Message[]): string => {
    const count = messages.length;
    if (count === 0) return '0';
    const first = messages[0];
    const last = messages[count - 1];
    return [
        count,
        first?.id || '',
        toTimestamp(first?.timestamp),
        last?.id || '',
        toTimestamp(last?.timestamp),
    ].join(':');
};

const deriveProfileContentFromMessages = (messages: Message[]): DerivedProfileContent => {
    const mediaItems: UserProfileMediaItem[] = [];
    const videoItems: UserProfileMediaItem[] = [];
    const imageItems: UserProfileMediaItem[] = [];
    const fileItems: UserProfileFileItem[] = [];

    // Messages in store are already timestamp-sorted in practice; iterate newest -> oldest
    // to avoid cloning/sorting full history on profile open.
    for (let i = messages.length - 1; i >= 0; i -= 1) {
        const m = messages[i];
        const type = (m.type || '').toLowerCase();
        const mediaUrl = typeof m.mediaUrl === 'string' ? m.mediaUrl : '';
        const timestamp = toTimestamp(m.timestamp);

        // Direct media only (no plaintext URL parsing)
        if (mediaUrl && (type === 'image' || type === 'video' || type === 'gif' || type === 'sticker')) {
            const item: UserProfileMediaItem = {
                id: m.id,
                type: m.type,
                mediaUrl,
                caption: toText(m),
                timestamp,
            };
            mediaItems.push(item);
            if (type === 'video') videoItems.push(item);
            else imageItems.push(item);
            continue;
        }

        // Music is included (playable via direct mediaUrl). Voice is excluded.
        if (type === 'file' || type === 'music') {
            fileItems.push({
                id: m.id,
                type: m.type,
                fileName: m.fileName || `${(m.type || 'FILE').toUpperCase()}-${m.id.slice(0, 6)}`,
                fileSize: m.fileSize,
                mediaUrl: mediaUrl || undefined,
                timestamp,
            });
        }
    }

    return {
        mediaItems,
        videoItems,
        imageItems,
        fileItems,
        linkItems: [],  // intentionally disabled: use direct media/file tabs only
    };
};

export default function UserProfileRoute() {
    const router = useRouter();
    const params = useLocalSearchParams();
    const { colors } = useThemeStore();
    const { user } = useAuthStore();
    const loadMessages = useChatStore((s) => s.loadMessages);
    const isConnected = useChatStore((s) => s.isConnected);
    const initSocket = useChatStore((s) => s.initSocket);
    const toggleMuteChat = useChatStore((s) => s.toggleMuteChat);
    const deleteChat = useChatStore((s) => s.deleteChat);
    const startCall = useCallStore((s) => s.startCall);
    const callStatus = useCallStore((s) => s.callStatus);
    const checkWebRTCAvailability = useCallStore((s) => s.checkWebRTCAvailability);

    const userId = typeof params.userId === 'string' ? params.userId : '';
    const chatIdParam = typeof params.chatId === 'string' ? params.chatId : '';
    const usernameParam = typeof params.username === 'string' ? params.username : '';
    const profileImageParam = typeof params.profileImage === 'string' ? params.profileImage : '';
    const isOnlineParam = toBool(params.isOnline);

    const chat = useChatStore((s) => {
        if (chatIdParam) {
            const byChatId = s.chats.find((entry) => entry.chatId === chatIdParam);
            if (byChatId) return byChatId;
        }
        if (!userId) return undefined;
        const targetId = userId.toUpperCase();
        return s.chats.find((entry) => (entry.friendId || '').toUpperCase() === targetId);
    });

    const [remoteProfile, setRemoteProfile] = useState<{
        username?: string;
        profileImage?: string | null;
        bio?: string;
        tier?: UserTier;
        online?: boolean;
    }>({});
    const [contentLoading, setContentLoading] = useState(false);
    const [mediaItems, setMediaItems] = useState<UserProfileMediaItem[]>([]);
    const [videoItems, setVideoItems] = useState<UserProfileMediaItem[]>([]);
    const [imageItems, setImageItems] = useState<UserProfileMediaItem[]>([]);
    const [fileItems, setFileItems] = useState<UserProfileFileItem[]>([]);
    const [linkItems, setLinkItems] = useState<UserProfileLinkItem[]>([]);
    const [pinnedItems, setPinnedItems] = useState<UserProfilePinnedItem[]>([]);

    useEffect(() => {
        let cancelled = false;
        if (!userId) return;
        (async () => {
            try {
                const payload = await apiClient.getUser(userId);
                if (!payload || cancelled) return;
                const resolvedTier = isValidTier(payload?.tier) ? payload.tier : undefined;
                setRemoteProfile({
                    username: payload?.username || payload?.name,
                    profileImage: payload?.profileImage || payload?.profile_image || null,
                    bio: payload?.bio,
                    tier: resolvedTier,
                    online: typeof payload?.online === 'boolean' ? payload.online : undefined,
                });
            } catch {
                // Keep route resilient with fallback params/chat data.
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [userId]);

    const displayUsername = remoteProfile.username || usernameParam || chat?.friendName || 'User';
    const displayImage = remoteProfile.profileImage ?? (profileImageParam || chat?.friendImage || null);
    const displayBio = remoteProfile.bio;
    const displayTier = remoteProfile.tier;
    const displayOnline = remoteProfile.online ?? isOnlineParam ?? false;
    const resolvedChatId = chat?.chatId || chatIdParam;
    const isMuted = !!chat?.muted;
    const localMessageCount = Array.isArray(chat?.messages) ? chat!.messages.length : 0;

    useEffect(() => {
        let cancelled = false;

        const run = async () => {
            const startedAt = Date.now();
            if (!resolvedChatId) {
                setMediaItems([]);
                setVideoItems([]);
                setImageItems([]);
                setFileItems([]);
                setLinkItems([]);
                setPinnedItems([]);
                userProfilePerfLog('content:skip:no-chat', { dt: Date.now() - startedAt });
                return;
            }

            setContentLoading(true);
            try {
                // Use existing local messages immediately so profile screen mounts fast.
                // Only refetch if we have no local history yet.
                if (localMessageCount === 0) {
                    userProfilePerfLog('content:loadMessages:start', { chatId: resolvedChatId });
                    try {
                        await loadMessages(resolvedChatId);
                    } catch {
                        // Continue with whatever local messages are currently available.
                    }
                    userProfilePerfLog('content:loadMessages:done', {
                        chatId: resolvedChatId,
                        dt: Date.now() - startedAt,
                    });
                } else {
                    userProfilePerfLog('content:use-local-cache-first', {
                        chatId: resolvedChatId,
                        localMessageCount,
                    });
                }

                const latestChat = useChatStore.getState().chats.find((c) => c.chatId === resolvedChatId);
                const sourceMessages = latestChat?.messages || [];
                const deriveStart = Date.now();
                const signature = messageListSignature(sourceMessages);
                const cachedDerived = profileContentCache.get(resolvedChatId);
                const derived = cachedDerived?.signature === signature
                    ? cachedDerived.data
                    : deriveProfileContentFromMessages(sourceMessages);
                if (cachedDerived?.signature !== signature) {
                    profileContentCache.set(resolvedChatId, {
                        signature,
                        data: derived,
                    });
                }
                userProfilePerfLog('content:messages:derived', {
                    chatId: resolvedChatId,
                    sourceCount: sourceMessages.length,
                    cacheHit: cachedDerived?.signature === signature,
                    dt: Date.now() - deriveStart,
                    totalDt: Date.now() - startedAt,
                });
                if (cancelled) return;
                setMediaItems(derived.mediaItems);
                setVideoItems(derived.videoItems);
                setImageItems(derived.imageItems);
                setFileItems(derived.fileItems);
                setLinkItems(derived.linkItems);

                let pinned: UserProfilePinnedItem[] = [];
                try {
                    const pinnedCached = pinnedItemsCache.get(resolvedChatId);
                    const now = Date.now();
                    if (pinnedCached && (now - pinnedCached.cachedAt) < PINNED_CACHE_TTL_MS) {
                        pinned = pinnedCached.items;
                        userProfilePerfLog('content:pinned:cache-hit', {
                            chatId: resolvedChatId,
                            count: pinned.length,
                            totalDt: Date.now() - startedAt,
                        });
                    } else {
                        const pinnedStart = Date.now();
                        const pinnedResp = await apiClient.getPinnedMessages(resolvedChatId);
                        const rawList = Array.isArray(pinnedResp)
                            ? pinnedResp
                            : Array.isArray((pinnedResp as any)?.data)
                                ? (pinnedResp as any).data
                                : Array.isArray((pinnedResp as any)?.messages)
                                    ? (pinnedResp as any).messages
                                    : [];

                        pinned = rawList.map((item: any) => ({
                            id: item?.id || item?.messageId || item?.message_id || `${Math.random()}`,
                            type: item?.type || 'text',
                            text: item?.plaintext || item?.content || item?.text || item?.fileName || item?.file_name || '',
                            timestamp: toTimestamp(item?.timestamp || item?.createdAt || item?.created_at),
                        }));
                        pinnedItemsCache.set(resolvedChatId, { items: pinned, cachedAt: now });
                        userProfilePerfLog('content:pinned:loaded', {
                            chatId: resolvedChatId,
                            count: pinned.length,
                            dt: Date.now() - pinnedStart,
                            totalDt: Date.now() - startedAt,
                        });
                    }
                } catch {
                    pinned = [];
                }

                if (cancelled) return;
                setPinnedItems(pinned);
                userProfilePerfLog('content:apply:done', {
                    chatId: resolvedChatId,
                    media: derived.mediaItems.length,
                    videos: derived.videoItems.length,
                    images: derived.imageItems.length,
                    files: derived.fileItems.length,
                    links: derived.linkItems.length,
                    pinned: pinned.length,
                    totalDt: Date.now() - startedAt,
                });
            } finally {
                if (!cancelled) setContentLoading(false);
            }
        };

        void run();
        return () => {
            cancelled = true;
        };
    }, [resolvedChatId, loadMessages, localMessageCount]);

    const handleToggleMute = useCallback(() => {
        if (!resolvedChatId) return;
        toggleMuteChat(resolvedChatId);
    }, [resolvedChatId, toggleMuteChat]);

    const handleClearChat = useCallback(() => {
        if (!resolvedChatId) return;
        Alert.alert(
            'Delete chat',
            'This removes the chat from your list.',
            [
                { text: 'Cancel', style: 'cancel' },
                {
                    text: 'Delete',
                    style: 'destructive',
                    onPress: () => {
                        deleteChat(resolvedChatId);
                        router.back();
                    },
                },
            ],
        );
    }, [resolvedChatId, deleteChat, router]);

    const handleBlock = useCallback(async () => {
        if (!user?.userId || !userId) return;
        try {
            await apiClient.blockUser(user.userId, userId);
            Alert.alert('Blocked', `${displayUsername} has been blocked.`);
            router.back();
        } catch {
            Alert.alert('Error', 'Failed to block this user.');
        }
    }, [user?.userId, userId, displayUsername, router]);

    const handleStartCall = useCallback(async (type: 'voice' | 'video') => {
        if (!userId) return;
        if ((user?.userId || '').toUpperCase() === userId.toUpperCase()) {
            Alert.alert('Call unavailable', 'You cannot call yourself.');
            return;
        }
        if (callStatus !== 'idle') {
            Alert.alert('Call in progress', 'Finish the current call first.');
            return;
        }

        const available = await checkWebRTCAvailability();
        if (!available) {
            Alert.alert('Call unavailable', 'WebRTC is not available on this build/device.');
            return;
        }

        if (!isConnected) {
            initSocket();
        }

        const channel = await waitForUserChannel();
        if (!channel) {
            Alert.alert('Call unavailable', 'Could not connect to call signaling. Please try again.');
            return;
        }

        const ok = await startCall(
            {
                userId,
                userName: displayUsername,
                userImage: displayImage || undefined,
            },
            type,
            channel,
        );

        if (!ok) {
            Alert.alert('Call failed', `Could not start ${type} call. Please try again.`);
        }
    }, [
        userId,
        user?.userId,
        callStatus,
        checkWebRTCAvailability,
        isConnected,
        initSocket,
        startCall,
        displayUsername,
        displayImage,
    ]);

    if (!userId) {
        return (
            <View style={[styles.fallback, { backgroundColor: colors.background }]}>
                <ActivityIndicator size="small" color={colors.text} />
            </View>
        );
    }

    return (
        <UserProfile
            visible
            onClose={() => router.back()}
            username={displayUsername}
            userId={userId}
            chatId={resolvedChatId || undefined}
            profileImage={displayImage}
            tier={displayTier}
            bio={displayBio}
            isOnline={displayOnline}
            isMuted={isMuted}
            onToggleMute={handleToggleMute}
            onAudioCall={() => { void handleStartCall('voice'); }}
            onVideoCall={() => { void handleStartCall('video'); }}
            onClearChat={handleClearChat}
            onDeleteContact={resolvedChatId ? handleClearChat : undefined}
            onBlock={handleBlock}
            isContentLoading={contentLoading}
            mediaItems={mediaItems}
            videoItems={videoItems}
            imageItems={imageItems}
            fileItems={fileItems}
            linkItems={linkItems}
            pinnedItems={pinnedItems}
        />
    );
}

const styles = StyleSheet.create({
    fallback: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
});
