import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Platform, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import Animated, {
    Easing,
    Extrapolation,
    interpolate,
    useAnimatedStyle,
    useDerivedValue,
    useSharedValue,
    withRepeat,
    withSpring,
    withTiming,
} from 'react-native-reanimated';
import { ChevronLeft, ChevronUp, Lock, Mic, Send, Video, X } from 'lucide-react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import { Audio } from 'expo-av';
import { LinearGradient } from 'expo-linear-gradient';

import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { AttachmentMenu } from './AttachmentMenu';
import { Contact } from '../../lib/stores/contact-store';
import { AnimatedGifToSmileIcon, VibeLogoIcon } from '../Icons';
import { haptics } from '../../lib/haptics';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useWallpaperStore, resolveThemeVariant } from '../../lib/stores/wallpaper-store';

const HOLD_TO_RECORD_DELAY_MS = 110;
const CANCEL_DISTANCE = 122;
const LOCK_DISTANCE = -94;
const VAD_DB_FLOOR = -60;
const COMPOSER_BASE_HEIGHT = 40;

export interface ReplyInfo {
    messageId: string;
    userName: string;
    text: string;
    isFromMe: boolean;
}

export interface EditInfo {
    messageId: string;
    text: string;
}

export interface TextInputFrame {
    x: number;
    y: number;
    width: number;
    height: number;
}

interface InputProps {
    text: string;
    setText: (value: string) => void;
    onSend: () => void;
    placeholder?: string;
    editable?: boolean;
    focusTrigger?: number;
    autoFocus?: boolean;
    onFocusChange?: (focused: boolean) => void;
    onTypingStatusChange?: (isTyping: boolean) => void;
    onGifPress?: () => void;
    onMicPress?: () => void;
    onAttachImage?: (uri: string, width?: number, height?: number) => void;
    onAttachFile?: (uri: string, name: string) => void;
    onAttachLocation?: (coords: { latitude: number; longitude: number }) => void;
    onAttachContact?: (contact: Contact) => void;
    onAttachVoice?: (uri: string, durationSec?: number, waveform?: number[]) => void;
    onVideoRecordStart?: () => void;
    onVideoRecordStop?: (canceled: boolean) => void;
    replyTo?: ReplyInfo | null;
    onCancelReply?: () => void;
    editTarget?: EditInfo | null;
    onCancelEdit?: () => void;
    onRecordingUiChange?: (state: {
        isRecording: boolean;
        isLocked: boolean;
        mode: 'voice' | 'video';
        vad: number;
    }) => void;
    onTextInputFrameChange?: (frame: TextInputFrame) => void;
}

const formatDuration = (elapsedMs: number) => {
    const totalSeconds = Math.floor(Math.max(0, elapsedMs) / 1000);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    return `${minutes}:${String(seconds).padStart(2, '0')}`;
};

export default function Input({
    text,
    setText,
    onSend,
    placeholder = 'Text Message • SMS',
    editable = true,
    focusTrigger,
    autoFocus = false,
    onFocusChange,
    onTypingStatusChange,
    onGifPress,
    onAttachImage,
    onAttachFile,
    onAttachLocation,
    onAttachContact,
    onAttachVoice,
    onVideoRecordStart,
    onVideoRecordStop,
    replyTo,
    onCancelReply,
    editTarget,
    onCancelEdit,
    onRecordingUiChange,
    onTextInputFrameChange,
}: InputProps) {
    const { colors, effectiveTheme } = useThemeStore();
    const isDark = effectiveTheme === 'dark';
    const { activeTheme } = useWallpaperStore();
    const [focused, setFocused] = useState(false);
    const [isRecording, setIsRecording] = useState(false);
    const [isLocked, setIsLocked] = useState(false);
    const [recordingMode, setRecordingMode] = useState<'voice' | 'video'>('voice');
    const [recordingElapsedMs, setRecordingElapsedMs] = useState(0);
    const [replyBannerSnapshot, setReplyBannerSnapshot] = useState<{
        author: string;
        body: string;
        accentColor: string;
    }>({
        author: 'User',
        body: 'Message',
        accentColor: 'rgba(255,255,255,0.65)',
    });

    const textInputRef = useRef<TextInput>(null);
    const recordingRef = useRef<Audio.Recording | null>(null);
    const recordingModeAtStartRef = useRef<'voice' | 'video'>('voice');
    const recordingWaveformRef = useRef<number[]>([]);
    const lastWavePointAtRef = useRef(0);
    const isStartingRef = useRef(false);
    const isStoppingRef = useRef(false);
    const tickerRef = useRef<ReturnType<typeof setInterval> | null>(null);
    const lastEditIdRef = useRef<string | null>(null);
    const [vadUiLevel, setVadUiLevel] = useState(0);

    const hasText = text.trim().length > 0;
    const canSend = hasText && editable;
    const hasContextBanner = !!replyTo || !!editTarget;

    const sendProgress = useSharedValue(canSend ? 1 : 0);
    const focusProgress = useSharedValue((focused || hasText) ? 1 : 0);
    const recordingProgress = useSharedValue(0);
    const contextProgress = useSharedValue(hasContextBanner ? 1 : 0);
    const dragX = useSharedValue(0);
    const dragY = useSharedValue(0);
    const vadLevel = useSharedValue(0);
    const arrowLeftPhase = useSharedValue(0);
    const arrowUpPhase = useSharedValue(0);
    const micPressScale = useSharedValue(1);
    const gifProgress = useSharedValue(0);

    const inputContainerStyle = useAnimatedStyle(() => ({
        opacity: interpolate(recordingProgress.value, [0, 1], [1, 0]),
        transform: [
            { scale: interpolate(recordingProgress.value, [0, 1], [1, 0.95]) },
        ],
    }));

    const recordingContainerStyle = useAnimatedStyle(() => ({
        opacity: recordingProgress.value,
        zIndex: recordingProgress.value > 0.5 ? 10 : -1,
        transform: [
            { scale: interpolate(recordingProgress.value, [0, 1], [0.95, 1]) },
        ],
    }));

    const lockDragProgress = useDerivedValue(() => interpolate(-dragY.value, [0, Math.abs(LOCK_DISTANCE)], [0, 1], Extrapolation.CLAMP));

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
    const sendGradient = useMemo<[string, string]>(() => {
        if (resolvedTheme.bubbleMeGradient && resolvedTheme.bubbleMeGradient.length >= 2) {
            return [resolvedTheme.bubbleMeGradient[0], resolvedTheme.bubbleMeGradient[1]];
        }
        const solid = resolvedTheme.bubbleMe || '#3b82f6';
        return [solid, solid];
    }, [resolvedTheme]);
    const auxButtonGlassBg = isDark ? 'rgba(28,30,38,0.66)' : 'rgba(255,255,255,0.74)';
    const auxButtonBorder = isDark ? 'rgba(255,255,255,0.1)' : 'rgba(255,255,255,0.42)';

    const clearTicker = useCallback(() => {
        if (tickerRef.current) {
            clearInterval(tickerRef.current);
            tickerRef.current = null;
        }
    }, []);

    const startTicker = useCallback(() => {
        clearTicker();
        const startedAt = Date.now();
        setRecordingElapsedMs(0);
        tickerRef.current = setInterval(() => {
            setRecordingElapsedMs(Date.now() - startedAt);
        }, 50);
    }, [clearTicker]);

    useEffect(() => {
        return () => {
            clearTicker();
            void (async () => {
                const current = recordingRef.current;
                if (!current) return;
                try {
                    await current.stopAndUnloadAsync();
                } catch {
                    // Ignore cleanup errors.
                }
                recordingRef.current = null;
            })();
        };
    }, [clearTicker]);

    useEffect(() => {
        gifProgress.value = withTiming(0, { duration: 1100 });
    }, [gifProgress]);

    useEffect(() => {
        sendProgress.value = withTiming(canSend ? 1 : 0, {
            duration: 220,
            easing: Easing.out(Easing.cubic),
        });
    }, [canSend, sendProgress]);

    useEffect(() => {
        focusProgress.value = withTiming((focused || hasText) ? 1 : 0, {
            duration: 200,
            easing: Easing.out(Easing.quad),
        });
    }, [focused, hasText, focusProgress]);

    useEffect(() => {
        recordingProgress.value = withTiming(isRecording ? 1 : 0, {
            duration: 220,
            easing: Easing.out(Easing.cubic),
        });
    }, [isRecording, recordingProgress]);

    useEffect(() => {
        contextProgress.value = withTiming(hasContextBanner ? 1 : 0, {
            duration: hasContextBanner ? 180 : 130,
            easing: hasContextBanner
                ? Easing.bezier(0.22, 0.9, 0.35, 1)
                : Easing.in(Easing.quad),
        });
    }, [hasContextBanner, contextProgress]);

    useEffect(() => {
        if (editTarget) {
            setReplyBannerSnapshot({
                author: 'Editing message',
                body: editTarget.text || 'Message',
                accentColor: 'rgba(255,195,84,0.96)',
            });
            return;
        }
        if (replyTo) {
            setReplyBannerSnapshot({
                author: replyTo.userName || 'User',
                body: replyTo.text || 'Message',
                accentColor: replyTo.isFromMe ? sendGradient[1] : 'rgba(255,255,255,0.65)',
            });
        }
    }, [editTarget, replyTo, sendGradient]);

    useEffect(() => {
        if (!replyTo) return;
        requestAnimationFrame(() => {
            textInputRef.current?.focus();
        });
    }, [replyTo]);

    useEffect(() => {
        if (!editable) return;
        if (typeof focusTrigger !== 'number' || focusTrigger === 0) return;
        requestAnimationFrame(() => {
            textInputRef.current?.focus();
        });
    }, [focusTrigger, editable]);

    useEffect(() => {
        const nextEditId = editTarget?.messageId ?? null;
        if (nextEditId && nextEditId !== lastEditIdRef.current) {
            requestAnimationFrame(() => {
                textInputRef.current?.focus();
            });
        }
        lastEditIdRef.current = nextEditId;
    }, [editTarget?.messageId]);

    useEffect(() => {
        if (isRecording && !isLocked) {
            arrowLeftPhase.value = withRepeat(
                withTiming(1, {
                    duration: 540,
                    easing: Easing.inOut(Easing.quad),
                }),
                -1,
                true,
            );
            arrowUpPhase.value = withRepeat(
                withTiming(1, {
                    duration: 520,
                    easing: Easing.inOut(Easing.quad),
                }),
                -1,
                true,
            );
            return;
        }

        arrowLeftPhase.value = withTiming(0, { duration: 120 });
        arrowUpPhase.value = withTiming(0, { duration: 120 });
    }, [isRecording, isLocked, arrowLeftPhase, arrowUpPhase]);

    useEffect(() => {
        onTypingStatusChange?.(hasText);
    }, [hasText, onTypingStatusChange]);

    useEffect(() => {
        onRecordingUiChange?.({
            isRecording,
            isLocked,
            mode: isRecording ? recordingModeAtStartRef.current : recordingMode,
            vad: vadUiLevel,
        });
    }, [isRecording, isLocked, recordingMode, vadUiLevel, onRecordingUiChange]);

    const applyVadFromMetering = useCallback((metering: number) => {
        const clampedDb = Math.max(VAD_DB_FLOOR, Math.min(0, metering));
        const normalized = (clampedDb - VAD_DB_FLOOR) / Math.abs(VAD_DB_FLOOR);
        vadLevel.value = withTiming(normalized, { duration: 60, easing: Easing.out(Easing.quad) });
        setVadUiLevel(normalized);
        const now = Date.now();
        if (now - lastWavePointAtRef.current >= 55) {
            lastWavePointAtRef.current = now;
            recordingWaveformRef.current.push(normalized);
            if (recordingWaveformRef.current.length > 180) {
                recordingWaveformRef.current.shift();
            }
        }
    }, [vadLevel]);

    const handleRecordingStatusUpdate = useCallback((status: Audio.RecordingStatus) => {
        const metering = (status as Audio.RecordingStatus & { metering?: number }).metering;
        if (typeof metering === 'number') {
            applyVadFromMetering(metering);
        }
    }, [applyVadFromMetering]);

    const startRecording = useCallback(async () => {
        if (!editable || isRecording || isStartingRef.current || isStoppingRef.current) return;
        isStartingRef.current = true;
        recordingModeAtStartRef.current = recordingMode;
        setRecordingElapsedMs(0);
        setVadUiLevel(0);
        recordingWaveformRef.current = [];
        lastWavePointAtRef.current = 0;
        vadLevel.value = withTiming(0, { duration: 80 });
        haptics.medium();

        try {
            if (recordingMode === 'video') {
                setIsLocked(false);
                setIsRecording(true);
                startTicker();
                dragX.value = 0;
                dragY.value = 0;
                onVideoRecordStart?.();
                return;
            }

            const permission = await Audio.requestPermissionsAsync();
            if (permission.status !== 'granted') return;

            await Audio.setAudioModeAsync({
                allowsRecordingIOS: true,
                playsInSilentModeIOS: true,
            });

            const recordingOptions: Audio.RecordingOptions = {
                ...Audio.RecordingOptionsPresets.HIGH_QUALITY,
                isMeteringEnabled: true,
            };

            const nextRecording = new Audio.Recording();
            (nextRecording as any).setOnRecordingStatusUpdate?.(handleRecordingStatusUpdate);
            (nextRecording as any).setProgressUpdateInterval?.(60);

            await nextRecording.prepareToRecordAsync(recordingOptions);
            await nextRecording.startAsync();

            recordingRef.current = nextRecording;
            setIsLocked(false);
            setIsRecording(true);
            startTicker();
            dragX.value = 0;
            dragY.value = 0;
        } catch {
            // Ignore start failure and keep UI stable.
        } finally {
            isStartingRef.current = false;
        }
    }, [editable, isRecording, recordingMode, startTicker, onVideoRecordStart, handleRecordingStatusUpdate, vadLevel, dragX, dragY]);

    const stopRecording = useCallback(async (canceled = false) => {
        if (isStoppingRef.current) return;
        if (!isRecording && !isStartingRef.current) return;

        isStoppingRef.current = true;
        const activeMode = recordingModeAtStartRef.current;

        setIsRecording(false);
        setIsLocked(false);
        dragX.value = withSpring(0, { damping: 18, stiffness: 180 });
        dragY.value = withSpring(0, { damping: 18, stiffness: 180 });
        clearTicker();
        vadLevel.value = withTiming(0, { duration: 120 });
        setVadUiLevel(0);

        try {
            if (activeMode === 'video') {
                onVideoRecordStop?.(canceled);
                if (!canceled) {
                    haptics.success();
                } else {
                    haptics.light();
                }
                return;
            }

            const current = recordingRef.current;
            if (!current) return;

            let uri: string | null = null;
            try {
                await current.stopAndUnloadAsync();
                uri = current.getURI() ?? null;
            } catch {
                uri = null;
            }
            recordingRef.current = null;

            try {
                await Audio.setAudioModeAsync({
                    allowsRecordingIOS: false,
                    playsInSilentModeIOS: true,
                });
            } catch {
                // Ignore reset failures.
            }

            if (!canceled && uri) {
                const raw = recordingWaveformRef.current;
                const steps = 28;
                const waveform = raw.length > 0
                    ? Array.from({ length: steps }, (_, idx) => {
                        const from = Math.floor((idx / steps) * raw.length);
                        const to = Math.max(from + 1, Math.floor(((idx + 1) / steps) * raw.length));
                        let sum = 0;
                        let count = 0;
                        for (let i = from; i < to; i++) {
                            sum += raw[i] || 0;
                            count += 1;
                        }
                        return count > 0 ? sum / count : 0;
                    })
                    : undefined;
                onAttachVoice?.(uri, recordingElapsedMs / 1000, waveform);
                haptics.success();
            } else if (canceled) {
                haptics.light();
            }
        } finally {
            isStoppingRef.current = false;
        }
    }, [isRecording, dragX, dragY, clearTicker, vadLevel, onVideoRecordStop, onAttachVoice, recordingElapsedMs]);

    const lockRecording = useCallback(() => {
        haptics.heavy();
        setIsLocked(true);
        dragX.value = withSpring(0, { damping: 18, stiffness: 180 });
        dragY.value = withSpring(0, { damping: 18, stiffness: 180 });
    }, [dragX, dragY]);

    const recordGesture = Gesture.Pan()
        .runOnJS(true)
        .activateAfterLongPress(HOLD_TO_RECORD_DELAY_MS)
        .minDistance(0)
        .onStart(() => {
            startRecording();
        })
        .onUpdate((e) => {
            dragX.value = Math.min(0, e.translationX);
            dragY.value = Math.min(0, e.translationY);
        })
        .onEnd((e) => {
            if (e.translationX < -CANCEL_DISTANCE) {
                stopRecording(true);
                return;
            }
            if (e.translationY < LOCK_DISTANCE) {
                lockRecording();
                return;
            }
            stopRecording(false);
        });

    const shellStyle = useAnimatedStyle(() => ({
        borderRadius: interpolate(focusProgress.value, [0, 1], [22, 22]),
        minHeight: interpolate(focusProgress.value, [0, 1], [COMPOSER_BASE_HEIGHT, COMPOSER_BASE_HEIGHT]),
    }));

    const shellMorphStyle = useAnimatedStyle(() => {
        return {
            marginRight: 0,
        };
    });

    const toolsStyle = useAnimatedStyle(() => {
        const hidden = recordingProgress.value;
        return {
            opacity: interpolate(hidden, [0, 1], [1, 0], Extrapolation.CLAMP),
            width: interpolate(hidden, [0, 1], [36, 0], Extrapolation.CLAMP),
            transform: [{ translateX: interpolate(hidden, [0, 1], [0, 8], Extrapolation.CLAMP) }],
        };
    });

    const sendWrapStyle = useAnimatedStyle(() => {
        const p = sendProgress.value * (1 - recordingProgress.value);
        return {
            width: interpolate(p, [0, 1], [0, 40], Extrapolation.CLAMP),
            opacity: interpolate(p, [0, 0.35, 1], [0, 0.4, 1], Extrapolation.CLAMP),
            transform: [
                { scale: interpolate(p, [0, 1], [0.74, 1], Extrapolation.CLAMP) },
                { translateY: interpolate(p, [0, 1], [6, 0], Extrapolation.CLAMP) },
            ],
        };
    });

    const micSlotStyle = useAnimatedStyle(() => {
        const hideByTyping = sendProgress.value * (1 - recordingProgress.value);
        return {
            opacity: interpolate(hideByTyping, [0, 1], [1, 0], Extrapolation.CLAMP),
            width: interpolate(hideByTyping, [0, 1], [40, 0], Extrapolation.CLAMP),
            transform: [
                { translateX: interpolate(hideByTyping, [0, 1], [0, 36], Extrapolation.CLAMP) },
                { scale: interpolate(hideByTyping, [0, 1], [1, 0.88], Extrapolation.CLAMP) },
            ],
        };
    });

    const replyWrapStyle = useAnimatedStyle(() => ({
        opacity: contextProgress.value,
        height: interpolate(contextProgress.value, [0, 1], [0, 44], Extrapolation.CLAMP),
        paddingTop: interpolate(contextProgress.value, [0, 1], [0, 8], Extrapolation.CLAMP),
        marginBottom: interpolate(contextProgress.value, [0, 1], [0, 6], Extrapolation.CLAMP),
        transform: [{ translateY: interpolate(contextProgress.value, [0, 1], [-8, 0], Extrapolation.CLAMP) }],
    }));

    const replyTextFadeStyle = useAnimatedStyle(() => ({
        opacity: interpolate(contextProgress.value, [0, 0.35, 1], [0, 0.12, 1], Extrapolation.CLAMP),
    }));

    const micShellStyle = useAnimatedStyle(() => ({
        transform: [
            { scale: micPressScale.value * interpolate(recordingProgress.value, [0, 1], [1, 1.95], Extrapolation.CLAMP) },
            { translateY: interpolate(recordingProgress.value, [0, 1], [0, -8], Extrapolation.CLAMP) },
        ],
    }));

    const cancelHintStyle = useAnimatedStyle(() => ({
        opacity: recordingProgress.value * (1 - (isLocked ? 1 : 0)),
        transform: [
            { translateX: interpolate(arrowLeftPhase.value, [0, 1], [0, -10], Extrapolation.CLAMP) },
        ],
    }));

    const lockPillStyle = useAnimatedStyle(() => ({
        opacity: recordingProgress.value * (isLocked ? 0 : 1),
        bottom: interpolate(recordingProgress.value, [0, 1], [56, 172], Extrapolation.CLAMP),
        transform: [
            { scale: interpolate(lockDragProgress.value, [0, 1], [1, 1.08], Extrapolation.CLAMP) },
            { translateY: interpolate(lockDragProgress.value, [0, 1], [0, -18], Extrapolation.CLAMP) },
        ],
    }));

    const lockArrowStyle = useAnimatedStyle(() => ({
        opacity: interpolate(arrowUpPhase.value, [0, 1], [0.62, 1], Extrapolation.CLAMP),
        transform: [{ translateY: interpolate(arrowUpPhase.value, [0, 1], [0, -8], Extrapolation.CLAMP) }],
    }));

    const lockContentStyle = useAnimatedStyle(() => ({
        transform: [{ translateY: interpolate(arrowUpPhase.value, [0, 1], [0, -5], Extrapolation.CLAMP) }],
    }));

    const recordingInlineStyle = useAnimatedStyle(() => ({
        opacity: recordingProgress.value,
        transform: [{ translateY: interpolate(recordingProgress.value, [0, 1], [8, 0], Extrapolation.CLAMP) }],
    }));

    const inputTextStyle = useMemo(() => [styles.input, !editable && styles.inputDisabled], [editable]);
    const reportTextInputFrame = useCallback(() => {
        if (!onTextInputFrameChange) return;
        textInputRef.current?.measureInWindow((x, y, width, height) => {
            if (width <= 0 || height <= 0) return;
            onTextInputFrameChange({ x, y, width, height });
        });
    }, [onTextInputFrameChange]);

    useEffect(() => {
        if (!onTextInputFrameChange) return;
        const t1 = setTimeout(reportTextInputFrame, 0);
        const t2 = setTimeout(reportTextInputFrame, 120);
        return () => {
            clearTimeout(t1);
            clearTimeout(t2);
        };
    }, [onTextInputFrameChange, reportTextInputFrame]);

    const onMicPress = useCallback(() => {
        if (!editable) return;

        if (isRecording && isLocked) {
            haptics.medium();
            void stopRecording(false);
            return;
        }

        if (!isRecording) {
            haptics.selection();
            setRecordingMode((prev) => (prev === 'voice' ? 'video' : 'voice'));
        }
    }, [editable, isRecording, isLocked, stopRecording]);

    return (
        <View style={styles.host}>
            <AttachmentMenu
                buttonSize={40}
                onSelectImage={(uri, w, h) => onAttachImage?.(uri, w, h)}
                onSelectFile={(uri, name) => onAttachFile?.(uri, name)}
                onSelectLocation={(coords) => onAttachLocation?.(coords)}
                onSelectContact={(contact) => onAttachContact?.(contact)}
            />

            <Animated.View style={[styles.shell, shellStyle]}>
                <SafeLiquidGlass
                    style={styles.glass}
                    blurIntensity={14}
                    tint={effectiveTheme}
                >
                    <Animated.View style={[styles.shellInner, shellMorphStyle]}>
                        <Animated.View style={[styles.replyWrap, replyWrapStyle]} pointerEvents={hasContextBanner ? 'auto' : 'none'}>
                            <View style={[styles.replyAccent, { backgroundColor: replyBannerSnapshot.accentColor }]} />
                            <View style={styles.replyTextWrap}>
                                <Animated.Text style={[styles.replyAuthorText, replyTextFadeStyle]} numberOfLines={1}>
                                    {replyBannerSnapshot.author}
                                </Animated.Text>
                                <Animated.Text style={[styles.replyBodyText, replyTextFadeStyle]} numberOfLines={1}>
                                    {replyBannerSnapshot.body}
                                </Animated.Text>
                            </View>
                            <Pressable onPress={editTarget ? onCancelEdit : onCancelReply} style={styles.replyCloseBtn} hitSlop={8}>
                                <X size={14} color={isDark ? "rgba(255,255,255,0.86)" : "rgba(0,0,0,0.86)"} strokeWidth={2.4} />
                            </Pressable>
                        </Animated.View>

                        <View style={styles.row}>
                            <Animated.View
                                style={[styles.inputRowContent, inputContainerStyle]}
                                pointerEvents={!isRecording ? 'auto' : 'none'}
                            >
                                <View style={styles.inputHost}>
                                    <TextInput
                                        ref={textInputRef}
                                        value={text}
                                        onChangeText={setText}
                                        style={[inputTextStyle, { color: colors.text }]}
                                        placeholder={placeholder}
                                        placeholderTextColor={colors.textTertiary || "#6f727b"}
                                        editable={editable}
                                        multiline
                                        maxLength={2000}
                                        autoFocus={autoFocus}
                                        onFocus={() => {
                                            setFocused(true);
                                            onFocusChange?.(true);
                                            reportTextInputFrame();
                                        }}
                                        onBlur={() => {
                                            setFocused(false);
                                            onFocusChange?.(false);
                                        }}
                                        onSubmitEditing={canSend ? onSend : undefined}
                                        onLayout={reportTextInputFrame}
                                    />
                                </View>

                                <View style={styles.inlineActions}>
                                    <Animated.View style={[styles.toolsWrap, toolsStyle]}>
                                        <Pressable style={styles.gifBtn} onPress={onGifPress}>
                                            <AnimatedGifToSmileIcon progress={gifProgress} size={20} color={isDark ? "#9ca0aa" : "#4a4a4f"} />
                                        </Pressable>
                                    </Animated.View>

                                    <Animated.View style={[styles.sendWrap, sendWrapStyle]}>
                                        <Pressable
                                            onPress={canSend ? onSend : undefined}
                                            style={[styles.sendBtn, !canSend && styles.sendBtnDisabled]}
                                            disabled={!canSend}
                                        >
                                            <LinearGradient
                                                colors={sendGradient}
                                                start={{ x: 0, y: 0 }}
                                                end={{ x: 1, y: 1 }}
                                                style={styles.sendBtnGradient}
                                            >
                                                <Send size={18} color="#fff" strokeWidth={2.5} />
                                            </LinearGradient>
                                        </Pressable>
                                    </Animated.View>
                                </View>
                            </Animated.View>

                            <Animated.View
                                style={[styles.recordingOverlay, recordingContainerStyle]}
                                pointerEvents={isRecording ? 'auto' : 'none'}
                            >
                                <Animated.View style={[styles.recordingInlineRow, recordingInlineStyle]}>
                                    <Text style={[styles.recordingTimeText, { color: colors.text }]}>{formatDuration(recordingElapsedMs)}</Text>
                                    {isLocked ? (
                                        <Text style={[styles.recordingHintText, { color: colors.textSecondary }]}>Tap mic to send</Text>
                                    ) : null}
                                    <Animated.View pointerEvents="none" style={[styles.recordingCancelInline, cancelHintStyle]}>
                                        <ChevronLeft size={14} color={isDark ? 'rgba(255,255,255,0.86)' : 'rgba(0,0,0,0.86)'} strokeWidth={2.5} />
                                        <Text style={[styles.recordingCancelText, { color: isDark ? 'rgba(255,255,255,0.86)' : 'rgba(0,0,0,0.86)' }]}>
                                            Slide to cancel
                                        </Text>
                                    </Animated.View>
                                </Animated.View>
                            </Animated.View>
                        </View>
                    </Animated.View>
                </SafeLiquidGlass>
            </Animated.View>

            <Animated.View
                style={[styles.micSlot, micSlotStyle]}
                pointerEvents={canSend && !isRecording ? 'none' : 'auto'}
            >
                <Animated.View pointerEvents={isRecording && !isLocked ? 'auto' : 'none'} style={[styles.lockPill, lockPillStyle]}>
                    <SafeLiquidGlass style={[styles.lockPillGlass, { backgroundColor: isDark ? 'rgba(25,28,40,0.76)' : 'rgba(248,248,252,0.78)' }]} blurIntensity={Platform.OS === 'android' ? 7 : 12} tint={effectiveTheme}>
                        <Animated.View style={[styles.lockPillContent, lockContentStyle]}>
                            <Animated.View style={[styles.lockArrowWrap, lockArrowStyle]}>
                                <ChevronUp size={14} color={isDark ? "rgba(255,255,255,0.95)" : "rgba(0,0,0,0.95)"} strokeWidth={2.5} />
                            </Animated.View>
                            <Lock size={13} color={isDark ? "rgba(255,255,255,0.95)" : "rgba(0,0,0,0.95)"} strokeWidth={2.5} />
                        </Animated.View>
                    </SafeLiquidGlass>
                </Animated.View>

                <GestureDetector gesture={recordGesture}>
                    <Animated.View style={[styles.micShell, micShellStyle]}>
                        <Pressable
                            onPress={onMicPress}
                            onPressIn={() => {
                                micPressScale.value = withTiming(0.94, { duration: 90, easing: Easing.out(Easing.quad) });
                            }}
                            onPressOut={() => {
                                micPressScale.value = withTiming(1, { duration: 120, easing: Easing.out(Easing.quad) });
                            }}
                            style={[styles.micPressable, { backgroundColor: auxButtonGlassBg, borderColor: auxButtonBorder }]}
                        >
                            <SafeLiquidGlass
                                style={StyleSheet.absoluteFill}
                                blurIntensity={Platform.OS === 'android' ? 4 : 12}
                                tint={effectiveTheme}
                            />
                            <View style={styles.touchArea}>
                                {isRecording ? (
                                    isLocked ? (
                                        <VibeLogoIcon size={20} color={isDark ? "#fff" : "#000"} strokeWidth={3.8} />
                                    ) : (
                                        recordingModeAtStartRef.current === 'video'
                                            ? <Video size={20} color="#fff" strokeWidth={2.6} />
                                            : <Mic size={20} color="#fff" strokeWidth={2.6} />
                                    )
                                ) : (
                                    recordingMode === 'video'
                                        ? <Video size={18} color={isDark ? "#8fe3ff" : "#007AFF"} strokeWidth={2.5} />
                                        : <Mic size={18} color={isDark ? "#fff" : "#000"} strokeWidth={2.5} />
                                )}
                            </View>
                        </Pressable>
                    </Animated.View>
                </GestureDetector>
            </Animated.View>
        </View>
    );
}

const styles = StyleSheet.create({
    host: {
        width: '100%',
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
        overflow: 'visible',
    },
    shell: {
        flex: 1,
        minHeight: COMPOSER_BASE_HEIGHT,
    },
    shellInner: {
        width: '100%',
    },
    glass: {
        width: '100%',
        minHeight: COMPOSER_BASE_HEIGHT,
        borderRadius: 21,
        overflow: 'hidden',
        borderWidth: Platform.OS === 'ios' ? 0 : undefined,
        backgroundColor: Platform.OS === 'ios' ? 'transparent' : undefined,
    },
    replyWrap: {
        overflow: 'hidden',
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 10,
    },
    replyAccent: {
        width: 3,
        height: 28,
        borderRadius: 2,
        marginRight: 8,
    },
    replyTextWrap: {
        flex: 1,
        minHeight: 28,
        justifyContent: 'center',
    },
    replyAuthorText: {
        color: 'rgba(255,255,255,0.92)', // Keep white on bubble color? Or use theme? 
        fontSize: 12,
        fontWeight: '700',
        lineHeight: 14,
    },
    replyBodyText: {
        color: 'rgba(255,255,255,0.72)',
        fontSize: 12,
        lineHeight: 14,
        marginTop: 1,
    },
    replyCloseBtn: {
        width: 24,
        height: 24,
        alignItems: 'center',
        justifyContent: 'center',
        borderRadius: 12,
    },
    row: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 8,
        paddingBottom: 0,
        minHeight: COMPOSER_BASE_HEIGHT,
    },
    inputHost: {
        flex: 1,
        justifyContent: 'center',
    },
    inlineActions: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'flex-end',
        marginLeft: 4,
    },
    input: {
        flex: 1,
        fontSize: 16,
        lineHeight: 20,
        minHeight: 20, // Reduced from 24
        maxHeight: 120,
        paddingTop: 9,
        paddingBottom: 6,
        paddingHorizontal: 10,
        textAlign: 'left',
        textAlignVertical: 'center',
    },
    inputDisabled: {
        opacity: 0.6,
    },
    recordingInlineRow: {
        flex: 1,
        minHeight: 30,
        flexDirection: 'row',
        alignItems: 'center',
        gap: 6,
        paddingHorizontal: 12,
        position: 'relative',
        zIndex: 2,
    },
    inputRowContent: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
    },
    recordingOverlay: {
        ...StyleSheet.absoluteFillObject,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 8,
    },
    recordingTimeText: {
        color: '#fff',
        fontSize: 16,
        fontWeight: '600',
        fontVariant: ['tabular-nums'],
    },
    recordingHintText: {
        color: 'rgba(255,255,255,0.68)',
        fontSize: 12,
        fontWeight: '500',
        flexShrink: 1,
    },
    recordingCancelInline: {
        position: 'absolute',
        left: 0,
        right: 0,
        alignItems: 'center',
        justifyContent: 'center',
        flexDirection: 'row',
        gap: 3,
    },
    recordingCancelText: {
        fontSize: 11,
        fontWeight: '700',
        letterSpacing: 0.2,
    },
    toolsWrap: {
        height: 34,
        overflow: 'hidden',
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'flex-end',
        paddingTop: 0, // Ensure no top padding
    },
    gifBtn: {
        width: 36,
        height: 36,
        alignItems: 'center',
        justifyContent: 'center',
    },
    sendWrap: {
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center',
        height: 34,
        paddingTop: 0, // Ensure no top padding
    },
    sendBtn: {
        width: 40,
        height: 'auto',
        borderRadius: 21,
        overflow: 'hidden',
        alignItems: 'center',
        justifyContent: 'center',
    },
    sendBtnGradient: {
        width: '100%',
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
        borderRadius: 16,
    },
    sendBtnDisabled: {
        opacity: 0.38,
    },
    micSlot: {
        width: 40,
        height: 40,
        alignItems: 'center',
        justifyContent: 'center',
        position: 'relative',
        overflow: 'visible',
    },
    micShell: {
        width: 40,
        height: 40,
        borderRadius: 20,
        position: 'absolute',
        overflow: 'visible',
        zIndex: 12,
    },
    micPressable: {
        width: '100%',
        height: '100%',
        borderRadius: 999,
        overflow: 'hidden',
    },
    micGlass: {
        width: '100%',
        height: '100%',
        borderRadius: 999,
        overflow: 'hidden',
        backgroundColor: 'rgba(120,120,138,0.18)',
    },
    touchArea: {
        flex: 1,
        alignItems: 'center',
        justifyContent: 'center',
    },
    lockPill: {
        position: 'absolute',
        bottom: 0,
        width: 46,
        height: 86,
        borderRadius: 23,
        overflow: 'hidden',
        zIndex: 14,
    },
    lockPillGlass: {
        flex: 1,
        borderRadius: 23,
        overflow: 'hidden',
        backgroundColor: 'rgba(25,28,40,0.8)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    lockPillContent: {
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8,
    },
    lockArrowWrap: {
        height: 14,
        alignItems: 'center',
        justifyContent: 'center',
    },
});
