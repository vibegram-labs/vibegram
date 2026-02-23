import React, { useEffect, useState, useRef, useCallback } from 'react';
import { View, Text, TouchableOpacity, Image, StyleSheet, Modal, Dimensions, ScrollView, Platform, ActivityIndicator } from 'react-native';
import { Audio } from 'expo-av';
import * as FileSystem from 'expo-file-system/legacy';
import { useMusicPlayerStore } from '../../lib/stores/music-player-store';
import { useMediaCacheStore } from '../../lib/stores/media-cache-store';
import { useThemeStore } from '../../lib/stores/theme-store';
import { apiClient } from '../../lib/api-client';
import { Play, Pause, ChevronDown, SkipBack, SkipForward, X, ListMusic, Disc, ArrowLeft, Music } from 'lucide-react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import AnimatedGlassButton from '../native/AnimatedGlassButton';
import { LinearGradient } from 'expo-linear-gradient';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, { useSharedValue, useAnimatedStyle, withSpring, withTiming, withRepeat, withSequence, Easing, runOnJS, interpolate } from 'react-native-reanimated';

const MaskedViewAny = MaskedView as any;
const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

const isLocalFileUri = (uri?: string | null) => {
    if (!uri || typeof uri !== 'string') return false;
    return uri.startsWith('file://') || uri.startsWith('/');
};

const normalizeFileUri = (uri: string) => (uri.startsWith('file://') ? uri : `file://${uri}`);

const fileBasename = (uri: string) => {
    const normalized = uri.replace('file://', '');
    const slash = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.slice(slash + 1) : normalized;
};

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

// True Left-to-Right Shine/Shimmer Effect
const ShimmerText = ({ text, style, shimmerColor = '#ffffff' }: { text: string; style?: any; shimmerColor?: string }) => {
    const translateX = useSharedValue(-100);

    useEffect(() => {
        translateX.value = withRepeat(
            withTiming(100, { duration: 1500, easing: Easing.linear }),
            -1,
            false
        );
    }, []);

    const animatedStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: translateX.value }]
    }));

    return (
        <View style={{ overflow: 'hidden' }}>
            <MaskedViewAny
                style={{ flexDirection: 'row', height: 20 }}
                maskElement={<Text style={[style, { backgroundColor: 'transparent' }]}>{text}</Text>}
            >
                {/* Base Text (Darker/Dimmed) */}
                <Text style={[style, { opacity: 0.5 }]}>{text}</Text>

                {/* Shining Overlay */}
                <Animated.View style={[StyleSheet.absoluteFill, animatedStyle]}>
                    <LinearGradient
                        colors={['transparent', shimmerColor, 'transparent']}
                        start={{ x: 0, y: 0 }}
                        end={{ x: 1, y: 0 }}
                        style={StyleSheet.absoluteFill}
                    />
                </Animated.View>
            </MaskedViewAny>
        </View>
    );
};

const VisualizerBar = ({ isPlaying, color, delay }: { isPlaying: boolean; color: string; delay: number }) => {
    const height = useSharedValue(0.3);

    useEffect(() => {
        if (isPlaying) {
            height.value = withRepeat(
                withSequence(
                    withTiming(Math.random() * 0.5 + 0.3, { duration: 150 + Math.random() * 100 }),
                    withTiming(Math.random() * 0.9 + 0.1, { duration: 150 + Math.random() * 100 })
                ),
                -1,
                true
            );
        } else {
            height.value = withTiming(0.3);
        }
    }, [isPlaying]);

    const style = useAnimatedStyle(() => ({
        height: height.value * 16,
    }));

    return <Animated.View style={[{ width: 3, borderRadius: 1.5, backgroundColor: color, marginHorizontal: 1 }, style]} />;
};

const MiniVisualizer = ({ isPlaying, color }: { isPlaying: boolean; color: string }) => {
    return (
        <View style={{ flexDirection: 'row', alignItems: 'flex-end', height: 16 }}>
            <VisualizerBar isPlaying={isPlaying} color={color} delay={0} />
            <VisualizerBar isPlaying={isPlaying} color={color} delay={100} />
            <VisualizerBar isPlaying={isPlaying} color={color} delay={200} />
        </View>
    );
};

export const GlobalMusicPlayer = () => {
    const { currentTrack, isPlaying, setIsPlaying, isExpanded, setIsExpanded, playNext, playPrev, queue, setTrack, reset, setProgress: setStoreProgress, setDuration: setStoreDuration, playbackRate, setPlaybackRate } = useMusicPlayerStore();
    const { downloadTrack, downloadingTracks, getTrack, cacheTrack, removeTrack } = useMediaCacheStore();
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';
    const insets = useSafeAreaInsets();

    // Check if current track is a voice message
    const isVoiceMessage = currentTrack?.title === 'Voice Message';

    // Background Color for gradients
    const bgColor = effectiveTheme === 'dark' ? '#000000' : '#ffffff';


    const soundRef = useRef<Audio.Sound | null>(null);
    const [isLoaded, setIsLoaded] = useState(false);
    const [reloadToken, setReloadToken] = useState(0);
    const [progress, setProgress] = useState(0);
    const [positionMs, setPositionMs] = useState(0);
    const [durationMs, setDurationMs] = useState(0);

    // Configure audio mode once on mount - ensures audio plays through main speaker
    useEffect(() => {
        const configureAudio = async () => {
            try {
                await Audio.setAudioModeAsync({
                    allowsRecordingIOS: false,
                    playsInSilentModeIOS: true,
                    staysActiveInBackground: true,
                    shouldDuckAndroid: true,
                    playThroughEarpieceAndroid: false, // Use main speaker, not earpiece
                });
                // console.log('[MusicPlayer] Audio mode configured');
            } catch (e) {
                console.error('[MusicPlayer] Failed to configure audio mode:', e);
            }
        };
        configureAudio();
    }, []);

    // Movable Position Shared Values
    const translateX = useSharedValue(0);
    const translateY = useSharedValue(0);
    const context = useSharedValue({ x: 0, y: 0 });

    const panGesture = Gesture.Pan()
        .onStart(() => {
            context.value = { x: translateX.value, y: translateY.value };
        })
        .onUpdate((event) => {
            translateX.value = event.translationX + context.value.x;
            translateY.value = event.translationY + context.value.y;
        })
        .onEnd(() => {
            // Keep the position where it ended
        });

    const animatedStyle = useAnimatedStyle(() => ({
        transform: [
            { translateX: translateX.value },
            { translateY: translateY.value }
        ]
    }));

    // Format time helper
    const formatTime = (ms: number) => {
        if (!ms) return "0:00";
        const minutes = Math.floor(ms / 60000);
        const seconds = Math.floor((ms % 60000) / 1000);
        return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
    };

    const resolveLocalPlayableUri = useCallback(async (rawUri: string) => {
        const normalized = normalizeFileUri(rawUri);
        const directInfo = await FileSystem.getInfoAsync(normalized);
        if (directInfo.exists) {
            return normalized;
        }

        const name = fileBasename(normalized);
        const candidates = [
            `${FileSystem.cacheDirectory || ''}voice-recordings/${name}`,
            `${FileSystem.documentDirectory || ''}voice-recordings/${name}`,
        ].filter((value) => value.length > 0);

        for (const candidate of candidates) {
            const info = await FileSystem.getInfoAsync(candidate);
            if (info.exists) {
                return candidate;
            }
        }

        return null;
    }, []);

    // Audio Logic - Proper cleanup and loading with lock
    const isLoadingRef = useRef(false);
    const currentTrackUrlRef = useRef<string | null>(null);
    const requestAudioReload = useCallback((reason: string) => {
        if (!currentTrack) return;
        if (isLoadingRef.current) return;
        // console.log('[MusicPlayer] Requesting audio reload:', reason);
        currentTrackUrlRef.current = null;
        setIsLoaded(false);
        setReloadToken((v) => v + 1);
    }, [currentTrack]);

    useEffect(() => {
        let isMounted = true;

        const loadSound = async () => {
            /*
            console.log('[MusicPlayer] loadSound called, currentTrack:', currentTrack?.title);
            console.log('[MusicPlayer] preview_url:', currentTrack?.preview_url);
            console.log('[MusicPlayer] video_id:', currentTrack?.video_id);
            */

            // Get the stream URL - either from preview_url or construct from video_id
            let streamUrl = currentTrack?.preview_url;

            if (!streamUrl && currentTrack?.video_id) {
                // Fetch stream URL from backend (which caches and returns actual playable URL)
                // console.log('[MusicPlayer] Fetching stream URL for video_id:', currentTrack.video_id);
                try {
                    const info = await apiClient.getMusicInfo(currentTrack.video_id);
                    if (info?.stream_url) {
                        streamUrl = info.stream_url;
                        // console.log('[MusicPlayer] Got stream URL from backend:', streamUrl);
                    }
                } catch (e) {
                    console.error('[MusicPlayer] Failed to fetch stream URL:', e);
                }
            }

            if (!streamUrl || !currentTrack) {
                // console.log('[MusicPlayer] No preview_url or video_id, skipping');
                return;
            }

            const isLocalSource = isLocalFileUri(streamUrl);
            if (isLocalSource) {
                const resolvedLocal = await resolveLocalPlayableUri(streamUrl);
                if (!resolvedLocal) {
                    console.warn('[MusicPlayer] Local audio file is no longer readable:', streamUrl);
                    setIsLoaded(false);
                    setIsPlaying(false);
                    reset();
                    return;
                }
                streamUrl = resolvedLocal;
            }

            const loadKey = streamUrl;

            // Prevent duplicate loads for same track
            if (currentTrackUrlRef.current === loadKey && soundRef.current && isLoaded) {
                // console.log('[MusicPlayer] Same track, skipping duplicate load');
                return;
            }

            // Wait if already loading
            if (isLoadingRef.current) {
                // console.log('[MusicPlayer] Already loading, queuing...');
                // Queue this load
                setTimeout(() => {
                    if (isMounted && (currentTrack?.preview_url || currentTrack?.video_id)) {
                        loadSound();
                    }
                }, 100);
                return;
            }

            isLoadingRef.current = true;
            currentTrackUrlRef.current = loadKey;

            // Unload previous sound first
            if (soundRef.current) {
                // console.log('[MusicPlayer] Unloading previous sound');
                setIsLoaded(false);
                // Reset progress states for clean slate
                setProgress(0);
                setPositionMs(0);
                setDurationMs(0);
                setStoreProgress(0);
                setStoreDuration(0);
                try {
                    await soundRef.current.stopAsync();
                    await soundRef.current.unloadAsync();
                } catch (e) {
                    // console.log('[MusicPlayer] Cleanup error (ignored):', e);
                }
                soundRef.current = null;
            }

            try {
                // CHECK CACHE FIRST (skip for chat voice/local files; they are transient and should not
                // be persisted in music cache state)
                const trackId = currentTrack.video_id || currentTrack.id || streamUrl;
                let uriToPlay = streamUrl;
                let usedCache = false;
                const shouldUseMusicCache = !isLocalFileUri(streamUrl) && currentTrack.source !== 'chat-voice';
                const cached = shouldUseMusicCache ? getTrack(trackId) : undefined;

                /*
                console.log('[MusicPlayer] Track ID:', trackId);
                console.log('[MusicPlayer] Cache enabled:', shouldUseMusicCache);
                console.log('[MusicPlayer] Cached track:', cached?.local_uri ? 'YES' : 'NO');
                */

                if (shouldUseMusicCache && cached?.local_uri) {
                    // console.log('[MusicPlayer] checking if cached file exists:', cached.local_uri);
                    const fileInfo = await FileSystem.getInfoAsync(cached.local_uri);
                    if (fileInfo.exists) {
                        uriToPlay = cached.local_uri;
                        usedCache = true;
                        // console.log('[MusicPlayer] Using cached URI:', uriToPlay);
                    } else {
                        console.warn('[MusicPlayer] Removing stale cached file reference:', cached.local_uri);
                        try { removeTrack(trackId); } catch (_) { /* ignore */ }
                        uriToPlay = streamUrl;
                    }
                } else if (shouldUseMusicCache) {
                    // console.log('[MusicPlayer] Using stream URL:', uriToPlay);
                    // Cache metadata
                    cacheTrack({
                        video_id: trackId,
                        title: currentTrack.title,
                        artist: currentTrack.artist,
                        cover: currentTrack.cover,
                        preview_url: streamUrl
                    });

                    // Start download in background (don't await)
                    downloadTrack({
                        video_id: trackId,
                        title: currentTrack.title,
                        artist: currentTrack.artist,
                        cover: currentTrack.cover,
                        preview_url: streamUrl,
                        play_count: 0,
                        cached_at: Date.now()
                    });
                } else {
                    // console.log('[MusicPlayer] Using direct source URI (no cache):', uriToPlay);
                }

                if (!isMounted) {
                    // console.log('[MusicPlayer] Component unmounted before load');
                    isLoadingRef.current = false;
                    return;
                }

                // Helper to create and wire up the Audio.Sound
                const createSound = async (uri: string) => {
                    // console.log('[MusicPlayer] Creating Audio.Sound with URI:', uri);
                    const progressUpdateIntervalMillis = currentTrack?.title === 'Voice Message' ? 50 : 220;
                    const shouldPlayNow = !!useMusicPlayerStore.getState().isPlaying;
                    return Audio.Sound.createAsync(
                        { uri },
                        { shouldPlay: shouldPlayNow, progressUpdateIntervalMillis },
                        (status) => {
                            if (!isMounted) return;
                            if (status.isLoaded) {
                                setDurationMs(status.durationMillis || 0);
                                setPositionMs(status.positionMillis);

                                // Sync with store for other components (like VoiceMessagePlayer)
                                setStoreDuration(status.durationMillis || 0);
                                setStoreProgress(status.positionMillis);

                                if (status.durationMillis) {
                                    setProgress(status.positionMillis / status.durationMillis);
                                }
                                if (status.didJustFinish) {
                                    // console.log('[MusicPlayer] Track finished');
                                    // For voice messages, reset the player instead of playing next
                                    if (currentTrack?.title === 'Voice Message') {
                                        setStoreProgress(0);
                                        setProgress(0);
                                        setPositionMs(0);
                                        setIsPlaying(false);
                                        reset();
                                    } else {
                                        playNext();
                                    }
                                }
                            } else if ('error' in status) {
                                console.error('[MusicPlayer] Playback error:', status.error);
                            }
                        }
                    );
                };

                let result;
                try {
                    result = await createSound(uriToPlay);
                } catch (loadErr: any) {
                    // If the cached file failed, retry with the original stream URL
                    if (usedCache && streamUrl && streamUrl !== uriToPlay) {
                        console.warn('[MusicPlayer] Cached file failed to load, retrying with stream URL:', streamUrl);
                        // Remove the broken cache entry so we don't hit it again
                        try { removeTrack(trackId); } catch (_) { /* ignore */ }
                        result = await createSound(streamUrl);
                    } else {
                        throw loadErr;
                    }
                }

                const { sound: newSound } = result;

                // console.log('[MusicPlayer] Audio.Sound created successfully');

                if (isMounted) {
                    soundRef.current = newSound;
                    setIsLoaded(true);
                    // console.log('[MusicPlayer] Playback started');
                } else {
                    // Cleanup if component unmounted during load
                    await newSound.unloadAsync();
                }
            } catch (e) {
                setIsLoaded(false);
                console.error("[MusicPlayer] Audio Load Error:", e);
                console.error("[MusicPlayer] Error details:", JSON.stringify(e, null, 2));
            } finally {
                isLoadingRef.current = false;
            }
        };

        loadSound();

        return () => {
            isMounted = false;
            // Clear ref so new tracks can load
            currentTrackUrlRef.current = null;
            if (soundRef.current) {
                soundRef.current.stopAsync().catch(() => { });
                soundRef.current.unloadAsync().catch(() => { });
                soundRef.current = null;
            }
        };
    }, [currentTrack?.id, currentTrack?.preview_url, currentTrack?.video_id, currentTrack?.source, reloadToken, resolveLocalPlayableUri, reset, setIsPlaying, setStoreDuration, setStoreProgress, playNext, removeTrack, cacheTrack, downloadTrack, getTrack]);

    // Play/Pause control
    useEffect(() => {
        // console.log('[MusicPlayer] Play/Pause effect triggered. isPlaying:', isPlaying, 'isLoaded:', isLoaded, 'soundRef exists:', !!soundRef.current);
        if (!soundRef.current || !isLoaded) {
            // console.log('[MusicPlayer] Cannot play/pause: soundRef or isLoaded is missing');
            if (isPlaying && currentTrack) {
                requestAudioReload('play-request-before-loaded');
            }
            return;
        }

        if (isPlaying) {
            // console.log('[MusicPlayer] Calling playAsync...');
            soundRef.current.playAsync()
                // .then((status) => console.log('[MusicPlayer] playAsync success, status:', status))
                .catch((error) => console.error('[MusicPlayer] playAsync failed:', error));
        } else {
            // console.log('[MusicPlayer] Calling pauseAsync...');
            soundRef.current.pauseAsync()
                // .then((status) => console.log('[MusicPlayer] pauseAsync success, status:', status))
                .catch((error) => console.error('[MusicPlayer] pauseAsync failed:', error));
        }
    }, [isPlaying, isLoaded, currentTrack, requestAudioReload]);

    // Debounced seek to prevent rapid seeking errors
    const seekTimeoutRef = useRef<NodeJS.Timeout | null>(null);
    const seekTo = useCallback((ms: number) => {
        if (seekTimeoutRef.current) {
            clearTimeout(seekTimeoutRef.current);
        }
        seekTimeoutRef.current = setTimeout(() => {
            if (soundRef.current && isLoaded) {
                soundRef.current.setPositionAsync(ms).catch(() => { });
            }
        }, 100); // Debounce 100ms
    }, [isLoaded]);

    // Cycle through playback rates: 1 -> 1.5 -> 2 -> 1
    const togglePlaybackRate = useCallback(() => {
        const rates = [1, 1.5, 2];
        const currentIndex = rates.indexOf(playbackRate);
        const nextIndex = (currentIndex + 1) % rates.length;
        setPlaybackRate(rates[nextIndex]);
    }, [playbackRate, setPlaybackRate]);

    // Apply playback rate to sound
    useEffect(() => {
        if (soundRef.current && isLoaded) {
            soundRef.current.setRateAsync(playbackRate, true).catch(console.error);
        }
    }, [playbackRate, isLoaded]);

    // Early return AFTER all hooks
    if (!currentTrack) return null;

    const trackId = currentTrack.video_id || currentTrack.id || currentTrack.preview_url || '';
    const downloadProgress = downloadingTracks[trackId];
    // Show download indicator if track is downloading OR if it's the current track and not yet cached/loaded and progress exists
    const isDownloading = (downloadProgress !== undefined && downloadProgress < 1);

    const togglePlay = () => {
        if (!soundRef.current || !isLoaded) {
            if (isPlaying) {
                setIsPlaying(false);
                return;
            }
            setIsPlaying(true);
            requestAudioReload('toggle-play-before-loaded');
            return;
        }
        // console.log('[MusicPlayer] togglePlay pressed. Toggling from', isPlaying, 'to', !isPlaying);
        setIsPlaying(!isPlaying);
    };


    // Full Modal
    const renderFullModal = () => (
        <Modal animationType="slide" transparent={true} visible={isExpanded} onRequestClose={() => setIsExpanded(false)}>
            <View style={{ flex: 1 }}>
                {/* Background (Semi-transparent) */}
                <View style={[StyleSheet.absoluteFill, { backgroundColor: bgColor }]}>
                    {/* Blurred Album Art Background */}
                    {currentTrack.cover ? (
                        <Image
                            source={{ uri: currentTrack.cover }}
                            style={[StyleSheet.absoluteFill, { opacity: 0.3 }]}
                            blurRadius={100}
                        />
                    ) : null}
                    <BlurView intensity={80} style={StyleSheet.absoluteFill} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} />
                </View>

                {/* --- HEADER MASK --- */}
                {/* Using same pattern as chat.tsx - MaskedView + BlurView to blend with parent bg */}
                <View style={[styles.headerContainer, { height: insets.top + 60, zIndex: 60, pointerEvents: 'none' }]}>
                    <MaskedViewAny
                        style={StyleSheet.absoluteFill}
                        maskElement={<LinearGradient colors={['rgba(0,0,0,1)', 'rgba(0,0,0,0)']} locations={[0.6, 1]} style={StyleSheet.absoluteFill} />}
                    >
                        <BlurView intensity={10} tint={effectiveTheme === 'dark' ? 'dark' : 'light'} style={[StyleSheet.absoluteFill, { backgroundColor: 'transparent' }]} />
                    </MaskedViewAny>
                </View>

                {/* --- HEADER CONTENT --- */}
                <View style={[styles.headerContentContainer, { height: insets.top + 60, paddingTop: insets.top + 10, zIndex: 130 }]} pointerEvents="box-none">
                    {/* Left: Close Button */}
                    <View style={styles.headerBtnWrapper}>
                        <AnimatedGlassButton
                            onPress={() => setIsExpanded(false)}
                            homeIcon={<ChevronDown color={colors.text} size={22} />}
                            showPanelIcon={false}
                            size={44}
                            effectiveTheme={effectiveTheme === 'dark' ? 'dark' : 'light'}
                            homeBackgroundColor="transparent"
                        />
                    </View>

                    {/* Center: Dynamic Title */}
                    <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', height: 44 }}>
                        <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>Now Playing</Text>
                    </View>

                    {/* Right: Spacer */}
                    <View style={styles.headerBtnWrapper} />
                </View>

                {/* Content ScrollView */}
                <ScrollView
                    contentContainerStyle={{ paddingBottom: insets.bottom + 60, paddingTop: insets.top + 80, alignItems: 'center' }}
                    showsVerticalScrollIndicator={false}
                >
                    {/* Large Banner Image with Play Button */}
                    <View style={{ width: SCREEN_WIDTH - 64, aspectRatio: 1, borderRadius: 24, overflow: 'hidden', marginVertical: 24, shadowColor: '#000', shadowOpacity: 0.3, shadowRadius: 20, elevation: 10, backgroundColor: colors.primary }}>
                        {currentTrack.cover ? (
                            <Image source={{ uri: currentTrack.cover }} style={{ width: '100%', height: '100%' }} />
                        ) : (
                            <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
                                <Music size={100} color="#fff" />
                            </View>
                        )}
                        <View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.05)' }]} />
                    </View>

                    {/* Title Info */}
                    <View style={{ paddingHorizontal: 32, width: '100%', marginBottom: 24 }}>
                        <Text style={{ color: colors.text, fontSize: 24, fontWeight: 'bold', textAlign: 'center', marginBottom: 8 }}>{currentTrack.title}</Text>
                        <Text style={{ color: colors.textSecondary, fontSize: 18, textAlign: 'center' }}>{currentTrack.artist}</Text>
                    </View>

                    {/* Download Progress - Using Left-to-Right Shine Text */}
                    {isDownloading && (
                        <View style={{ flexDirection: 'row', alignItems: 'center', marginBottom: 16 }}>
                            <ShimmerText
                                text={`Downloading ${Math.round((downloadProgress || 0) * 100)}%`}
                                style={{ color: colors.primary, fontSize: 13, fontWeight: '600' }}
                                shimmerColor={colors.primary}
                            />
                        </View>
                    )}

                    {/* Gesture Controlled Minimalist Progress */}
                    <View style={{ width: SCREEN_WIDTH - 64, marginBottom: 40 }}>
                        <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginBottom: 8 }}>
                            <Text style={{ color: colors.text, fontSize: 12, opacity: 0.6, fontVariant: ['tabular-nums'] }}>{formatTime(positionMs)}</Text>
                            <Text style={{ color: colors.text, fontSize: 12, opacity: 0.6, fontVariant: ['tabular-nums'] }}>{currentTrack.duration || formatTime(durationMs)}</Text>
                        </View>

                        <GestureDetector gesture={Gesture.Pan().onEnd((e) => {
                            const percentage = Math.max(0, Math.min(1, e.x / (SCREEN_WIDTH - 64)));
                            runOnJS(seekTo)(percentage * durationMs);
                        })}>
                            <View style={{ height: 24, justifyContent: 'center' }}>
                                <View style={{ width: '100%', height: 4, backgroundColor: 'rgba(150,150,150,0.3)', borderRadius: 2, overflow: 'hidden' }}>
                                    {/* Download Progress Background */}
                                    {isDownloading && (
                                        <View
                                            style={{
                                                position: 'absolute',
                                                left: 0,
                                                top: 0,
                                                bottom: 0,
                                                width: `${(downloadProgress || 0) * 100}%`,
                                                backgroundColor: withAlpha(colors.accent, 0.3)
                                            }}
                                        />
                                    )}
                                    <Animated.View style={{
                                        width: `${progress * 100}%`,
                                        height: '100%',
                                        backgroundColor: colors.accent
                                    }} />
                                </View>
                            </View>
                        </GestureDetector>
                    </View>

                    {/* Controls */}
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 40, marginBottom: 40 }}>
                        <TouchableOpacity onPress={playPrev}><SkipBack size={32} color={colors.text} /></TouchableOpacity>
                        <TouchableOpacity onPress={togglePlay} style={{ width: 64, height: 64, borderRadius: 32, backgroundColor: colors.text, alignItems: 'center', justifyContent: 'center' }}>
                            {isPlaying ? <Pause size={28} color={colors.background} fill={colors.background} /> : <Play size={28} color={colors.background} fill={colors.background} style={{ marginLeft: 2 }} />}
                        </TouchableOpacity>
                        <TouchableOpacity onPress={playNext}><SkipForward size={32} color={colors.text} /></TouchableOpacity>
                    </View>

                    {/* Queue List */}
                    {queue.length > 0 && (
                        <View style={{ width: '100%', paddingHorizontal: 24 }}>
                            <Text style={{ color: colors.text, fontWeight: '600', marginBottom: 16, marginLeft: 8 }}>Up Next</Text>
                            {queue.map((track, idx) => (
                                <TouchableOpacity key={`${track.title}-${idx}`} onPress={() => setTrack(track)} style={{ flexDirection: 'row', alignItems: 'center', marginBottom: 12, padding: 8, borderRadius: 12, backgroundColor: currentTrack.preview_url === track.preview_url ? 'rgba(255,255,255,0.1)' : 'transparent' }}>
                                    <Image source={{ uri: track.cover }} style={{ width: 40, height: 40, borderRadius: 6, marginRight: 12 }} />
                                    <View style={{ flex: 1 }}>
                                        <Text style={{ color: colors.text, fontSize: 14, fontWeight: '600' }} numberOfLines={1}>{track.title}</Text>
                                        <Text style={{ color: colors.textSecondary, fontSize: 12 }} numberOfLines={1}>{track.artist}</Text>
                                    </View>
                                    {currentTrack.preview_url === track.preview_url && <MiniVisualizer isPlaying={isPlaying} color={colors.accent} />}
                                </TouchableOpacity>
                            ))}
                        </View>
                    )}

                </ScrollView>
            </View>
        </Modal>
    );

    // Voice message mini player - compact UI
    if (isVoiceMessage) {
        return (
            <GestureDetector gesture={panGesture}>
                <Animated.View style={[styles.miniPlayerContainer, { top: insets.top + 60, shadowColor: '#000' }, animatedStyle]}>
                    <SafeLiquidGlass style={[styles.glassPill, { height: 44 }]} blurIntensity={25} tint={isLight ? 'light' : 'dark'}>
                        {/* Playback Progress */}
                        <View style={[
                            StyleSheet.absoluteFill,
                            {
                                width: `${progress * 100}%`,
                                backgroundColor: withAlpha(colors.primary, 0.2),
                                borderRadius: 22
                            }
                        ]} />

                        <View style={[styles.pillContent, { paddingHorizontal: 12 }]}>
                            {/* Left: Play/Pause + Voice info */}
                            <View style={{ flexDirection: 'row', alignItems: 'center', flex: 1 }}>
                                <TouchableOpacity onPress={togglePlay} style={{ marginRight: 10 }}>
                                    {isPlaying ? <Pause size={18} color={colors.text} /> : <Play size={18} color={colors.text} />}
                                </TouchableOpacity>
                                <View style={{ flex: 1 }}>
                                    <Text style={{ color: colors.text, fontSize: 13, fontWeight: '600' }} numberOfLines={1}>
                                        Voice Message
                                    </Text>
                                    <Text style={{ color: colors.textSecondary, fontSize: 11 }}>
                                        {formatTime(positionMs)} / {formatTime(durationMs)}
                                    </Text>
                                </View>
                            </View>

                            {/* Right: Playback Speed + Close */}
                            <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                                <TouchableOpacity onPress={togglePlaybackRate} style={{ paddingHorizontal: 8, paddingVertical: 4, backgroundColor: withAlpha(colors.text, 0.1), borderRadius: 10, marginRight: 8 }}>
                                    <Text style={{ color: colors.text, fontSize: 12, fontWeight: '600' }}>{playbackRate}x</Text>
                                </TouchableOpacity>
                                <TouchableOpacity onPress={reset} style={{ padding: 4 }}>
                                    <X size={16} color={colors.textSecondary} />
                                </TouchableOpacity>
                            </View>
                        </View>
                    </SafeLiquidGlass>
                </Animated.View>
            </GestureDetector>
        );
    }

    // Standard music player
    return (
        <React.Fragment>
            <GestureDetector gesture={panGesture}>
                <Animated.View style={[styles.miniPlayerContainer, { top: insets.top + 60, shadowColor: '#000' }, animatedStyle]}>
                    <SafeLiquidGlass style={styles.glassPill} blurIntensity={25} tint={isLight ? 'light' : 'dark'}>
                        {/* Playback Progress - Water-like reflect banner */}
                        <View style={[
                            StyleSheet.absoluteFill,
                            {
                                width: `${progress * 100}%`,
                                overflow: 'hidden'
                            }
                        ]}>
                            {/* Reflect Banner: Use the cover image itself */}
                            {currentTrack.cover ? (
                                <Image
                                    source={{ uri: currentTrack.cover }}
                                    style={{ width: SCREEN_WIDTH - 40, height: 52, position: 'absolute', left: 0, top: 0, opacity: 0.5 }}
                                    blurRadius={20}
                                />
                            ) : null}
                            <View style={{ ...StyleSheet.absoluteFillObject, backgroundColor: withAlpha(colors.primary, 0.1) }} />
                        </View>

                        {/* Download Indicator - Pulsing Text/Dot instead of Spinner */}
                        {isDownloading && (
                            <View style={{ position: 'absolute', right: 80, top: 18 }}>
                                <ShimmerText
                                    text="Downloading..."
                                    style={{ fontSize: 10, color: colors.text, fontWeight: '600' }}
                                    shimmerColor={colors.primary}
                                />
                            </View>
                        )}

                        <View style={styles.pillContent}>
                            <TouchableOpacity onPress={() => setIsExpanded(true)} style={styles.pillMainBtn} activeOpacity={0.8}>
                                <View style={{ flexDirection: 'row', alignItems: 'center', flex: 1 }}>
                                    {currentTrack.cover ? (
                                        <Image source={{ uri: currentTrack.cover }} style={{ width: 28, height: 28, borderRadius: 14, marginRight: 10 }} />
                                    ) : (
                                        <View style={{ width: 28, height: 28, borderRadius: 14, marginRight: 10, backgroundColor: colors.primary, alignItems: 'center', justifyContent: 'center' }}>
                                            <Music size={14} color="#fff" />
                                        </View>
                                    )}
                                    <View style={{ flex: 1 }}>
                                        <Text style={[styles.miniTitle, { color: colors.text }]} numberOfLines={1}>
                                            {currentTrack.title}
                                        </Text>
                                        <Text style={[styles.miniArtist, { color: colors.textSecondary }]} numberOfLines={1}>
                                            {formatTime(positionMs)} / {formatTime(durationMs)}
                                        </Text>
                                    </View>
                                </View>
                            </TouchableOpacity>

                            <View style={styles.pillActions}>
                                <TouchableOpacity onPress={togglePlay} style={{ padding: 4, marginRight: 4 }}>
                                    {isPlaying ? <Pause size={18} color={colors.text} /> : <Play size={18} color={colors.text} />}
                                </TouchableOpacity>
                                <TouchableOpacity onPress={reset} style={{ padding: 4 }}>
                                    <X size={18} color={colors.textSecondary} />
                                </TouchableOpacity>
                            </View>
                        </View>
                    </SafeLiquidGlass>
                </Animated.View>
            </GestureDetector>
            {renderFullModal()}
        </React.Fragment>
    );
};

const styles = StyleSheet.create({
    miniPlayerContainer: {
        position: 'absolute',
        left: 20,
        right: 20,
        zIndex: 9999,
        alignItems: 'center',
        justifyContent: 'center',
    },
    glassPill: {
        width: '100%',
        height: 52,
        borderRadius: 26,
        overflow: 'hidden',
    },
    pillContent: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'center',
        paddingHorizontal: 12,
    },
    pillMainBtn: {
        flex: 1,
        height: '100%',
        justifyContent: 'center',
    },
    pillActions: {
        flexDirection: 'row',
        alignItems: 'center',
    },
    miniTitle: {
        fontSize: 14,
        fontWeight: '600',
    },
    miniArtist: {
        fontSize: 11,
        opacity: 0.7,
    },
    // Header Styles
    headerContainer: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, zIndex: 50 },
    headerContentContainer: { position: 'absolute', top: 0, left: 0, right: 0, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingBottom: 4, zIndex: 101 },
    headerBtnWrapper: { width: 44, height: 44, borderRadius: 22, overflow: 'hidden', zIndex: 140 },
});
