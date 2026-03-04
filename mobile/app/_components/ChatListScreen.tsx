import React, { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import {
    View,
    Text,
    StyleSheet,

    Platform,
    InteractionManager,
    Pressable,
    Dimensions,
    Image,
    Keyboard,
} from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    useDerivedValue,
    withTiming,
    withSpring,
    withSequence,
    Easing,
    runOnJS,
    interpolate,
    Extrapolation,
    type SharedValue,
} from 'react-native-reanimated';
import { LinearGradient } from 'expo-linear-gradient';
import Svg, { Path } from 'react-native-svg';
import { useLocalSearchParams } from 'expo-router';
import * as ExpoCrypto from 'expo-crypto';
import { KeyboardStickyView, OverKeyboardView, useReanimatedKeyboardAnimation } from 'react-native-keyboard-controller';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import { Pin } from 'lucide-react-native';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';
import * as Clipboard from 'expo-clipboard';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { FlashList } from '@shopify/flash-list';

import { useChatStore } from '../../src/lib/ChatStore';
import { useAuthStore } from '../../src/lib/stores/auth-store';
import { useThemeStore } from '../../src/lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../../src/lib/stores/wallpaper-store';
import Input, { type EditInfo, type ReplyInfo } from '../../src/components/chat/input';
import {
    MessageBubbleBody,
    type BubbleMessageType,
    type BubbleStatus,
    type ChatListBubbleMessage,
} from '../../src/components/chat/bubbles';
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass';
import { type EmojiReactionFx } from '../../src/components/chat/EmojiReactionFxLayer';
import { useToastStore } from '../../src/lib/stores/toast-store';
import ReactionOverlays, { type ReactionFlyFx } from '../../src/components/chat/ReactionOverlays';
import ReactionMenu from '../../src/components/chat/menus/ReactionMenu';
import ContextActionMenu from '../../src/components/chat/menus/ContextActionMenu';
import GlobalPinnedBanner from '../../src/components/chat/GlobalPinnedBanner';
import {
    REACTION_PRESETS,
    resolveBubbleMenuItems,
    type BubbleMenuAction,
} from '../../src/components/chat/menus/menu-config';
import {
    getNativeChatEngineModule,
    getNativeChatRuntimeInfo,
    isNativeChatJsFallbackEnabled,
    mapMessagesToNativeRows,
    NativeChatSurface,
    type NativeChatAppearance,
    type NativeSendTransitionPayload,
    type NativeChatSurfaceRef,
} from '../../src/native/chat';

const MaskedViewAny = MaskedView as any;
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

const normalizeImageUri = (value?: string | null) => {
    if (!value) return null;
    if (
        value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('file://') ||
        value.startsWith('content://') ||
        value.startsWith('data:')
    ) {
        return value;
    }
    return `data:image/jpeg;base64,${value}`;
};


// Match your real theme colors
const BUBBLE_GRADIENT: [string, string] = ['#7C5CE0', '#6A4FCF'];
const INPUT_TEXT_COLOR = '#fff';
const BUBBLE_RADIUS = 18;
const BUBBLE_PADDING_V = 7;
const BUBBLE_PADDING_H = 10;
const BUBBLE_MIN_WIDTH = 26;
const TELEGRAM_BUBBLE_TRANSITION = {
    durationMs: 300,
    // Telegram iOS chat message transition curves.
    verticalCurve: Easing.bezier(
        0.19919472913616398,
        0.010644531250000006,
        0.27920937042459737,
        0.91025390625
    ),
    horizontalCurve: Easing.bezier(0.23, 1.0, 0.32, 1.0),
} as const;
const BUBBLE_TEXT_SIZE = 16;
const BUBBLE_TEXT_LINE_HEIGHT = 20;
const BUBBLE_TIME_SIZE = 10;
const BUBBLE_TIME_OPACITY = 0.7;
const BUBBLE_INNER_RADIUS = 5;
const MAX_RENDER_MESSAGES = 80;
const HYDRATE_DEBOUNCE_MS = 60;
const MENU_BASE_LIFT = 0;
const MENU_TOP_SAFE = 78;
const MENU_BOTTOM_SAFE = Platform.OS === 'ios' ? 176 : 160;
const SWIPE_REPLY_TRIGGER = 48;
const SWIPE_REPLY_MAX = 72;
const HOLD_MENU_DELAY_MS = 170;
const LIST_BOTTOM_THRESHOLD = 40;
const LIST_BOTTOM_AUTOSCROLL_THRESHOLD = 1;
const LIST_INITIAL_RENDER = 14;
const LIST_BATCH_RENDER = 10;
const LIST_WINDOW_SIZE = 7;
const BINARY_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EMPTY_LIST_ROWS: ListRow[] = [];
const EMPTY_SEQUENCE_META = new Map<string, { isSequenceStart: boolean; isSequenceEnd: boolean }>();
const CHATLIST_PERF_LOG = false;
const chatListPerfLog = (...args: any[]) => {
    if (!CHATLIST_PERF_LOG) return;
    console.log('[ChatListPerf]', ...args);
};

const isValidBinaryMessageId = (value?: string | null) => {
    if (!value || typeof value !== 'string') return false;
    return BINARY_ID_RE.test(value);
};

const normalizeMessageIdValue = (value: unknown): string | null => {
    if (typeof value === 'string') {
        const trimmed = value.trim();
        return trimmed.length > 0 ? trimmed : null;
    }
    if (typeof value === 'number' && Number.isFinite(value)) {
        return String(value);
    }
    return null;
};

const normalizeOptionalStringId = (value: unknown): string | undefined => {
    const normalized = normalizeMessageIdValue(value);
    return normalized || undefined;
};

interface BubbleThemeSpec {
    meGradient: [string, string];
    themSolid: string;
}

const tailBaseStyle = (isMe: boolean) => ({
    position: 'absolute' as const,
    bottom: 0,
    [isMe ? 'right' : 'left']: -28,
    width: 29,
    height: 29,
    zIndex: -1,
    transform: [
        { rotate: isMe ? '25deg' : '-25deg' },
        { scaleX: isMe ? 1 : -1 },
    ],
});

interface Message extends ChatListBubbleMessage {
    fromId?: string;
    encryptedContent?: string;
    replyToId?: string;
    isEdited?: boolean;
    editedAt?: number;
    errorMessage?: string;
    timestampMs: number;
    isGhostHidden?: boolean;
    isOptimistic?: boolean;
    reactionEmoji?: string;
}

interface BubbleRect {
    x: number;
    y: number;
    width: number;
    height: number;
}

interface ReactionSourcePoint {
    x: number;
    y: number;
}

type ListRow =
    | { kind: 'message'; key: string; message: Message }
    | { kind: 'day'; key: string; label: string };

type MessageType = BubbleMessageType;

interface BubbleShape {
    isMe: boolean;
    showTail: boolean;
    borderTopLeftRadius: number;
    borderTopRightRadius: number;
    borderBottomLeftRadius: number;
    borderBottomRightRadius: number;
}

interface QueuedSend {
    messageId: string;
    chatId: string;
    text: string;
    replyToId?: string;
}

interface CrossfadeOverlayProps {
    text: string;
    startX: number;
    startY: number;
    startWidth: number;
    startHeight: number;
    targetX: SharedValue<number>;
    targetY: SharedValue<number>;
    targetWidth: SharedValue<number>;
    targetHeight: SharedValue<number>;
    shape: BubbleShape;
    bubbleTheme: BubbleThemeSpec;
    onComplete: () => void;
}

const clampNumber = (value: number, min: number, max: number) => {
    return Math.max(min, Math.min(max, value));
};

const getReactionFlightDuration = (startX: number, startY: number, targetX: number, targetY: number) => {
    const distance = Math.hypot(targetX - startX, targetY - startY);
    return Math.round(clampNumber(260 + (distance * 0.33), 300, 440));
};

const resolveBubbleShape = (
    isMe: boolean,
    isSequenceStart: boolean,
    isSequenceEnd: boolean,
    messageType: MessageType = 'text',
): BubbleShape => {
    const shape: BubbleShape = {
        isMe,
        showTail: isSequenceEnd && messageType !== 'sticker',
        borderTopLeftRadius: BUBBLE_RADIUS,
        borderTopRightRadius: BUBBLE_RADIUS,
        borderBottomLeftRadius: BUBBLE_RADIUS,
        borderBottomRightRadius: BUBBLE_RADIUS,
    };

    if (isMe) {
        if (!isSequenceStart) shape.borderTopRightRadius = BUBBLE_INNER_RADIUS;
        if (!isSequenceEnd) shape.borderBottomRightRadius = BUBBLE_INNER_RADIUS;
    } else {
        if (!isSequenceStart) shape.borderTopLeftRadius = BUBBLE_INNER_RADIUS;
        if (!isSequenceEnd) shape.borderBottomLeftRadius = BUBBLE_INNER_RADIUS;
    }

    return shape;
};

const formatUiTime = (timestamp: number | string | undefined) => {
    const t = typeof timestamp === 'number' ? timestamp : new Date(timestamp || Date.now()).getTime();
    return new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
};

const toDayKey = (timestampMs: number) => {
    const d = new Date(timestampMs);
    return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
};

const sameCalendarDay = (aMs: number, bMs: number) => toDayKey(aMs) === toDayKey(bMs);

const formatDayLabel = (timestampMs: number) => {
    const date = new Date(timestampMs);
    const today = new Date();
    const yesterday = new Date();
    yesterday.setDate(today.getDate() - 1);

    if (sameCalendarDay(timestampMs, today.getTime())) return 'Today';
    if (sameCalendarDay(timestampMs, yesterday.getTime())) return 'Yesterday';
    return date.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' });
};

const normalizeMessageType = (rawType: any): BubbleMessageType => {
    const type = typeof rawType === 'string' ? rawType : 'text';
    if (
        type === 'text' ||
        type === 'image' ||
        type === 'video' ||
        type === 'voice' ||
        type === 'call' ||
        type === 'gif' ||
        type === 'file' ||
        type === 'location' ||
        type === 'music' ||
        type === 'sticker' ||
        type === 'contact'
    ) {
        return type;
    }
    return 'text';
};

const getStoreMessageText = (m: any, type: BubbleMessageType): string => {
    const text = m?.plaintext || m?.content || m?.text || '';
    if (typeof text === 'string' && text.trim().length > 0) return text;
    if (type === 'image' || type === 'video' || type === 'voice' || type === 'music' || type === 'sticker' || type === 'gif') return '';
    if (type === 'file') return m?.fileName || m?.file_name || '📎 File';
    if (type === 'location') {
        if (typeof m?.latitude === 'number' && typeof m?.longitude === 'number') {
            return `📍 ${m.latitude.toFixed(4)}, ${m.longitude.toFixed(4)}`;
        }
        return '📍 Location';
    }
    if (type === 'contact') return m?.contact?.username || m?.contact?.phoneNumber || '👤 Contact';
    if (type === 'call') return 'Call';
    return 'Message';
};

const sameRenderableMessage = (a: Message, b: Message) => (
    a.id === b.id &&
    a.type === b.type &&
    a.text === b.text &&
    a.timestamp === b.timestamp &&
    a.timestampMs === b.timestampMs &&
    a.isMe === b.isMe &&
    a.isGhostHidden === b.isGhostHidden &&
    a.isOptimistic === b.isOptimistic &&
    a.status === b.status &&
    a.mediaUrl === b.mediaUrl &&
    a.fileName === b.fileName &&
    a.fileSize === b.fileSize &&
    a.duration === b.duration &&
    a.latitude === b.latitude &&
    a.longitude === b.longitude &&
    a.caption === b.caption &&
    a.viewOnce === b.viewOnce &&
    (a.viewedBy?.length || 0) === (b.viewedBy?.length || 0) &&
    (a.viewedBy?.[0] || '') === (b.viewedBy?.[0] || '') &&
    (a.viewedBy?.[1] || '') === (b.viewedBy?.[1] || '') &&
    a.isVideoNote === b.isVideoNote &&
    a.contact?.id === b.contact?.id &&
    a.contact?.username === b.contact?.username &&
    a.contact?.phoneNumber === b.contact?.phoneNumber &&
    a.contact?.profileImage === b.contact?.profileImage &&
    a.extra?.width === b.extra?.width &&
    a.extra?.height === b.extra?.height &&
    a.reactionEmoji === b.reactionEmoji &&
    (a.extra?.waveform?.length || 0) === (b.extra?.waveform?.length || 0) &&
    (a.extra?.waveform?.[0] || 0) === (b.extra?.waveform?.[0] || 0) &&
    (a.extra?.waveform?.[4] || 0) === (b.extra?.waveform?.[4] || 0) &&
    (a.extra?.waveform?.[9] || 0) === (b.extra?.waveform?.[9] || 0)
);

const CrossfadeOverlay = ({
    text,
    timestamp,
    startX,
    startY,
    startWidth,
    startHeight,
    targetX,
    targetY,
    targetWidth,
    targetHeight,
    shape,
    bubbleTheme,
    onComplete,
}: CrossfadeOverlayProps & { timestamp: string }) => {
    // Telegram-style split curves: horizontal and vertical can differ.
    const verticalProgress = useSharedValue(0);
    const horizontalProgress = useSharedValue(0);

    // Using the same curve config as test-animation-basic.tsx
    useEffect(() => {
        horizontalProgress.value = withTiming(1, {
            duration: TELEGRAM_BUBBLE_TRANSITION.durationMs,
            easing: TELEGRAM_BUBBLE_TRANSITION.horizontalCurve,
        });
        verticalProgress.value = withTiming(1, {
            duration: TELEGRAM_BUBBLE_TRANSITION.durationMs,
            easing: TELEGRAM_BUBBLE_TRANSITION.verticalCurve,
        }, (finished) => {
            if (finished) {
                runOnJS(onComplete)();
            }
        });
    }, []);

    const containerStyle = useAnimatedStyle(() => {
        const px = horizontalProgress.value;
        const py = verticalProgress.value;

        const x = interpolate(px, [0, 1], [startX, targetX.value]);
        const y = interpolate(py, [0, 1], [startY, targetY.value]);
        const w = interpolate(px, [0, 1], [startWidth, targetWidth.value]);
        const h = interpolate(py, [0, 1], [startHeight, targetHeight.value]);

        return {
            position: 'absolute',
            left: x,
            top: y,
            width: w,
            height: h,
            zIndex: 9999,
        };
    });

    // Bubble background fades in
    const bgStyle = useAnimatedStyle(() => {
        const bgOpacity = interpolate(verticalProgress.value, [0, 0.1, 0.4], [0, 0, 1], Extrapolation.CLAMP);
        return {
            ...StyleSheet.absoluteFillObject,
            borderTopLeftRadius: shape.borderTopLeftRadius,
            borderTopRightRadius: shape.borderTopRightRadius,
            borderBottomLeftRadius: shape.borderBottomLeftRadius,
            borderBottomRightRadius: shape.borderBottomRightRadius,
            overflow: 'hidden',
            opacity: bgOpacity,
        };
    }, [shape]);

    // Input text fades out
    const inputTextStyle = useAnimatedStyle(() => {
        const opacity = interpolate(verticalProgress.value, [0, 0.2], [1, 0], Extrapolation.CLAMP);
        return { opacity };
    });

    // Bubble text + time fades in
    const bubbleContentStyle = useAnimatedStyle(() => {
        const opacity = interpolate(verticalProgress.value, [0.1, 0.4], [0, 1], Extrapolation.CLAMP);
        return { opacity };
    });
    const crossfadeTextItem = useMemo<ChatListBubbleMessage>(() => ({
        id: '__crossfade-overlay__',
        type: 'text',
        text,
        isMe: shape.isMe,
        timestamp,
        status: 'sending',
    }), [shape.isMe, text, timestamp]);

    return (
        <Animated.View style={containerStyle} pointerEvents="none">
            <Animated.View style={bgStyle}>
                {shape.isMe ? (
                    <LinearGradient
                        colors={bubbleTheme.meGradient}
                        start={{ x: 0, y: 0 }}
                        end={{ x: 1, y: 1 }}
                        style={StyleSheet.absoluteFillObject}
                    />
                ) : (
                    <View style={[StyleSheet.absoluteFillObject, { backgroundColor: bubbleTheme.themSolid }]} />
                )}
            </Animated.View>

            <View style={styles.crossfadeContent}>
                {/* Input-style text (fades out) */}
                <Animated.View
                    style={[{
                        position: 'absolute',
                        left: BUBBLE_PADDING_H,
                        top: BUBBLE_PADDING_V,
                        right: BUBBLE_PADDING_H,
                    }, inputTextStyle]}
                >
                    <Text style={styles.bubbleTextInput} numberOfLines={1}>{text}</Text>
                </Animated.View>

                {/* Bubble-style text (fades in) */}
                <Animated.View style={bubbleContentStyle}>
                    <MessageBubbleBody item={crossfadeTextItem} />
                </Animated.View>
            </View>

            {shape.showTail && (
                <View style={tailBaseStyle(shape.isMe)}>
                    <Svg width={29} height={29} viewBox="0 0 29 29">
                        <Path d="M0,0 Q-5,22 14,25 Q10.5,29 0,29 Z" fill={shape.isMe ? bubbleTheme.meGradient[1] : bubbleTheme.themSolid} />
                    </Svg>
                </View>
            )}
        </Animated.View>
    );
};

const MessageBubble = React.memo(({
    item,
    isSequenceStart,
    isSequenceEnd,
    bubbleTheme,
    onLayout,
    onMenuAction,
    onReactionSelect,
    reactionEmoji,
    reactionAvatarUri,
    reactionAvatarLabel,
    onHold,
    onReplySwipe,
    isMenuOpen,
    onMenuOpenChange,
    isPinned,
    isPinnedHighlight,
    isDeleting,
    onDeleteAnimationDone,
    ghostHiddenId,
}: {
    item: Message;
    isSequenceStart: boolean;
    isSequenceEnd: boolean;
    bubbleTheme: BubbleThemeSpec;
    onLayout?: (id: string, x: number, y: number, w: number, h: number, shape: BubbleShape) => void;
    onMenuAction?: (action: BubbleMenuAction, message: Message, rect?: BubbleRect) => void;
    onReactionSelect?: (emoji: string, message: Message, rect?: BubbleRect, sourcePoint?: ReactionSourcePoint) => void;
    reactionEmoji?: string;
    reactionAvatarUri?: string | null;
    reactionAvatarLabel?: string;
    onHold?: () => void;
    onReplySwipe?: (message: Message) => void;
    isMenuOpen?: boolean;
    onMenuOpenChange?: (open: boolean) => void;
    isPinned?: boolean;
    isPinnedHighlight?: boolean;
    isDeleting?: boolean;
    onDeleteAnimationDone?: (messageId: string) => void;
    ghostHiddenId: SharedValue<string>;
}) => {
    const bubbleRef = useRef<View>(null);
    const menuProgress = useSharedValue(isMenuOpen ? 1 : 0);
    const holdProgress = useSharedValue(0);
    const deleteProgress = useSharedValue(0);
    const [menuMounted, setMenuMounted] = useState(!!isMenuOpen);
    const [overlayRect, setOverlayRect] = useState<{ x: number; y: number; width: number; height: number } | null>(null);
    const [bubbleLiftTarget, setBubbleLiftTarget] = useState(0);
    const [bubbleRenderWidth, setBubbleRenderWidth] = useState(0);
    const closeUnmountTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const deleteStartedRef = useRef(false);
    const lastTapAtRef = useRef(0);
    const didLongPressRef = useRef(false);
    const swipeReplyTriggeredRef = useRef(false);
    const swipeReplyX = useSharedValue(0);
    const pinHighlightProgress = useSharedValue(0);
    const { effectiveTheme } = useThemeStore();
    const isLightMenu = effectiveTheme === 'light';
    const menuTint = isLightMenu ? 'light' : 'dark';
    const backdropTintColor = isLightMenu ? withAlpha('#eef3ff', 0.66) : withAlpha('#03060d', 0.8);
    const actionTextColor = isLightMenu ? withAlpha('#1a2030', 0.94) : withAlpha('#f7f8ff', 0.97);
    const reactionChipColor = isLightMenu ? withAlpha(bubbleTheme.meGradient[0], 0.12) : withAlpha('#ffffff', 0.12);
    const pinGlowColor = withAlpha('#f8d26f', 0.95);
    const extractedProgress = useDerivedValue(() => {
        return Math.max(menuProgress.value, holdProgress.value);
    });
    const isGhostHidden = item.isGhostHidden === true;
    const ghostHiddenStyle = useAnimatedStyle(() => {
        if (!isGhostHidden) return { opacity: 1 };
        // When ghostHiddenId matches, bubble stays hidden (ghost overlay is animating).
        // When ghostHiddenId clears, bubble reveals instantly on UI thread.
        return { opacity: ghostHiddenId.value === item.id ? 0 : 1 };
    }, [isGhostHidden, item.id]);
    const shape = useMemo(
        () => resolveBubbleShape(item.isMe, isSequenceStart, isSequenceEnd, item.type),
        [item.isMe, isSequenceStart, isSequenceEnd, item.type]
    );
    const mediaOnly = (
        (item.type === 'image' || item.type === 'video' || item.type === 'gif' || item.type === 'sticker')
        && !item.text?.trim()
    );
    const shouldShowTail = shape.showTail && !mediaOnly;
    const menuItems = useMemo(() => resolveBubbleMenuItems({
        isMine: item.isMe,
        hasText: !!item.text?.trim(),
        isPinned: !!isPinned,
        hasError: item.isMe && item.status === 'error',
    }), [item.isMe, item.status, item.text, isPinned]);
    const estimatedMenuHeight = useMemo(() => {
        const dividerHeight = menuItems.reduce((acc, menuItem) => acc + (menuItem.dividerBefore ? 9 : 0), 0);
        return 24 + (menuItems.length * 40) + dividerHeight;
    }, [menuItems]);

    const applyMenuGeometry = useCallback((y: number, h: number) => {
        const screenHeight = Dimensions.get('window').height;
        const screenTop = MENU_TOP_SAFE;
        const screenBottom = screenHeight - MENU_BOTTOM_SAFE;
        const actionBottom = y + h + 12 + estimatedMenuHeight;
        const neededUpShift = Math.max(0, actionBottom - screenBottom);
        const maxUpShift = Math.max(0, y - (screenTop - 8));
        const safeUpShift = Math.min(neededUpShift, maxUpShift);
        const translateY = -Math.max(MENU_BASE_LIFT, safeUpShift);

        setBubbleLiftTarget((prev) => (Math.abs(prev - translateY) < 0.5 ? prev : translateY));
    }, [estimatedMenuHeight]);

    const updateMenuGeometry = useCallback(() => {
        bubbleRef.current?.measureInWindow((x, y, w, h) => {
            if (h <= 0 || w <= 0) return;
            setOverlayRect({ x, y, width: w, height: h });
            applyMenuGeometry(y, h);
        });
    }, [applyMenuGeometry]);

    useEffect(() => {
        if (closeUnmountTimerRef.current) {
            clearTimeout(closeUnmountTimerRef.current);
            closeUnmountTimerRef.current = null;
        }

        if (!isMenuOpen && !menuMounted) {
            holdProgress.value = 0;
            menuProgress.value = 0;
            return;
        }

        if (isMenuOpen) {
            setMenuMounted(true);
        }

        if (isMenuOpen) {
            holdProgress.value = 1;
            menuProgress.value = withSpring(1, {
                damping: 24,
                stiffness: 280,
                mass: 0.62,
                overshootClamping: true,
            });
        } else {
            holdProgress.value = withTiming(0, {
                duration: 130,
                easing: Easing.out(Easing.quad),
            });
            menuProgress.value = withTiming(0, {
                duration: 190,
                easing: Easing.out(Easing.quad),
            });
        }

        if (!isMenuOpen) {
            if (menuMounted) {
                closeUnmountTimerRef.current = setTimeout(() => {
                    setMenuMounted(false);
                    setOverlayRect(null);
                }, 200);
            }
        }
    }, [isMenuOpen, menuMounted, menuProgress, holdProgress]);

    useEffect(() => () => {
        if (!closeUnmountTimerRef.current) return;
        clearTimeout(closeUnmountTimerRef.current);
        closeUnmountTimerRef.current = null;
    }, []);

    useEffect(() => {
        if (!isDeleting) {
            deleteStartedRef.current = false;
            deleteProgress.value = 0;
            return;
        }
        if (menuMounted) return;
        if (deleteStartedRef.current) return;
        deleteStartedRef.current = true;
        deleteProgress.value = withTiming(1, {
            duration: 340,
            easing: Easing.out(Easing.cubic),
        }, (finished) => {
            if (!finished) return;
            if (onDeleteAnimationDone) {
                runOnJS(onDeleteAnimationDone)(item.id);
            }
        });
    }, [isDeleting, menuMounted, deleteProgress, onDeleteAnimationDone, item.id]);

    useEffect(() => {
        if (!isPinnedHighlight) {
            pinHighlightProgress.value = withTiming(0, { duration: 200, easing: Easing.out(Easing.quad) });
            return;
        }
        pinHighlightProgress.value = 0;
        pinHighlightProgress.value = withSequence(
            withTiming(1, { duration: 240, easing: Easing.out(Easing.cubic) }),
            withTiming(0, { duration: 700, easing: Easing.inOut(Easing.quad) })
        );
    }, [isPinnedHighlight, pinHighlightProgress]);

    useEffect(() => {
        if (!menuMounted) {
            setBubbleLiftTarget(0);
            return;
        }
        const firstPass = setTimeout(updateMenuGeometry, 16);
        const settlePass = setTimeout(updateMenuGeometry, 130);
        return () => {
            clearTimeout(firstPass);
            clearTimeout(settlePass);
        };
    }, [menuMounted, isMenuOpen, updateMenuGeometry]);

    useEffect(() => {
        if (!item.isGhostHidden || !onLayout) return;
        const timer = setTimeout(() => {
            bubbleRef.current?.measureInWindow((x, y, w, h) => {
                if (w > 0 && h > 0) onLayout(item.id, x, y, w, h, shape);
            });
        }, 50);
        return () => clearTimeout(timer);
    }, [item.isGhostHidden, item.id, onLayout, shape]);

    const bubbleLiftStyle = useAnimatedStyle(() => ({
        transform: [
            { scale: interpolate(extractedProgress.value, [0, 1], [1, 0.965], Extrapolation.CLAMP) },
            { translateY: interpolate(extractedProgress.value, [0, 1], [0, bubbleLiftTarget], Extrapolation.CLAMP) },
        ],
    }), [bubbleLiftTarget]);

    const inlineHoldStyle = useAnimatedStyle(() => ({
        transform: [
            { scale: interpolate(holdProgress.value, [0, 1], [1, 0.972], Extrapolation.CLAMP) },
        ],
    }));

    const swipeReplyStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: swipeReplyX.value }],
    }));

    const pinnedPulseStyle = useAnimatedStyle(() => ({
        shadowOpacity: interpolate(pinHighlightProgress.value, [0, 1], [0, 0.5], Extrapolation.CLAMP),
        shadowRadius: interpolate(pinHighlightProgress.value, [0, 1], [0, 18], Extrapolation.CLAMP),
        shadowColor: pinGlowColor,
        transform: [
            { scale: 1 + (pinHighlightProgress.value * 0.03) },
        ],
    }), [pinGlowColor]);

    const reactionMenuStyle = useAnimatedStyle(() => ({
        opacity: menuProgress.value,
        transform: [
            { translateY: interpolate(menuProgress.value, [0, 1], [10, 0]) },
        ],
    }));

    const actionMenuStyle = useAnimatedStyle(() => ({
        opacity: menuProgress.value,
        transform: [
            { translateY: interpolate(menuProgress.value, [0, 1], [12, 0]) },
        ],
    }));

    const backdropStyle = useAnimatedStyle(() => ({
        opacity: menuProgress.value,
    }));

    const deleteClipStyle = useAnimatedStyle(() => ({
        width: bubbleRenderWidth > 0
            ? interpolate(deleteProgress.value, [0, 1], [bubbleRenderWidth, 0], Extrapolation.CLAMP)
            : undefined,
        opacity: interpolate(deleteProgress.value, [0, 0.8, 1], [1, 0.88, 0], Extrapolation.CLAMP),
        transform: [{ translateX: interpolate(deleteProgress.value, [0, 1], [0, 12], Extrapolation.CLAMP) }],
    }), [bubbleRenderWidth]);

    const deleteWaterSweepStyle = useAnimatedStyle(() => {
        const startX = Math.max(0, bubbleRenderWidth - 28);
        const endX = -16;
        return {
            opacity: interpolate(deleteProgress.value, [0, 0.08, 0.9, 1], [0, 0.58, 0.2, 0], Extrapolation.CLAMP),
            transform: [
                { translateX: interpolate(deleteProgress.value, [0, 1], [startX, endX], Extrapolation.CLAMP) },
            ],
        };
    }, [bubbleRenderWidth]);

    const closeMenu = useCallback((_source: 'backdrop' | 'request-close' | 'action' = 'backdrop') => {
        onMenuOpenChange?.(false);
    }, [onMenuOpenChange]);

    const handleMenuSelect = useCallback((action: BubbleMenuAction) => {
        onMenuAction?.(action, item, overlayRect || undefined);
        closeMenu('action');
    }, [closeMenu, onMenuAction, item, overlayRect]);

    const handleLongPressOpen = useCallback(() => {
        if (isDeleting) return;
        if (item.isGhostHidden) return;
        didLongPressRef.current = true;
        holdProgress.value = 1;
        bubbleRef.current?.measureInWindow((x, y, w, h) => {
            if (w <= 0 || h <= 0) return;
            setOverlayRect({ x, y, width: w, height: h });
            applyMenuGeometry(y, h);
            onHold?.();
            requestAnimationFrame(() => {
                onMenuOpenChange?.(true);
            });
        });
    }, [isDeleting, item.isGhostHidden, applyMenuGeometry, onHold, onMenuOpenChange, holdProgress]);

    const triggerReplyFromSwipe = useCallback(() => {
        if (isDeleting || item.isGhostHidden) return;
        onReplySwipe?.(item);
    }, [isDeleting, item, onReplySwipe]);

    const swipeReplyGesture = useMemo(() => (
        Gesture.Pan()
            .enabled(!menuMounted && !isDeleting && !item.isGhostHidden && !isMenuOpen)
            .activeOffsetX(item.isMe ? [-999, -12] : [12, 999])
            .failOffsetY([-16, 16])
            .onBegin(() => {
                swipeReplyTriggeredRef.current = false;
                swipeReplyX.value = 0;
            })
            .onUpdate((event) => {
                const directionalTranslation = event.translationX * (item.isMe ? -1 : 1);
                const clamped = Math.max(0, Math.min(SWIPE_REPLY_MAX, directionalTranslation));
                swipeReplyX.value = clamped * (item.isMe ? -1 : 1);
            })
            .onEnd((event) => {
                const directionalTranslation = event.translationX * (item.isMe ? -1 : 1);
                if (directionalTranslation < SWIPE_REPLY_TRIGGER) return;
                if (swipeReplyTriggeredRef.current) return;
                swipeReplyTriggeredRef.current = true;
                if (onHold) {
                    runOnJS(onHold)();
                }
                runOnJS(triggerReplyFromSwipe)();
            })
            .onFinalize(() => {
                swipeReplyX.value = withSpring(0, {
                    damping: 18,
                    stiffness: 260,
                    mass: 0.55,
                    overshootClamping: false,
                });
            })
    ), [menuMounted, isDeleting, item.isGhostHidden, isMenuOpen, item.isMe, onHold, triggerReplyFromSwipe, swipeReplyX]);

    const renderBubbleCore = (forOverlay: boolean) => {
        const reactionInset = reactionEmoji ? 22 : 0;
        return (
            <Pressable
                delayLongPress={HOLD_MENU_DELAY_MS}
                onPressIn={forOverlay || isDeleting ? undefined : () => {
                    didLongPressRef.current = false;
                    holdProgress.value = withTiming(1, {
                        duration: 170,
                        easing: Easing.out(Easing.cubic),
                    });
                }}
                onPressOut={forOverlay || isDeleting ? undefined : () => {
                    if (menuMounted) return;
                    if (didLongPressRef.current) return;
                    holdProgress.value = withTiming(0, {
                        duration: 110,
                        easing: Easing.out(Easing.quad),
                    });
                }}
                onLongPress={forOverlay || isDeleting ? undefined : handleLongPressOpen}
                onPress={forOverlay || isDeleting ? undefined : (event) => {
                    if (!menuMounted && !didLongPressRef.current) {
                        holdProgress.value = withTiming(0, {
                            duration: 110,
                            easing: Easing.out(Easing.quad),
                        });
                    }
                    if (item.isGhostHidden) return;
                    const now = Date.now();
                    if ((now - lastTapAtRef.current) <= 260) {
                        lastTapAtRef.current = 0;
                        const nextEmoji = reactionEmoji === '❤️' ? '👍' : '❤️';
                        bubbleRef.current?.measureInWindow((x, y, w, h) => {
                            if (w <= 0 || h <= 0) return;
                            onReactionSelect?.(
                                nextEmoji,
                                item,
                                { x, y, width: w, height: h },
                                { x: event.nativeEvent.pageX, y: event.nativeEvent.pageY }
                            );
                        });
                        return;
                    }
                    lastTapAtRef.current = now;
                }}
                style={styles.menuTouchArea}
            >
                <View style={styles.messageContainer}>
                    {mediaOnly ? (
                        <View style={[styles.mediaOnlyBubble, reactionInset > 0 && { paddingBottom: reactionInset }]}>
                            <MessageBubbleBody item={item} />
                        </View>
                    ) : item.isMe ? (
                        <LinearGradient
                            colors={bubbleTheme.meGradient}
                            start={{ x: 0, y: 0 }}
                            end={{ x: 1, y: 1 }}
                            style={[
                                styles.bubble,
                                {
                                    borderTopLeftRadius: shape.borderTopLeftRadius,
                                    borderTopRightRadius: shape.borderTopRightRadius,
                                    borderBottomLeftRadius: shape.borderBottomLeftRadius,
                                    borderBottomRightRadius: shape.borderBottomRightRadius,
                                    paddingTop: BUBBLE_PADDING_V,
                                    paddingHorizontal: BUBBLE_PADDING_H,
                                    paddingBottom: BUBBLE_PADDING_V + reactionInset,
                                    minWidth: BUBBLE_MIN_WIDTH,
                                    overflow: 'hidden',
                                },
                            ]}
                        >
                            <MessageBubbleBody item={item} />
                        </LinearGradient>
                    ) : (
                        <View
                            style={[
                                styles.bubble,
                                {
                                    backgroundColor: bubbleTheme.themSolid,
                                    borderTopLeftRadius: shape.borderTopLeftRadius,
                                    borderTopRightRadius: shape.borderTopRightRadius,
                                    borderBottomLeftRadius: shape.borderBottomLeftRadius,
                                    borderBottomRightRadius: shape.borderBottomRightRadius,
                                    paddingTop: BUBBLE_PADDING_V,
                                    paddingHorizontal: BUBBLE_PADDING_H,
                                    paddingBottom: BUBBLE_PADDING_V + reactionInset,
                                    minWidth: BUBBLE_MIN_WIDTH,
                                    overflow: 'hidden',
                                },
                            ]}
                        >
                            <MessageBubbleBody item={item} />
                        </View>
                    )}

                    {shouldShowTail && (
                        <View style={tailBaseStyle(item.isMe)}>
                            <Svg width={29} height={29} viewBox="0 0 29 29">
                                <Path d="M0,0 Q-5,22 14,25 Q10.5,29 0,29 Z" fill={item.isMe ? bubbleTheme.meGradient[1] : bubbleTheme.themSolid} />
                            </Svg>
                        </View>
                    )}

                    {!!reactionEmoji && (
                        <View style={styles.reactionBadge}>
                            <Text style={styles.reactionBadgeText}>{reactionEmoji}</Text>
                            {reactionAvatarUri ? (
                                <Image
                                    source={{ uri: reactionAvatarUri }}
                                    style={styles.reactionBadgeAvatar}
                                />
                            ) : (
                                <View style={styles.reactionBadgeAvatarFallback}>
                                    <Text style={styles.reactionBadgeAvatarInitial}>
                                        {reactionAvatarLabel || 'U'}
                                    </Text>
                                </View>
                            )}
                        </View>
                    )}

                    {!!isPinned && (
                        <View style={styles.pinBadge}>
                            <Pin size={10} color={withAlpha('#f4b83a', 0.96)} strokeWidth={2.5} />
                        </View>
                    )}
                </View>
            </Pressable>
        );
    };

    return (
        <Animated.View
            ref={bubbleRef}
            style={[
                styles.bubbleWrapper,
                { alignSelf: item.isMe ? 'flex-end' : 'flex-start', marginHorizontal: 8 },
                isGhostHidden && { opacity: 0 },
                ghostHiddenStyle,
                menuMounted && styles.bubbleWrapperMenuOpen,
            ]}
        >
            <GestureDetector gesture={swipeReplyGesture}>
                <Animated.View style={swipeReplyStyle}>
                    <Animated.View
                        style={[
                            styles.bubbleLiftLayer,
                            !menuMounted && inlineHoldStyle,
                            isPinnedHighlight && pinnedPulseStyle,
                            isDeleting && styles.deleteClipHost,
                            isDeleting && deleteClipStyle,
                            menuMounted && styles.inlineBubbleHidden,
                        ]}
                        onLayout={(event) => {
                            const nextWidth = Math.max(0, event.nativeEvent.layout.width);
                            if (Math.abs(nextWidth - bubbleRenderWidth) < 0.5) return;
                            setBubbleRenderWidth(nextWidth);
                        }}
                        pointerEvents={menuMounted || isDeleting ? 'none' : 'auto'}
                    >
                        {renderBubbleCore(false)}
                        {isDeleting && (
                            <Animated.View pointerEvents="none" style={[styles.deleteWaterSweep, deleteWaterSweepStyle]} />
                        )}
                    </Animated.View>
                </Animated.View>
            </GestureDetector>

            {menuMounted && overlayRect && (
                <OverKeyboardView visible={menuMounted}>
                    <View style={styles.menuModalRoot} pointerEvents="box-none">
                        <Pressable
                            style={StyleSheet.absoluteFill}
                            onPress={() => {
                                closeMenu('backdrop');
                            }}
                        >
                            <Animated.View style={[StyleSheet.absoluteFill, backdropStyle]}>
                                <BlurView tint={menuTint as any} intensity={58} style={StyleSheet.absoluteFill} />
                                <View style={[styles.menuBackdropTint, { backgroundColor: backdropTintColor }]} />
                            </Animated.View>
                        </Pressable>

                        <Animated.View
                            style={[
                                styles.overlayLiftHost,
                                {
                                    left: overlayRect.x,
                                    top: overlayRect.y,
                                    width: overlayRect.width,
                                },
                                bubbleLiftStyle,
                            ]}
                        >
                            {renderBubbleCore(true)}

                            <Animated.View
                                style={[
                                    styles.reactionMenuWrap,
                                    styles.reactionMenuWrapAbove,
                                    item.isMe ? styles.reactionMenuWrapMe : styles.reactionMenuWrapThem,
                                    reactionMenuStyle,
                                ]}
                            >
                                <ReactionMenu
                                    tint={menuTint as any}
                                    blurIntensity={20}
                                    presets={REACTION_PRESETS}
                                    chipColor={reactionChipColor}
                                    onSelect={(emoji, sourcePoint) => {
                                        onReactionSelect?.(
                                            emoji,
                                            item,
                                            overlayRect || undefined,
                                            sourcePoint
                                        );
                                        closeMenu('action');
                                    }}
                                />
                            </Animated.View>

                            <Animated.View
                                style={[
                                    styles.actionMenuWrapBelow,
                                    item.isMe ? styles.actionMenuWrapMe : styles.actionMenuWrapThem,
                                    actionMenuStyle,
                                ]}
                            >
                                <ContextActionMenu
                                    tint={menuTint as any}
                                    blurIntensity={22}
                                    items={menuItems}
                                    textColor={actionTextColor}
                                    destructiveColor="#ff5c4d"
                                    pinActiveColor={withAlpha('#f4b83a', 0.14)}
                                    onSelect={handleMenuSelect}
                                />
                            </Animated.View>
                        </Animated.View>
                    </View>
                </OverKeyboardView>
            )}
        </Animated.View>
    );
}, (prev, next) => (
    prev.isSequenceStart === next.isSequenceStart &&
    prev.isSequenceEnd === next.isSequenceEnd &&
    prev.isMenuOpen === next.isMenuOpen &&
    prev.isPinned === next.isPinned &&
    prev.isPinnedHighlight === next.isPinnedHighlight &&
    prev.isDeleting === next.isDeleting &&
    prev.reactionEmoji === next.reactionEmoji &&
    prev.reactionAvatarUri === next.reactionAvatarUri &&
    prev.reactionAvatarLabel === next.reactionAvatarLabel &&
    sameRenderableMessage(prev.item, next.item)
));

const DateDivider = React.memo(({ label }: { label: string }) => (
    <View style={styles.dayDividerWrap}>
        <View style={styles.dayDividerPill}>
            <Text style={styles.dayDividerText}>{label}</Text>
        </View>
    </View>
));

interface ChatListScreenProps {
    forceNativeOnly?: boolean;
    onTypingStatusChange?: (isTyping: boolean) => void;
    onReplySwipeHaptic?: () => void;
    ListHeaderComponent?: React.ComponentType<any> | React.ReactElement | null;
    searchQuery?: string;
    topContentOffset?: number;
    onVideoNoteStart?: () => void;
    onVideoNoteStop?: (canceled: boolean) => void;
    incomingVideoNote?: { uri: string; duration?: number; token: number } | null;
    onIncomingVideoNoteConsumed?: () => void;
    onRecordingUiChange?: (state: {
        isRecording: boolean;
        isLocked: boolean;
        mode: 'voice' | 'video';
        vad: number;
    }) => void;
}

export default function ChatListScreen({
    forceNativeOnly = false,
    onTypingStatusChange,
    onReplySwipeHaptic,
    ListHeaderComponent,
    searchQuery = '',
    topContentOffset = 0,
    onVideoNoteStart,
    onVideoNoteStop,
    incomingVideoNote,
    onIncomingVideoNoteConsumed,
    onRecordingUiChange,
}: ChatListScreenProps) {
    const params = useLocalSearchParams();
    const insets = useSafeAreaInsets();
    const { user } = useAuthStore();
    const chats = useChatStore(s => s.chats);
    const activeChatId = useChatStore(s => s.activeChatId);
    const setActiveChat = useChatStore(s => s.setActiveChat);
    const loadMessages = useChatStore(s => s.loadMessages);
    const sendMessage = useChatStore(s => s.sendMessage);
    const editMessage = useChatStore(s => s.editMessage);
    const retryMessage = useChatStore(s => s.retryMessage);
    const deleteFailedMessage = useChatStore(s => s.deleteFailedMessage);
    const isConnected = useChatStore(s => s.isConnected);
    const onlineUsers = useChatStore(s => s.onlineUsers);
    const uploadProgressById = useChatStore(s => s.uploadProgress);
    const { colors, effectiveTheme } = useThemeStore();
    const { activeTheme } = useWallpaperStore();
    const isIOS = Platform.OS === 'ios';
    const inputVerticalPadding = isIOS ? 3 : 6;
    const androidBottomSafeInset = isIOS ? 0 : Math.max(0, insets.bottom);
    // Some Android devices report a very small/zero bottom inset in chat layouts.
    // Keep the composer lifted above the gesture area with a stable floor.
    const bottomInsetPadding = isIOS
        ? Math.min(insets.bottom, 80)
        : Math.max(22, androidBottomSafeInset + 10);
    const androidKeyboardOpenBottomInsetPadding = isIOS
        ? 0
        : Math.max(10, Math.min(14, androidBottomSafeInset + 2));
    const footerHeight = (isIOS ? 43 : 48) + bottomInsetPadding + inputVerticalPadding * 2;
    const listBottomPadding = footerHeight + (isIOS ? 0 : 8);
    const listTopPadding = 10 + Math.max(0, topContentOffset);
    const nativeAndroidHeaderReserve = Platform.OS === 'android' ? (insets.top + 68) : 0;
    const jsListTopPadding = listTopPadding + nativeAndroidHeaderReserve;
    const nativeListTopPadding = listTopPadding + nativeAndroidHeaderReserve;
    const footerMaskHeight = footerHeight + (isIOS ? 34 : 52);
    const keyboardStickyOffset = Platform.OS === 'android'
        ? {
            opened: 10,
            closed: 18,
        }
        : {
            opened: 20,
            closed: 10,
        };

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
    const bubbleTheme = useMemo<BubbleThemeSpec>(() => ({
        meGradient: (
            resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2
                ? [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]]
                : BUBBLE_GRADIENT
        ) as [string, string],
        themSolid: (
            resolvedTheme.bubbleThemGradient && resolvedTheme.bubbleThemGradient.length > 0
                ? resolvedTheme.bubbleThemGradient[0]
                : (resolvedTheme.bubbleThem || '#2a2a4a')
        ),
    }), [resolvedTheme]);
    const nativeAppearance = useMemo<NativeChatAppearance>(() => ({
        // Native list now resolves and renders its own wallpaper/mask.
        backgroundMode: 'gradient',
        nativeThemeId: activeTheme?.id,
        nativeThemeIsDark: effectiveTheme === 'dark',
        wallpaperGradient: (resolvedTheme.backgroundGradient || [colors.background, colors.background]).slice(0, 3),
        wallpaperOpacity: 1,
        wallpaperPatternGradient: resolvedTheme.patternGradientColors?.slice(0, 6),
        wallpaperPatternLocations: resolvedTheme.patternGradientLocations?.slice(0, 6),
        wallpaperPatternOpacity: resolvedTheme.patternOpacity,
        wallpaperMaskKey: resolvedTheme.maskedImage || activeTheme?.maskedImage,
        bubbleMeGradient: [...bubbleTheme.meGradient],
        bubbleThemColor: bubbleTheme.themSolid,
        textColorMe: resolvedTheme.textColorMe || '#FFFFFF',
        textColorThem: resolvedTheme.textColorThem || '#DDDDDD',
        timeColorMe: withAlpha(resolvedTheme.textColorMe || '#FFFFFF', 0.72),
        timeColorThem: withAlpha(resolvedTheme.textColorThem || '#FFFFFF', 0.5),
        dayTextColor: withAlpha(resolvedTheme.textColorThem || '#ECEFFF', 0.82),
        dayBackgroundColor: withAlpha(resolvedTheme.backgroundGradient?.[0] || colors.background, 0.42),
        dayBorderColor: withAlpha('#FFFFFF', 0.16),
    }), [resolvedTheme, colors.background, bubbleTheme, activeTheme?.id, activeTheme?.maskedImage, effectiveTheme]);
    const reactionAvatarUri = useMemo(
        () => normalizeImageUri(user?.profileImage || null),
        [user?.profileImage]
    );
    const reactionAvatarLabel = useMemo(() => {
        const base = (user?.name || user?.username || 'U').trim();
        return base.length > 0 ? base[0].toUpperCase() : 'U';
    }, [user?.name, user?.username]);

    const chatIdFromParams = getParamString(params?.id) || getParamString((params as any)?.chatId);
    const effectiveChatId = chatIdFromParams || activeChatId || chats[0]?.chatId || null;
    const activeChat = useMemo(
        () => chats.find((c) => c.chatId === effectiveChatId),
        [chats, effectiveChatId]
    );
    const activeChatMessages = activeChat?.messages;
    const nativeChatRuntime = useMemo(() => getNativeChatRuntimeInfo(), []);
    const nativeChatSupported = !!(nativeChatRuntime.moduleAvailable && nativeChatRuntime.listModuleAvailable && !nativeChatRuntime.isExpoGo);
    const nativeChatEnabled = forceNativeOnly ? nativeChatSupported : nativeChatRuntime.enabled;
    const shouldUseNativeList = nativeChatEnabled;
    const nativeChatJsFallbackEnabled = useMemo(() => isNativeChatJsFallbackEnabled(), []);
    const normalizedSearchQuery = useMemo(() => searchQuery.trim().toLowerCase(), [searchQuery]);
    const searchActive = !shouldUseNativeList && normalizedSearchQuery.length > 0;
    const nativeSurfaceId = useMemo(
        () => `chat-surface-${effectiveChatId || 'none'}`,
        [effectiveChatId]
    );

    const [messages, setMessages] = useState<Message[]>([]);
    const [text, setText] = useState('');
    const [replyTo, setReplyTo] = useState<ReplyInfo | null>(null);
    const [editTarget, setEditTarget] = useState<EditInfo | null>(null);
    const [pinnedMessageIds, setPinnedMessageIds] = useState<string[]>([]);
    const [activePinnedIndex, setActivePinnedIndex] = useState(0);
    const [highlightedPinnedMessageId, setHighlightedPinnedMessageId] = useState<string | null>(null);
    const [activeMenuId, setActiveMenuId] = useState<string | null>(null);
    const [reactionFxList, setReactionFxList] = useState<EmojiReactionFx[]>([]);
    const [reactionFlyFx, setReactionFlyFx] = useState<ReactionFlyFx | null>(null);
    const [deletingMessageIds, setDeletingMessageIds] = useState<Record<string, true>>({});
    const [inputFocusTrigger, setInputFocusTrigger] = useState(0);

    const flatListRef = useRef<FlashList<ListRow>>(null);
    const nativeSurfaceRef = useRef<NativeChatSurfaceRef>(null);
    const inputBarRef = useRef<View>(null);
    const keyboardVisibleRef = useRef(false);
    const restoreKeyboardOnMenuCloseRef = useRef(false);
    const { height: keyboardHeight, progress: keyboardProgress } = useReanimatedKeyboardAnimation();
    const queuedSendsRef = useRef<Map<string, QueuedSend>>(new Map());
    const queuedTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());
    const recoveryTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());
    const recoveryAttemptedRef = useRef<Set<string>>(new Set());
    const nativeSendInFlightRef = useRef<Set<string>>(new Set());
    const nativeSendRecentlyHandledRef = useRef<Map<string, number>>(new Map());
    const reactionCommitTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());
    const deletingMessageIdsRef = useRef<Set<string>>(new Set());
    const deletedMessageIdsRef = useRef<Set<string>>(new Set());
    const pendingDeletePayloadRef = useRef<Map<string, { message: Message; chatId: string }>>(new Map());
    const listMetricsRef = useRef({
        contentHeight: 0,
        layoutHeight: 0,
        offsetY: 0,
    });
    const fallbackScrollOffsetYRef = useRef(0);
    const nativeRecordingStateRef = useRef<{
        isRecording: boolean;
        isLocked: boolean;
        mode: 'voice' | 'video';
        vad: number;
    }>({
        isRecording: false,
        isLocked: false,
        mode: 'voice',
        vad: 0,
    });

    // Matches test-animation-basic.tsx flow
    const ghostTargetX = useSharedValue(0);
    const ghostTargetY = useSharedValue(0);
    const ghostTargetWidth = useSharedValue(0);
    const ghostTargetHeight = useSharedValue(0);
    const ghostHiddenId = useSharedValue('');
    const activeGhostMessageIdRef = useRef<string | null>(null);

    const [ghostData, setGhostData] = useState<{
        text: string;
        timestamp: string;
        startX: number;
        startY: number;
        startWidth: number;
        startHeight: number;
        // Targets are now shared values
        shape: BubbleShape;
        messageId: string;
    } | null>(null);

    useEffect(() => {
        activeGhostMessageIdRef.current = ghostData?.messageId ?? null;
    }, [ghostData]);

    const [pendingGhost, setPendingGhost] = useState<{
        text: string;
        timestamp: string;
        startX: number;
        startY: number;
        startWidth: number;
        startHeight: number;
        messageId: string;
    } | null>(null);

    const sendDebug = useCallback((...args: unknown[]) => {
        if (!__DEV__) return;
        // Opt-in verbose chatlist logs only.
        // Enable dynamically in dev with: global.__VIBE_CHATLIST_DEBUG = true
        if ((globalThis as any).__VIBE_CHATLIST_DEBUG !== true) return;
        console.log('[ChatList][SendDebug]', ...args);
    }, []);

    const extractNativePayload = useCallback((event: unknown): Record<string, unknown> => {
        if (!event || typeof event !== 'object') return {};
        const record = event as Record<string, unknown>;
        const nested = record.nativeEvent;
        if (nested && typeof nested === 'object' && !Array.isArray(nested)) {
            return nested as Record<string, unknown>;
        }
        return record;
    }, []);

    const handleNativeViewportChanged = useCallback((event: { nativeEvent: Record<string, unknown> }) => {
        const nativeEvent = extractNativePayload(event);
        const contentHeight = Number(nativeEvent.contentHeight || 0);
        const layoutHeight = Number(nativeEvent.layoutHeight || 0);
        const offsetY = Number(nativeEvent.offsetY || 0);

        listMetricsRef.current.contentHeight = Number.isFinite(contentHeight) ? contentHeight : 0;
        listMetricsRef.current.layoutHeight = Number.isFinite(layoutHeight) ? layoutHeight : 0;
        listMetricsRef.current.offsetY = Number.isFinite(offsetY) ? offsetY : 0;
    }, [extractNativePayload]);

    useEffect(() => {
        if (chatIdFromParams && chatIdFromParams !== activeChatId) {
            setActiveChat(chatIdFromParams);
        }
    }, [chatIdFromParams, activeChatId, setActiveChat]);

    useEffect(() => {
        sendDebug('context', {
            chatIdFromParams,
            activeChatId,
            effectiveChatId,
            chatsCount: chats.length,
            activeChatFound: !!activeChat,
            activeChatMessagesCount: Array.isArray(activeChatMessages) ? activeChatMessages.length : -1,
            nativeChatEnabled,
            shouldUseNativeList,
        });
    }, [
        chatIdFromParams,
        activeChatId,
        effectiveChatId,
        chats.length,
        !!activeChat,
        nativeChatEnabled,
        shouldUseNativeList,
    ]);

    useEffect(() => {
        deletingMessageIdsRef.current = new Set(Object.keys(deletingMessageIds));
    }, [deletingMessageIds]);

    useEffect(() => {
        const syncNativeListForKeyboard = () => {
            if (!shouldUseNativeList) return;
            const { contentHeight, layoutHeight, offsetY } = listMetricsRef.current;
            const distanceFromBottom = Math.max(0, contentHeight - (offsetY + layoutHeight));
            const shouldFollowBottom = distanceFromBottom <= Math.max(56, LIST_BOTTOM_THRESHOLD * 2);
            if (!shouldFollowBottom) return;
            requestAnimationFrame(() => {
                void nativeSurfaceRef.current?.scrollToBottom(false);
            });
        };

        const showSub = Keyboard.addListener('keyboardDidShow', () => {
            keyboardVisibleRef.current = true;
            syncNativeListForKeyboard();
        });
        const hideSub = Keyboard.addListener('keyboardDidHide', () => {
            keyboardVisibleRef.current = false;
            syncNativeListForKeyboard();
        });
        const frameSub = Keyboard.addListener('keyboardWillChangeFrame', (event) => {
            const endHeight = event?.endCoordinates?.height;
            if (typeof endHeight === 'number') {
                keyboardVisibleRef.current = endHeight > 0.5;
            }
            syncNativeListForKeyboard();
        });

        return () => {
            showSub.remove();
            hideSub.remove();
            frameSub.remove();
        };
    }, [shouldUseNativeList]);

    useEffect(() => {
        setDeletingMessageIds({});
        setReplyTo(null);
        setEditTarget(null);
        setPinnedMessageIds([]);
        setActivePinnedIndex(0);
        setHighlightedPinnedMessageId(null);
        deletingMessageIdsRef.current.clear();
        deletedMessageIdsRef.current.clear();
        pendingDeletePayloadRef.current.clear();
        setReactionFlyFx(null);
        listMetricsRef.current = {
            contentHeight: 0,
            layoutHeight: 0,
            offsetY: 0,
        };
        fallbackScrollOffsetYRef.current = 0;
        reactionCommitTimersRef.current.forEach((timer) => clearTimeout(timer));
        reactionCommitTimersRef.current.clear();
    }, [effectiveChatId]);

    useEffect(() => {
        if (!effectiveChatId) return;
        const chat = useChatStore.getState().chats.find(c => c.chatId === effectiveChatId);
        chatListPerfLog('loadMessages:effect', {
            effectiveChatId,
            chatFound: !!chat,
            localMessages: chat?.messages?.length ?? 0,
            native: shouldUseNativeList,
        });
        sendDebug('loadMessages:trigger', {
            effectiveChatId,
            chatFound: !!chat,
            localMessages: chat?.messages?.length ?? 0,
        });
        // Defer loadMessages until the navigation transition finishes so the
        // screen mounts instantly with cached messages. The fetch/decrypt/merge
        // work runs after the transition animation completes, avoiding the
        // ~1-2 second UI delay on Android when opening a chat.
        const handle = InteractionManager.runAfterInteractions(() => {
            loadMessages(effectiveChatId);
        });
        return () => handle.cancel();
    }, [effectiveChatId, loadMessages, shouldUseNativeList]);

    useEffect(() => {
        if (!effectiveChatId) return;
        let cancelled = false;
        const handle = InteractionManager.runAfterInteractions(() => {
            (async () => {
                try {
                    const { apiClient } = await import('../../src/lib/api-client');
                    const json = await apiClient.getPinnedMessages(effectiveChatId);
                    if (cancelled) return;
                    const ids = Array.isArray(json?.data)
                        ? json.data
                            .map((entry: any) => entry?.messageId || entry?.message_id)
                            .filter((id: any) => typeof id === 'string')
                        : [];
                    setPinnedMessageIds(ids);
                    setActivePinnedIndex(0);
                } catch {
                    if (!cancelled) setPinnedMessageIds([]);
                }
            })();
        });
        return () => {
            cancelled = true;
            handle.cancel();
        };
    }, [effectiveChatId]);

    // --- Debounced hydration: avoid blocking the JS thread on every store change ---
    const hydrateTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const lastHydrateSourceRef = useRef<any>(null);

    useEffect(() => {
        // Clear any pending debounce when deps change
        if (hydrateTimerRef.current) {
            clearTimeout(hydrateTimerRef.current);
            hydrateTimerRef.current = null;
        }

        if (!effectiveChatId) return;
        if (!Array.isArray(activeChatMessages)) return;
        if (pendingGhost || ghostData) return;

        // Fast reference-equality check: skip if the source array hasn't changed
        if (lastHydrateSourceRef.current === activeChatMessages) return;

        const runHydrate = () => {
            const hydrateStart = Date.now();
            lastHydrateSourceRef.current = activeChatMessages;
            const source = activeChatMessages;
            const windowStart = Math.max(0, source.length - MAX_RENDER_MESSAGES);
            const windowedSource = source.slice(windowStart);
            let requiresSort = false;
            for (let i = 1; i < windowedSource.length; i++) {
                if ((windowedSource[i - 1]?.timestamp || 0) < (windowedSource[i]?.timestamp || 0)) {
                    requiresSort = true;
                    break;
                }
            }

            const normalizedRows = requiresSort
                ? [...windowedSource].sort((a: any, b: any) => (a?.timestamp || 0) - (b?.timestamp || 0))
                : windowedSource;

            const storeRows: Message[] = [];
            const indexById = new Map<string, number>();
            for (let i = 0; i < normalizedRows.length; i++) {
                const m: any = normalizedRows[i];
                const rawId = m?.id ?? m?.message_id ?? m?.messageId;
                const normalizedId = normalizeMessageIdValue(rawId);
                if (!normalizedId) continue;
                const type = normalizeMessageType(m?.type);
                const timestampMs = typeof m?.timestamp === 'number'
                    ? m.timestamp
                    : new Date(m?.timestamp || Date.now()).getTime();
                const mapped: Message = {
                    id: normalizedId,
                    chatId: normalizeOptionalStringId(m.chatId || m.chat_id),
                    fromId: normalizeOptionalStringId(m.fromId || m.from_id) || '',
                    encryptedContent: m.encryptedContent || m.encrypted_content,
                    type,
                    text: getStoreMessageText(m, type),
                    isMe: normalizeOptionalStringId(m.fromId || m.from_id) === user?.userId,
                    timestamp: formatUiTime(timestampMs),
                    timestampMs,
                    status: m.status as BubbleStatus,
                    errorMessage: typeof m.errorMessage === 'string' ? m.errorMessage : undefined,
                    isOptimistic: false,
                    mediaUrl: m.mediaUrl || m.media_url,
                    fileName: m.fileName || m.file_name,
                    fileSize: m.fileSize || m.file_size,
                    duration: m.duration,
                    latitude: m.latitude,
                    longitude: m.longitude,
                    caption: m.caption,
                    viewOnce: !!m.viewOnce,
                    viewedBy: Array.isArray(m.viewedBy)
                        ? m.viewedBy
                        : (Array.isArray(m.viewed_by) ? m.viewed_by : []),
                    isVideoNote: !!m.isVideoNote,
                    contact: m.contact,
                    replyToId: normalizeOptionalStringId(m.replyToId || m.reply_to_id),
                    isEdited: !!(m.isEdited || m.edited || m.extra?.isEdited),
                    editedAt: m.editedAt || m.edited_at || m.extra?.editedAt,
                    reactionEmoji: (
                        typeof m?.reactionEmoji === 'string'
                            ? m.reactionEmoji
                            : (typeof m?.extra?.reactionEmoji === 'string' ? m.extra.reactionEmoji : undefined)
                    ),
                    extra: {
                        width: m.extra?.width,
                        height: m.extra?.height,
                        thumbnailBase64: m.extra?.thumbnailBase64,
                        waveform: Array.isArray(m.extra?.waveform)
                            ? m.extra.waveform.filter((v: any) => typeof v === 'number')
                            : undefined,
                    },
                };

                const existingIndex = indexById.get(normalizedId);
                if (existingIndex === undefined) {
                    indexById.set(normalizedId, storeRows.length);
                    storeRows.push(mapped);
                } else {
                    storeRows[existingIndex] = {
                        ...storeRows[existingIndex],
                        ...mapped,
                        id: normalizedId,
                    };
                }
            }
            const deletingIds = deletingMessageIdsRef.current;
            const deletedIds = deletedMessageIdsRef.current;
            const visibleStoreRows = storeRows.filter((row) => (
                !deletingIds.has(row.id) && !deletedIds.has(row.id)
            ));

            sendDebug('hydrate:source', {
                effectiveChatId,
                sourceCount: source.length,
                storeRows: storeRows.length,
                visibleStoreRows: visibleStoreRows.length,
            });
            chatListPerfLog('hydrate:normalized', {
                effectiveChatId,
                sourceCount: source.length,
                windowedSource: windowedSource.length,
                storeRows: storeRows.length,
                visibleStoreRows: visibleStoreRows.length,
                dt: Date.now() - hydrateStart,
            });

            setMessages(prev => {
                const mergeStart = Date.now();
                const localCarryRows = prev.filter((m) => (
                    deletingIds.has(m.id) || (
                        m.isOptimistic &&
                        !deletingIds.has(m.id) &&
                        !deletedIds.has(m.id) &&
                        !visibleStoreRows.some((s) => s.id === m.id)
                    )
                ));
                const merged = [...visibleStoreRows, ...localCarryRows].sort((a, b) => a.timestampMs - b.timestampMs);
                if (merged.length === prev.length) {
                    let same = true;
                    for (let i = 0; i < merged.length; i++) {
                        if (!sameRenderableMessage(merged[i], prev[i])) {
                            same = false;
                            break;
                        }
                    }
                    if (same) return prev;
                }
                sendDebug('hydrate:apply', {
                    effectiveChatId,
                    prevCount: prev.length,
                    mergedCount: merged.length,
                    localCarryRows: localCarryRows.length,
                });
                chatListPerfLog('hydrate:setMessages', {
                    effectiveChatId,
                    prevCount: prev.length,
                    mergedCount: merged.length,
                    localCarryRows: localCarryRows.length,
                    totalDt: Date.now() - hydrateStart,
                    mergeDt: Date.now() - mergeStart,
                });
                return merged;
            });
        };

        // Debounce hydration so rapid store updates don't fire multiple heavy passes
        hydrateTimerRef.current = setTimeout(runHydrate, HYDRATE_DEBOUNCE_MS);
        return () => {
            if (hydrateTimerRef.current) {
                clearTimeout(hydrateTimerRef.current);
                hydrateTimerRef.current = null;
            }
        };
    }, [effectiveChatId, activeChatMessages, user?.userId, pendingGhost, ghostData]);

    useEffect(() => {
        return () => {
            queuedTimersRef.current.forEach((timer) => clearTimeout(timer));
            queuedTimersRef.current.clear();
            recoveryTimersRef.current.forEach((timer) => clearTimeout(timer));
            recoveryTimersRef.current.clear();
            recoveryAttemptedRef.current.clear();
            nativeSendInFlightRef.current.clear();
            nativeSendRecentlyHandledRef.current.clear();
            reactionCommitTimersRef.current.forEach((timer) => clearTimeout(timer));
            reactionCommitTimersRef.current.clear();
        };
    }, []);

    const pageShiftStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: -Math.max(0, Math.abs(keyboardHeight.value)) }],
    }));

    const inputMarginStyle = useAnimatedStyle(() => ({
        marginHorizontal: interpolate(keyboardProgress.value, [0, 1], [28, 12], Extrapolation.CLAMP),
    }));
    const inputBottomPaddingStyle = useAnimatedStyle(() => ({
        paddingBottom: Platform.OS === 'android'
            ? interpolate(
                keyboardProgress.value,
                [0, 1],
                [bottomInsetPadding, androidKeyboardOpenBottomInsetPadding],
                Extrapolation.CLAMP
            )
            : bottomInsetPadding,
    }));

    const clearRecoveryTimer = useCallback((messageId: string) => {
        const timer = recoveryTimersRef.current.get(messageId);
        if (timer) {
            clearTimeout(timer);
            recoveryTimersRef.current.delete(messageId);
        }
    }, []);

    const scheduleBackgroundRecovery = useCallback((chatId: string, messageId: string, delayMs = 2400) => {
        if (!isConnected) return;
        if (recoveryAttemptedRef.current.has(messageId)) return;
        if (recoveryTimersRef.current.has(messageId)) return;

        const timer = setTimeout(() => {
            recoveryTimersRef.current.delete(messageId);
            if (!isConnected) return;

            recoveryAttemptedRef.current.add(messageId);
            retryMessage(chatId, messageId);
        }, delayMs);

        recoveryTimersRef.current.set(messageId, timer);
    }, [isConnected, retryMessage]);

    const runQueuedSend = useCallback((queued: QueuedSend) => {
        Promise.resolve(sendMessage(queued.chatId, queued.text, 'text', { replyToId: queued.replyToId }, queued.messageId))
            .then(() => {
                clearRecoveryTimer(queued.messageId);
                recoveryAttemptedRef.current.delete(queued.messageId);
                setMessages(prev => prev.map(m => (
                    m.id === queued.messageId
                        ? { ...m, isOptimistic: false }
                        : m
                )));
            })
            .catch(() => {
                setMessages(prev => prev.map(m => (m.id === queued.messageId ? { ...m, isOptimistic: false, status: 'error' } : m)));
                scheduleBackgroundRecovery(queued.chatId, queued.messageId);
            });
    }, [sendMessage, clearRecoveryTimer, scheduleBackgroundRecovery]);

    useEffect(() => {
        if (!effectiveChatId || !isConnected) return;
        for (const message of messages) {
            if (!message.isMe) continue;
            if (message.status !== 'error' && message.status !== 'pending') continue;
            if (
                message.status === 'error'
                && typeof message.errorMessage === 'string'
                && message.errorMessage.toLowerCase().includes('local media file is no longer available')
            ) {
                continue;
            }
            if (recoveryAttemptedRef.current.has(message.id)) continue;
            if (recoveryTimersRef.current.has(message.id)) continue;
            sendDebug('auto-retry:scheduled', {
                chatId: effectiveChatId,
                messageId: message.id,
                type: message.type,
                status: message.status,
            });
            scheduleBackgroundRecovery(effectiveChatId, message.id, message.status === 'error' ? 1200 : 2200);
        }
    }, [messages, effectiveChatId, isConnected, scheduleBackgroundRecovery, sendDebug]);

    const removeMessageLocally = useCallback((chatId: string, messageId: string) => {
        setMessages(prev => prev.filter((m) => m.id !== messageId));
        useChatStore.setState((state) => {
            const chatIdx = state.chats.findIndex((c) => c.chatId === chatId);
            if (chatIdx === -1) return {};
            const updatedChats = [...state.chats];
            const target = updatedChats[chatIdx];
            const filteredMessages = target.messages.filter((m: any) => m.id !== messageId);
            updatedChats[chatIdx] = {
                ...target,
                messages: filteredMessages,
                lastMessage: filteredMessages.length > 0 ? filteredMessages[filteredMessages.length - 1] : undefined,
            };
            return { chats: updatedChats };
        });
    }, []);

    const getReactionBadgeTarget = useCallback((rect: BubbleRect) => ({
        x: rect.x + 20,
        y: rect.y + rect.height - 11,
    }), []);

    const spawnReactionFx = useCallback((emoji: string, message: Message, x: number, y: number) => {
        const token = Date.now() + Math.floor(Math.random() * 1000);
        const color = message.isMe ? bubbleTheme.meGradient[1] : bubbleTheme.themSolid;
        setReactionFxList((prev) => [...prev, { token, x, y, color, emoji }]);
    }, [bubbleTheme.meGradient, bubbleTheme.themSolid]);

    const completeDeleteMessage = useCallback(async (messageId: string) => {
        const payload = pendingDeletePayloadRef.current.get(messageId);
        if (!payload) return;

        pendingDeletePayloadRef.current.delete(messageId);
        deletedMessageIdsRef.current.add(messageId);
        setDeletingMessageIds((prev) => {
            if (!prev[messageId]) return prev;
            const next = { ...prev };
            delete next[messageId];
            return next;
        });
        setActiveMenuId((current) => (current === messageId ? null : current));
        setPinnedMessageIds((prev) => prev.filter((id) => id !== messageId));

        removeMessageLocally(payload.chatId, messageId);

        if (payload.message.status === 'error' || payload.message.status === 'pending' || payload.message.isOptimistic) {
            deleteFailedMessage(payload.chatId, messageId);
            return;
        }

        if (shouldUseNativeList && nativeChatEnabled) {
            try {
                const nativeChatEngine = getNativeChatEngineModule();
                const nativeDelete = nativeChatEngine?.deleteMessage ?? nativeChatEngine?.sendDeleteMessage;
                if (typeof nativeDelete === 'function') {
                    const result = await Promise.resolve(nativeDelete({
                        chatId: payload.chatId,
                        messageId,
                        forEveryone: true,
                    }));
                    if ((result as any)?.accepted) {
                        return;
                    }
                    if (!nativeChatJsFallbackEnabled) {
                        console.warn('[ChatListScreen] native delete rejected without JS fallback', {
                            chatId: payload.chatId,
                            messageId,
                            result,
                        });
                        return;
                    }
                } else if (!nativeChatJsFallbackEnabled) {
                    console.warn('[ChatListScreen] native delete API unavailable and JS fallback disabled');
                    return;
                }
            } catch (error) {
                if (!nativeChatJsFallbackEnabled) {
                    console.warn('[ChatListScreen] native delete failed without JS fallback', error);
                    return;
                }
            }
        }

        try {
            const { apiClient } = await import('../../src/lib/api-client');
            await apiClient.deleteMessage(payload.chatId, messageId, payload.message.isMe);
        } catch {
            // Local deletion is authoritative for UI.
        }
    }, [removeMessageLocally, deleteFailedMessage, shouldUseNativeList, nativeChatEnabled, nativeChatJsFallbackEnabled]);

    const showToast = useCallback((message: string, type: 'success' | 'error' | 'info' = 'info') => {
        useToastStore.getState().showToast(message, type);
    }, []);

    const openReplyComposer = useCallback((message: Message) => {
        if (!effectiveChatId) return;
        const userName = message.isMe ? 'You' : (activeChat?.friendName || activeChat?.name || 'User');
        setEditTarget(null);
        setReplyTo({
            messageId: message.id,
            userName,
            text: message.text?.trim() || 'Message',
            isFromMe: message.isMe,
        });
    }, [effectiveChatId, activeChat]);

    const handleBubbleMenuAction = useCallback(async (action: BubbleMenuAction, message: Message, _rect?: BubbleRect) => {
        if (!effectiveChatId) return;
        setActiveMenuId(null);

        if (action === 'reply') {
            if (shouldUseNativeList) {
                showToast('Reply composer is not available in native-only mode', 'info');
                return;
            }
            openReplyComposer(message);
            return;
        }

        if (action === 'copy') {
            if (message.text?.trim()) {
                await Clipboard.setStringAsync(message.text.trim());
                showToast('Copied to clipboard', 'success');
            }
            return;
        }

        if (action === 'edit') {
            if (shouldUseNativeList) {
                showToast('Edit is not available in native-only mode yet', 'info');
                return;
            }
            const currentText = message.text?.trim() || '';
            if (!message.isMe || !currentText) {
                showToast('Only your text messages can be edited', 'info');
                return;
            }
            if (!isValidBinaryMessageId(message.id)) {
                showToast('Message is not ready for edit yet', 'info');
                return;
            }
            setReplyTo(null);
            setText(currentText);
            setEditTarget({
                messageId: message.id,
                text: currentText,
            });
            return;
        }

        if (action === 'pin') {
            const alreadyPinned = pinnedMessageIds.includes(message.id);
            const nextPinned = !alreadyPinned;
            try {
                const { apiClient } = await import('../../src/lib/api-client');
                await apiClient.pinMessage(effectiveChatId, message.id, nextPinned);
                setPinnedMessageIds((prev) => {
                    const filtered = prev.filter((id) => id !== message.id);
                    return nextPinned ? [message.id, ...filtered] : filtered;
                });
                setActivePinnedIndex(0);
                showToast(nextPinned ? 'Message pinned' : 'Message unpinned', 'success');
            } catch {
                showToast('Failed to update pin', 'error');
            }
            return;
        }

        if (action === 'resend') {
            if (!message.isMe || message.status !== 'error') {
                showToast('Only failed outgoing messages can be resent', 'info');
                return;
            }
            clearRecoveryTimer(message.id);
            setMessages(prev => prev.map((m) => (
                m.id === message.id ? { ...m, status: isConnected ? 'sending' : 'pending' } : m
            )));
            recoveryAttemptedRef.current.add(message.id);
            retryMessage(effectiveChatId, message.id);
            return;
        }

        if (action === 'delete') {
            clearRecoveryTimer(message.id);
            recoveryAttemptedRef.current.delete(message.id);
            pendingDeletePayloadRef.current.set(message.id, { message, chatId: effectiveChatId });
            setDeletingMessageIds((prev) => (
                prev[message.id] ? prev : { ...prev, [message.id]: true }
            ));
            return;
        }
    }, [effectiveChatId, isConnected, retryMessage, clearRecoveryTimer, pinnedMessageIds, showToast, openReplyComposer, shouldUseNativeList]);

    const commitReactionLocally = useCallback((
        emoji: string,
        message: Message,
        sourcePoint?: { x: number; y: number }
    ) => {
        console.log('[ReactionDebug] commitReactionLocally:start', {
            messageId: message.id,
            chatId: message.chatId || effectiveChatId,
            emoji,
            sourcePoint: sourcePoint || null,
            shouldUseNativeList,
        });
        setMessages((prev) => prev.map((entry) => (
            entry.id === message.id ? { ...entry, reactionEmoji: emoji } : entry
        )));
        const targetChatId = message.chatId || effectiveChatId;
        if (targetChatId) {
            useChatStore.setState((state) => {
                const chatIdx = state.chats.findIndex((c) => c.chatId === targetChatId);
                if (chatIdx === -1) return {};
                const updatedChats = [...state.chats];
                const targetChat = updatedChats[chatIdx];
                const updatedMessages = targetChat.messages.map((m: any) => (
                    m.id === message.id
                        ? {
                            ...m,
                            reactionEmoji: emoji,
                            extra: {
                                ...(m.extra || {}),
                                reactionEmoji: emoji,
                            },
                        }
                        : m
                ));
                updatedChats[chatIdx] = {
                    ...targetChat,
                    messages: updatedMessages,
                };
                return { chats: updatedChats };
            });
        }
        if (!shouldUseNativeList && sourcePoint && Number.isFinite(sourcePoint.x) && Number.isFinite(sourcePoint.y)) {
            spawnReactionFx(emoji, message, sourcePoint.x, sourcePoint.y);
        }
        console.log('[ReactionDebug] commitReactionLocally:done', {
            messageId: message.id,
            emoji,
        });
    }, [effectiveChatId, shouldUseNativeList, spawnReactionFx]);

    const handleNativeSurfaceEvent = useCallback((event: { nativeEvent: Record<string, unknown> } | Record<string, unknown>) => {
        const nativeEvent = extractNativePayload(event);
        const type = typeof nativeEvent.type === 'string' ? nativeEvent.type : '';
        sendDebug('nativeEvent:received', {
            type: type || '(missing)',
            keys: Object.keys(nativeEvent),
        });

        const pushRecordingUi = (patch: Partial<{ isRecording: boolean; isLocked: boolean; mode: 'voice' | 'video'; vad: number }>) => {
            const prev = nativeRecordingStateRef.current;
            const next = {
                ...prev,
                ...patch,
            };
            nativeRecordingStateRef.current = next;
            onRecordingUiChange?.(next);
        };

        if (type === 'sendMessage') {
            const textRaw = nativeEvent.text;
            const messageIdRaw = nativeEvent.messageId;
            if (typeof textRaw !== 'string' || !effectiveChatId) {
                sendDebug('nativeEvent:sendMessage:blocked', {
                    textType: typeof textRaw,
                    effectiveChatId,
                    messageIdRaw,
                });
                console.warn('[Native] sendMessage blocked:', {
                    textIsString: typeof textRaw === 'string',
                    hasChatId: !!effectiveChatId,
                });
                return;
            }
            const replyToIdRaw = nativeEvent.replyToMessageId;
            const replyToId = typeof replyToIdRaw === 'string' ? replyToIdRaw : replyTo?.messageId;
            const existingId = typeof messageIdRaw === 'string' ? messageIdRaw : undefined;
            if (existingId) {
                const nowMs = Date.now();
                nativeSendRecentlyHandledRef.current.forEach((handledAt, id) => {
                    if (nowMs - handledAt > 60_000) {
                        nativeSendRecentlyHandledRef.current.delete(id);
                    }
                });
                if (nativeSendInFlightRef.current.has(existingId)) {
                    sendDebug('nativeEvent:sendMessage:duplicate-inflight', {
                        effectiveChatId,
                        messageIdRaw,
                    });
                    return;
                }
                const handledAt = nativeSendRecentlyHandledRef.current.get(existingId);
                if (typeof handledAt === 'number' && nowMs - handledAt < 12_000) {
                    sendDebug('nativeEvent:sendMessage:duplicate-recent', {
                        effectiveChatId,
                        messageIdRaw,
                        ageMs: nowMs - handledAt,
                    });
                    return;
                }
                const existingLocalMessage = messages.find((entry) => entry.id === existingId && entry.isMe);
                if (existingLocalMessage) {
                    const sameText = existingLocalMessage.text.trim() === textRaw.trim();
                    const finalized =
                        existingLocalMessage.status === 'sending'
                        || existingLocalMessage.status === 'sent'
                        || existingLocalMessage.status === 'delivered'
                        || existingLocalMessage.status === 'read';
                    if (sameText && finalized) {
                        sendDebug('nativeEvent:sendMessage:duplicate-existing-row', {
                            effectiveChatId,
                            messageIdRaw,
                            status: existingLocalMessage.status,
                        });
                        return;
                    }
                    if (!sameText && finalized) {
                        sendDebug('nativeEvent:sendMessage:id-collision-blocked', {
                            effectiveChatId,
                            messageIdRaw,
                            existingTextLength: existingLocalMessage.text.length,
                            incomingTextLength: textRaw.length,
                        });
                        return;
                    }
                }
                nativeSendInFlightRef.current.add(existingId);
            }
            sendDebug('nativeEvent:sendMessage', {
                effectiveChatId,
                messageIdRaw,
                replyToId,
                textLength: textRaw.length,
            });
            void sendMessage(
                effectiveChatId,
                textRaw,
                'text',
                replyToId ? { replyToId } : {},
                existingId
            )
                .then(() => {
                    if (existingId) {
                        nativeSendRecentlyHandledRef.current.set(existingId, Date.now());
                    }
                    sendDebug('nativeEvent:sendMessage:resolved', {
                        effectiveChatId,
                        messageIdRaw,
                    });
                })
                .catch((error) => {
                    console.error('[Native] sendMessage error:', {
                        effectiveChatId,
                        messageIdRaw,
                        error: String(error),
                    });
                })
                .finally(() => {
                    if (existingId) {
                        nativeSendInFlightRef.current.delete(existingId);
                    }
                });
            if (replyToId) {
                setReplyTo(null);
            }
            return;
        }

        if (type === 'textChanged') {
            const textRaw = typeof nativeEvent.text === 'string' ? nativeEvent.text : '';
            if (!(shouldUseNativeList && nativeChatEnabled)) {
                onTypingStatusChange?.(textRaw.trim().length > 0);
            }
            return;
        }

        if (type === 'attachmentPressed') {
            showToast('Native attachment menu is not wired yet', 'info');
            return;
        }

        if (type === 'attachmentImage') {
            const uriRaw = nativeEvent.uri;
            if (typeof uriRaw !== 'string' || !effectiveChatId) return;
            void sendMessage(effectiveChatId, '', 'image', { mediaUrl: uriRaw });
            return;
        }

        if (type === 'attachmentGif') {
            const urlRaw = nativeEvent.url;
            const previewRaw = nativeEvent.previewUrl;
            const widthRaw = typeof nativeEvent.width === 'number' ? nativeEvent.width : undefined;
            const heightRaw = typeof nativeEvent.height === 'number' ? nativeEvent.height : undefined;
            if (typeof urlRaw !== 'string' || urlRaw.trim().length === 0 || !effectiveChatId) return;
            void sendMessage(effectiveChatId, '', 'gif', {
                mediaUrl: urlRaw,
                previewUrl: typeof previewRaw === 'string' ? previewRaw : urlRaw,
                width: widthRaw,
                height: heightRaw,
            });
            return;
        }

        if (type === 'attachmentFile') {
            const uriRaw = nativeEvent.uri;
            const nameRaw = nativeEvent.name;
            if (typeof uriRaw !== 'string' || !effectiveChatId) return;
            void sendMessage(effectiveChatId, typeof nameRaw === 'string' ? nameRaw : 'File', 'file', {
                mediaUrl: uriRaw,
                fileName: typeof nameRaw === 'string' ? nameRaw : 'File',
            });
            return;
        }

        if (type === 'attachmentLocation') {
            const latitude = typeof nativeEvent.latitude === 'number' ? nativeEvent.latitude : NaN;
            const longitude = typeof nativeEvent.longitude === 'number' ? nativeEvent.longitude : NaN;
            if (!effectiveChatId || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return;
            void sendMessage(effectiveChatId, '', 'location', { latitude, longitude });
            return;
        }

        if (type === 'attachmentVoice') {
            const uriRaw = nativeEvent.uri;
            const durationRaw = typeof nativeEvent.duration === 'number' ? nativeEvent.duration : 0;
            const waveformRaw = Array.isArray(nativeEvent.waveform)
                ? nativeEvent.waveform.filter((v: unknown) => typeof v === 'number').map((v: number) => Math.max(0, Math.min(1, v)))
                : undefined;
            if (typeof uriRaw !== 'string' || !effectiveChatId) return;
            void sendMessage(effectiveChatId, '', 'voice', {
                mediaUrl: uriRaw,
                duration: durationRaw,
                fileName: 'voice-message.m4a',
                waveform: waveformRaw,
            });
            return;
        }

        if (type === 'attachmentVideoNote') {
            const uriRaw = nativeEvent.uri;
            const durationRaw = typeof nativeEvent.duration === 'number' ? nativeEvent.duration : 0;
            if (typeof uriRaw !== 'string' || !effectiveChatId) return;
            void sendMessage(effectiveChatId, '', 'video', {
                mediaUrl: uriRaw,
                duration: durationRaw,
                fileName: 'video-note.mov',
                isVideoNote: true,
            });
            return;
        }

        if (type === 'recordingState') {
            const modeRaw = nativeEvent.mode === 'video' ? 'video' : 'voice';
            pushRecordingUi({
                isRecording: !!nativeEvent.isRecording,
                isLocked: !!nativeEvent.isLocked,
                mode: modeRaw,
            });
            return;
        }

        if (type === 'recordingVad') {
            const levelRaw = typeof nativeEvent.level === 'number' ? nativeEvent.level : 0;
            pushRecordingUi({
                vad: Math.max(0, Math.min(1, levelRaw)),
            });
            return;
        }

        if (type === 'recordingCanceled') {
            pushRecordingUi({
                isRecording: false,
                isLocked: false,
                vad: 0,
            });
            return;
        }

        if (type === 'contextMenuOpened') {
            if (keyboardVisibleRef.current) {
                Keyboard.dismiss();
            }
            return;
        }

        if (type === 'swipeReply') {
            const messageIdRaw = nativeEvent.messageId;
            if (typeof messageIdRaw !== 'string') return;
            const message = messages.find((entry) => entry.id === messageIdRaw);
            if (!message) return;
            onReplySwipeHaptic?.();
            if (shouldUseNativeList) {
                // Native surface already opens the reply banner in-place.
                return;
            }
            openReplyComposer(message);
            return;
        }

        if (type === 'contextMenuReaction') {
            const messageIdRaw = nativeEvent.messageId;
            const emojiRaw = nativeEvent.emoji;
            if (typeof messageIdRaw !== 'string' || typeof emojiRaw !== 'string' || emojiRaw.trim().length === 0) {
                console.log('[ReactionDebug] nativeEvent:contextMenuReaction:invalid-payload', nativeEvent);
                return;
            }
            const message = messages.find((entry) => entry.id === messageIdRaw);
            if (!message) {
                console.log('[ReactionDebug] nativeEvent:contextMenuReaction:message-not-found', {
                    messageId: messageIdRaw,
                    emoji: emojiRaw,
                    messagesCount: messages.length,
                });
                return;
            }
            const sourceX = typeof nativeEvent.sourceX === 'number' ? nativeEvent.sourceX : undefined;
            const sourceY = typeof nativeEvent.sourceY === 'number' ? nativeEvent.sourceY : undefined;
            const sourcePoint = Number.isFinite(sourceX) && Number.isFinite(sourceY)
                ? { x: sourceX as number, y: sourceY as number }
                : undefined;
            console.log('[ReactionDebug] nativeEvent:contextMenuReaction:received', {
                messageId: messageIdRaw,
                emoji: emojiRaw,
                sourcePoint: sourcePoint || null,
                shouldUseNativeList,
            });
            if (shouldUseNativeList && sourcePoint) {
                void nativeSurfaceRef.current?.playReactionFx({
                    emoji: emojiRaw,
                    x: sourcePoint.x,
                    y: sourcePoint.y,
                });
                commitReactionLocally(emojiRaw, message);
                console.log('[ReactionDebug] nativeEvent:contextMenuReaction:nativeFx-dispatched', {
                    messageId: messageIdRaw,
                    emoji: emojiRaw,
                });
                return;
            }
            commitReactionLocally(emojiRaw, message, sourcePoint);
            return;
        }

        if (type !== 'contextMenuAction') return;
        const actionRaw = nativeEvent.action;
        const messageIdRaw = nativeEvent.messageId;
        if (typeof actionRaw !== 'string' || typeof messageIdRaw !== 'string') return;
        if (
            actionRaw !== 'reply'
            && actionRaw !== 'copy'
            && actionRaw !== 'edit'
            && actionRaw !== 'pin'
            && actionRaw !== 'resend'
            && actionRaw !== 'delete'
        ) {
            return;
        }

        const message = messages.find((entry) => entry.id === messageIdRaw);
        if (!message) return;
        void handleBubbleMenuAction(actionRaw as BubbleMenuAction, message);
    }, [messages, handleBubbleMenuAction, onReplySwipeHaptic, openReplyComposer, commitReactionLocally, effectiveChatId, sendMessage, onTypingStatusChange, onRecordingUiChange, replyTo, shouldUseNativeList, nativeChatEnabled, showToast, extractNativePayload, sendDebug]);

    const handleNativeSurfaceError = useCallback((error: unknown, context: string) => {
        console.error(`[ChatList] Native surface error in ${context}`, error);
        showToast('Native chat error', 'error');
    }, [showToast]);

    const handleReactionSelect = useCallback((
        emoji: string,
        message: Message,
        rect?: BubbleRect,
        sourcePoint?: ReactionSourcePoint
    ) => {
        if (shouldUseNativeList) {
            commitReactionLocally(emoji, message);
            return;
        }

        const applyReaction = (targetX?: number, targetY?: number) => {
            if (typeof targetX === 'number' && typeof targetY === 'number') {
                commitReactionLocally(emoji, message, { x: targetX, y: targetY });
                return;
            }
            commitReactionLocally(emoji, message);
        };

        if (!rect) {
            if (Number.isFinite(sourcePoint?.x) && Number.isFinite(sourcePoint?.y)) {
                applyReaction(sourcePoint?.x as number, sourcePoint?.y as number);
            } else {
                applyReaction();
            }
            return;
        }

        const target = getReactionBadgeTarget(rect);
        const token = Date.now() + Math.floor(Math.random() * 1000);
        const fallbackStartX = rect.x + (message.isMe ? rect.width - 40 : 40);
        const fallbackStartY = rect.y - 30;
        const startX = Number.isFinite(sourcePoint?.x) ? (sourcePoint?.x as number) : fallbackStartX;
        const startY = Number.isFinite(sourcePoint?.y) ? (sourcePoint?.y as number) : fallbackStartY;
        const durationMs = getReactionFlightDuration(startX, startY, target.x, target.y);

        setReactionFlyFx({
            token,
            emoji,
            startX,
            startY,
            targetX: target.x,
            targetY: target.y,
            durationMs,
        });

        const existing = reactionCommitTimersRef.current.get(message.id);
        if (existing) clearTimeout(existing);
        const commitDelay = Math.round(durationMs * 0.82);
        const timer = setTimeout(() => {
            reactionCommitTimersRef.current.delete(message.id);
            applyReaction(target.x, target.y);
        }, commitDelay);
        reactionCommitTimersRef.current.set(message.id, timer);
    }, [commitReactionLocally, getReactionBadgeTarget, shouldUseNativeList]);

    useEffect(() => {
        for (const msg of messages) {
            if (msg.status === 'sent' || msg.status === 'delivered' || msg.status === 'read') {
                clearRecoveryTimer(msg.id);
                recoveryAttemptedRef.current.delete(msg.id);
            }
        }
    }, [messages, clearRecoveryTimer]);

    useEffect(() => {
        setPinnedMessageIds((prev) => prev.filter((id) => messages.some((msg) => msg.id === id)));
    }, [messages]);

    useEffect(() => {
        if (pinnedMessageIds.length <= 1) return;
        const timer = setInterval(() => {
            setActivePinnedIndex((current) => (current + 1) % pinnedMessageIds.length);
        }, 3200);
        return () => clearInterval(timer);
    }, [pinnedMessageIds.length]);

    useEffect(() => {
        if (activePinnedIndex < pinnedMessageIds.length) return;
        setActivePinnedIndex(0);
    }, [activePinnedIndex, pinnedMessageIds.length]);

    // Called when the hidden real bubble measures itself
    const onBubbleLayout = useCallback((id: string, x: number, y: number, w: number, h: number, shape: BubbleShape) => {
        if (activeGhostMessageIdRef.current === id) {
            ghostTargetX.value = x;
            ghostTargetY.value = y;
            ghostTargetWidth.value = w;
            ghostTargetHeight.value = h;
        }

        // We can optionally use a ref to store measures if needed for debouncing, 
        // but for now let's just trigger immediately like the simple version, 
        // but writing to shared values first.

        setPendingGhost(prev => {
            if (!prev || prev.messageId !== id) return prev;

            // Launch immediately on first valid measure to avoid visible delay.
            ghostTargetX.value = x;
            ghostTargetY.value = y;
            ghostTargetWidth.value = w;
            ghostTargetHeight.value = h;

            setGhostData({
                ...prev,
                shape,
            });

            return null;
        });
    }, [ghostTargetX, ghostTargetY, ghostTargetWidth, ghostTargetHeight]);

    const handleSend = useCallback(() => {
        if (!text.trim()) return;
        if (!effectiveChatId) return;

        const currentText = text.trim();
        if (editTarget) {
            const targetMessageId = editTarget.messageId;
            const previousText = editTarget.text.trim();
            if (!targetMessageId) return;
            if (currentText === previousText) {
                setEditTarget(null);
                setText('');
                return;
            }
            setEditTarget(null);
            setText('');
            void (async () => {
                let ok = false;
                if (shouldUseNativeList && nativeChatEnabled) {
                    try {
                        const nativeChatEngine = getNativeChatEngineModule();
                        const nativeEdit = nativeChatEngine?.editMessage;
                        if (typeof nativeEdit === 'function') {
                            const result = await Promise.resolve(nativeEdit({
                                chatId: effectiveChatId,
                                messageId: targetMessageId,
                                text: currentText,
                            }));
                            ok = !!(result as any)?.accepted;
                            if (!ok && !nativeChatJsFallbackEnabled) {
                                console.warn('[ChatListScreen] native edit rejected without JS fallback', {
                                    chatId: effectiveChatId,
                                    messageId: targetMessageId,
                                    result,
                                });
                            }
                        } else if (!nativeChatJsFallbackEnabled) {
                            console.warn('[ChatListScreen] native edit API unavailable and JS fallback disabled');
                        }
                    } catch (error) {
                        if (!nativeChatJsFallbackEnabled) {
                            console.warn('[ChatListScreen] native edit failed without JS fallback', error);
                        }
                    }
                }
                if (!ok && (!shouldUseNativeList || !nativeChatEnabled || nativeChatJsFallbackEnabled)) {
                    ok = await editMessage(effectiveChatId, targetMessageId, currentText);
                }
                if (ok) {
                    showToast('Message edited', 'success');
                } else {
                    showToast('Could not edit message', 'error');
                }
            })();
            return;
        }

        const replyToId = replyTo?.messageId;
        const messageId = ExpoCrypto.randomUUID();
        const timestampMs = Date.now();
        const timestamp = formatUiTime(timestampMs);
        const queuedSend: QueuedSend = {
            messageId,
            chatId: effectiveChatId,
            text: currentText,
            replyToId,
        };

        if (nativeChatEnabled) {
            setText('');
            setReplyTo(null);

            const appendOptimisticMessage = () => {
                setMessages(prev => {
                    if (prev.some((entry) => entry.id === messageId)) return prev;
                    return [...prev, {
                        id: messageId,
                        type: 'text',
                        text: currentText,
                        timestamp,
                        timestampMs,
                        isMe: true,
                        replyToId,
                        isOptimistic: true,
                        status: (isConnected ? 'sending' : 'pending') as BubbleStatus,
                    }];
                });
            };

            const scheduleQueuedSend = () => {
                InteractionManager.runAfterInteractions(() => {
                    setTimeout(() => runQueuedSend(queuedSend), 0);
                });
            };

            const dispatchNativeSend = (barX: number, barY: number, barW: number) => {
                const fallbackWidth = Dimensions.get('window').width;
                const fallbackHeight = Dimensions.get('window').height;
                const resolvedBarX = Number.isFinite(barX) ? barX : 0;
                const resolvedBarY = Number.isFinite(barY) ? barY : (fallbackHeight - 84);
                const resolvedBarW = Number.isFinite(barW) && barW > 0 ? barW : fallbackWidth;
                const startX = resolvedBarX + 16;
                const startY = resolvedBarY + 13;
                const startWidth = Math.max(120, resolvedBarW - 64);
                const startHeight = 40;
                const startBackgroundX = startX;
                const startBackgroundY = startY;
                const startBackgroundWidth = startWidth;
                const startBackgroundHeight = startHeight;
                const startContentX = startX + 8;
                const startContentY = startY + 8;
                const startContentWidth = Math.max(1, startWidth - 16);
                const startContentHeight = Math.max(1, startHeight - 16);

                (async () => {
                    try {
                        const transitionPayload: NativeSendTransitionPayload = {
                            messageId,
                            text: currentText,
                            timestamp,
                            startX,
                            startY,
                            startWidth,
                            startHeight,
                            startBackgroundX,
                            startBackgroundY,
                            startBackgroundWidth,
                            startBackgroundHeight,
                            startContentX,
                            startContentY,
                            startContentWidth,
                            startContentHeight,
                            sourceScrollOffset: 0,
                            sourceContainerX: startBackgroundX,
                            sourceContainerY: startBackgroundY,
                            sourceContainerWidth: startBackgroundWidth,
                            sourceContainerHeight: startBackgroundHeight,
                        };
                        // Register transition BEFORE inserting row so list shift and morph stay in sync.
                        await nativeSurfaceRef.current?.startSendTransition(transitionPayload);
                    } catch (error) {
                        console.error('[ChatList] startSendTransition failed', error);
                    } finally {
                        appendOptimisticMessage();
                        scheduleQueuedSend();
                    }
                })();
            };

            let didDispatch = false;
            const dispatchOnce = (barX: number, barY: number, barW: number) => {
                if (didDispatch) return;
                didDispatch = true;
                dispatchNativeSend(barX, barY, barW);
            };

            inputBarRef.current?.measureInWindow((barX, barY, barW) => {
                dispatchOnce(barX, barY, barW);
            });
            setTimeout(() => {
                dispatchOnce(NaN, NaN, NaN);
            }, 70);
            return;
        }

        inputBarRef.current?.measureInWindow((barX, barY, barW) => {
            const startX = barX + 16;
            const startY = barY + 13;
            const startWidth = barW - 64;
            const startHeight = 40;

            setText('');
            ghostHiddenId.value = messageId;

            setMessages(prev => [...prev, {
                id: messageId,
                type: 'text',
                text: currentText,
                timestamp,
                timestampMs,
                isMe: true,
                replyToId,
                isGhostHidden: true,
                isOptimistic: true,
                status: (isConnected ? 'sending' : 'pending') as BubbleStatus,
            }]);

            setPendingGhost({
                text: currentText,
                timestamp,
                startX,
                startY,
                startWidth,
                startHeight,
                messageId,
            });

            queuedSendsRef.current.set(messageId, queuedSend);
            setReplyTo(null);

            const timer = setTimeout(() => {
                const queued = queuedSendsRef.current.get(messageId);
                if (!queued) return;
                if (ghostData || pendingGhost) return;
                queuedSendsRef.current.delete(messageId);
                InteractionManager.runAfterInteractions(() => {
                    setTimeout(() => runQueuedSend(queued), 0);
                });
            }, 1400);
            queuedTimersRef.current.set(messageId, timer);
        });
    }, [text, effectiveChatId, isConnected, ghostData, pendingGhost, runQueuedSend, editTarget, editMessage, showToast, replyTo, nativeChatEnabled, shouldUseNativeList, nativeChatJsFallbackEnabled]);

    const sendAttachmentMessage = useCallback(async (
        type: BubbleMessageType,
        attachmentText: string,
        metadata: Record<string, any>,
    ) => {
        if (!effectiveChatId) return;
        if (shouldUseNativeList && nativeChatEnabled) {
            try {
                const mediaUrl = typeof metadata?.mediaUrl === 'string' ? metadata.mediaUrl.trim() : '';
                const isRemoteMediaUrl = mediaUrl.startsWith('http://') || mediaUrl.startsWith('https://') || mediaUrl.startsWith('data:');
                const canUseNativeNow =
                    type === 'location'
                    || type === 'contact'
                    || (['gif', 'image', 'file', 'voice', 'video', 'music'].includes(type) && isRemoteMediaUrl);
                if (canUseNativeNow) {
                    const nativeChatEngine = getNativeChatEngineModule();
                    const nativeSend = nativeChatEngine?.sendMessage;
                    if (typeof nativeSend === 'function') {
                        const result = await Promise.resolve(nativeSend({
                            chatId: effectiveChatId,
                            type,
                            text: attachmentText,
                            metadata,
                        }));
                        if ((result as any)?.accepted) {
                            return;
                        }
                        if (!nativeChatJsFallbackEnabled) {
                            console.warn('[ChatListScreen] native attachment send rejected without JS fallback', {
                                chatId: effectiveChatId,
                                type,
                                result,
                            });
                            return;
                        }
                    } else if (!nativeChatJsFallbackEnabled) {
                        console.warn('[ChatListScreen] native attachment send API unavailable and JS fallback disabled', {
                            type,
                        });
                        return;
                    }
                }
            } catch (error) {
                if (!nativeChatJsFallbackEnabled) {
                    console.warn('[ChatListScreen] native attachment send failed without JS fallback', {
                        chatId: effectiveChatId,
                        type,
                        error: String(error),
                    });
                    return;
                }
            }
        }
        try {
            await sendMessage(effectiveChatId, attachmentText, type, metadata);
        } catch {
            // Send errors are surfaced by ChatStore status updates.
        }
    }, [effectiveChatId, sendMessage, shouldUseNativeList, nativeChatEnabled, nativeChatJsFallbackEnabled]);

    useEffect(() => {
        if (!incomingVideoNote) return;
        if (!effectiveChatId) return;

        void sendAttachmentMessage('video', '', {
            mediaUrl: incomingVideoNote.uri,
            duration: incomingVideoNote.duration,
            isVideoNote: true,
        });
        onIncomingVideoNoteConsumed?.();
    }, [incomingVideoNote, effectiveChatId, onIncomingVideoNoteConsumed, sendAttachmentMessage]);

    const onGhostComplete = useCallback(() => {
        if (!ghostData) return;

        const completed = ghostData;

        // Reveal the real bubble instantly on the UI thread — no React state churn
        ghostHiddenId.value = '';

        const queued = queuedSendsRef.current.get(completed.messageId);
        const timer = queuedTimersRef.current.get(completed.messageId);
        if (timer) {
            clearTimeout(timer);
            queuedTimersRef.current.delete(completed.messageId);
        }
        if (queued) {
            queuedSendsRef.current.delete(completed.messageId);
            InteractionManager.runAfterInteractions(() => {
                setTimeout(() => runQueuedSend(queued), 50);
            });
        }

        setTimeout(() => {
            setGhostData(null);
        }, 10);
    }, [ghostData, runQueuedSend]);

    const visibleMessages = useMemo(() => {
        if (!searchActive) return messages;
        return messages.filter((message) => {
            const haystack = [
                message.text,
                message.caption,
                message.fileName,
            ]
                .filter((value): value is string => typeof value === 'string' && value.trim().length > 0)
                .join(' ')
                .toLowerCase();
            return haystack.includes(normalizedSearchQuery);
        });
    }, [messages, normalizedSearchQuery, searchActive]);

    const sequenceMetaById = useMemo(() => {
        if (shouldUseNativeList) return EMPTY_SEQUENCE_META;
        const meta = new Map<string, { isSequenceStart: boolean; isSequenceEnd: boolean }>();

        for (let i = 0; i < visibleMessages.length; i++) {
            const item = visibleMessages[i];
            const older = i > 0 ? visibleMessages[i - 1] : undefined;
            const newer = i < visibleMessages.length - 1 ? visibleMessages[i + 1] : undefined;
            meta.set(item.id, {
                isSequenceStart: !older || older.isMe !== item.isMe,
                isSequenceEnd: !newer || newer.isMe !== item.isMe,
            });
        }

        return meta;
    }, [visibleMessages, shouldUseNativeList]);

    const listRows = useMemo<ListRow[]>(() => {
        if (shouldUseNativeList) return EMPTY_LIST_ROWS;
        if (visibleMessages.length === 0) return [];

        const rows: ListRow[] = [];
        for (let i = 0; i < visibleMessages.length; i++) {
            const message = visibleMessages[i];
            const previous = i > 0 ? visibleMessages[i - 1] : undefined;
            if (!previous || !sameCalendarDay(previous.timestampMs, message.timestampMs)) {
                rows.push({
                    kind: 'day',
                    key: `d-${toDayKey(message.timestampMs)}-${message.id}`,
                    label: formatDayLabel(message.timestampMs),
                });
            }
            rows.push({ kind: 'message', key: `m-${message.id}`, message });
        }

        return rows;
    }, [visibleMessages, shouldUseNativeList]);

    const nativeRows = useMemo(() => {
        const t0 = Date.now();
        const rows = mapMessagesToNativeRows(visibleMessages.map((message) => ({
            id: message.id,
            chatId: message.chatId,
            fromId: message.fromId,
            timestamp: message.timestamp,
            text: message.text,
            type: message.type,
            status: message.status,
            mediaUrl: message.mediaUrl,
            fileName: message.fileName,
            duration: message.duration,
            waveform: Array.isArray(message.extra?.waveform)
                ? message.extra?.waveform.filter((v: unknown) => typeof v === 'number').map((v: number) => Math.max(0, Math.min(1, v)))
                : undefined,
            isVideoNote: !!message.isVideoNote,
            uploadProgress: uploadProgressById?.[message.id] || 0,
            isMe: message.isMe,
            timestampMs: message.timestampMs,
            isEdited: message.isEdited,
            editedAt: message.editedAt,
            replyToId: message.replyToId,
            reactionEmoji: message.reactionEmoji,
            encryptedContent: message.encryptedContent,
        })));
        chatListPerfLog('nativeRows:map', {
            visibleMessages: visibleMessages.length,
            rows: rows.length,
            dt: Date.now() - t0,
        });
        return rows;
    }, [visibleMessages, uploadProgressById, onlineUsers]);

    useEffect(() => {
        if (!shouldUseNativeList) return;
        const nativeChatEngine = getNativeChatEngineModule();
        if (!nativeChatEngine?.setPresenceSnapshot) return;
        const userIds = Array.from(onlineUsers).filter((id): id is string => typeof id === 'string' && id.length > 0);
        try {
            void nativeChatEngine.setPresenceSnapshot({ userIds });
        } catch (error) {
            console.warn('[ChatList] setPresenceSnapshot failed', error);
        }
    }, [shouldUseNativeList, onlineUsers]);

    const currentPinnedMessageId = pinnedMessageIds.length > 0
        ? pinnedMessageIds[Math.min(activePinnedIndex, pinnedMessageIds.length - 1)]
        : null;
    const currentPinnedMessage = currentPinnedMessageId
        ? messages.find((entry) => entry.id === currentPinnedMessageId)
        : null;

    const jumpToPinnedMessage = useCallback((messageId: string | null) => {
        if (!messageId) return;
        if (shouldUseNativeList) {
            (async () => {
                try {
                    await nativeSurfaceRef.current?.scrollToMessage(messageId, true, 0.46);
                } catch (error) {
                    console.error('[ChatList] scrollToMessage failed', error);
                }
            })();
            setHighlightedPinnedMessageId(messageId);
            setTimeout(() => {
                setHighlightedPinnedMessageId((current) => (current === messageId ? null : current));
            }, 1500);
            return;
        }
        const rowIndex = listRows.findIndex((row) => row.kind === 'message' && row.message.id === messageId);
        if (rowIndex < 0) {
            showToast('Pinned message is not loaded yet', 'info');
            return;
        }
        flatListRef.current?.scrollToIndex({
            index: rowIndex,
            animated: true,
            viewPosition: 0.46,
        });
        setHighlightedPinnedMessageId(messageId);
        setTimeout(() => {
            setHighlightedPinnedMessageId((current) => (current === messageId ? null : current));
        }, 1500);
    }, [shouldUseNativeList, listRows, showToast]);

    const handleMenuOpenChange = useCallback((messageId: string, open: boolean) => {
        if (open) {
            restoreKeyboardOnMenuCloseRef.current = keyboardVisibleRef.current;
            if (keyboardVisibleRef.current) {
                Keyboard.dismiss();
            }
            setActiveMenuId(messageId);
            return;
        }
        setActiveMenuId((current) => {
            if (current !== messageId) return current;
            return null;
        });
        if (restoreKeyboardOnMenuCloseRef.current) {
            restoreKeyboardOnMenuCloseRef.current = false;
            setTimeout(() => {
                setInputFocusTrigger((prev) => prev + 1);
            }, 220);
        }
    }, []);

    const renderItem = useCallback(
        ({ item }: { item: ListRow }) => {
            if (item.kind === 'day') {
                return <DateDivider label={item.label} />;
            }

            const message = item.message;
            const seq = sequenceMetaById.get(message.id) || { isSequenceStart: true, isSequenceEnd: true };
            return (
                <MessageBubble
                    item={message}
                    isSequenceStart={seq.isSequenceStart}
                    isSequenceEnd={seq.isSequenceEnd}
                    bubbleTheme={bubbleTheme}
                    onLayout={onBubbleLayout}
                    onMenuAction={handleBubbleMenuAction}
                    onReactionSelect={handleReactionSelect}
                    reactionEmoji={message.reactionEmoji}
                    reactionAvatarUri={reactionAvatarUri}
                    reactionAvatarLabel={reactionAvatarLabel}
                    onHold={onReplySwipeHaptic}
                    onReplySwipe={openReplyComposer}
                    isMenuOpen={activeMenuId === message.id}
                    onMenuOpenChange={(open: boolean) => handleMenuOpenChange(message.id, open)}
                    isPinned={pinnedMessageIds.includes(message.id)}
                    isPinnedHighlight={highlightedPinnedMessageId === message.id}
                    isDeleting={!!deletingMessageIds[message.id]}
                    onDeleteAnimationDone={completeDeleteMessage}
                    ghostHiddenId={ghostHiddenId}
                />
            );
        },
        [onBubbleLayout, sequenceMetaById, bubbleTheme, handleBubbleMenuAction, handleReactionSelect, reactionAvatarUri, reactionAvatarLabel, onReplySwipeHaptic, openReplyComposer, activeMenuId, handleMenuOpenChange, pinnedMessageIds, highlightedPinnedMessageId, deletingMessageIds, completeDeleteMessage, ghostHiddenId]
    );

    const listExtraData = useMemo(() => ({
        activeMenuId,
        pinnedMessageIds,
        highlightedPinnedMessageId,
        deletingMessageIds,
    }), [activeMenuId, pinnedMessageIds, highlightedPinnedMessageId, deletingMessageIds]);

    const handleReactionFxDone = useCallback((token: number) => {
        setReactionFxList((prev) => prev.filter((entry) => entry.token !== token));
    }, []);
    const handleReactionFlyDone = useCallback((token: number) => {
        setReactionFlyFx((current) => (
            current && current.token === token ? null : current
        ));
    }, []);

    if (forceNativeOnly && !nativeChatSupported) {
        return (
            <View style={[styles.container, { alignItems: 'center', justifyContent: 'center', paddingHorizontal: 24 }]}>
                <Text style={{ color: colors.text, textAlign: 'center', opacity: 0.9 }}>
                    Native chat list is not available on this build.
                </Text>
            </View>
        );
    }

    return (
        <View style={styles.container}>
            {/* Header handled by parent ChatScreen */}

            {!shouldUseNativeList && !searchActive && currentPinnedMessage && (
                <GlobalPinnedBanner
                    onPress={() => jumpToPinnedMessage(currentPinnedMessageId)}
                    body={currentPinnedMessage.text?.trim() || (currentPinnedMessage.type === 'text' ? 'Message' : currentPinnedMessage.type)}
                    dotIds={pinnedMessageIds}
                    activeDotIndex={activePinnedIndex}
                />
            )}

            <Animated.View style={[styles.listArea, !shouldUseNativeList && pageShiftStyle]}>
                {shouldUseNativeList ? (
                    <NativeChatSurface
                        ref={nativeSurfaceRef}
                        surfaceId={nativeSurfaceId}
                        rows={nativeRows}
                        engineSurfaceId={nativeSurfaceId}
                        chatId={effectiveChatId || undefined}
                        myUserId={user?.userId || undefined}
                        peerUserId={activeChat?.friendId || undefined}
                        statusAuthorityEnabled
                        appearance={nativeAppearance}
                        contentPaddingTop={nativeListTopPadding}
                        contentPaddingBottom={14}
                        inputBarEnabled
                        inputPlaceholder="Message"
                        nativeSendEnabled
                        onViewportChanged={handleNativeViewportChanged}
                        onNativeEvent={handleNativeSurfaceEvent}
                        onNativeError={handleNativeSurfaceError}
                    />
                ) : (
                    <FlashList
                        ref={flatListRef}
                        data={listRows}
                        renderItem={renderItem}
                        extraData={listExtraData}
                        keyExtractor={(item) => item.key}
                        estimatedItemSize={96}
                        drawDistance={420}
                        getItemType={(item) => item.kind}
                        initialNumToRender={LIST_INITIAL_RENDER}
                        maxToRenderPerBatch={LIST_BATCH_RENDER}
                        windowSize={LIST_WINDOW_SIZE}
                        maintainVisibleContentPosition={{
                            autoscrollToBottomThreshold: LIST_BOTTOM_AUTOSCROLL_THRESHOLD,
                            animateAutoScrollToBottom: true,
                            startRenderingFromBottom: true,
                        }}
                        contentContainerStyle={{
                            paddingTop: jsListTopPadding,
                            paddingBottom: listBottomPadding,
                        }}
                        showsVerticalScrollIndicator={false}
                        keyboardDismissMode="interactive"
                        keyboardShouldPersistTaps="handled"
                        onLayout={(event) => {
                            listMetricsRef.current.layoutHeight = event.nativeEvent.layout.height;
                        }}
                        onContentSizeChange={(_w, h) => {
                            listMetricsRef.current.contentHeight = h;
                        }}
                        onScroll={(event) => {
                            const { contentOffset, layoutMeasurement, contentSize } = event.nativeEvent;
                            const deltaY = contentOffset.y - fallbackScrollOffsetYRef.current;
                            fallbackScrollOffsetYRef.current = contentOffset.y;
                            listMetricsRef.current.offsetY = contentOffset.y;
                            listMetricsRef.current.layoutHeight = layoutMeasurement.height;
                            listMetricsRef.current.contentHeight = contentSize.height;
                            if (Math.abs(deltaY) > 0.1 && activeGhostMessageIdRef.current) {
                                ghostTargetY.value -= deltaY;
                            }
                        }}
                        scrollEventThrottle={16}
                        ListHeaderComponent={ListHeaderComponent}
                    />
                )}
            </Animated.View>

            {!shouldUseNativeList && (
                <KeyboardStickyView
                    offset={keyboardStickyOffset}
                    style={styles.inputStickyHost}
                >
                    <View style={styles.inputStickyContainer}>
                        <View style={[styles.footerMask, { height: footerMaskHeight }]} pointerEvents="none">
                            <MaskedViewAny
                                style={StyleSheet.absoluteFill}
                                maskElement={<LinearGradient colors={['rgba(0,0,0,0)', 'rgba(0,0,0,0.92)']} locations={[0.1, 1]} style={StyleSheet.absoluteFill} />}
                            >
                                <BlurView
                                    intensity={25}
                                    tint={effectiveTheme === 'dark' ? 'dark' : 'light'}
                                    style={[StyleSheet.absoluteFill, { backgroundColor: withAlpha(resolvedTheme.backgroundGradient?.[0] || '#000', 0.88) }]}
                                />
                            </MaskedViewAny>
                        </View>

                        <Animated.View
                            ref={inputBarRef}
                            style={[styles.inputBar, inputMarginStyle, inputBottomPaddingStyle, { paddingTop: inputVerticalPadding }]}
                        >
                            <Input
                                autoFocus={false}
                                text={text}
                                setText={setText}
                                onSend={handleSend}
                                editable={!!effectiveChatId}
                                focusTrigger={inputFocusTrigger}
                                placeholder={effectiveChatId ? 'Message' : 'No active chat'}
                                replyTo={replyTo}
                                onCancelReply={() => setReplyTo(null)}
                                editTarget={editTarget}
                                onCancelEdit={() => setEditTarget(null)}
                                onTypingStatusChange={onTypingStatusChange}
                                onAttachImage={(uri, width, height) => {
                                    void sendAttachmentMessage('image', '', {
                                        mediaUrl: uri,
                                        width,
                                        height,
                                    });
                                }}
                                onAttachFile={(uri, name) => {
                                    void sendAttachmentMessage('file', name || 'File', {
                                        mediaUrl: uri,
                                        fileName: name || 'file',
                                    });
                                }}
                                onAttachLocation={(coords) => {
                                    void sendAttachmentMessage(
                                        'location',
                                        `Location: ${coords.latitude.toFixed(5)}, ${coords.longitude.toFixed(5)}`,
                                        {
                                            latitude: coords.latitude,
                                            longitude: coords.longitude,
                                        }
                                    );
                                }}
                                onAttachContact={(contact) => {
                                    void sendAttachmentMessage(
                                        'contact',
                                        contact.username || contact.phoneNumber || 'Contact',
                                        { contact }
                                    );
                                }}
                                onAttachVoice={(uri, durationSec, waveform) => {
                                    void sendAttachmentMessage('voice', '', {
                                        mediaUrl: uri,
                                        duration: durationSec,
                                        fileName: 'voice-message.m4a',
                                        waveform,
                                    });
                                }}
                                onVideoRecordStart={() => {
                                    onVideoNoteStart?.();
                                }}
                                onVideoRecordStop={(canceled) => {
                                    onVideoNoteStop?.(canceled);
                                }}
                                onRecordingUiChange={onRecordingUiChange}
                            />
                        </Animated.View>
                    </View>
                </KeyboardStickyView>
            )}

            {
                !shouldUseNativeList && !ghostData && pendingGhost && (
                    <View
                        style={{
                            position: 'absolute',
                            left: pendingGhost.startX,
                            top: pendingGhost.startY,
                            width: pendingGhost.startWidth,
                            height: pendingGhost.startHeight,
                            zIndex: 9999,
                        }}
                        pointerEvents="none"
                    >
                        <View style={styles.crossfadeContent}>
                            <View
                                style={{
                                    position: 'absolute',
                                    left: BUBBLE_PADDING_H,
                                    top: BUBBLE_PADDING_V,
                                    right: BUBBLE_PADDING_H,
                                }}
                            >
                                <Text style={styles.bubbleTextInput} numberOfLines={1}>{pendingGhost.text}</Text>
                            </View>
                        </View>
                    </View>
                )
            }

            {
                !shouldUseNativeList && ghostData && (
                    <CrossfadeOverlay
                        text={ghostData.text}
                        timestamp={ghostData.timestamp}
                        startX={ghostData.startX}
                        startY={ghostData.startY}
                        startWidth={ghostData.startWidth}
                        startHeight={ghostData.startHeight}
                        targetX={ghostTargetX}
                        targetY={ghostTargetY}
                        targetWidth={ghostTargetWidth}
                        targetHeight={ghostTargetHeight}
                        shape={ghostData.shape}
                        bubbleTheme={bubbleTheme}
                        onComplete={onGhostComplete}
                    />
                )
            }

            {!shouldUseNativeList && (
                <ReactionOverlays
                    reactionFxList={reactionFxList}
                    reactionFlyFx={reactionFlyFx}
                    onReactionFxDone={handleReactionFxDone}
                    onReactionFlyDone={handleReactionFlyDone}
                />
            )}
        </View >
    );
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: 'transparent',
    },
    listArea: {
        flex: 1,
        overflow: 'visible',
    },
    listContent: {
        paddingHorizontal: 16,
        paddingTop: 10,
        paddingBottom: 10,
        flexGrow: 1,
        justifyContent: 'flex-end',
        overflow: 'visible',
    },
    listCell: {
        overflow: 'visible',
        position: 'relative',
        zIndex: 1,
    },
    listCellActive: {
        zIndex: 30000,
        elevation: 30000,
        position: 'relative',
    },
    inputStickyHost: {
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: 0,
        width: '100%',
        zIndex: 1000,
    },
    inputStickyContainer: {
        width: '100%',
        position: 'relative',
        flexDirection: 'row',
        alignItems: 'flex-end',
    },
    footerMask: {
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: -10,
        zIndex: -1,
        overflow: 'hidden',
    },
    bubbleWrapper: {
        maxWidth: '85%',
        marginTop: 1,
        marginBottom: 1,
        position: 'relative',
    },
    dayDividerWrap: {
        width: '100%',
        alignItems: 'center',
        paddingVertical: 6,
    },
    dayDividerPill: {
        paddingHorizontal: 11,
        paddingVertical: 4,
        borderRadius: 12,
        backgroundColor: 'rgba(20,20,34,0.42)',
        borderWidth: StyleSheet.hairlineWidth,
        borderColor: 'rgba(255,255,255,0.16)',
    },
    dayDividerText: {
        fontSize: 11,
        color: 'rgba(236,239,255,0.82)',
        fontWeight: '600',
        letterSpacing: 0.2,
    },
    bubbleWrapperMenuOpen: {
        zIndex: 31000,
        elevation: 31000,
    },
    bubbleLiftLayer: {
        zIndex: 2,
    },
    deleteClipHost: {
        overflow: 'hidden',
        alignSelf: 'flex-start',
    },
    deleteWaterSweep: {
        position: 'absolute',
        top: -2,
        bottom: -2,
        width: 30,
        borderRadius: 16,
        backgroundColor: 'rgba(255,255,255,0.32)',
        borderWidth: StyleSheet.hairlineWidth,
        borderColor: 'rgba(255,255,255,0.46)',
    },
    inlineBubbleHidden: {
        opacity: 0,
    },
    menuModalRoot: {
        flex: 1,
    },
    overlayLiftHost: {
        position: 'absolute',
        zIndex: 50,
        elevation: 50,
    },
    menuTouchArea: {
        alignSelf: 'stretch',
    },
    bubble: {
        borderRadius: BUBBLE_RADIUS,
        padding: BUBBLE_PADDING_V,
        paddingHorizontal: BUBBLE_PADDING_H,
        minWidth: BUBBLE_MIN_WIDTH,
    },
    messageContainer: {
        position: 'relative',
        overflow: 'visible',
    },
    reactionBadge: {
        position: 'absolute',
        left: 8,
        bottom: 6,
        minWidth: 48,
        height: 22,
        paddingHorizontal: 4,
        borderRadius: 11,
        flexDirection: 'row',
        gap: 4,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(255,255,255,0.86)',
        borderWidth: StyleSheet.hairlineWidth,
        borderColor: 'rgba(0,0,0,0.15)',
        zIndex: 9,
    },
    reactionBadgeText: {
        fontSize: 14,
        marginLeft: 1,
    },
    reactionBadgeAvatar: {
        width: 16,
        height: 16,
        borderRadius: 8,
        backgroundColor: 'rgba(255,255,255,0.92)',
    },
    reactionBadgeAvatarFallback: {
        width: 16,
        height: 16,
        borderRadius: 8,
        backgroundColor: 'rgba(96,116,255,0.24)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    reactionBadgeAvatarInitial: {
        fontSize: 9,
        fontWeight: '700',
        color: 'rgba(37,46,81,0.95)',
    },
    mediaOnlyBubble: {
        backgroundColor: 'transparent',
        padding: 0,
        minWidth: 0,
        overflow: 'visible',
    },
    messageLine: {
        flexDirection: 'row',
        alignItems: 'flex-end',
    },
    timeMetaInline: {
        flexDirection: 'row',
        alignItems: 'center',
        marginLeft: 6,
        marginBottom: 0,
        gap: 3,
        flexShrink: 0,
        opacity: BUBBLE_TIME_OPACITY,
    },
    timeText: {
        fontSize: BUBBLE_TIME_SIZE,
        color: 'rgba(255,255,255,0.7)',
    },
    timeTextThem: {
        fontSize: BUBBLE_TIME_SIZE,
        color: 'rgba(255,255,255,0.5)',
    },
    statusPending: {
        fontSize: 10.5,
        lineHeight: 12,
        color: 'rgba(255,255,255,0.78)',
        marginLeft: 1,
        fontWeight: '600',
    },
    statusSending: {
        fontSize: 11,
        lineHeight: 12,
        color: 'rgba(255,255,255,0.78)',
        marginLeft: 1,
        fontWeight: '700',
    },
    statusSent: {
        fontSize: 11,
        lineHeight: 12,
        color: 'rgba(255,255,255,0.92)',
        marginLeft: 1,
        fontWeight: '700',
        textShadowColor: 'rgba(255,255,255,0.3)',
        textShadowRadius: 2,
    },
    statusError: {
        fontSize: 10,
        lineHeight: 11,
        color: '#ff7b7b',
        marginLeft: 1,
        fontWeight: '700',
    },
    doubleCheckWrap: {
        flexDirection: 'row',
        alignItems: 'center',
        marginLeft: 1,
        minWidth: 12,
        marginBottom: 0.2,
    },
    statusCheckBase: {
        fontSize: 11,
        lineHeight: 12,
        fontWeight: '700',
    },
    statusCheckSecond: {
        marginLeft: -4,
    },
    statusCheckGlow: {
        textShadowColor: 'rgba(108,184,255,0.95)',
        textShadowRadius: 4,
    },
    menuBackdropTint: {
        ...StyleSheet.absoluteFillObject,
        backgroundColor: withAlpha('#05070c', 0.5),
    },
    reactionMenuWrap: {
        position: 'absolute',
        zIndex: 24,
    },
    reactionMenuWrapAbove: {
        top: -58,
    },
    reactionMenuWrapMe: {
        right: 0,
    },
    reactionMenuWrapThem: {
        left: 0,
    },
    actionMenuWrapBelow: {
        position: 'absolute',
        top: '100%',
        marginTop: 12,
        zIndex: 24,
    },
    actionMenuWrapAbove: {
        position: 'absolute',
        bottom: '100%',
        marginBottom: 12,
        zIndex: 24,
    },
    actionMenuWrapMe: {
        right: 0,
    },
    actionMenuWrapThem: {
        left: 0,
    },
    bubbleTextMe: {
        color: '#fff',
        fontSize: BUBBLE_TEXT_SIZE,
        lineHeight: BUBBLE_TEXT_LINE_HEIGHT,
        flexShrink: 1,
    },
    bubbleTextThem: {
        color: '#ddd',
        fontSize: BUBBLE_TEXT_SIZE,
        lineHeight: BUBBLE_TEXT_LINE_HEIGHT,
        flexShrink: 1,
    },
    inputBar: {
        flex: 1,
        backgroundColor: 'transparent',
    },
    crossfadeContent: {
        flex: 1,
        paddingTop: BUBBLE_PADDING_V,
        paddingHorizontal: BUBBLE_PADDING_H,
        paddingBottom: BUBBLE_PADDING_V,
    },
    bubbleTextInput: {
        color: INPUT_TEXT_COLOR,
        fontSize: BUBBLE_TEXT_SIZE,
        lineHeight: BUBBLE_TEXT_LINE_HEIGHT,
        textAlign: 'left',
    },
    pinBadge: {
        position: 'absolute',
        right: 6,
        top: 6,
        width: 20,
        height: 20,
        borderRadius: 10,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: withAlpha('#081018', 0.52),
        borderWidth: StyleSheet.hairlineWidth,
        borderColor: withAlpha('#f4b83a', 0.72),
    },
});
