
import React, { useEffect, useState, useCallback, useRef, useMemo } from 'react'
import { View, Text, FlatList, TouchableOpacity, StyleSheet, Platform, Pressable, Image, ActivityIndicator, TextInput, RefreshControl, AppState, AppStateStatus, ScrollView, LayoutChangeEvent } from 'react-native'
import { useAuthStore } from '../../src/lib/stores/auth-store'
import { useThemeStore } from '../../src/lib/stores/theme-store'
import { resolveThemeVariant, useWallpaperStore } from '../../src/lib/stores/wallpaper-store'
import { useChatStore } from '../../src/lib/ChatStore'
import { useCallStore } from '../../src/lib/stores/CallStore'
import { useUIStore } from '../../src/lib/stores/ui-store'
import { Copy, Check, Pin, VolumeX, Trash2, Pencil, Settings, User, Search, CheckCircle, Smartphone, Plus, X, Shield, Bookmark, Archive } from 'lucide-react-native'
import { PlusCircleVibeIcon, AnimatedShieldIcon, EditChatVibeIcon, VibeLogoIcon, VibeAgentLogo } from '../../src/components/Icons'
import * as Clipboard from 'expo-clipboard'
import * as Haptics from 'expo-haptics'
import { useRouter, Stack } from 'expo-router'
import { useFocusEffect } from '@react-navigation/native'
import MaskedView from '@react-native-masked-view/masked-view'
import { LinearGradient } from 'expo-linear-gradient'
import LottieView from 'lottie-react-native'
import Swipeable from 'react-native-gesture-handler/Swipeable'
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass'
import { StoryBar, StoryViewer, StoryAvatar } from '../../src/components/story'
import { useStoryStore } from '../../src/lib/stores/story-store'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { BlurView } from 'expo-blur'
import { Animated as RNAnimated } from 'react-native'
import Animated, { cancelAnimation, useAnimatedStyle, useSharedValue, withTiming, withSpring, interpolate, Easing, withRepeat, withSequence, FadeIn, FadeOut, useAnimatedScrollHandler, useAnimatedReaction, Extrapolate, useDerivedValue, runOnJS, LinearTransition } from 'react-native-reanimated'
import MainMenuModal from '../../src/components/chat/MainMenuModal'
import ConnectionModal, { ConnectionModalRef } from '../../src/components/settings/ConnectionModal'
import ChatPreviewModal from '../../src/components/chat/ChatPreviewModal'
import { useSavedMessagesStore } from '../../src/lib/stores/saved-messages-store'
import NativeHomeListSurface, { isNativeHomeListAvailable, type NativeHomeListRow } from '../../src/native/home/NativeHomeListSurface'
import { getNativeChatEngineModule } from '../../src/native/chat'
import { mapMessagesToNativeRows, type RuntimeChatMessage } from '../../src/native/chat/mapper'
import { theme } from '../../src/lib/theme'


// Helper to add alpha to hex color
const withAlpha = (color: string, alpha: number): string => {
    'worklet';
    if (!color) return `rgba(127, 127, 127, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    if (color.startsWith('rgba')) {
        return color.replace(/[\d\.]+\)$/g, `${alpha})`)
    }
    return color
}

// Time ago helper
const timeAgo = (timestamp: number | string | Date): string => {
    const now = Date.now()
    const time = typeof timestamp === 'number' ? timestamp : new Date(timestamp).getTime()
    const diff = now - time
    const mins = Math.floor(diff / 60000)
    if (mins < 1) return 'now'
    if (mins < 60) return `${mins}m`
    const hours = Math.floor(mins / 60)
    if (hours < 24) return `${hours}h`
    const days = Math.floor(hours / 24)
    return `${days}d`
}

const formatDuration = (seconds: number) => {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}:${secs.toString().padStart(2, '0')}`;
};

const getMessageText = (msg: any): string => {
    if (!msg) return 'Start a conversation'
    if (typeof msg === 'string') return msg

    let text = msg._senderPlaintext ||
        msg.senderPlaintext ||
        msg.sender_plaintext ||
        msg.plaintext ||
        msg.content ||
        msg.text

    // If text is an object, try to extract string
    if (text && typeof text === 'object') {
        text = text.plaintext || text.content || text.text || ''
    }

    // If we found text, check if it's stringified JSON
    if (text && typeof text === 'string' && text.length > 0) {
        const trimmed = text.trim();
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
            try {
                const parsed = JSON.parse(text);
                const extracted = parsed.plaintext || parsed.content || parsed.text;
                if (extracted && typeof extracted === 'string') return extracted;

                // If parsed strictly as JSON but found no readable text content, 
                // treat it as empty so we fallback to media types
                text = '';
            } catch (e) {
                // Not JSON or parse failed, continue
            }
        }
    }

    // Check file messages first so previews don't show raw link/text blobs.
    if (msg.type === 'file') {
        const rawFileName = msg.fileName || msg.file_name
        if (typeof rawFileName === 'string' && rawFileName.trim().length > 0) {
            return rawFileName.trim()
        }
        const rawUrl = msg.mediaUrl || msg.media_url
        if (typeof rawUrl === 'string' && rawUrl.trim().length > 0) {
            const normalized = rawUrl.split('?')[0]
            const fromPath = normalized.split('/').pop()
            if (fromPath && fromPath.trim().length > 0) return fromPath.trim()
        }
        return 'Document'
    }

    // If we have text and it's not a JSON blob (or was successfully parsed above)
    if (text && typeof text === 'string' && text.length > 0) {
        if (text.includes('/uploads/agent-docs/')) return 'Document attached'
        return text
    }

    // Check if it's a media message
    if (msg.type === 'image') return 'Photo'
    if (msg.type === 'voice') return 'Voice message'
    if (msg.type === 'gif') return 'GIF'
    if (msg.type === 'sticker') return 'Sticker'
    if (msg.type === 'video') return 'Video'

    // If encrypted and not yet decrypted, show placeholder
    if (msg.encryptedContent && (!text || text === '')) {
        return 'Message'
    }

    return 'Message'
}

const getChatSortTimestamp = (chat: any): number => {
    if (!chat) return 0

    const updatedAt = chat.updatedAt ?? chat.updated_at
    if (typeof updatedAt === 'number') return updatedAt
    if (typeof updatedAt === 'string' || updatedAt instanceof Date) {
        const parsed = new Date(updatedAt).getTime()
        if (!Number.isNaN(parsed)) return parsed
    }

    const last = chat.lastMessage ?? chat.last_message
    const lastTs = last?.timestamp ?? last?.createdAt ?? last?.created_at ?? last?.time
    if (typeof lastTs === 'number') return lastTs
    if (typeof lastTs === 'string' || lastTs instanceof Date) {
        const parsed = new Date(lastTs).getTime()
        if (!Number.isNaN(parsed)) return parsed
    }

    return 0
}

const toTimestampMs = (value: unknown): number => {
    if (typeof value === 'number' && Number.isFinite(value)) return value
    if (typeof value === 'string' || value instanceof Date) {
        const parsed = new Date(value).getTime()
        return Number.isNaN(parsed) ? Date.now() : parsed
    }
    return Date.now()
}

const toFiniteNumber = (value: unknown): number | undefined => {
    if (typeof value === 'number' && Number.isFinite(value)) return value
    if (typeof value === 'string') {
        const parsed = Number(value)
        return Number.isFinite(parsed) ? parsed : undefined
    }
    return undefined
}

const extractNativeSavedMessages = (result: unknown): any[] => {
    if (!result || typeof result !== 'object') return []
    const payload = result as Record<string, unknown>
    if (Array.isArray(payload.messages)) return payload.messages as any[]
    if (Array.isArray(payload.data)) return payload.data as any[]
    return []
}

const getSavedMessageSortTimestamp = (message: any): number => {
    return toTimestampMs(
        message?.timestamp
        ?? message?.timestampMs
        ?? message?.createdAt
        ?? message?.created_at
        ?? message?.savedAt
    )
}

const normalizeChatType = (value: unknown): 'dm' | 'group' | 'channel' => {
    const raw = String(value || '').trim().toLowerCase()
    if (raw === 'group') return 'group'
    if (raw === 'channel') return 'channel'
    return 'dm'
}

interface HomeScreenProps {
    onChatSelect?: (chatId: string) => void;
    onOpenStoryCamera?: () => void;
}

type PendingHomeActionKind = 'delete' | 'clear';

interface PendingHomeAction {
    id: string;
    kind: PendingHomeActionKind;
    chatId: string;
    chatName: string;
    expiresAt: number;
}

const SEARCH_BAR_HEIGHT = 44;
const SEARCH_BAR_VERTICAL_PADDING = 14;
const SEARCH_BAR_BLOCK_HEIGHT = SEARCH_BAR_HEIGHT + (SEARCH_BAR_VERTICAL_PADDING * 2);
const HOME_UNDO_WINDOW_MS = 10_000;

// Swipeable Chat Row Component 
const ChatRowCard = React.memo(({ chat, colors, theme, onPress, onLongPress, onDelete, onPin, onMute, onMarkRead, isEditing, isSelected, isTyping, isOnline }: any) => {
    const shiftX = useSharedValue(0);
    const swipeableRef = useRef<any>(null);
    const rowRef = useRef<View>(null);
    const badgeScale = useSharedValue(1);
    const prevUnreadRef = useRef<number>(chat?.unreadCount ?? 0);

    useEffect(() => {
        shiftX.value = withTiming(isEditing ? 44 : 0, {
            duration: 250,
            easing: Easing.bezier(0.33, 1, 0.68, 1)
        });
    }, [isEditing]);

    useEffect(() => {
        const prev = prevUnreadRef.current ?? 0
        const next = chat?.unreadCount ?? 0
        if (next > prev) {
            badgeScale.value = withSequence(
                withSpring(1.12, { damping: 14, stiffness: 220 }),
                withSpring(1, { damping: 14, stiffness: 220 }),
            )
        }
        prevUnreadRef.current = next
    }, [chat?.unreadCount])

    const rStyle = useAnimatedStyle(() => {
        return {
            transform: [{ translateX: shiftX.value }]
        }
    });

    const renderRightActions = (_progress: any, dragX: any) => {
        if (isEditing) return null;
        const trans = dragX.interpolate({
            inputRange: [-222, 0],
            outputRange: [0, 222],
        });
        const contentOpacity = dragX.interpolate({
            inputRange: [-222, -96, -24, 0],
            outputRange: [1, 0.92, 0.18, 0],
            extrapolate: 'clamp',
        });
        const contentTranslate = dragX.interpolate({
            inputRange: [-222, -96, -24, 0],
            outputRange: [0, 8, 18, 26],
            extrapolate: 'clamp',
        });

        return (
            <RNAnimated.View style={{ width: 222, transform: [{ translateX: trans }] }}>
                <View style={styles.swipeActionRow}>
                    <TouchableOpacity onPress={() => { onMute(); swipeableRef.current?.close(); }} style={[styles.swipeAction, { backgroundColor: '#d68500' }]}>
                        <RNAnimated.View style={[styles.swipeActionContent, { opacity: contentOpacity, transform: [{ translateX: contentTranslate }] }]}>
                            <VolumeX color="white" size={22} />
                            <Text style={styles.swipeActionLabel}>{chat.muted ? 'Unmute' : 'Mute'}</Text>
                        </RNAnimated.View>
                    </TouchableOpacity>
                    <TouchableOpacity onPress={() => { onDelete(); swipeableRef.current?.close(); }} style={[styles.swipeAction, { backgroundColor: '#df1010' }]}>
                        <RNAnimated.View style={[styles.swipeActionContent, { opacity: contentOpacity, transform: [{ translateX: contentTranslate }] }]}>
                            <Trash2 color="white" size={22} />
                            <Text style={styles.swipeActionLabel}>Delete</Text>
                        </RNAnimated.View>
                    </TouchableOpacity>
                    <TouchableOpacity onPress={() => { onDelete(); swipeableRef.current?.close(); }} style={[styles.swipeAction, { backgroundColor: '#7c7c82' }]}>
                        <RNAnimated.View style={[styles.swipeActionContent, { opacity: contentOpacity, transform: [{ translateX: contentTranslate }] }]}>
                            <Archive color="white" size={22} />
                            <Text style={styles.swipeActionLabel}>Archive</Text>
                        </RNAnimated.View>
                    </TouchableOpacity>
                </View>
            </RNAnimated.View>
        );
    };

    const renderLeftActions = (_progress: any, dragX: any) => {
        if (isEditing) return null;
        const trans = dragX.interpolate({
            inputRange: [0, 148],
            outputRange: [-148, 0],
        });
        const contentOpacity = dragX.interpolate({
            inputRange: [0, 24, 96, 148],
            outputRange: [0, 0.18, 0.92, 1],
            extrapolate: 'clamp',
        });
        const contentTranslate = dragX.interpolate({
            inputRange: [0, 24, 96, 148],
            outputRange: [-26, -18, -8, 0],
            extrapolate: 'clamp',
        });
        return (
            <RNAnimated.View style={{ width: 148, transform: [{ translateX: trans }] }}>
                <View style={styles.swipeActionRow}>
                    <TouchableOpacity onPress={() => { onMarkRead(); swipeableRef.current?.close(); }} style={[styles.swipeAction, { backgroundColor: '#3b8fd2' }]}>
                        <RNAnimated.View style={[styles.swipeActionContent, { opacity: contentOpacity, transform: [{ translateX: contentTranslate }] }]}>
                            <CheckCircle color="white" size={22} />
                            <Text style={styles.swipeActionLabel}>{chat.markedUnread || chat.unreadCount > 0 ? 'Read' : 'Unread'}</Text>
                        </RNAnimated.View>
                    </TouchableOpacity>
                    <TouchableOpacity onPress={() => { onPin(); swipeableRef.current?.close(); }} style={[styles.swipeAction, { backgroundColor: '#3777e3' }]}>
                        <RNAnimated.View style={[styles.swipeActionContent, { opacity: contentOpacity, transform: [{ translateX: contentTranslate }] }]}>
                            <Pin color="white" size={22} fill="white" />
                            <Text style={styles.swipeActionLabel}>{chat.pinned ? 'Unpin' : 'Pin'}</Text>
                        </RNAnimated.View>
                    </TouchableOpacity>
                </View>
            </RNAnimated.View>
        )
    }

    const lastMsgTime = chat.lastMessage ? timeAgo(chat.lastMessage.timestamp || chat.updatedAt) : '';

    const shimmerX = useSharedValue(-80);

    useEffect(() => {
        cancelAnimation(shimmerX);
        if (isTyping) {
            shimmerX.value = -80;
            shimmerX.value = withRepeat(
                withTiming(260, { duration: 1600, easing: Easing.linear }),
                -1, false
            );
        } else {
            shimmerX.value = withTiming(-80, { duration: 150 })
        }
        return () => {
            cancelAnimation(shimmerX);
        };
    }, [isTyping, shimmerX]);

    const shimmerStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: shimmerX.value }]
    }));

    const circleStyle = useAnimatedStyle(() => ({
        opacity: interpolate(shiftX.value, [10, 40], [0, 1], Extrapolate.CLAMP),
        transform: [{ scale: interpolate(shiftX.value, [0, 44], [0.5, 1], Extrapolate.CLAMP) }]
    }));

    const badgeAnimatedStyle = useAnimatedStyle(() => ({
        transform: [{ scale: badgeScale.value }]
    }))

    return (
        <View style={{ marginVertical: 1 }}>
            <Animated.View
                style={[{
                    position: 'absolute',
                    left: 16,
                    top: 0,
                    bottom: 0,
                    justifyContent: 'center',
                    zIndex: isEditing ? 10 : -1,
                    width: 44
                }, circleStyle]}
            >
                <TouchableOpacity
                    activeOpacity={0.7}
                    onPress={() => isEditing && onPress()}
                    style={{ width: '100%', height: '100%', justifyContent: 'center' }}
                >
                    {isSelected ? (
                        <View style={{ width: 22, height: 22, borderRadius: 11, backgroundColor: colors.primary, alignItems: 'center', justifyContent: 'center' }}>
                            <Check size={14} color="#fff" />
                        </View>
                    ) : (
                        <View style={{ width: 22, height: 22, borderRadius: 11, borderWidth: 2, borderColor: withAlpha(colors.text, 0.3) }} />
                    )}
                </TouchableOpacity>
            </Animated.View>

            <Animated.View ref={rowRef} style={[{ flex: 1 }, rStyle]}>
                <Swipeable
                    ref={swipeableRef}
                    renderRightActions={renderRightActions}
                    renderLeftActions={renderLeftActions}
                    friction={2}
                    rightThreshold={40}
                    leftThreshold={40}
                    onSwipeableWillOpen={() => Haptics.selectionAsync()}
                    overshootLeft={false}
                    overshootRight={false}
                    containerStyle={{ overflow: 'hidden' }}
                    enabled={!isEditing}
                >
                    <Pressable
                        onPress={onPress}
                        onLongPress={(e) => {
                            if (isEditing) return;
                            rowRef.current?.measureInWindow((x: number, y: number, width: number, height: number) => {
                                onLongPress(chat, { x, y, width, height })
                            })
                        }}
                        delayLongPress={200}
                        style={({ pressed }) => [
                            styles.chatRowPressable,
                            {
                                backgroundColor: pressed ? withAlpha(colors.text, 0.05) : 'transparent',
                                borderBottomColor: withAlpha(colors.text, 0.03),
                                borderBottomWidth: 1,
                                alignItems: 'flex-start',
                                paddingTop: 14,
                                paddingBottom: 14
                            }
                        ]}
                    >
                        <View style={styles.avatarContainer}>
                            <SafeLiquidGlass
                                style={[styles.avatarGlass, { backgroundColor: withAlpha(colors.text, 0.12) }]}
                                blurIntensity={10}
                                tint={theme === 'dark' ? 'dark' : 'light'}
                            >
                                {chat.chatId === 'saved_messages' ? (
                                    <View style={[styles.avatarPlaceholder, { backgroundColor: colors.primary + '20' }]}>
                                        <Bookmark size={24} color={colors.primary} fill={colors.primary} />
                                    </View>
                                ) : chat.friendImage ? (
                                    <Image source={{ uri: chat.friendImage }} style={styles.avatarImage} />
                                ) : (
                                    <View style={styles.avatarPlaceholder}>
                                        <Text style={[styles.avatarText, { color: colors.text }]}>
                                            {(chat.friendName || chat.username || chat.friendId || 'U').substring(0, 1).toUpperCase()}
                                        </Text>
                                    </View>
                                )}
                            </SafeLiquidGlass>
                            {isOnline && chat.chatId !== 'saved_messages' && (
                                <View style={[
                                    styles.onlineIndicator,
                                    { backgroundColor: '#34d399', borderColor: colors.background }
                                ]} />
                            )}
                        </View>

                        <View style={[styles.chatRowContent, { justifyContent: 'flex-start', marginTop: 2 }]}>
                            <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                                <View style={{ flexDirection: 'row', alignItems: 'center', flex: 1 }}>
                                    {chat.type === 'channel' && (
                                        <View style={{ backgroundColor: colors.primary + '20', paddingHorizontal: 5, paddingVertical: 1, borderRadius: 4, marginRight: 6 }}>
                                            <Text style={{ color: colors.primary, fontSize: 9, fontWeight: '700' }}>CH</Text>
                                        </View>
                                    )}
                                    {chat.type === 'group' && (
                                        <View style={{ backgroundColor: colors.primary + '20', paddingHorizontal: 5, paddingVertical: 1, borderRadius: 4, marginRight: 6 }}>
                                            <Text style={{ color: colors.primary, fontSize: 9, fontWeight: '700' }}>GR</Text>
                                        </View>
                                    )}
                                    <Text style={[styles.chatNameText, { color: colors.text }]} numberOfLines={1}>
                                        {chat.chatId === 'saved_messages' ? 'Saved Messages' : (chat.name || chat.friendName || chat.friendId || 'Unknown')}
                                    </Text>
                                </View>
                                <Text style={{ fontSize: 13, color: colors.textSecondary, marginLeft: 8 }}>
                                    {lastMsgTime}
                                </Text>
                            </View>

                            <View style={{ flexDirection: 'row', alignItems: 'flex-start', marginTop: 4 }}>
                                <View style={{ flex: 1, height: 20, justifyContent: 'center' }}>
                                    {isTyping ? (
                                        <MaskedView
                                            style={{ height: 20 }}
                                            maskElement={
                                                <Text style={[styles.chatStatusText, { color: colors.textSecondary, fontWeight: '500' }]} numberOfLines={1}>
                                                    typing...
                                                </Text>
                                            }
                                        >
                                            <View style={{ flex: 1, backgroundColor: colors.textSecondary }}>
                                                <Animated.View style={[StyleSheet.absoluteFill, { width: 90 }, shimmerStyle]}>
                                                    <LinearGradient
                                                        colors={['transparent', withAlpha('#fff', 0.35), 'transparent']}
                                                        start={{ x: 0, y: 0 }}
                                                        end={{ x: 1, y: 0 }}
                                                        style={StyleSheet.absoluteFill}
                                                    />
                                                </Animated.View>
                                            </View>
                                        </MaskedView>
                                    ) : (
                                        <Text style={[styles.chatStatusText, { color: colors.textSecondary }]} numberOfLines={1}>
                                            {getMessageText(chat.lastMessage)}
                                        </Text>
                                    )}
                                </View>

                                <View style={{ alignItems: 'flex-end', marginLeft: 10 }}>
                                    {(chat.unreadCount > 0 || chat.markedUnread) && (
                                        <Animated.View layout={LinearTransition.duration(180)} style={[styles.unreadBadge, { backgroundColor: colors.text }, badgeAnimatedStyle]}>
                                            {chat.unreadCount > 0 && (
                                                <Text style={[styles.unreadText, { color: colors.background }]}>{chat.unreadCount}</Text>
                                            )}
                                        </Animated.View>
                                    )}
                                    <View style={[styles.iconRow, { marginTop: 4 }]}>
                                        {chat.muted && <VolumeX size={15} color={withAlpha(colors.text, 0.4)} strokeWidth={2} />}
                                        {chat.pinned && <Pin size={15} color={withAlpha(colors.text, 0.4)} fill={withAlpha(colors.text, 0.4)} style={{ transform: [{ rotate: '45deg' }] }} strokeWidth={2} />}
                                    </View>
                                </View>
                            </View>
                        </View>
                    </Pressable>
                </Swipeable>
            </Animated.View>
        </View >
    )
}, (prev, next) => {
    // Compare chat by ID and lastMessage to detect updates
    const sameChat = prev.chat.chatId === next.chat.chatId &&
        prev.chat.lastMessage?.id === next.chat.lastMessage?.id &&
        prev.chat.lastMessage?.timestamp === next.chat.lastMessage?.timestamp &&
        prev.chat.unreadCount === next.chat.unreadCount &&
        prev.chat.markedUnread === next.chat.markedUnread &&
        prev.chat.updatedAt === next.chat.updatedAt &&
        prev.colors === next.colors &&
        prev.theme === next.theme;
    return sameChat &&
        prev.isEditing === next.isEditing &&
        prev.isSelected === next.isSelected &&
        prev.isTyping === next.isTyping &&
        prev.isOnline === next.isOnline &&
        prev.chat.pinned === next.chat.pinned &&
        prev.chat.muted === next.chat.muted;
})

const withLog = (data: any, label: string) => {
    // Helper to debug rendering
    return data;
};

const PulseBar = ({ delay }: { delay: number }) => {
    const height = useSharedValue(4);

    useEffect(() => {
        height.value = withRepeat(
            withSequence(
                withTiming(12, { duration: 400 + delay, easing: Easing.inOut(Easing.sin) }),
                withTiming(4, { duration: 400 + delay, easing: Easing.inOut(Easing.sin) })
            ),
            -1,
            true
        );
    }, []);

    const style = useAnimatedStyle(() => ({
        height: height.value,
        width: 3,
        backgroundColor: '#fff',
        borderRadius: 1.5,
        opacity: interpolate(height.value, [4, 12], [0.5, 1]),
    }));

    return <Animated.View style={style} />;
};

export default function HomeScreen({ onChatSelect, onOpenStoryCamera }: HomeScreenProps) {
    const { user } = useAuthStore()
    const { colors, effectiveTheme } = useThemeStore()
    const activeWallpaperTheme = useWallpaperStore((s) => s.activeTheme)
    const { setActiveChat, chats, isLoading, loadChats, deleteChat, clearChat, pinChat, toggleMuteChat, toggleMarkUnread, typingUsers, onlineUsers, isConnected } = useChatStore()
    const { savedMessages, sync: syncSavedMessages } = useSavedMessagesStore()
    const { callStatus, remoteUser, callDuration, callType } = useCallStore()
    const { feed, myStories } = useStoryStore()
    const onlineUsersList = onlineUsers ? Array.from(onlineUsers) : [];
    const nativeEngineModule = useMemo(() => getNativeChatEngineModule(), [])
    const nativeSavedMessagesEnabled = !!nativeEngineModule?.fetchSavedMessages
    const [nativeSavedMessages, setNativeSavedMessages] = useState<any[]>([])
    const [usesNativeSavedMessagesPreview, setUsesNativeSavedMessagesPreview] = useState(false)
    const [savedMessagesPreviewLoaded, setSavedMessagesPreviewLoaded] = useState(false)



    const insets = useSafeAreaInsets()
    const [copied, setCopied] = useState(false)
    const router = useRouter()
    const [isEditing, setIsEditing] = useState(false)
    const setHomeEditing = useUIStore(s => s.setHomeEditing)
    const setHomeEditSelectionCount = useUIStore(s => s.setHomeEditSelectionCount)
    const homeEditAction = useUIStore(s => s.homeEditAction)
    const homeEditActionRequestId = useUIStore(s => s.homeEditActionRequestId)
    const safePress = useCallback((label: string, action: () => void | Promise<void>) => {
        try {
            // console.log(`[HomeScreen] press:${label}`)
            const maybePromise = action()
            if (maybePromise && typeof (maybePromise as Promise<void>).catch === 'function') {
                void (maybePromise as Promise<void>).catch((error) => {
                    console.error(`[HomeScreen] async press failed: ${label}`, error)
                })
            }
        } catch (error) {
            console.error(`[HomeScreen] press failed: ${label}`, error)
        }
    }, [])
    const lastHandledHomeEditActionIdRef = useRef(0)
    const [selectedConversations, setSelectedConversations] = useState(new Set<string>())
    const selectedConversationIds = useMemo(() => Array.from(selectedConversations), [selectedConversations])
    const [pendingHomeAction, setPendingHomeAction] = useState<PendingHomeAction | null>(null)
    const [pendingHomeActionClock, setPendingHomeActionClock] = useState(Date.now())
    const pendingHomeActionRef = useRef<PendingHomeAction | null>(null)

    // Sync editing state
    useEffect(() => {
        setHomeEditing(isEditing)
        setHomeEditSelectionCount(isEditing ? selectedConversationIds.length : 0)
    }, [isEditing, selectedConversationIds.length, setHomeEditing, setHomeEditSelectionCount])

    useEffect(() => {
        return () => {
            setHomeEditing(false)
            setHomeEditSelectionCount(0)
        }
    }, [setHomeEditing, setHomeEditSelectionCount])

    // Context Menu State
    const [contextMenuVisible, setContextMenuVisible] = useState(false);
    const [selectedChat, setSelectedChat] = useState<any>(null);
    const [chatLayout, setChatLayout] = useState({ x: 0, y: 0, width: 0, height: 0 });

    const [showMainMenu, setShowMainMenu] = useState(false);
    const connectionModalRef = useRef<ConnectionModalRef>(null);

    // Parent scale for modal effect
    const parentScale = useSharedValue(1);

    // Test Page State


    // Story state
    const [showAddStory, setShowAddStory] = useState(false);
    const [showStoryViewer, setShowStoryViewer] = useState(false);
    const [storyViewerUserId, setStoryViewerUserId] = useState<string | null>(null);
    const [storyViewerIndex, setStoryViewerIndex] = useState(0);

    const scrollY = useSharedValue(0);

    const onScroll = useAnimatedScrollHandler({
        onScroll: (event) => {
            scrollY.value = event.contentOffset.y;
        },
    });



    // Search Interaction
    const searchFocusProgress = useSharedValue(0);
    const scrollYAtStart = useSharedValue(0);
    const [isSearchActive, setIsSearchActive] = useState(false);
    const [searchQuery, setSearchQuery] = useState('');
    const searchInputRef = useRef<TextInput>(null);
    const [isPullRefreshing, setIsPullRefreshing] = useState(false)
    const hasStories = feed.length > 0 || myStories.length > 0
    const homeSavedMessages = useMemo(() => {
        const source = usesNativeSavedMessagesPreview ? nativeSavedMessages : savedMessages
        return [...source].sort((a, b) => getSavedMessageSortTimestamp(b) - getSavedMessageSortTimestamp(a))
    }, [nativeSavedMessages, savedMessages, usesNativeSavedMessagesPreview])
    const estimatedNativeHeaderHeight = useMemo(
        () => {
            if (chats.length === 0 && homeSavedMessages.length === 0) return 0;
            return SEARCH_BAR_BLOCK_HEIGHT + (hasStories ? 108 : 0);
        },
        [hasStories, chats.length, homeSavedMessages.length]
    )
    const nativeListTopOffset = insets.top + (Platform.OS === 'android' ? 64 : 50)
    const nativeHomeContentTopInset = nativeListTopOffset + estimatedNativeHeaderHeight

    const loadSavedMessagesPreview = useCallback(async () => {
        if (!user?.userId) {
            console.log('[home/savedPreview] no userId, clearing')
            setNativeSavedMessages([])
            setUsesNativeSavedMessagesPreview(false)
            setSavedMessagesPreviewLoaded(false)
            return
        }

        if (nativeSavedMessagesEnabled && nativeEngineModule?.fetchSavedMessages) {
            try {
                console.log('[home/savedPreview] fetching via native engine...')
                const result = await Promise.resolve(nativeEngineModule.fetchSavedMessages({ userId: user.userId }))
                const nextMessages = extractNativeSavedMessages(result)
                    .sort((a, b) => getSavedMessageSortTimestamp(b) - getSavedMessageSortTimestamp(a))
                console.log(`[home/savedPreview] native engine returned ${nextMessages.length} messages`)
                setNativeSavedMessages(nextMessages)
                setUsesNativeSavedMessagesPreview(true)
                setSavedMessagesPreviewLoaded(true)
                return
            } catch (error) {
                console.warn('[home/native-saved] fetchSavedMessages failed', error)
            }
        }

        try {
            console.log('[home/savedPreview] fetching via JS sync...')
            setUsesNativeSavedMessagesPreview(false)
            await Promise.resolve(syncSavedMessages())
        } catch (error) {
            console.warn('[home] sync saved messages failed', error)
        } finally {
            setSavedMessagesPreviewLoaded(true)
        }
    }, [nativeEngineModule, nativeSavedMessagesEnabled, syncSavedMessages, user?.userId])

    useFocusEffect(
        useCallback(() => {
            void loadSavedMessagesPreview()
        }, [loadSavedMessagesPreview])
    )


    const allChats = useMemo(() => {
        const pendingDeleteChatId = pendingHomeAction?.kind === 'delete' ? pendingHomeAction.chatId : null
        const pendingClearChatId = pendingHomeAction?.kind === 'clear' ? pendingHomeAction.chatId : null
        let list = chats.filter((chat: any) => {
            if (chat.chatId === 'saved_messages') return true;
            if (chat.type !== 'dm' && chat.type !== 'direct') return true;
            if (chat.lastMessage) return true;
            if (chat.messages && chat.messages.length > 0) return true;
            if (chat.unreadCount > 0 || chat.markedUnread) return true;
            if (chat.friendId && typingUsers.has(chat.friendId.toUpperCase())) return true;
            return false;
        });
        if (pendingDeleteChatId) {
            list = list.filter((chat: any) => chat.chatId !== pendingDeleteChatId)
        }
        if (homeSavedMessages.length > 0) {
            const lastMsg = homeSavedMessages[0] as any;
            const savedChat = {
                chatId: 'saved_messages',
                name: 'Saved Messages',
                lastMessage: lastMsg,
                updatedAt: lastMsg.timestamp ?? lastMsg.createdAt ?? lastMsg.created_at ?? Date.now(),
                unreadCount: 0,
                type: 'direct',
                friendId: user?.userId,
                friendName: 'Saved Messages',
                messages: []
            } as any;
            if (!list.find((c: any) => c.chatId === 'saved_messages')) {
                list.push(savedChat);
            }
        }
        const sorted = list
            .map((chat: any) => (
                chat.chatId === pendingClearChatId
                    ? {
                        ...chat,
                        messages: [],
                        lastMessage: undefined,
                        previewLastMessage: '',
                        unreadCount: 0,
                        markedUnread: false,
                    }
                    : chat
            ))
            .sort((a: any, b: any) => getChatSortTimestamp(b) - getChatSortTimestamp(a));
        console.log(`[home/allChats] chats=${chats.length} homeSaved=${homeSavedMessages.length} final=${sorted.length}`);
        return sorted;
    }, [chats, homeSavedMessages, pendingHomeAction, typingUsers, user?.userId]);

    const filteredChats = useMemo(() => {
        const q = searchQuery.trim().toLowerCase()
        if (!q) return allChats
        return allChats.filter((chat: any) => {
            const name = chat.chatId === 'saved_messages' ? 'Saved Messages' : (chat.name || chat.friendName || chat.friendId || 'Unknown');
            return name.toLowerCase().includes(q) ||
                getMessageText(chat.lastMessage).toLowerCase().includes(q)
        })
    }, [allChats, searchQuery])

    const chatsById = useMemo(() => {
        const index = new Map<string, any>()
        allChats.forEach((chat: any) => {
            if (chat?.chatId) index.set(chat.chatId, chat)
        })
        return index
    }, [allChats])

    const resolvedWallpaperTheme = useMemo(() => {
        const resolved = resolveThemeVariant(activeWallpaperTheme, effectiveTheme === 'dark')
        const bg = Array.isArray(resolved.backgroundGradient) ? resolved.backgroundGradient : []
        return {
            ...resolved,
            backgroundGradient: bg.length >= 2 ? bg : [colors.background, colors.background],
        }
    }, [activeWallpaperTheme, colors.background, effectiveTheme])

    const headerGlassTintColor = useMemo(() => {
        const baseColor = resolvedWallpaperTheme.backgroundGradient?.[0] || colors.background
        return withAlpha(baseColor, effectiveTheme === 'dark' ? 0.16 : 0.2)
    }, [colors.background, effectiveTheme, resolvedWallpaperTheme.backgroundGradient])

    const nativePreviewAppearance = useMemo(() => ({
        backgroundMode: 'gradient' as const,
        nativeThemeId: `chat-${effectiveTheme}`,
        nativeThemeIsDark: effectiveTheme === 'dark',
        avatarBackgroundColorDark: theme.dark.bg.input,
        avatarBackgroundColorLight: theme.light.bg.input,
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
    }), [colors.card, colors.text, colors.textSecondary, effectiveTheme, resolvedWallpaperTheme])

    const nativeHomeRows = useMemo<NativeHomeListRow[]>(() => {
        const useNativeEnginePresence = Platform.OS === 'ios' || Platform.OS === 'android'
        // When native engine is available, skip the expensive per-chat message
        // mapping for previewRows. The native ChatPreviewViewController fetches
        // its own rows from ChatEngine.getChatRows() which is much faster.
        const useNativePreview = useNativeEnginePresence
        return filteredChats.map((chat: any) => {
            const friendId = (chat.friendId || '').toUpperCase()
            const chatType = normalizeChatType(chat?.type)
            const isDirectChat = chatType === 'dm'
            const canShowPeerPresence =
                chat.chatId !== 'saved_messages'
                && isDirectChat
                && friendId.length > 0
            const title = chat.chatId === 'saved_messages'
                ? 'Saved Messages'
                : (chat.name || chat.friendName || chat.friendId || 'Unknown')
            const isTyping = !useNativeEnginePresence && canShowPeerPresence && typingUsers.has(friendId)
            const isOnline = !useNativeEnginePresence && canShowPeerPresence && onlineUsers.has(friendId)
            const preview = isTyping ? 'typing...' : getMessageText(chat.lastMessage)
            const lastMsgTime = chat.lastMessage ? timeAgo(chat.lastMessage.timestamp || chat.updatedAt) : ''

            // Skip expensive message→nativeRow mapping when native engine handles previews
            let previewRows: any[] | undefined
            if (!useNativePreview) {
                const sourceMessages: any[] = Array.isArray(chat?.messages) ? chat.messages : []
                const myUserIdUpper = (user?.userId || '').trim().toUpperCase()
                const runtimeMessages = sourceMessages
                    .map((message: any) => {
                        const messageId = typeof message?.id === 'string'
                            ? message.id
                            : (typeof message?.id === 'number' ? String(message.id) : '')
                        if (!messageId) return null
                        const fromId = typeof message?.fromId === 'string' ? message.fromId : undefined
                        const timestampMs = toTimestampMs(
                            message?.timestampMs ?? message?.timestamp ?? message?.createdAt ?? message?.created_at
                        )
                        const inferredIsMe = !!fromId && !!myUserIdUpper && fromId.trim().toUpperCase() === myUserIdUpper
                        return {
                            id: messageId,
                            chatId: chat.chatId,
                            fromId,
                            timestamp: typeof message?.timestamp === 'string' ? message.timestamp : undefined,
                            text: getMessageText(message),
                            type: typeof message?.type === 'string' ? message.type : 'text',
                            status: typeof message?.status === 'string' ? message.status : undefined,
                            mediaUrl: (
                                typeof message?.mediaUrl === 'string' ? message.mediaUrl :
                                    (typeof message?.media_url === 'string' ? message.media_url :
                                        (typeof message?.uri === 'string' ? message.uri : undefined))
                            ),
                            fileName: (
                                typeof message?.fileName === 'string' ? message.fileName :
                                    (typeof message?.file_name === 'string' ? message.file_name : undefined)
                            ),
                            duration: toFiniteNumber(message?.duration),
                            metadata: message?.extra && typeof message.extra === 'object' ? message.extra : undefined,
                            waveform: Array.isArray(message?.waveform)
                                ? message.waveform.filter((n: any) => typeof n === 'number' && Number.isFinite(n))
                                : undefined,
                            isVideoNote: message?.isVideoNote === true,
                            uploadProgress: toFiniteNumber(message?.uploadProgress ?? message?.upload_progress),
                            isMe: typeof message?.isMe === 'boolean' ? message.isMe : inferredIsMe,
                            timestampMs,
                            isEdited: message?.isEdited === true,
                            isPinned: message?.isPinned === true,
                            editedAt: toFiniteNumber(message?.editedAt ?? message?.edited_at),
                            replyToId: typeof message?.replyToId === 'string' ? message.replyToId : undefined,
                            reactionEmoji: typeof message?.reactionEmoji === 'string' ? message.reactionEmoji : undefined,
                            encryptedContent: typeof message?.encryptedContent === 'string' ? message.encryptedContent : undefined,
                        } as RuntimeChatMessage
                    })
                    .filter(Boolean) as RuntimeChatMessage[]
                runtimeMessages.sort((a, b) => a.timestampMs - b.timestampMs)
                previewRows = runtimeMessages.length > 0 ? mapMessagesToNativeRows(runtimeMessages) : undefined
            }

            return {
                chatId: chat.chatId,
                name: title,
                preview,
                friendId: isDirectChat ? (chat.friendId || undefined) : undefined,
                chatType,
                avatarUri: chat.avatarUrl || undefined,
                timeLabel: lastMsgTime,
                unreadCount: chat.unreadCount ?? 0,
                markedUnread: !!chat.markedUnread,
                muted: !!chat.muted,
                pinned: !!chat.pinned,
                isTyping,
                isOnline,
                avatarFallback: title.substring(0, 1).toUpperCase(),
                previewRows,
            }
        })
    }, [filteredChats, typingUsers, onlineUsers, user?.userId])

    const pendingHomeActionRemainingSeconds = useMemo(() => {
        if (!pendingHomeAction) return 0
        return Math.max(0, Math.ceil((pendingHomeAction.expiresAt - pendingHomeActionClock) / 1000))
    }, [pendingHomeAction, pendingHomeActionClock])

    const nativeHomeUndoBanner = useMemo(() => {
        if (!pendingHomeAction) return undefined
        const title = pendingHomeAction.kind === 'delete' ? 'Chat deleted' : 'Chat cleared'
        return {
            visible: true,
            title,
            body: pendingHomeAction.chatName,
            actionLabel: 'Undo',
            timerLabel: `${pendingHomeActionRemainingSeconds}s`,
            destructive: true,
        }
    }, [pendingHomeAction, pendingHomeActionRemainingSeconds])

    const handleSearchFocus = () => {
        setIsSearchActive(true);
        scrollYAtStart.value = scrollY.value;
        Haptics.selectionAsync();
        searchFocusProgress.value = withTiming(1, {
            duration: 350,
            easing: Easing.bezier(0.33, 1, 0.68, 1) // Premium decelerate
        });
        setTimeout(() => searchInputRef.current?.focus(), 50);
    };

    const handleSearchClose = () => {
        searchFocusProgress.value = withTiming(0, { duration: 250 }, () => {
            runOnJS(setIsSearchActive)(false);
        });
        searchInputRef.current?.blur();
    };

    const handleOpenStoryCamera = useCallback(() => {
        safePress('openStoryCamera', () => {
            if (isSearchActive) handleSearchClose();
            setContextMenuVisible(false);
            setShowMainMenu(false);
            if (onOpenStoryCamera) onOpenStoryCamera();
            else router.push('/story-camera');
        });
    }, [isSearchActive, handleSearchClose, onOpenStoryCamera, router, safePress]);

    const handleOpenStoryViewer = useCallback((userId: string, index: number = 0) => {
        setStoryViewerUserId(userId);
        setStoryViewerIndex(index);
        setShowStoryViewer(true);
    }, []);


    const headerTitleStyle = useAnimatedStyle(() => ({
        // Simply keep it fixed, no translation/fade
        opacity: 1,
    }));

    const listHeaderAnimatedStyle = useAnimatedStyle(() => ({
        // Spacer opacity
        opacity: 0,
    }));

    const androidHeaderAnimatedStyle = useAnimatedStyle(() => {
        const opacity = interpolate(scrollY.value, [0, 40], [0, 1], Extrapolate.CLAMP);
        const elevation = interpolate(scrollY.value, [0, 40], [0, 4], Extrapolate.CLAMP);
        return {
            opacity,
            elevation,
            shadowColor: '#000',
            shadowOffset: { width: 0, height: 2 },
            shadowOpacity: interpolate(scrollY.value, [0, 40], [0, 0.1], Extrapolate.CLAMP),
            shadowRadius: 2,
            borderBottomWidth: opacity > 0 ? StyleSheet.hairlineWidth : 0,
            borderBottomColor: withAlpha(colors.text, interpolate(scrollY.value, [0, 40], [0, 0.05], Extrapolate.CLAMP)),
        };
    });



    const searchOverlayStyle = useAnimatedStyle(() => ({
        opacity: searchFocusProgress.value,
    }));



    const searchBarStyle = useAnimatedStyle(() => {
        // Search bar collapse from scroll
        const scrollCollapse = interpolate(
            Math.max(0, scrollY.value),
            [0, SEARCH_BAR_BLOCK_HEIGHT],
            [0, SEARCH_BAR_BLOCK_HEIGHT],
            Extrapolate.CLAMP
        );
        // Search bar collapse from focus gesture
        const focusCollapse = interpolate(
            searchFocusProgress.value,
            [0, 1],
            [0, SEARCH_BAR_BLOCK_HEIGHT],
            Extrapolate.CLAMP
        );
        // Whichever is greater shrinks the bar
        const totalCollapse = Math.min(SEARCH_BAR_BLOCK_HEIGHT, Math.max(scrollCollapse, focusCollapse));
        const currentHeight = Math.max(0, SEARCH_BAR_BLOCK_HEIGHT - totalCollapse);
        const currentScaleY = currentHeight / SEARCH_BAR_BLOCK_HEIGHT;
        const currentPadStr = interpolate(currentHeight, [0, SEARCH_BAR_BLOCK_HEIGHT], [0, SEARCH_BAR_VERTICAL_PADDING], Extrapolate.CLAMP);

        return {
            height: currentHeight,
            paddingTop: currentPadStr,
            paddingBottom: currentPadStr,
            transform: [{ scaleY: currentScaleY }],
            opacity: 1,
            overflow: 'hidden',
        };
    });

    const searchInnerStyle = useAnimatedStyle(() => {
        const scrollCollapse = interpolate(
            Math.max(0, scrollY.value),
            [0, SEARCH_BAR_BLOCK_HEIGHT],
            [0, SEARCH_BAR_BLOCK_HEIGHT],
            Extrapolate.CLAMP
        );
        const focusCollapse = interpolate(
            searchFocusProgress.value,
            [0, 1],
            [0, SEARCH_BAR_BLOCK_HEIGHT],
            Extrapolate.CLAMP
        );
        const totalCollapse = Math.min(SEARCH_BAR_BLOCK_HEIGHT, Math.max(scrollCollapse, focusCollapse));

        return {
            opacity: interpolate(totalCollapse, [0, SEARCH_BAR_BLOCK_HEIGHT * 0.6], [1, 0], Extrapolate.CLAMP),
        };
    });

    const searchInputOverlayStyle = useAnimatedStyle(() => {
        // Capture initial position based on scroll when animation started
        const startY = insets.top + (feed.length > 0 || myStories.length > 0 ? 170 : 66) - scrollYAtStart.value;
        const targetY = insets.top + 8;

        // Physical expansion instead of opacity cross-fade
        const scaleY = interpolate(searchFocusProgress.value, [0, 1], [0, 1], Extrapolate.CLAMP);

        // We want to feel like we "lift" the bar from the list
        // and move it to the fixed header position.
        return {
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            transform: [
                { translateY: interpolate(searchFocusProgress.value, [0, 1], [startY, targetY], Extrapolate.CLAMP) },
                { scaleY }
            ],
            height: SEARCH_BAR_BLOCK_HEIGHT,
            paddingTop: SEARCH_BAR_VERTICAL_PADDING,
            paddingBottom: SEARCH_BAR_VERTICAL_PADDING,
            opacity: 1,
            paddingHorizontal: interpolate(searchFocusProgress.value, [0, 1], [16, 20], Extrapolate.CLAMP),
            zIndex: 4000,
        };
    });

    const cancelBtnStyle = useAnimatedStyle(() => ({
        opacity: 1,
        transform: [{ scale: interpolate(searchFocusProgress.value, [0.7, 1], [0, 1], Extrapolate.CLAMP) }],
        width: interpolate(searchFocusProgress.value, [0.7, 1], [0, 32], Extrapolate.CLAMP),
    }));

    const nativeHeaderScrollStyle = useAnimatedStyle(() => {
        // Only translate the header out of view AFTER the search bar has fully collapsed.
        const headerCollapseOffset = Math.max(0, scrollY.value - SEARCH_BAR_BLOCK_HEIGHT);
        // Max translation shouldn't exceed the StoryBar height (which is nativeHeaderHeight - SEARCH_BAR_BLOCK_HEIGHT)
        const maxTranslation = Math.max(0, estimatedNativeHeaderHeight - SEARCH_BAR_BLOCK_HEIGHT);
        const translateShift = Math.min(headerCollapseOffset, maxTranslation);

        return {
            transform: [{ translateY: -translateShift }],
        }
    }, [estimatedNativeHeaderHeight])

    const showEditButton = true

    // Initial load & Socket Sync
    useEffect(() => {
        if (user?.userId) {
            if (chats.length === 0 && !isLoading) {
                loadChats()
            }
            // Ensure socket is connected (Fix for Auth -> Socket gap)
            const state = useChatStore.getState();
            if (!state.isConnected) {
                // preventing duplicates is handled inside initSocket via socketInitialized flag.
                // Do NOT call disconnect() here as it resets that flag and causes loops.
                state.initSocket();
            }
        }
    }, [user?.userId])

    // Retry loadChats when socket connects and we still have no chats.
    // This handles the race where the initial loadChats fires before the
    // server has fully established the session (returns 0 chats).
    useEffect(() => {
        if (isConnected && chats.length === 0 && user?.userId && !isLoading) {
            loadChats()
        }
    }, [isConnected])

    // App State / Connection Recovery with debounce
    const lastReloadRef = useRef<number>(0);
    useEffect(() => {
        const handleAppStateChange = (nextAppState: AppStateStatus) => {
            if (nextAppState === 'active') {
                const now = Date.now();
                // Debounce: only reload if 3+ seconds have passed since last reload
                if (now - lastReloadRef.current > 3000) {
                    // console.log('[HomeScreen] App became active, reloading chats...');
                    lastReloadRef.current = now;
                    loadChats();
                    void loadSavedMessagesPreview();
                    // Ensure connection is active upon resume
                    if (!useChatStore.getState().isConnected) {
                        useChatStore.getState().disconnect();
                        setTimeout(() => useChatStore.getState().initSocket(), 100);
                    }
                }
            }
        };

        const subscription = AppState.addEventListener('change', handleAppStateChange);

        return () => {
            subscription.remove();
        };
    }, [loadChats, loadSavedMessagesPreview]);

    const handleChatPress = useCallback((item: any) => {
        safePress(`openChat:${item?.chatId || 'unknown'}`, () => {
            if (isEditing) return
            if (item.chatId === 'saved_messages') {
                router.push('/saved-messages');
                return;
            }
            const chatType = normalizeChatType(item?.type)
            // console.log('[HomeScreen] Navigating to /chat:', item.chatId);
            setActiveChat(item.chatId)
            router.push({
                pathname: '/chat',
                params: {
                    id: item.chatId,
                    chatType,
                },
            });
        });
    }, [isEditing, router, setActiveChat, safePress])

    const handleLongPress = (chat: any, layout: any) => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)
        setSelectedChat(chat)
        setChatLayout(layout)
        setContextMenuVisible(true)
    }

    const copyToClipboard = async () => {
        if (user?.userId) {
            await Clipboard.setStringAsync(user.userId)
            await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
            setCopied(true)
            setTimeout(() => setCopied(false), 2000)
        }
    }

    const toggleSelection = (chatId: string) => {
        setSelectedConversations(prev => {
            const next = new Set(prev)
            if (next.has(chatId)) next.delete(chatId)
            else next.add(chatId)
            return next
        })
    }

    const clearSelectedConversations = useCallback(() => {
        setSelectedConversations(new Set())
    }, [])

    const resolveChatTitle = useCallback((chat: any) => {
        if (!chat) return 'Chat'
        return chat.chatId === 'saved_messages'
            ? 'Saved Messages'
            : (chat.name || chat.friendName || chat.friendId || 'Chat')
    }, [])

    const commitPendingHomeAction = useCallback((action: PendingHomeAction | null) => {
        if (!action) return

        if (action.kind === 'delete') {
            void Promise.resolve(deleteChat(action.chatId))
        } else {
            void Promise.resolve(clearChat(action.chatId))
        }

        pendingHomeActionRef.current = null
        setPendingHomeAction(null)
    }, [clearChat, deleteChat])

    const dismissPendingHomeAction = useCallback(() => {
        pendingHomeActionRef.current = null
        setPendingHomeAction(null)
    }, [])

    const schedulePendingHomeAction = useCallback((kind: PendingHomeActionKind, chat: any) => {
        if (!chat?.chatId) return

        if (pendingHomeActionRef.current) {
            commitPendingHomeAction(pendingHomeActionRef.current)
        }

        const now = Date.now()
        const nextAction: PendingHomeAction = {
            id: `${kind}:${chat.chatId}:${now}`,
            kind,
            chatId: chat.chatId,
            chatName: resolveChatTitle(chat),
            expiresAt: now + HOME_UNDO_WINDOW_MS,
        }

        pendingHomeActionRef.current = nextAction
        setPendingHomeAction(nextAction)
        setPendingHomeActionClock(now)
    }, [commitPendingHomeAction, resolveChatTitle])

    useEffect(() => {
        pendingHomeActionRef.current = pendingHomeAction
    }, [pendingHomeAction])

    useEffect(() => {
        if (!pendingHomeAction) return

        setPendingHomeActionClock(Date.now())
        const interval = setInterval(() => {
            setPendingHomeActionClock(Date.now())
        }, 250)
        const timeout = setTimeout(() => {
            commitPendingHomeAction(pendingHomeAction)
        }, Math.max(0, pendingHomeAction.expiresAt - Date.now()))

        return () => {
            clearInterval(interval)
            clearTimeout(timeout)
        }
    }, [commitPendingHomeAction, pendingHomeAction])

    const handleEditModeChange = useCallback((nextEditing: boolean) => {
        setIsEditing(nextEditing)
        if (!nextEditing) {
            clearSelectedConversations()
        }
    }, [clearSelectedConversations])

    const markChatsReadLocally = useCallback((chatIds: string[]) => {
        const targetIds = new Set(chatIds.filter((chatId) => chatId && chatId !== 'saved_messages'))
        if (targetIds.size === 0) return

        useChatStore.setState((state: any) => ({
            chats: state.chats.map((chat: any) => (
                targetIds.has(chat.chatId)
                    ? {
                        ...chat,
                        unreadCount: 0,
                        markedUnread: false,
                    }
                    : chat
            )),
        }))
    }, [])

    const handleReadSelectedChats = useCallback(() => {
        const targetIds = selectedConversationIds.length > 0
            ? selectedConversationIds
            : allChats.map((chat: any) => chat.chatId)
        markChatsReadLocally(targetIds)
        if (selectedConversationIds.length > 0) {
            clearSelectedConversations()
        }
    }, [allChats, clearSelectedConversations, markChatsReadLocally, selectedConversationIds])

    const handleDeleteSelectedChats = useCallback(() => {
        const targetIds = selectedConversationIds.filter((chatId) => chatId !== 'saved_messages')
        if (targetIds.length === 0) return

        clearSelectedConversations()
        targetIds.forEach((chatId) => {
            void Promise.resolve(deleteChat(chatId))
        })
    }, [clearSelectedConversations, deleteChat, selectedConversationIds])

    useEffect(() => {
        if (!isEditing) return
        if (homeEditActionRequestId === 0) return
        if (lastHandledHomeEditActionIdRef.current === homeEditActionRequestId) return

        lastHandledHomeEditActionIdRef.current = homeEditActionRequestId

        if (homeEditAction === 'readAll' || homeEditAction === 'read') {
            handleReadSelectedChats()
            return
        }

        if (homeEditAction === 'delete') {
            handleDeleteSelectedChats()
        }
    }, [handleDeleteSelectedChats, handleReadSelectedChats, homeEditAction, homeEditActionRequestId, isEditing])

    const renderItem = useCallback(({ item, index }: any) => {
        const friendId = (item.friendId || '').toUpperCase();
        const chatType = normalizeChatType(item?.type);
        const canShowPeerPresence =
            item?.chatId !== 'saved_messages'
            && chatType === 'dm'
            && friendId.length > 0;
        const isTyping = canShowPeerPresence && typingUsers.has(friendId);
        const isOnline = canShowPeerPresence && onlineUsers.has(friendId);

        return (
            <Animated.View>
                <ChatRowCard
                    chat={item}
                    colors={colors}
                    theme={effectiveTheme}
                    isEditing={isEditing}
                    isSelected={selectedConversations.has(item.chatId)}
                    isTyping={isTyping}
                    isOnline={isOnline}
                    onPress={() => {
                        if (isEditing) toggleSelection(item.chatId)
                        else handleChatPress(item)
                    }}
                    onLongPress={(c: any, layout: any) => handleLongPress(c, layout)}
                    onDelete={() => schedulePendingHomeAction('delete', item)}
                    onPin={() => pinChat(item.chatId)}
                    onMute={() => toggleMuteChat(item.chatId)}
                    onMarkRead={() => toggleMarkUnread(item.chatId)}
                />
            </Animated.View>
        );
    }, [colors, isEditing, selectedConversations, typingUsers, onlineUsers, chats, handleChatPress, pinChat, schedulePendingHomeAction, toggleMuteChat, toggleMarkUnread])

    const handlePullRefresh = useCallback(async () => {
        if (isPullRefreshing) return
        setIsPullRefreshing(true)
        try {
            await Promise.all([
                Promise.resolve(loadChats()),
                Promise.resolve(loadSavedMessagesPreview()),
            ])
        } finally {
            setIsPullRefreshing(false)
        }
    }, [isPullRefreshing, loadChats, loadSavedMessagesPreview])

    const handleNativeHomeEvent = useCallback((event: any) => {
        const payload = event?.nativeEvent ?? event ?? {}
        const type = String(payload?.type || '')
        const chatId = String(payload?.chatId || payload?.chat_id || '')

        if (type === 'scroll') {
            const nextOffset = Number(payload?.offsetY ?? 0)
            scrollY.value = Number.isFinite(nextOffset) ? nextOffset : 0
            return
        }

        if (type === 'refresh') {
            void handlePullRefresh()
            return
        }

        if (type === 'undoPendingHomeAction') {
            dismissPendingHomeAction()
            return
        }

        if (!chatId) return
        const chat = chatsById.get(chatId) || filteredChats.find((entry: any) => entry.chatId === chatId)
        if (!chat) return

        if (type === 'editToggleSelect') {
            toggleSelection(chat.chatId)
            return
        }

        if (type === 'press') {
            if (isEditing) {
                toggleSelection(chat.chatId)
                return
            }
            handleChatPress(chat)
            return
        }

        if (type === 'swipePin') {
            pinChat(chat.chatId)
            return
        }

        if (type === 'swipeMute') {
            toggleMuteChat(chat.chatId)
            return
        }

        if (type === 'swipeDelete') {
            schedulePendingHomeAction('delete', chat)
            return
        }

        if (type === 'swipeMarkRead') {
            toggleMarkUnread(chat.chatId)
            return
        }

        if (type === 'clearChat') {
            schedulePendingHomeAction('clear', chat)
            return
        }

        if (type === 'swipeArchive') {
            // Archive = delete for now (archive not yet implemented separately)
            schedulePendingHomeAction('delete', chat)
            return
        }

        if (type === 'longPress') {
            // Native preview is rendered on the native side for native-home list.
            return
        }
    }, [chatsById, dismissPendingHomeAction, filteredChats, handleChatPress, handlePullRefresh, isEditing, pinChat, schedulePendingHomeAction, scrollY, toggleMuteChat, toggleMarkUnread])

    const containerAnimatedStyle = useAnimatedStyle(() => ({
        transform: [
            { scale: parentScale.value }
        ],
        borderRadius: interpolate(parentScale.value, [1, 0.94], [0, 24]),
        opacity: 1,
        overflow: 'hidden',
    }))

    const shouldUseNativeHomeList = useMemo(() => {
        if (!(Platform.OS === 'ios' || Platform.OS === 'android')) return false
        if (!isNativeHomeListAvailable()) return false
        if (Platform.OS === 'ios') return true
        return !isEditing
    }, [isEditing])

    const renderHomeListHeader = () => {
        if (allChats.length === 0) return null;
        return (
            <View>
                {(feed.length > 0 || myStories.length > 0) && (
                    <View style={{ paddingBottom: 4, paddingLeft: 10 }}>
                        <StoryBar
                            size="medium"
                            onViewerOpen={handleOpenStoryViewer}
                            onAddStoryPress={handleOpenStoryCamera}
                            isMoving={false}
                        />
                    </View>
                )}
                <Animated.View style={searchBarStyle} pointerEvents={isSearchActive ? 'none' : 'auto'}>
                    <Animated.View style={searchInnerStyle}>
                        <View
                            style={{
                                flexDirection: 'row',
                                alignItems: 'center',
                                backgroundColor: colors.input || colors.card,
                                borderRadius: 22,
                                height: SEARCH_BAR_HEIGHT,
                                paddingHorizontal: 14,
                                marginHorizontal: 16
                            }}
                        >
                            <Pressable
                                onPress={handleSearchFocus}
                                style={{ flexDirection: 'row', alignItems: 'center', flex: 1, height: '100%' }}
                            >
                                <Search size={18} color={withAlpha(colors.text, 0.5)} strokeWidth={1.5} />
                                <Text style={{ marginLeft: 8, color: withAlpha(colors.text, 0.4), fontSize: 16 }}>Search</Text>
                            </Pressable>
                        </View>
                    </Animated.View>
                </Animated.View>
            </View>
        )
    }

    const renderHomeEmptyState = () => (
        <Animated.View entering={FadeIn.duration(400)} style={styles.emptyStateContainer}>
            <View style={{ width: 250, height: 250, marginBottom: 10, alignSelf: 'center', position: 'relative' }}>
                <View style={{ position: 'absolute', top: '10%', left: -25, width: 300, height: 300 }}>
                    <LottieView
                        source={require('../../src/lottie/Cat playing animation.json')}
                        autoPlay
                        loop
                        style={{ width: '100%', height: '100%' }}
                    />
                </View>
            </View>
            <Text style={[styles.emptyDescription, { color: colors.text, marginTop: 10, marginBottom: 8, fontSize: 24, fontWeight: '600', letterSpacing: -0.5 }]}>
                No messages yet
            </Text>
            <Text style={[{ color: withAlpha(colors.text, 0.6), marginBottom: 30, fontSize: 16 }]}>
                Start a conversation to catch the vibe.
            </Text>
            <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 12, paddingHorizontal: 20, width: '100%', maxWidth: 360 }}>
                <TouchableOpacity onPress={() => safePress('openAgent', () => router.push('/agent'))} activeOpacity={0.8} style={{ flex: 1 }}>
                    <SafeLiquidGlass
                        style={{ paddingVertical: 12, borderRadius: 24, borderWidth: 1, borderColor: withAlpha(colors.text, 0.1), alignItems: 'center' }}
                        blurIntensity={15}
                        tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                    >
                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                            <VibeAgentLogo color={colors.text} size={18} />
                            <Text style={{ color: colors.text, fontSize: 14, fontWeight: '600' }}>Talk to Vibe</Text>
                        </View>
                    </SafeLiquidGlass>
                </TouchableOpacity>
                <TouchableOpacity onPress={() => safePress('openMainMenuSearch', () => setShowMainMenu(true))} activeOpacity={0.8} style={{ flex: 1 }}>
                    <SafeLiquidGlass
                        style={{ paddingVertical: 12, borderRadius: 24, alignItems: 'center' }}
                        blurIntensity={15}
                        tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                        tintColor={withAlpha(colors.primary, 0.15)}
                    >
                        <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 4 }}>
                            <Plus color={colors.primary} size={18} strokeWidth={1.5} />
                            <Text style={{ color: colors.primary, fontSize: 14, fontWeight: '600' }}>New Chat</Text>
                        </View>
                    </SafeLiquidGlass>
                </TouchableOpacity>
            </View>
        </Animated.View>
    )

    return (
        <View style={[styles.container, { backgroundColor: 'transparent' }]}>
            <Stack.Screen options={{ headerShown: false }} />

            {/* Main Content Layer (Scales/Translates) */}
            <Animated.View style={[{ flex: 1, backgroundColor: colors.background }, containerAnimatedStyle]}>
                <View style={styles.container}>
                    {/* Header Overlay (Blurred for iOS, Elevated for Android) */}
                    <View style={[styles.headerMaskContainer, { height: insets.top + (Platform.OS === 'android' ? 56 : 50) }]}>
                        {Platform.OS === 'android' ? (
                            <Animated.View
                                style={[
                                    StyleSheet.absoluteFill,
                                    { backgroundColor: effectiveTheme === 'dark' ? '#121212' : '#ffffff' },
                                    androidHeaderAnimatedStyle
                                ]}
                            />
                        ) : (
                            <MaskedView
                                style={StyleSheet.absoluteFill}
                                maskElement={
                                    <LinearGradient
                                        colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']}
                                        locations={[0.6, 1]}
                                        style={StyleSheet.absoluteFill}
                                    />
                                }
                            >
                                <BlurView
                                    intensity={30}
                                    tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                    style={[StyleSheet.absoluteFill, { backgroundColor: effectiveTheme === 'dark' ? 'rgba(0,0,0,0.4)' : 'rgba(255,255,255,0.4)' }]}
                                />
                            </MaskedView>
                        )}
                    </View>

                    {/* Header Buttons/Title */}
                    <View style={[styles.headerContentContainer, { height: insets.top + 56, paddingTop: insets.top }]}>
                        {/* Title Container - Centered properly in the header area */}
                        <View style={[StyleSheet.absoluteFill, { top: insets.top, alignItems: 'center', justifyContent: 'center', zIndex: -1 }]} pointerEvents="none">
                            <Animated.View key={!isConnected ? 'connecting' : (isLoading && chats.length === 0 ? 'updating' : 'chats')} entering={FadeIn.duration(200)} exiting={FadeOut.duration(200)}>
                                <Text style={[
                                    styles.headerTitle,
                                    { color: colors.text },
                                ]}>
                                    {!isConnected ? 'Connecting...' : (isLoading && chats.length === 0 ? 'Updating...' : 'Chats')}
                                </Text>
                            </Animated.View>
                        </View>



                        {/* Search & Add Story Container - Right Aligned */}
                        {showEditButton && (
                            <View style={{ zIndex: 200 }}>
                                {Platform.OS === 'android' ? (
                                    <TouchableOpacity
                                        onPress={() => {
                                            safePress('toggleEdit', () => {
                                                Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                                                handleEditModeChange(!isEditing);
                                            });
                                        }}
                                        activeOpacity={0.7}
                                    >
                                        <View style={[styles.glassBtnEdit, {
                                            backgroundColor: isEditing ? colors.primary : 'transparent',
                                            borderRadius: 20,
                                            paddingHorizontal: 8,
                                        }]}>
                                            <View style={styles.textBtnTouch}>
                                                <Text style={[styles.headerTextBtn, { color: isEditing ? '#fff' : colors.text }]}>
                                                    {isEditing ? 'Done' : 'Edit'}
                                                </Text>
                                            </View>
                                        </View>
                                    </TouchableOpacity>
                                ) : (
                                    <SafeLiquidGlass
                                        style={styles.glassBtnEdit}
                                        blurIntensity={15}
                                        tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                        tintColor={headerGlassTintColor}
                                        onStartShouldSetResponder={() => true}
                                        onResponderRelease={() => {
                                            safePress('toggleEdit', () => {
                                                Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                                                handleEditModeChange(!isEditing);
                                            });
                                        }}
                                    >
                                        <Text style={[styles.headerTextBtn, { color: colors.text }]}>
                                            {isEditing ? 'Done' : 'Edit'}
                                        </Text>
                                    </SafeLiquidGlass>
                                )}
                            </View>
                        )}

                        {/* REMOVED OLD ABSOLUTE TITLE CONTAINER */}


                        <View style={{ zIndex: 200 }}>
                            {Platform.OS === 'android' ? (
                                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 0 }}>
                                    <TouchableOpacity onPress={() => safePress('openConnectionModal', () => connectionModalRef.current?.present())} style={[styles.iconBtnCircle, { width: 36, height: 36 }]}>
                                        <AnimatedShieldIcon size={22} />
                                    </TouchableOpacity>
                                    <TouchableOpacity
                                        onPress={handleOpenStoryCamera}
                                        style={[styles.iconBtnCircle, { width: 36, height: 36 }]}
                                    >
                                        <PlusCircleVibeIcon size={23} color={colors.text} />
                                    </TouchableOpacity>

                                    <TouchableOpacity onPress={() => safePress('openMainMenuHeader', () => setShowMainMenu(true))} style={[styles.iconBtnCircle, { width: 36, height: 36 }]}>
                                        <EditChatVibeIcon size={23} color={colors.text} strokeWidth={1.5} />
                                    </TouchableOpacity>
                                </View>
                            ) : (
                                <SafeLiquidGlass
                                    style={styles.glassBtnRow}
                                    blurIntensity={15}
                                    tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                    tintColor={headerGlassTintColor}
                                >
                                    <Pressable
                                        onPress={() => safePress('openConnectionModal', () => connectionModalRef.current?.present())}
                                        style={styles.iconBtnCircle}
                                    >
                                        <AnimatedShieldIcon size={22} />
                                    </Pressable>
                                    <Pressable
                                        onPress={handleOpenStoryCamera}
                                        style={styles.iconBtnCircle}
                                    >
                                        <PlusCircleVibeIcon size={24} color={colors.text} />
                                    </Pressable>

                                    <Pressable
                                        onPress={() => safePress('openMainMenuHeader', () => setShowMainMenu(true))}
                                        style={styles.iconBtnCircle}
                                    >
                                        <EditChatVibeIcon size={24} color={colors.text} strokeWidth={1.5} />
                                    </Pressable>
                                </SafeLiquidGlass>
                            )}
                        </View>
                    </View>

                    {/* Chat List */}
                    {shouldUseNativeHomeList ? (
                        <View style={{ flex: 1 }}>
                            <View style={{ flex: 1 }}>
                                <NativeHomeListSurface
                                    rows={nativeHomeRows}
                                    refreshing={isPullRefreshing}
                                    isDark={effectiveTheme === 'dark'}
                                    previewAppearance={nativePreviewAppearance}
                                    contentTopInset={nativeHomeContentTopInset}
                                    contentBottomInset={100 + (Platform.OS === 'android' ? insets.bottom : 0)}
                                    isEditing={Platform.OS === 'ios' ? isEditing : undefined}
                                    selectedChatIds={Platform.OS === 'ios' ? selectedConversationIds : undefined}
                                    undoBanner={nativeHomeUndoBanner}
                                    onNativeEvent={handleNativeHomeEvent}
                                />
                                <Animated.View
                                    pointerEvents={isSearchActive ? 'none' : 'auto'}
                                    style={[
                                        {
                                            position: 'absolute',
                                            top: nativeListTopOffset,
                                            left: 0,
                                            right: 0,
                                            zIndex: 10,
                                            elevation: 10,
                                        },
                                        nativeHeaderScrollStyle,
                                    ]}
                                >
                                    {renderHomeListHeader()}
                                </Animated.View>
                                {filteredChats.length === 0 && savedMessagesPreviewLoaded && (
                                    <View style={StyleSheet.absoluteFill} pointerEvents="box-none">
                                        {renderHomeEmptyState()}
                                    </View>
                                )}
                            </View>
                        </View>
                    ) : (
                        <Animated.FlatList
                            data={filteredChats}
                            renderItem={renderItem}
                            extraData={[typingUsers, onlineUsers, selectedConversations, isEditing, chats.length, homeSavedMessages.length, savedMessagesPreviewLoaded]}
                            keyExtractor={item => item.chatId}
                            contentContainerStyle={[styles.listContent, { paddingTop: insets.top + (Platform.OS === 'android' ? 64 : 50) }]}
                            showsVerticalScrollIndicator={false}
                            onScroll={onScroll}
                            scrollEventThrottle={16}
                            refreshControl={
                                <RefreshControl refreshing={isPullRefreshing} onRefresh={handlePullRefresh} tintColor={colors.text} />
                            }
                            ListHeaderComponent={renderHomeListHeader}
                            ListFooterComponent={<View style={{ height: 100 + (Platform.OS === 'android' ? insets.bottom : 0) }} />}
                            ListEmptyComponent={savedMessagesPreviewLoaded ? renderHomeEmptyState : null}
                        />
                    )}

                    {/* Chat Preview Modal */}
                    <ChatPreviewModal
                        visible={contextMenuVisible}
                        startLayout={chatLayout}
                        chat={selectedChat}
                        onClose={() => setContextMenuVisible(false)}
                        onPin={() => { if (selectedChat) pinChat(selectedChat.chatId); setContextMenuVisible(false); }}
                        onMute={() => { if (selectedChat) toggleMuteChat(selectedChat.chatId); setContextMenuVisible(false); }}
                        onDelete={() => {
                            if (selectedChat) schedulePendingHomeAction('delete', selectedChat);
                            setContextMenuVisible(false);
                        }}
                    />

                    {/* Story Modals */}
                    <StoryViewer
                        visible={showStoryViewer}
                        initialUserId={storyViewerUserId || undefined}
                        initialStoryIndex={storyViewerIndex}
                        onClose={() => {
                            setShowStoryViewer(false);
                            setStoryViewerUserId(null);
                        }}
                    />
                </View>
            </Animated.View >

            {/* Global Overlays & Modals */}
            < MainMenuModal
                visible={showMainMenu}
                onClose={() => setShowMainMenu(false)
                }
                parentScale={parentScale}
            />

            {/* Search Backdrop & Results */}
            < Animated.View
                pointerEvents={isSearchActive ? 'auto' : 'none'}
                style={[StyleSheet.absoluteFill, { zIndex: 3000 }, searchOverlayStyle]}
            >
                <View style={{ flex: 1, backgroundColor: colors.background, paddingTop: insets.top + 8 + SEARCH_BAR_BLOCK_HEIGHT + 8 }}>
                    {isSearchActive && searchQuery === '' && (
                        <View style={{ flex: 1 }}>
                            {/* Latest Chat Preview */}
                            {chats.length > 0 && (
                                <View style={{ paddingHorizontal: 14, marginVertical: 10 }}>
                                    <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                                        <StoryAvatar
                                            userId={chats[0].friendId}
                                            username={chats[0].friendName}
                                            profileImage={chats[0].friendImage}
                                            size="medium"
                                            showName
                                            isOnline={onlineUsers.has(chats[0].friendId?.toUpperCase())}
                                        />
                                    </View>
                                </View>
                            )}

                            {/* Recent activities Section at Top */}
                            {chats.length > 0 && (
                                <View style={{ marginTop: 10 }}>
                                    <Text style={{ color: colors.textSecondary, fontSize: 13, marginLeft: 24, marginBottom: 12, textTransform: 'uppercase', letterSpacing: 0.5 }}>Recent</Text>
                                    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ paddingHorizontal: 25 }}>
                                        {allChats.slice(0, 10).map((chat: any) => {
                                            const isSaved = chat.chatId === 'saved_messages';
                                            const displayName = isSaved ? 'Saved' : (chat.friendName || chat.name || 'Unknown');
                                            const friendId = chat.friendId || chat.chatId;
                                            return (
                                                <View key={chat.chatId} style={{ marginRight: 20, alignItems: 'center' }}>
                                                    <StoryAvatar
                                                        userId={friendId}
                                                        username={displayName}
                                                        profileImage={isSaved ? null : chat.friendImage}
                                                        size="medium"
                                                        showName
                                                        isOnline={isSaved ? false : onlineUsers.has(friendId?.toUpperCase())}
                                                    />
                                                </View>
                                            );
                                        })}
                                    </ScrollView>
                                </View>
                            )}
                        </View>
                    )}
                </View>
            </Animated.View >

            {/* Search Bar Refactored into ScrollView */}

            {/* Pinned Search Bar (Always on Top during Search) - zIndex higher than overlay */}
            <Animated.View
                pointerEvents={isSearchActive ? 'auto' : 'none'}
                style={[searchInputOverlayStyle, { zIndex: 4001 }]}
            >
                <View
                    pointerEvents={isSearchActive ? 'auto' : 'none'}
                    style={{
                        flexDirection: 'row',
                        alignItems: 'center',
                        backgroundColor: colors.input || colors.card,
                        borderRadius: 22,
                        height: SEARCH_BAR_HEIGHT,
                        paddingHorizontal: 12
                    }}
                >
                    <Search size={18} color={withAlpha(colors.text, 0.5)} strokeWidth={1.5} />
                    <TextInput
                        ref={searchInputRef}
                        autoFocus={false}
                        placeholder="Search"
                        placeholderTextColor={withAlpha(colors.text, 0.5)}
                        style={{ flex: 1, marginLeft: 8, color: colors.text, fontSize: 16 }}
                        editable={isSearchActive}
                        value={searchQuery}
                        onChangeText={setSearchQuery}
                        onBlur={handleSearchClose}
                    />
                    <Animated.View style={[cancelBtnStyle, { overflow: 'hidden', alignItems: 'flex-end' }]}>
                        <TouchableOpacity onPress={handleSearchClose} style={{ padding: 4 }}>
                            <X size={20} color={colors.text} />
                        </TouchableOpacity>
                    </Animated.View>
                </View>
            </Animated.View>

            <ConnectionModal ref={connectionModalRef} parentScale={parentScale} />


        </View >
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    // Header Style
    headerMaskContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 60,
        pointerEvents: 'none'
    },
    headerContentContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 130,
        flexDirection: 'row',
        justifyContent: 'space-between',
        alignItems: 'center',
        paddingHorizontal: 16,
    },
    absTitleContainer: {
        position: 'absolute',
        top: '100%',
        left: 0,
        right: 0,
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: -1,
        height: '100%',
    },
    glassBtnGroupSmall: {
        borderRadius: 12,
        overflow: 'hidden',
        height: 32,
        justifyContent: 'center',
        paddingHorizontal: 16
    },
    glassBtnEdit: {
        borderRadius: 20,
        overflow: 'hidden',
        height: 40,
        justifyContent: 'center',
        paddingHorizontal: 16,
    },
    glassBtnCircle: {
        width: 40,
        height: 40,
        borderRadius: 20,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center'
    },
    glassBtnRow: {
        flexDirection: 'row',
        alignItems: 'center',
        height: 40,
        borderRadius: 20,
        overflow: 'hidden',
        paddingHorizontal: 4,
        backgroundColor: 'rgba(255, 255, 255, 0.025)',
    },
    rowDivider: {
        width: 1,
        height: 20,
        borderRadius: 0.5,
    },
    iconBtnCircle: {
        width: 38,
        height: 40,
        alignItems: 'center',
        justifyContent: 'center'
    },
    headerTextBtn: {
        fontSize: 15,
        fontWeight: '600'
    },
    textBtnTouch: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    headerTitle: {
        fontSize: 17,
        fontWeight: '700',
        letterSpacing: -0.4,
    },

    listContent: {
        paddingBottom: 100,
    },
    chatRowPressable: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 12,
        paddingHorizontal: 16,
        minHeight: 76,
    },
    swipeAction: {
        width: 74,
        alignItems: 'center',
        justifyContent: 'center',
        height: '100%',
    },
    swipeActionRow: {
        flex: 1,
        flexDirection: 'row',
        gap: 0,
    },
    swipeActionContent: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
    swipeActionLabel: {
        color: '#fff',
        fontSize: 13,
        fontWeight: '500',
        marginTop: 6,
    },
    avatarContainer: {
        marginRight: 14,
    },
    avatarGlass: {
        width: 60,
        height: 60,
        borderRadius: 999,
        overflow: 'hidden',
    },
    avatarImage: {
        width: '100%',
        height: '100%',
    },
    avatarPlaceholder: {
        width: '100%',
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(127, 127, 127, 0.12)'
    },
    avatarText: {
        fontSize: 20,
        fontWeight: '600',
    },
    chatRowContent: {
        flex: 1,
        justifyContent: 'center',
        gap: 2
    },
    chatRowMetaCol: {
        alignItems: 'flex-end',
        justifyContent: 'center',
        height: 52,
        marginLeft: 5,
        minWidth: 24
    },
    chatNameText: {
        fontSize: 17,
        fontWeight: '500',
    },
    chatStatusText: {
        fontSize: 15,
    },
    iconRow: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
        marginTop: 4,
        justifyContent: 'flex-end',
    },
    unreadBadge: {
        minWidth: 20,
        height: 20,
        borderRadius: 10,
        alignItems: 'center',
        justifyContent: 'center',
        paddingHorizontal: 6,
    },
    unreadText: {
        fontSize: 11,
        fontWeight: '700',
        color: '#fff',
    },
    bottomBar: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        height: 80,
        borderTopWidth: 1,
        borderTopColor: 'rgba(255,255,255,0.1)',
        zIndex: 100
    },
    emptyStateContainer: {
        padding: 20,
        paddingTop: 60,
        alignItems: 'center'
    },
    emptyDescription: {
        fontSize: 16,
        textAlign: 'center',
        maxWidth: 240,
        marginTop: 40,
        lineHeight: 22,
        fontWeight: '500',

    },
    actionButton: {
        height: 48,
        borderRadius: 24,
        paddingHorizontal: 32,
        alignItems: 'center',
        justifyContent: 'center',
        minWidth: 160
    },

    onlineIndicator: {
        position: 'absolute',
        bottom: 2,
        right: 2,
        width: 14,
        height: 14,
        borderRadius: 7,
        borderWidth: 2,
        zIndex: 10,
    },
    ongoingCallOverlay: {
        position: 'absolute',
        left: 20,
        right: 20,
        zIndex: 2000,
        alignItems: 'center',
    },
    ongoingCallContainer: {
        width: 'auto',
        minWidth: 160,
    },
    ongoingCallGlass: {
        borderRadius: 25,
        overflow: 'hidden',
    },
    ongoingCallContent: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 8,
        paddingHorizontal: 16,
        gap: 12,
    },
    callTypeIndicator: {
        width: 8,
        height: 8,
        borderRadius: 4,
    },
    callRemoteInfo: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 8,
    },
    callRemoteName: {
        color: '#fff',
        fontSize: 14,
        fontWeight: '600',
        maxWidth: 100,
    },
    callStatusLabel: {
        color: 'rgba(255,255,255,0.7)',
        fontSize: 12,
        fontWeight: '500',
    },
    callVisualizer: {
        marginLeft: 4,
    }
})
