
import React, { useEffect, useState, useCallback, useRef, useMemo } from 'react'
import { View, Text, FlatList, TouchableOpacity, StyleSheet, Platform, Pressable, Image, ActivityIndicator, TextInput, RefreshControl, AppState, AppStateStatus, ScrollView } from 'react-native'
import { useAuthStore } from '../../src/lib/stores/auth-store'
import { useThemeStore } from '../../src/lib/stores/theme-store'
import { useChatStore } from '../../src/lib/ChatStore'
import { useCallStore } from '../../src/lib/stores/CallStore'
import { useUIStore } from '../../src/lib/stores/ui-store'
import { Copy, Check, Pin, VolumeX, Trash2, Pencil, Settings, User, Search, Circle, CheckCircle, Smartphone, Plus, X, Shield, Bookmark, Sparkles } from 'lucide-react-native'
import { PlusCircleVibeIcon, AnimatedShieldIcon, EditChatVibeIcon } from '../../src/components/Icons'
import * as Clipboard from 'expo-clipboard'
import * as Haptics from 'expo-haptics'
import { useRouter, Stack } from 'expo-router'
import MaskedView from '@react-native-masked-view/masked-view'
import { LinearGradient } from 'expo-linear-gradient'
import LottieView from 'lottie-react-native'
import Swipeable from 'react-native-gesture-handler/Swipeable'
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass'
import { StoryBar, StoryViewer, StoryAvatar } from '../../src/components/story'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { BlurView } from 'expo-blur'
import { Animated as RNAnimated } from 'react-native'
import Animated, { cancelAnimation, useAnimatedStyle, useSharedValue, withTiming, withSpring, interpolate, Easing, withRepeat, withSequence, FadeIn, FadeOut, useAnimatedScrollHandler, useAnimatedReaction, Extrapolate, useDerivedValue, runOnJS, LinearTransition } from 'react-native-reanimated'
import ThemeBackground from '../../src/components/ThemeBackground'
import MainMenuModal from '../../src/components/chat/MainMenuModal'
import ConnectionModal, { ConnectionModalRef } from '../../src/components/settings/ConnectionModal'
import ChatPreviewModal from '../../src/components/chat/ChatPreviewModal'
import { useSavedMessagesStore } from '../../src/lib/stores/saved-messages-store'


// Helper to add alpha to hex color
const withAlpha = (color: string, alpha: number): string => {
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

    // If we have text and it's not a JSON blob (or was successfully parsed above)
    if (text && typeof text === 'string' && text.length > 0) {
        return text
    }

    // Check if it's a media message
    if (msg.type === 'image') return '📷 Photo'
    if (msg.type === 'voice') return '🎤 Voice message'
    if (msg.type === 'gif') return '🎬 GIF'
    if (msg.type === 'sticker') return '🧩 Sticker'
    if (msg.type === 'video') return '🎥 Video'

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

interface HomeScreenProps {
    onChatSelect?: (chatId: string) => void;
    onOpenStoryCamera?: () => void;
}

// Swipeable Chat Row Component 
const ChatRowCard = React.memo(({ chat, colors, theme, onPress, onLongPress, onDelete, onPin, onMute, isEditing, isSelected, isTyping, isOnline }: any) => {
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

    const renderRightActions = (progress: any, dragX: any) => {
        if (isEditing) return null;
        const trans = dragX.interpolate({
            inputRange: [-140, 0],
            outputRange: [0, 140],
        });
        const iconScale = dragX.interpolate({
            inputRange: [-100, -50, 0],
            outputRange: [1, 0.5, 0.01],
            extrapolate: 'clamp',
        });

        return (
            <RNAnimated.View style={{ width: 140, transform: [{ translateX: trans }] }}>
                <View style={{ flex: 1, flexDirection: 'row' }}>
                    <TouchableOpacity onPress={() => { onMute(); swipeableRef.current?.close(); }} style={[styles.swipeAction, { backgroundColor: '#f97316' }]}>
                        <RNAnimated.View style={{ transform: [{ scale: iconScale }] }}>
                            <VolumeX color="white" size={24} />
                        </RNAnimated.View>
                    </TouchableOpacity>
                    <TouchableOpacity onPress={() => { onDelete(); swipeableRef.current?.close(); }} style={[styles.swipeAction, { backgroundColor: '#ef4444' }]}>
                        <RNAnimated.View style={{ transform: [{ scale: iconScale }] }}>
                            <Trash2 color="white" size={24} />
                        </RNAnimated.View>
                    </TouchableOpacity>
                </View>
            </RNAnimated.View>
        );
    };

    const renderLeftActions = (progress: any, dragX: any) => {
        if (isEditing) return null;
        const trans = dragX.interpolate({
            inputRange: [0, 80],
            outputRange: [-80, 0],
        });
        return (
            <RNAnimated.View style={{ width: 80, transform: [{ translateX: trans }] }}>
                <TouchableOpacity onPress={() => { onPin(); swipeableRef.current?.close(); }} style={[styles.swipeAction, { backgroundColor: '#3b82f6', flex: 1 }]}>
                    <Pin color="white" size={24} fill="white" />
                </TouchableOpacity>
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
                    containerStyle={{ overflow: 'visible' }}
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
                            <SafeLiquidGlass style={styles.avatarGlass} blurIntensity={10} effect="clear" tint={theme === 'dark' ? 'dark' : 'light'}>
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
    const { setActiveChat, chats, isLoading, loadChats, deleteChat, pinChat, toggleMuteChat, toggleMarkUnread, typingUsers, onlineUsers, isConnected } = useChatStore()
    const { savedMessages } = useSavedMessagesStore()
    const { callStatus, remoteUser, callDuration, callType } = useCallStore()
    const onlineUsersList = onlineUsers ? Array.from(onlineUsers) : [];



    const insets = useSafeAreaInsets()
    const [copied, setCopied] = useState(false)
    const router = useRouter()
    const [isEditing, setIsEditing] = useState(false)
    const setHomeEditing = useUIStore(s => s.setHomeEditing)
    const safePress = useCallback((label: string, action: () => void | Promise<void>) => {
        try {
            console.log(`[HomeScreen] press:${label}`)
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

    // Sync editing state
    useEffect(() => {
        setHomeEditing(isEditing)
        return () => setHomeEditing(false)
    }, [isEditing])

    const [selectedConversations, setSelectedConversations] = useState(new Set<string>())

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



    const allChats = useMemo(() => {
        let list = [...chats];
        if (savedMessages.length > 0) {
            const lastMsg = savedMessages[0] as any;
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
            if (!list.find(c => c.chatId === 'saved_messages')) {
                list.push(savedChat);
            }
        }
        return list.sort((a: any, b: any) => getChatSortTimestamp(b) - getChatSortTimestamp(a));
    }, [chats, savedMessages, user?.userId]);

    const filteredChats = useMemo(() => {
        const q = searchQuery.trim().toLowerCase()
        if (!q) return allChats
        return allChats.filter((chat: any) => {
            const name = chat.chatId === 'saved_messages' ? 'Saved Messages' : (chat.name || chat.friendName || chat.friendId || 'Unknown');
            return name.toLowerCase().includes(q) ||
                getMessageText(chat.lastMessage).toLowerCase().includes(q)
        })
    }, [allChats, searchQuery])

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

    const handleOpenGlassDebug = useCallback(() => {
        safePress('openGlassDebug', () => {
            router.push('/test-telegram-morph-native');
        });
    }, [router, safePress]);

    const handleOpenNativeInsertTest = useCallback(() => {
        safePress('openNativeInsertTest', () => {
            router.push('/test-native-insert');
        });
    }, [router, safePress]);

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



    const searchOverlayStyle = useAnimatedStyle(() => ({
        opacity: searchFocusProgress.value,
    }));



    const searchBarStyle = useAnimatedStyle(() => {
        // Natural opacity fades OUT when focused to reveal the pinned overlay
        const focusOpacity = interpolate(searchFocusProgress.value, [0, 0.2], [1, 0], Extrapolate.CLAMP);

        // Natural scroll collapse: height shrinks and content slides up
        const scrollHeight = interpolate(scrollY.value, [0, 40], [44, 0], Extrapolate.CLAMP);
        const scrollTranslateY = interpolate(scrollY.value, [0, 40], [0, -22], Extrapolate.CLAMP);
        const scrollOpacity = interpolate(scrollY.value, [0, 30], [1, 0], Extrapolate.CLAMP);

        return {
            height: scrollHeight,
            opacity: Math.min(focusOpacity, scrollOpacity),
            transform: [{ translateY: scrollTranslateY }],
            overflow: 'hidden',
        };
    });

    const searchInputOverlayStyle = useAnimatedStyle(() => {
        // Capture initial position based on scroll when animation started
        const startY = insets.top + 170 - scrollYAtStart.value;
        const targetY = insets.top + 10;

        // Match the container's vertical shift (-30px)
        const parentShift = interpolate(searchFocusProgress.value, [0, 1], [0, -30], Extrapolate.CLAMP);

        // Synchronized Cross-fade: Overlay fades IN as list bar fades OUT
        const opacity = interpolate(searchFocusProgress.value, [0, 0.15], [0, 1], Extrapolate.CLAMP);

        // We want to feel like we "lift" the bar from the list
        // and move it to the fixed header position.
        return {
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            transform: [
                { translateY: interpolate(searchFocusProgress.value, [0, 1], [startY + parentShift, targetY], Extrapolate.CLAMP) }
            ],
            height: 44,
            opacity,
            paddingHorizontal: interpolate(searchFocusProgress.value, [0, 1], [16, 20], Extrapolate.CLAMP),
            zIndex: 4000,
        };
    });

    const cancelBtnStyle = useAnimatedStyle(() => ({
        opacity: interpolate(searchFocusProgress.value, [0.7, 1], [0, 1], Extrapolate.CLAMP),
        transform: [{ scale: interpolate(searchFocusProgress.value, [0.7, 1], [0.8, 1], Extrapolate.CLAMP) }],
        width: interpolate(searchFocusProgress.value, [0.7, 1], [0, 32], Extrapolate.CLAMP),
    }));

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
    }, []); // loadChats is stable from Zustand, no need in deps

    const handleChatPress = useCallback((item: any) => {
        safePress(`openChat:${item?.chatId || 'unknown'}`, () => {
            if (isEditing) return
            if (item.chatId === 'saved_messages') {
                router.push('/saved-messages');
                return;
            }
            console.log('[HomeScreen] Navigating to /chat:', item.chatId);
            setActiveChat(item.chatId)
            router.push((`/chat?id=${encodeURIComponent(item.chatId)}`) as any);
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

    const renderItem = useCallback(({ item, index }: any) => {
        const friendId = (item.friendId || '').toUpperCase();
        const isTyping = typingUsers.has(friendId);
        const isOnline = onlineUsers.has(friendId);

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
                    onDelete={() => deleteChat(item.chatId)}
                    onPin={() => pinChat(item.chatId)}
                    onMute={() => toggleMuteChat(item.chatId)}
                />
            </Animated.View>
        );
    }, [colors, isEditing, selectedConversations, typingUsers, onlineUsers, chats, handleChatPress])

    const handlePullRefresh = useCallback(async () => {
        if (isPullRefreshing) return
        setIsPullRefreshing(true)
        try {
            await Promise.resolve(loadChats())
        } finally {
            setIsPullRefreshing(false)
        }
    }, [isPullRefreshing, loadChats])

    const containerAnimatedStyle = useAnimatedStyle(() => ({
        transform: [
            { scale: parentScale.value },
            { translateY: interpolate(searchFocusProgress.value, [0, 1], [0, -30], Extrapolate.CLAMP) }
        ],
        borderRadius: interpolate(parentScale.value, [1, 0.94], [0, 24]),
        opacity: 1,
        overflow: 'hidden',
    }))

    return (
        <View style={[styles.container, { backgroundColor: '#000' }]}>
            <Stack.Screen options={{ headerShown: false }} />

            {/* Main Content Layer (Scales/Translates) */}
            <Animated.View style={[{ flex: 1, backgroundColor: colors.background }, containerAnimatedStyle]}>
                <View style={styles.container}>
                    {/* Header Overlay (Blurred) */}
                    <View style={[styles.headerMaskContainer, { height: Math.max(80, insets.top + 20) }]}>
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
                                style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(colors.background, 0.85) }]}
                            />
                        </MaskedView>
                    </View>

                    {/* Header Buttons/Title */}
                    <View style={[styles.headerContentContainer, { height: insets.top + 50, paddingTop: insets.top }]}>
                        {/* Title Container - Centered properly in the header area */}
                        <View style={[StyleSheet.absoluteFill, { top: insets.top, alignItems: 'center', justifyContent: 'center', zIndex: -1 }]} pointerEvents="none">
                            <Animated.View key={!isConnected ? 'connecting' : (isLoading ? 'updating' : 'chats')} entering={FadeIn.duration(200)} exiting={FadeOut.duration(200)}>
                                <Text style={[
                                    styles.headerTitle,
                                    { color: colors.text },
                                ]}>
                                    {!isConnected ? 'Connecting...' : (isLoading ? 'Updating...' : 'Chats')}
                                </Text>
                            </Animated.View>
                        </View>



                        {/* Search & Add Story Container - Right Aligned */}
                        {showEditButton && (
                            <View
                                style={{ zIndex: 200 }}
                            >
                                <SafeLiquidGlass style={styles.glassBtnEdit} blurIntensity={15} effect="clear">
                                    <TouchableOpacity
                                        onPress={() => {
                                            safePress('toggleEdit', () => {
                                                Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                                                setIsEditing(!isEditing);
                                            });
                                        }}
                                        style={styles.textBtnTouch}
                                    >
                                        <Text style={[styles.headerTextBtn, { color: colors.text }]}>
                                            {isEditing ? 'Done' : 'Edit'}
                                        </Text>
                                    </TouchableOpacity>
                                </SafeLiquidGlass>
                            </View>
                        )}

                        {/* REMOVED OLD ABSOLUTE TITLE CONTAINER */}


                        <View style={{ zIndex: 200 }}>
                            <SafeLiquidGlass style={styles.glassBtnRow} blurIntensity={15} effect="clear">
                                <TouchableOpacity onPress={() => safePress('openConnectionModal', () => connectionModalRef.current?.present())} style={styles.iconBtnCircle}>
                                    <AnimatedShieldIcon size={22} />
                                </TouchableOpacity>
                                <TouchableOpacity
                                    onPress={handleOpenStoryCamera}
                                    onLongPress={handleOpenNativeInsertTest}
                                    delayLongPress={400}
                                    style={styles.iconBtnCircle}
                                >
                                    <PlusCircleVibeIcon size={24} color={colors.text} />
                                </TouchableOpacity>

                                <TouchableOpacity
                                    onPress={handleOpenGlassDebug}
                                    style={styles.iconBtnCircle}
                                >
                                    <Sparkles size={20} color={colors.text} strokeWidth={2} />
                                </TouchableOpacity>

                                <TouchableOpacity onPress={() => safePress('openMainMenuHeader', () => setShowMainMenu(true))} style={styles.iconBtnCircle}>
                                    <EditChatVibeIcon size={24} color={colors.text} strokeWidth={1.5} />
                                </TouchableOpacity>
                            </SafeLiquidGlass>
                        </View>
                    </View>

                    {/* Chat List */}
                    <Animated.FlatList
                        data={filteredChats}
                        renderItem={renderItem}
                        extraData={[typingUsers, onlineUsers, selectedConversations, isEditing, chats.length]}
                        keyExtractor={item => item.chatId}
                        contentContainerStyle={[styles.listContent, { paddingTop: insets.top + 60 }]}
                        showsVerticalScrollIndicator={false}
                        onScroll={onScroll}
                        scrollEventThrottle={16}
                        refreshControl={
                            <RefreshControl refreshing={isPullRefreshing} onRefresh={handlePullRefresh} tintColor={colors.text} />
                        }
                        ListHeaderComponent={
                            <View>
                                <View style={{ paddingBottom: 4, paddingLeft: 10 }}>
                                    <StoryBar
                                        size="medium"
                                        onViewerOpen={handleOpenStoryViewer}
                                        onAddStoryPress={handleOpenStoryCamera}
                                        isMoving={false}
                                    />
                                </View>
                                {/* Search Bar (Natural version in ScrollView) */}
                                <Animated.View style={searchBarStyle} pointerEvents={isSearchActive ? 'none' : 'auto'}>
                                    <View
                                        style={{
                                            flexDirection: 'row',
                                            alignItems: 'center',
                                            backgroundColor: colors.input || colors.card,
                                            borderRadius: 22,
                                            height: 44,
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
                            </View>
                        }
                        ListFooterComponent={<View style={{ height: 100 + (Platform.OS === 'android' ? insets.bottom : 0) }} />}
                        ListEmptyComponent={
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
                                <Text style={[styles.emptyDescription, { color: withAlpha(colors.text, 0.6), marginTop: 20, marginBottom: 30 }]}>
                                    Waiting for a friend?
                                </Text>
                                <TouchableOpacity onPress={() => safePress('openMainMenuSearch', () => setShowMainMenu(true))} activeOpacity={0.8}>
                                    <View style={[styles.actionButton, { backgroundColor: colors.button?.background || colors.primary }]}>
                                        <Text style={{ color: colors.button?.text || '#ffffff', fontSize: 14, fontWeight: '500' }}>Start Vibing</Text>
                                    </View>
                                </TouchableOpacity>
                            </Animated.View>
                        }
                    />

                    {/* Chat Preview Modal */}
                    <ChatPreviewModal
                        visible={contextMenuVisible}
                        startLayout={chatLayout}
                        chat={selectedChat}
                        onClose={() => setContextMenuVisible(false)}
                        onPin={() => { if (selectedChat) pinChat(selectedChat.chatId); setContextMenuVisible(false); }}
                        onMute={() => { if (selectedChat) toggleMuteChat(selectedChat.chatId); setContextMenuVisible(false); }}
                        onDelete={() => { if (selectedChat) deleteChat(selectedChat.chatId); setContextMenuVisible(false); }}
                    />

                    {/* Editing Bottom Bar */}
                    {isEditing && (
                        <Animated.View
                            entering={FadeIn.duration(250)}
                            exiting={FadeOut.duration(200)}
                            style={[styles.bottomBarEdit, { bottom: insets.bottom + 0 }]}
                        >
                            <View style={styles.editActionsContainer}>
                                <SafeLiquidGlass style={styles.glassActionBtn} blurIntensity={20} effect="clear" tint={effectiveTheme === 'dark' ? 'dark' : 'light'}>
                                    <TouchableOpacity onPress={() => setSelectedConversations(new Set())} style={styles.actionBtnTouch}>
                                        <X size={24} color={colors.primary} />
                                    </TouchableOpacity>
                                </SafeLiquidGlass>

                                <SafeLiquidGlass
                                    style={[styles.glassActionBtn, { backgroundColor: withAlpha('#ef4444', 0.15) }]}
                                    blurIntensity={20}
                                    effect="clear"
                                    tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                >
                                    <TouchableOpacity onPress={() => {/* Delete logic */ }} style={styles.actionBtnTouch}>
                                        <Trash2 size={24} color="#ef4444" />
                                    </TouchableOpacity>
                                </SafeLiquidGlass>
                            </View>
                        </Animated.View>
                    )}

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
                <View style={{ flex: 1, backgroundColor: colors.background, paddingTop: insets.top + 60 }}>
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
                        height: '100%',
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
        paddingHorizontal: 16
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
    textBtnTouch: {
        height: '100%',
        justifyContent: 'center',
    },
    headerTextBtn: {
        fontSize: 15,
        fontWeight: '600'
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
        alignItems: 'center',
        justifyContent: 'center',
        flex: 1,
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

    bottomBarEdit: {
        position: 'absolute',
        left: 0,
        right: 0,
        height: 80,
        zIndex: 200,
        paddingHorizontal: 24,
        justifyContent: 'center',
    },
    editActionsContainer: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        width: '100%',
    },
    glassActionBtn: {
        width: 54,
        height: 54,
        borderRadius: 27,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center'
    },
    actionBtnTouch: {
        width: 54,
        height: 54,
        alignItems: 'center',
        justifyContent: 'center'
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
