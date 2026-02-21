import React, { useEffect, useState } from 'react';
import {
    View,
    Text,
    StyleSheet,
    Image,
    TouchableOpacity,
    Dimensions,
    StatusBar,
    Platform,
} from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    FadeIn,
} from 'react-native-reanimated';
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
    PhoneOff,
    Mic,
    MicOff,
    Volume2,
    VolumeX,
    VideoOff,
    ChevronDown,
    Maximize2,
    RotateCcw,
    Camera,
    CameraOff,
    ArrowLeftRight,
} from 'lucide-react-native';
import * as Haptics from 'expo-haptics';

import { useCallStore, useIsInCall } from '../../lib/stores/CallStore';
import { useThemeStore } from '../../lib/stores/theme-store';
import { getUserChannel } from '../../lib/ChatStore';
import WebRTCService from '../../lib/services/WebRTCService';
import SafeLiquidGlass from '../native/SafeLiquidGlass';
import { RefreshIcon, MinimizeIcon, ExpandIcon, ChevronDownIcon } from '../Icons';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

// --- Components ---

const withAlpha = (color: string, alpha: number): string => {
    if (!color) return `rgba(127, 127, 127, ${alpha})`;
    if (color.startsWith('#')) {
        const hex = color.replace('#', '');
        const r = parseInt(hex.substring(0, 2), 16);
        const g = parseInt(hex.substring(2, 4), 16);
        const b = parseInt(hex.substring(4, 6), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
    if (color.startsWith('rgba')) {
        return color.replace(/[\d\.]+\)$/g, `${alpha})`);
    }
    return color;
};

interface ControlButtonProps {
    icon: React.ReactNode;
    onPress: () => void;
    isActive?: boolean;
    isDestructive?: boolean;
    backgroundColor: string;
    iconColor: string;
}

const ControlButton = ({
    icon,
    onPress,
    isActive = false,
    isDestructive = false,
    backgroundColor,
    iconColor,
}: ControlButtonProps) => {
    return (
        <TouchableOpacity
            onPress={() => {
                Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                onPress();
            }}
            activeOpacity={0.6}
            style={[
                styles.controlBtn,
                { backgroundColor, width: isDestructive ? 56 : 48 }
            ]}
        >
            {React.cloneElement(icon as React.ReactElement<any>, {
                color: iconColor,
                size: 20
            })}
        </TouchableOpacity>
    );
};

export default function ActiveCallScreen() {
    const { colors, effectiveTheme } = useThemeStore();
    const insets = useSafeAreaInsets();
    const isInCall = useIsInCall();
    const RTCView = WebRTCService.RTCView;

    const {
        callType,
        callStatus,
        remoteUser,
        isMuted,
        isSpeakerOn,
        isVideoEnabled,
        isFrontCamera,
        callDuration,
        hasLocalStream,
        hasRemoteStream,
        toggleMute,
        toggleSpeaker,
        toggleVideo,
        flipCamera,
        endCall,
        updateDuration,
    } = useCallStore();

    // UI States
    const [isMinimized, setIsMinimized] = useState(false);
    const [localIsFull, setLocalIsFull] = useState(false);


    const [localStreamUrl, setLocalStreamUrl] = useState<string | null>(null);
    const [remoteStreamUrl, setRemoteStreamUrl] = useState<string | null>(null);

    // Draggable PiP (Local Video)
    // Draggable PiP (Local Video when full, or whole screen when minimized)
    const pipX = useSharedValue(SCREEN_WIDTH - 120 - 16);
    const pipY = useSharedValue(insets.top + 60);

    // Draggable Minimized Screen
    const minX = useSharedValue(SCREEN_WIDTH - 150 - 16);
    const minY = useSharedValue(SCREEN_HEIGHT - 200 - insets.bottom);


    // Timer
    useEffect(() => {
        let timer: NodeJS.Timeout | null = null;
        if (callStatus === 'active') {
            timer = setInterval(updateDuration, 1000);
        }
        return () => { if (timer) clearInterval(timer); };
    }, [callStatus]);

    // Streams
    useEffect(() => {
        if (hasLocalStream) {
            const stream = WebRTCService.getLocalStream();
            if (stream) setLocalStreamUrl(stream.toURL());
        }
    }, [hasLocalStream]);

    useEffect(() => {
        if (hasRemoteStream) {
            const stream = WebRTCService.getRemoteStream();
            if (stream) setRemoteStreamUrl(stream.toURL());
        }
    }, [hasRemoteStream]);

    // Cleanup when ending
    const handleEndCall = () => {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
        endCall(getUserChannel());
    };

    const formatDuration = (seconds: number) => {
        const m = Math.floor(seconds / 60);
        const s = seconds % 60;
        return `${m}:${s.toString().padStart(2, '0')}`;
    };

    // PiP Gestures
    const pipGesture = Gesture.Pan()
        .onUpdate((e) => {
            pipX.value = Math.max(16, Math.min(SCREEN_WIDTH - 120 - 16, e.absoluteX - 60));
            pipY.value = Math.max(insets.top + 20, Math.min(SCREEN_HEIGHT - 200, e.absoluteY - 80));
        });

    const pipAnimatedStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: pipX.value }, { translateY: pipY.value }],
    }));

    // Minimized Screen Gestures
    const minGesture = Gesture.Pan()
        .onUpdate((e) => {
            minX.value = Math.max(16, Math.min(SCREEN_WIDTH - 150 - 16, e.absoluteX - 75));
            minY.value = Math.max(insets.top + 20, Math.min(SCREEN_HEIGHT - 200 - insets.bottom, e.absoluteY - 100));
        });

    const minAnimatedStyle = useAnimatedStyle(() => ({
        transform: [
            { translateX: minX.value },
            { translateY: minY.value }
        ],
    }));

    const swapFeeds = () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        setLocalIsFull(!localIsFull);
    };

    const toggleMinimize = () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        setIsMinimized(!isMinimized);
    };


    if (!isInCall || callStatus === 'idle' || callStatus === 'ended') return null;
    if (callStatus === 'ringing' && useCallStore.getState().callDirection === 'incoming') return null;

    const isVideoCall = callType === 'video';
    const isDark = effectiveTheme === 'dark';
    const glassTint = isDark ? 'dark' : 'light';
    const palette = {
        text: colors.text,
        textSubtle: withAlpha(colors.text, isDark ? 0.66 : 0.58),
        textDim: withAlpha(colors.text, isDark ? 0.82 : 0.72),
        surfaceSoft: withAlpha(colors.surface || colors.card, isDark ? 0.42 : 0.74),
        avatarBg: withAlpha(colors.primary, isDark ? 0.28 : 0.18),
        avatarRing: withAlpha(colors.text, isDark ? 0.18 : 0.1),
        controlBg: withAlpha(colors.text, isDark ? 0.16 : 0.12),
        controlActiveBg: withAlpha(colors.text, isDark ? 0.9 : 0.82),
        controlBarBg: withAlpha(colors.background, isDark ? 0.48 : 0.36),
        danger: withAlpha(colors.danger, 0.9),
        pipBorder: withAlpha(colors.text, isDark ? 0.24 : 0.18),
        pipBg: withAlpha(colors.background, isDark ? 0.92 : 0.82),
        overlay: withAlpha(colors.background, isDark ? 0.44 : 0.22),
        pipSwapBg: withAlpha(colors.background, isDark ? 0.62 : 0.46),
    } as const;
    const baseControlColor = palette.text;
    const activeControlIconColor = colors.background;

    // Shared Bottom Bar - Matches Native Tab Bar Style
    const renderBottomBar = () => (
        <View style={{ position: 'absolute', bottom: insets.bottom + 20, width: '100%', alignItems: 'center' }}>
            <SafeLiquidGlass
                blurIntensity={20}
                tint={glassTint}
                style={[styles.bottomBar, { backgroundColor: palette.controlBarBg }]}
            >
                <View style={styles.controlsRow}>
                    <ControlButton
                        icon={isMuted ? <MicOff /> : <Mic />}
                        onPress={toggleMute}
                        isActive={isMuted}
                        backgroundColor={isMuted ? palette.controlActiveBg : palette.controlBg}
                        iconColor={isMuted ? activeControlIconColor : baseControlColor}
                    />

                    <ControlButton
                        icon={isVideoEnabled ? <Camera /> : <CameraOff />}
                        onPress={toggleVideo}
                        isActive={isVideoEnabled}
                        backgroundColor={isVideoEnabled ? palette.controlActiveBg : palette.controlBg}
                        iconColor={isVideoEnabled ? activeControlIconColor : baseControlColor}
                    />

                    {isVideoCall && (
                        <ControlButton
                            icon={<RefreshIcon />}
                            onPress={flipCamera}
                            backgroundColor={palette.controlBg}
                            iconColor={baseControlColor}
                        />
                    )}

                    <ControlButton
                        icon={isSpeakerOn ? <Volume2 /> : <VolumeX />}
                        onPress={toggleSpeaker}
                        isActive={isSpeakerOn}
                        backgroundColor={isSpeakerOn ? palette.controlActiveBg : palette.controlBg}
                        iconColor={isSpeakerOn ? activeControlIconColor : baseControlColor}
                    />

                    <ControlButton
                        icon={<PhoneOff />}
                        onPress={handleEndCall}
                        isDestructive
                        backgroundColor={palette.danger}
                        iconColor={palette.text}
                    />
                </View>
            </SafeLiquidGlass>
        </View>
    );

    // --- VIDEO CALL UI ---
    if (isVideoCall) {
        const fullShowsLocal = localIsFull;
        const fullIsLocal = fullShowsLocal;
        const miniIsLocal = !fullShowsLocal;
        const FullView = fullShowsLocal ? localStreamUrl : remoteStreamUrl;
        const MiniView = fullShowsLocal ? remoteStreamUrl : localStreamUrl;
        // iOS remote front-camera frames can arrive mirrored depending on capturer path.
        // Use RTCView's native mirror prop (not style transforms) to compensate.
        const shouldCompensateRemoteMirror = Platform.OS === 'ios';
        const isFullMirror = fullIsLocal ? isFrontCamera : shouldCompensateRemoteMirror;
        const isMiniMirror = miniIsLocal ? isFrontCamera : shouldCompensateRemoteMirror;

        const renderVideoContent = (isMinimizedMode = false) => (
            <View style={[StyleSheet.absoluteFill, isMinimizedMode && { borderRadius: 24, overflow: 'hidden' }]}>
                {FullView && RTCView ? (
                    <RTCView
                        key={`full-${fullIsLocal ? 'local' : 'remote'}-${isFullMirror ? 'm1' : 'm0'}-${FullView}`}
                        streamURL={FullView}
                        style={StyleSheet.absoluteFill}
                        objectFit="cover"
                        mirror={isFullMirror}
                    />
                ) : (
                    <View style={[StyleSheet.absoluteFill, { backgroundColor: palette.pipBg, justifyContent: 'center', alignItems: 'center' }]}>
                        <VideoOff size={32} color={palette.textSubtle} />
                    </View>
                )}

                {/* Header Overlay */}
                {!isMinimizedMode && (
                    <View style={{ position: 'absolute', top: insets.top + 10, left: 16, right: 16, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                        <TouchableOpacity
                            onPress={toggleMinimize}
                            activeOpacity={0.7}
                        >
                            <SafeLiquidGlass
                                style={styles.headerBtn}
                                blurIntensity={20}
                                tint={glassTint}
                            >
                                <MinimizeIcon color={palette.text} size={20} />
                            </SafeLiquidGlass>
                        </TouchableOpacity>

                        <SafeLiquidGlass
                            borderRadius={20}
                            blurIntensity={15}
                            tint={glassTint}
                            style={{ paddingHorizontal: 16, paddingVertical: 8, flexDirection: 'row', alignItems: 'center', gap: 8 }}
                        >
                            <Text style={{ color: palette.text, fontSize: 16, fontWeight: '700' }}>
                                {remoteUser?.userName || 'Unknown'}
                            </Text>
                            <View style={{ width: 4, height: 4, borderRadius: 2, backgroundColor: palette.textSubtle }} />
                            <Text style={{ color: palette.textDim, fontSize: 14 }}>
                                {formatDuration(callDuration)}
                            </Text>
                        </SafeLiquidGlass>

                        <View style={{ width: 44 }} />
                    </View>
                )}

                {/* PiP feed within screen */}
                {!isMinimizedMode && MiniView && RTCView && (
                    <GestureDetector gesture={pipGesture}>
                        <Animated.View style={[styles.pipContainer, pipAnimatedStyle]}>
                            <TouchableOpacity activeOpacity={1} onPress={swapFeeds} style={StyleSheet.absoluteFill}>
                                <RTCView
                                    key={`mini-${miniIsLocal ? 'local' : 'remote'}-${isMiniMirror ? 'm1' : 'm0'}-${MiniView}`}
                                    streamURL={MiniView}
                                    style={{ width: '100%', height: '100%' }}
                                    objectFit="cover"
                                    mirror={isMiniMirror}
                                />
                                {(!localIsFull && !isVideoEnabled) && (
                                    <View style={[StyleSheet.absoluteFill, { backgroundColor: palette.pipBg, alignItems: 'center', justifyContent: 'center' }]}>
                                        <VideoOff size={20} color={palette.textSubtle} />
                                    </View>
                                )}
                                <View style={[styles.pipSwapBtn, { backgroundColor: palette.pipSwapBg }]}>
                                    <ArrowLeftRight size={14} color={palette.text} />
                                </View>
                            </TouchableOpacity>
                        </Animated.View>
                    </GestureDetector>
                )}

                {!isMinimizedMode && renderBottomBar()}

                {isMinimizedMode && (
                    <TouchableOpacity onPress={toggleMinimize} style={StyleSheet.absoluteFill}>
                        <View style={[styles.minimizedOverlay, { backgroundColor: palette.overlay }]} />
                    </TouchableOpacity>
                )}
            </View>
        );

        if (isMinimized) {
            return (
                <GestureHandlerRootView style={styles.minimizedContainer}>
                    <GestureDetector gesture={minGesture}>
                        <Animated.View style={[styles.minimizedWindow, minAnimatedStyle]}>
                            {renderVideoContent(true)}
                        </Animated.View>
                    </GestureDetector>
                </GestureHandlerRootView>
            );
        }

        return (
            <View style={StyleSheet.absoluteFill}>
                <StatusBar barStyle={isDark ? 'light-content' : 'dark-content'} />
                <GestureHandlerRootView style={StyleSheet.absoluteFill}>
                    <View style={[StyleSheet.absoluteFill, { backgroundColor: colors.background }]}>
                        {renderVideoContent(false)}
                    </View>
                </GestureHandlerRootView>
            </View>
        );
    }

    // --- VOICE CALL UI ---
    if (isMinimized) {
        return (
            <GestureHandlerRootView style={styles.minimizedContainer}>
                <GestureDetector gesture={minGesture}>
                    <Animated.View style={[styles.minimizedWindow, minAnimatedStyle]}>
                        <TouchableOpacity onPress={toggleMinimize} style={StyleSheet.absoluteFill}>
                            <View style={[StyleSheet.absoluteFill, { backgroundColor: colors.background, alignItems: 'center', justifyContent: 'center' }]}>
                                {remoteUser?.userImage ? (
                                    <Image source={{ uri: remoteUser.userImage }} style={{ width: 80, height: 80, borderRadius: 40 }} />
                                ) : (
                                    <View style={{ width: 80, height: 80, borderRadius: 40, backgroundColor: palette.surfaceSoft, alignItems: 'center', justifyContent: 'center' }}>
                                        <Text style={{ fontSize: 32, fontWeight: '700', color: colors.text }}>
                                            {remoteUser?.userName?.[0]?.toUpperCase() || '?'}
                                        </Text>
                                    </View>
                                )}
                                <View style={[styles.minimizedOverlay, { backgroundColor: palette.overlay }]} />
                            </View>
                        </TouchableOpacity>
                    </Animated.View>
                </GestureDetector>
            </GestureHandlerRootView>
        );
    }
    const voiceAvatarSize = 136;
    const voiceAvatarRadius = voiceAvatarSize / 2;
    const voiceControlsOffset = insets.bottom + 96;

    return (
        <View style={[StyleSheet.absoluteFill, { backgroundColor: colors.background }]}>
            <StatusBar barStyle={isDark ? 'light-content' : 'dark-content'} />

            {/* Header - Static */}
            <View style={{ paddingTop: insets.top + 32, alignItems: 'center' }}>
                <Text style={{ color: palette.textSubtle, fontSize: 16, fontWeight: '500', marginBottom: 8 }}>
                    {callStatus === 'connecting' ? 'Connecting...' : callStatus === 'ringing' ? 'Ringing...' : 'Vibe Audio'}
                </Text>
            </View>

            {/* Avatar */}
            <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', paddingBottom: voiceControlsOffset, gap: 14 }}>
                <View style={{
                    width: voiceAvatarSize,
                    height: voiceAvatarSize,
                    borderRadius: voiceAvatarRadius,
                    backgroundColor: palette.avatarBg,
                    borderWidth: 1,
                    borderColor: palette.avatarRing,
                    alignItems: 'center',
                    justifyContent: 'center'
                }}>
                    {remoteUser?.userImage ? (
                        <Image source={{ uri: remoteUser.userImage }} style={{ width: voiceAvatarSize, height: voiceAvatarSize, borderRadius: voiceAvatarRadius }} />
                    ) : (
                        <Text style={{ fontSize: 52, fontWeight: '700', color: colors.text }}>
                            {remoteUser?.userName?.[0]?.toUpperCase() || '?'}
                        </Text>
                    )}
                </View>
                <View style={{ alignItems: 'center' }}>
                    <Text style={{ color: palette.text, fontSize: 24, fontWeight: '700', marginBottom: 6 }}>
                        {remoteUser?.userName || 'Unknown'}
                    </Text>
                    {callStatus === 'active' && (
                        <Text style={{ color: palette.textDim, fontSize: 16, fontWeight: '500', fontVariant: ['tabular-nums'] }}>
                            {formatDuration(callDuration)}
                        </Text>
                    )}
                </View>
            </View>

            {renderBottomBar()}

            {/* Header Close button for voice call too */}
            <TouchableOpacity
                onPress={toggleMinimize}
                activeOpacity={0.7}
                style={{ position: 'absolute', top: insets.top + 10, left: 16 }}
            >
                <SafeLiquidGlass
                    style={styles.headerBtn}
                    blurIntensity={20}
                    tint={glassTint}
                >
                    <MinimizeIcon color={palette.text} size={20} />
                </SafeLiquidGlass>
            </TouchableOpacity>
        </View>

    );
}

const styles = StyleSheet.create({
    pipContainer: {
        position: 'absolute',
        width: 120,
        height: 160,
        borderRadius: 16,
        overflow: 'hidden',
        borderWidth: 1,
    },
    bottomBar: {
        borderRadius: 32,
        overflow: 'hidden',
        height: 64,
    },
    controlsRow: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 12,
        paddingHorizontal: 16,
        flex: 1,
    },
    controlBtn: {
        width: 48,
        height: 48,
        borderRadius: 24,
        justifyContent: 'center',
        alignItems: 'center',
    },
    headerBtn: {
        width: 44,
        height: 44,
        borderRadius: 22,
        backgroundColor: 'rgba(255,255,255,0.15)',
        justifyContent: 'center',
        alignItems: 'center',
    },
    minimizedContainer: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        zIndex: 9999,
        pointerEvents: 'box-none',
    },
    minimizedWindow: {
        width: 150,
        height: 200,
        borderRadius: 24,
        elevation: 10,
        shadowOffset: { width: 0, height: 4 },
        shadowOpacity: 0.3,
        shadowRadius: 8,
        overflow: 'hidden',
    },
    minimizedOverlay: {
        ...StyleSheet.absoluteFillObject,
        justifyContent: 'center',
        alignItems: 'center',
    },
    pipSwapBtn: {
        position: 'absolute',
        bottom: 8,
        right: 8,
        width: 24,
        height: 24,
        borderRadius: 12,
        justifyContent: 'center',
        alignItems: 'center',
    },
});
