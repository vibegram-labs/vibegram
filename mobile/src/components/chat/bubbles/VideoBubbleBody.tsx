import React, { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Dimensions, Pressable, StyleSheet, Text, View } from 'react-native';
import { AVPlaybackStatus, ResizeMode, Video } from 'expo-av';
import { Play, Square, X } from 'lucide-react-native';
import Animated, {
    Easing,
    useAnimatedProps,
    useAnimatedStyle,
    useSharedValue,
    withSpring,
    withTiming,
} from 'react-native-reanimated';
import Svg, { Circle } from 'react-native-svg';

import { BubbleMeta } from './BubbleMeta';
import { formatDuration } from './format';
import type { ChatListBubbleMessage } from './types';
import { useChatStore } from '../../../lib/ChatStore';
import { useWallpaperStore } from '../../../lib/stores/wallpaper-store';
import { useThemeStore } from '../../../lib/stores/theme-store';

const AnimatedCircle = Animated.createAnimatedComponent(Circle);

const VIDEO_NOTE_SIZE = 200;
const NOTE_RING_STROKE = 3;
const NOTE_RING_SIZE = VIDEO_NOTE_SIZE + 12;
const NOTE_RING_RADIUS = (NOTE_RING_SIZE / 2) - NOTE_RING_STROKE;
const NOTE_RING_CIRCUMFERENCE = 2 * Math.PI * NOTE_RING_RADIUS;
const SEND_RING_RADIUS = 22;
const SEND_RING_CIRCUMFERENCE = 2 * Math.PI * SEND_RING_RADIUS;
const SCREEN_WIDTH = Dimensions.get('window').width;

let activeVideoPlayback: { id: string; pause: () => Promise<void> } | null = null;

const VideoBubbleBody = React.memo(({ item }: { item: ChatListBubbleMessage }) => {
    const playerId = `${item.chatId || 'chat'}:${item.id}`;
    const videoRef = useRef<Video | null>(null);
    const mediaFrameRef = useRef<View | null>(null);
    const [isPlaying, setIsPlaying] = useState(false);
    const [positionMs, setPositionMs] = useState(0);
    const [durationMs, setDurationMs] = useState<number>((item.duration || 0) * 1000);
    const isTogglingRef = useRef(false);
    const mediaScale = useSharedValue(1);
    const mediaTranslateX = useSharedValue(0);
    const ringProgress = useSharedValue(0);
    const uploadProgress = useChatStore((s) => s.uploadProgress?.[item.id] || 0);
    const cancelUpload = useChatStore((s) => s.cancelUpload);

    const { activeTheme } = useWallpaperStore();
    const { effectiveTheme } = useThemeStore();
    const theme = activeTheme[effectiveTheme === 'dark' ? 'dark' : 'light'];
    const textColor = item.isMe ? theme.textColorMe : theme.textColorThem;
    const isVideoNote = !!item.isVideoNote;
    const duration = durationMs > 0 ? durationMs / 1000 : item.duration;
    const durationLabel = formatDuration(duration);

    const onStatusUpdate = useCallback((status: AVPlaybackStatus) => {
        if (!status.isLoaded) return;
        setIsPlaying(status.isPlaying);
        if (status.isPlaying) {
            activeVideoPlayback = {
                id: playerId,
                pause: async () => {
                    try {
                        await videoRef.current?.pauseAsync();
                    } catch {
                        // Ignore pause races.
                    }
                },
            };
        } else if (activeVideoPlayback?.id === playerId) {
            activeVideoPlayback = null;
        }
        setPositionMs(status.positionMillis || 0);
        if (typeof status.durationMillis === 'number' && status.durationMillis > 0) {
            setDurationMs(status.durationMillis);
        }
        if (status.didJustFinish) {
            setIsPlaying(false);
            setPositionMs(0);
            if (activeVideoPlayback?.id === playerId) {
                activeVideoPlayback = null;
            }
            // Avoid direct seek here; rapid state transitions can trigger
            // "Seeking interrupted" errors on iOS.
        }
    }, [playerId]);

    const togglePlay = useCallback(async () => {
        const node = videoRef.current;
        if (!node || !item.mediaUrl) return;
        if (isTogglingRef.current) return;
        isTogglingRef.current = true;

        try {
            if (isPlaying) {
                await node.pauseAsync();
            } else {
                if (activeVideoPlayback && activeVideoPlayback.id !== playerId) {
                    await activeVideoPlayback.pause();
                }
                if (durationMs > 0 && positionMs >= durationMs - 10) {
                    await node.setPositionAsync(0);
                }
                activeVideoPlayback = {
                    id: playerId,
                    pause: async () => {
                        try {
                            await node.pauseAsync();
                        } catch {
                            // Ignore pause races.
                        }
                    },
                };
                await node.playAsync();
            }
        } catch {
            // Keep UI stable on playback errors.
        } finally {
            isTogglingRef.current = false;
        }
    }, [durationMs, isPlaying, item.mediaUrl, playerId, positionMs]);

    const progress = durationMs > 0 ? Math.max(0, Math.min(1, positionMs / durationMs)) : 0;
    useEffect(() => {
        const target = isPlaying ? Math.max(0.001, progress) : 0;
        ringProgress.value = withTiming(target, {
            duration: isPlaying ? 90 : 160,
            easing: Easing.out(Easing.quad),
        });
    }, [isPlaying, progress, ringProgress]);

    const isUploading = !!item.isMe && (item.status === 'sending' || item.status === 'pending');

    useEffect(() => {
        mediaScale.value = withSpring(isPlaying ? (isVideoNote ? 1.1 : 1.05) : 1, {
            damping: 17,
            stiffness: 170,
            mass: 0.85,
        });

        if (!isPlaying) {
            mediaTranslateX.value = withSpring(0, { damping: 20, stiffness: 180, mass: 0.9 });
            return;
        }

        requestAnimationFrame(() => {
            mediaFrameRef.current?.measureInWindow?.((x, _y, width) => {
                if (!width) return;
                const frameCenter = x + (width / 2);
                const target = (SCREEN_WIDTH / 2) - frameCenter;
                mediaTranslateX.value = withSpring(target, { damping: 20, stiffness: 180, mass: 0.9 });
            });
        });
    }, [isPlaying, isVideoNote, mediaScale, mediaTranslateX]);

    useEffect(() => () => {
        if (activeVideoPlayback?.id === playerId) {
            activeVideoPlayback = null;
        }
    }, [playerId]);

    const mediaFrameStyle = useAnimatedStyle(() => ({
        transform: [
            { translateX: mediaTranslateX.value },
            { scale: mediaScale.value },
        ],
    }));

    const ringProgressProps = useAnimatedProps(() => ({
        strokeDashoffset: NOTE_RING_CIRCUMFERENCE * (1 - ringProgress.value),
    }));

    if (isVideoNote) {
        return (
            <View style={styles.noteContainer}>
                <Animated.View ref={mediaFrameRef as any} style={[styles.noteScaleWrap, mediaFrameStyle, isPlaying && styles.mediaPlaying]}>
                    <View pointerEvents="none" style={styles.noteProgressRingWrap}>
                        <Svg width={NOTE_RING_SIZE} height={NOTE_RING_SIZE}>
                            <Circle
                                cx={NOTE_RING_SIZE / 2}
                                cy={NOTE_RING_SIZE / 2}
                                r={NOTE_RING_RADIUS}
                                stroke={effectiveTheme === 'dark' ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.06)'}
                                strokeWidth={NOTE_RING_STROKE}
                                fill="none"
                            />
                            <AnimatedCircle
                                cx={NOTE_RING_SIZE / 2}
                                cy={NOTE_RING_SIZE / 2}
                                r={NOTE_RING_RADIUS}
                                stroke={item.isMe ? '#FFFFFF' : (effectiveTheme === 'dark' ? '#FFFFFF' : '#007AFF')}
                                strokeWidth={NOTE_RING_STROKE}
                                strokeDasharray={`${NOTE_RING_CIRCUMFERENCE}`}
                                strokeLinecap="round"
                                fill="none"
                                rotation="-90"
                                origin={`${NOTE_RING_SIZE / 2}, ${NOTE_RING_SIZE / 2}`}
                                animatedProps={ringProgressProps}
                            />
                        </Svg>
                    </View>

                    <Pressable style={styles.notePress} onPress={togglePlay}>
                        {item.mediaUrl ? (
                            <Video
                                ref={videoRef}
                                source={{ uri: item.mediaUrl }}
                                style={styles.noteVideo}
                                resizeMode={ResizeMode.COVER}
                                stayAwake={false}
                                shouldPlay={false}
                                isLooping
                                progressUpdateIntervalMillis={50}
                                onPlaybackStatusUpdate={onStatusUpdate}
                            />
                        ) : (
                            <View style={[styles.noteVideo, styles.previewFallback, { backgroundColor: effectiveTheme === 'dark' ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.05)' }]} />
                        )}

                        {!isPlaying && (
                            <View style={styles.notePlayOverlay}>
                                <View style={styles.notePlayBtn}>
                                    <Play size={22} color="#FFFFFF" fill="#FFFFFF" />
                                </View>
                            </View>
                        )}

                        {!!duration && (
                            <View style={styles.noteDurationWrap}>
                                <View style={styles.noteDurationPill}>
                                    <Text style={styles.noteDurationText}>{formatDuration(duration)}</Text>
                                </View>
                            </View>
                        )}

                        {isUploading && (
                            <View style={styles.noteUploadOverlay}>
                                <Pressable
                                    onPress={() => {
                                        if (item.chatId) cancelUpload(item.chatId, item.id);
                                    }}
                                    style={styles.noteUploadAction}
                                >
                                    {uploadProgress > 0 ? (
                                        <>
                                            <Svg width={52} height={52}>
                                                <Circle
                                                    cx={26}
                                                    cy={26}
                                                    r={SEND_RING_RADIUS}
                                                    stroke="rgba(255,255,255,0.2)"
                                                    strokeWidth={3}
                                                    fill="none"
                                                />
                                                <Circle
                                                    cx={26}
                                                    cy={26}
                                                    r={SEND_RING_RADIUS}
                                                    stroke="#FFFFFF"
                                                    strokeWidth={3}
                                                    strokeDasharray={`${SEND_RING_CIRCUMFERENCE}`}
                                                    strokeDashoffset={`${SEND_RING_CIRCUMFERENCE * (1 - Math.max(0.02, uploadProgress))}`}
                                                    strokeLinecap="round"
                                                    fill="none"
                                                    rotation="-90"
                                                    origin="26, 26"
                                                />
                                            </Svg>
                                            <View style={styles.noteUploadCancelIcon}>
                                                <X size={17} color="#FFFFFF" strokeWidth={2.7} />
                                            </View>
                                        </>
                                    ) : (
                                        <ActivityIndicator color="rgba(255,255,255,0.8)" size="small" />
                                    )}
                                </Pressable>
                            </View>
                        )}
                    </Pressable>
                </Animated.View>

                <View style={styles.bottomRow}>
                    <Text style={[styles.durationLabel, { color: textColor }]}>{durationLabel}</Text>
                    <BubbleMeta timestamp={item.timestamp} status={item.status} isMe={item.isMe} isPinned={item.isPinned} />
                </View>
            </View>
        );
    }

    return (
        <View style={styles.wrap}>
            <Pressable onPress={togglePlay}>
                <Animated.View
                    ref={mediaFrameRef as any}
                    style={[styles.previewWrap, styles.previewRectWrap, mediaFrameStyle, isPlaying && styles.mediaPlaying]}
                >
                    {item.mediaUrl ? (
                        <Video
                            ref={videoRef}
                            source={{ uri: item.mediaUrl }}
                            style={styles.videoRect}
                            resizeMode={ResizeMode.COVER}
                            stayAwake={false}
                            shouldPlay={false}
                            isLooping={false}
                            progressUpdateIntervalMillis={80}
                            onPlaybackStatusUpdate={onStatusUpdate}
                        />
                    ) : (
                        <View style={[styles.videoRect, styles.previewFallback]} />
                    )}

                    <View style={styles.previewOverlay}>
                        <View style={styles.playBtn}>
                            {isPlaying ? (
                                <Square size={15} color="#FFFFFF" strokeWidth={2.8} />
                            ) : (
                                <Play size={18} color="#FFFFFF" strokeWidth={2.6} />
                            )}
                        </View>
                    </View>
                </Animated.View>
            </Pressable>

            <View style={styles.bottomRow}>
                <Text style={[styles.label, { color: textColor }]}>{durationLabel}</Text>
                <View style={[styles.progressTrack, { backgroundColor: effectiveTheme === 'dark' ? 'rgba(255,255,255,0.15)' : 'rgba(0,0,0,0.06)' }]}>
                    <View style={[styles.progressFill, { width: `${progress * 100}%`, backgroundColor: textColor }]} />
                </View>
                <BubbleMeta timestamp={item.timestamp} status={item.status} isMe={item.isMe} isPinned={item.isPinned} />
            </View>
        </View>
    );
});

const styles = StyleSheet.create({
    wrap: {
        minWidth: 170,
        maxWidth: 232,
    },
    noteContainer: {
        alignItems: 'flex-start',
        alignSelf: 'flex-start',
    },
    noteScaleWrap: {
        width: NOTE_RING_SIZE,
        height: NOTE_RING_SIZE,
        alignItems: 'center',
        justifyContent: 'center',
    },
    noteProgressRingWrap: {
        position: 'absolute',
        left: 0,
        top: 0,
        width: NOTE_RING_SIZE,
        height: NOTE_RING_SIZE,
        alignItems: 'center',
        justifyContent: 'center',
    },
    notePress: {
        width: VIDEO_NOTE_SIZE,
        height: VIDEO_NOTE_SIZE,
        borderRadius: VIDEO_NOTE_SIZE / 2,
        overflow: 'hidden',
        backgroundColor: '#000000',
        borderWidth: 0,
    },
    noteVideo: {
        width: VIDEO_NOTE_SIZE,
        height: VIDEO_NOTE_SIZE,
    },
    notePlayOverlay: {
        ...StyleSheet.absoluteFillObject,
        justifyContent: 'center',
        alignItems: 'center',
    },
    notePlayBtn: {
        width: 44,
        height: 44,
        borderRadius: 22,
        backgroundColor: 'rgba(0,0,0,0.4)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    noteDurationWrap: {
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: 8,
        alignItems: 'center',
    },
    noteDurationPill: {
        backgroundColor: 'rgba(0,0,0,0.5)',
        borderRadius: 10,
        paddingHorizontal: 8,
        paddingVertical: 2,
    },
    noteDurationText: {
        color: '#FFFFFF',
        fontSize: 11,
        fontWeight: '600',
    },
    noteUploadOverlay: {
        ...StyleSheet.absoluteFillObject,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(0,0,0,0.3)',
        borderRadius: VIDEO_NOTE_SIZE / 2,
    },
    noteUploadAction: {
        width: 52,
        height: 52,
        alignItems: 'center',
        justifyContent: 'center',
    },
    noteUploadCancelIcon: {
        position: 'absolute',
    },
    previewWrap: {
        overflow: 'hidden',
    },
    mediaPlaying: {
        zIndex: 25,
        elevation: 25,
    },
    previewRectWrap: {
        width: 224,
        height: 140,
        borderRadius: 12,
    },
    videoRect: {
        width: '100%',
        height: '100%',
    },
    previewFallback: {
    },
    previewOverlay: {
        ...StyleSheet.absoluteFillObject,
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: 'rgba(0,0,0,0.2)',
    },
    playBtn: {
        width: 42,
        height: 42,
        borderRadius: 21,
        backgroundColor: 'rgba(0,0,0,0.3)',
        alignItems: 'center',
        justifyContent: 'center',
    },
    bottomRow: {
        marginTop: 7,
        flexDirection: 'row',
        alignItems: 'center',
        gap: 7,
    },
    label: {
        fontSize: 12,
        fontWeight: '600',
        minWidth: 30,
    },
    durationLabel: {
        fontSize: 12,
        marginLeft: 48,
    },
    progressTrack: {
        flex: 1,
        height: 3,
        borderRadius: 1.5,
        overflow: 'hidden',
    },
    progressFill: {
        height: '100%',
    },
});

export default VideoBubbleBody;
