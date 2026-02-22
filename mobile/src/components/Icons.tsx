import React, { useEffect, useState } from 'react';
import Svg, { Path, Circle, G, Rect, Polyline, Line } from 'react-native-svg';
import Animated, {
    useAnimatedStyle,
    useSharedValue,
    withSpring,
    withSequence,
    withTiming,
    withRepeat,
    interpolate,
    Easing,
    Extrapolate,
    ZoomIn
} from 'react-native-reanimated';
import { Image, View, Text, StyleSheet } from 'react-native';
import { useChatStore } from '../lib/ChatStore';
import { colors as themeColors, theme as appTheme } from '../lib/theme';
import { useThemeStore } from '../lib/stores/theme-store';
import RelayClient from '../lib/relay/RelayClient';
import RelayNode from '../lib/relay/RelayNode';
import type { SharedValue } from 'react-native-reanimated';

interface IconProps {
    size?: number;
    color?: string;
    focused?: boolean;
}

const AnimatedView = Animated.View;

/**
 * Common Animation Wrapper for Tab Icons
 */
const AnimatedTabIcon = ({ children, focused, size, noSpring = false }: { children: React.ReactNode, focused: boolean, size: number, noSpring?: boolean }) => {
    const scale = useSharedValue(1);
    const rotation = useSharedValue(0);

    useEffect(() => {
        if (focused) {
            if (noSpring) {
                // Smooth timing for profile image
                scale.value = withTiming(1.08, { duration: 200, easing: Easing.out(Easing.quad) });
                rotation.value = 0; // No zigzag for profile
            } else {
                // Punchy spring for vector icons
                scale.value = withSpring(1.08, { damping: 12, stiffness: 200 });
                rotation.value = withSequence(
                    withTiming(-8, { duration: 60 }),
                    withTiming(8, { duration: 100 }),
                    withTiming(0, { duration: 100 })
                );
            }
        } else {
            scale.value = withTiming(1, { duration: 200 });
            rotation.value = withTiming(0, { duration: 200 });
        }
    }, [focused, noSpring]);

    const animatedStyle = useAnimatedStyle(() => ({
        width: size,
        height: size,
        alignItems: 'center',
        justifyContent: 'center',
        transform: [{ scale: scale.value }, { rotate: `${rotation.value}deg` }]
    }));

    return <AnimatedView style={animatedStyle}>{children}</AnimatedView>;
};

export const ContactsIcon = ({ size = 24, color = "#000", focused = false }: IconProps) => (
    <AnimatedTabIcon focused={focused} size={size}>
        <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
            <Path
                d="M12 12C14.21 12 16 10.21 16 8C16 5.79 14.21 4 12 4C9.79 4 8 5.79 8 8C8 10.21 9.79 12 12 12ZM12 14C9.33 14 4 15.34 4 18V20H20V18C20 15.34 14.67 14 12 14Z"
                fill={color}
                opacity={focused ? 1 : 0.6}
            />
        </Svg>
    </AnimatedTabIcon>
);

export const CallsIcon = ({ size = 24, color = "#000", focused = false }: IconProps) => (
    <AnimatedTabIcon focused={focused} size={size}>
        <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
            <Path
                d="M20.01 15.38C18.78 15.38 17.59 15.18 16.48 14.82C16.13 14.7 15.74 14.79 15.47 15.06L13.9 17.03C11.07 15.68 8.42 13.06 7.01 10.15L8.96 8.54C9.23 8.26 9.31 7.87 9.2 7.52C8.83 6.41 8.64 5.22 8.64 3.99C8.64 3.45 8.19 3 7.65 3H4.19C3.65 3 3 3.24 3 3.99C3 13.28 10.73 21 20.01 21C20.72 21 21 20.37 21 19.82V16.37C21 15.83 20.55 15.38 20.01 15.38Z"
                fill={color}
                opacity={focused ? 1 : 0.6}
            />
        </Svg>
    </AnimatedTabIcon>
);

export const SettingsIcon = ({ size = 24, color = "#000", focused = false, imageUri, name }: IconProps & { imageUri?: string, name?: string }) => (
    <AnimatedTabIcon focused={focused} size={size} noSpring>
        <View style={{
            width: size,
            height: size,
            borderRadius: size / 2,
            overflow: 'hidden',
            backgroundColor: 'rgba(0,0,0,0.08)', // Natural neutral background
            alignItems: 'center',
            justifyContent: 'center',
            borderColor: focused ? color : 'transparent',
            borderWidth: focused ? 1 : 0 // Subtle edge definition only when active
        }}>
            {imageUri ? (
                <Image
                    source={{ uri: imageUri }}
                    style={{ width: '100%', height: '100%' }}
                    resizeMode="cover"
                />
            ) : (
                <View style={{ width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center' }}>
                    {name ? (
                        <Text style={{
                            color: color,
                            fontSize: size * 0.45,
                            fontWeight: '600',
                            textAlign: 'center',
                            opacity: focused ? 1 : 0.7
                        }}>
                            {name.charAt(0).toUpperCase()}
                        </Text>
                    ) : (
                        <Svg width="70%" height="70%" viewBox="0 0 24 24" fill="none">
                            <Path d="M12 12C14.21 12 16 10.21 16 8C16 5.79 14.21 4 12 4C9.79 4 8 5.79 8 8C8 10.21 9.79 12 12 12ZM12 14C9.33 14 4 15.34 4 18V22H20V18C20 15.34 14.67 14 12 14Z" fill={color} opacity={focused ? 1 : 0.6} />
                        </Svg>
                    )}
                </View>
            )}
        </View>
    </AnimatedTabIcon>
);


export const DoubleCheckIcon = ({ size = 24, color = "#1C274C", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <Path
            d="M4 12.9L7.14286 16.5L15 7.5"
            stroke={color}
            strokeWidth={strokeWidth}
            strokeLinecap="round"
            strokeLinejoin="round"
        />
        <Path
            d="M20 7.5625L11.4283 16.5625L11 16"
            stroke={color}
            strokeWidth={strokeWidth}
            strokeLinecap="round"
            strokeLinejoin="round"
        />
    </Svg>
);

export const CheckIcon = ({ size = 24, color = "#1C274C", strokeWidth = 2 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <Path d="M4 12L8.94975 16.9497L19.5572 6.34326" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
);

export const VibeLogoIcon = ({ size = 24, color = "#fff", strokeWidth = 3 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <Path
            d="M5 8L12 17L19 8"
            stroke={color}
            strokeWidth={strokeWidth}
            strokeLinecap="round"
            strokeLinejoin="round"
        />
    </Svg>
);

export const AttachmentIcon = ({ size = 20, color = '#fff' }: IconProps) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
    </Svg>
);

export const SearchIcon = ({ size = 24, color = '#000', focused = false }: IconProps) => (
    <AnimatedTabIcon focused={focused} size={size}>
        <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
            <Circle cx="11" cy="11" r="7" stroke={color} strokeWidth={1.5} fill="none" />
            <Path d="M20 20L16.5 16.5" stroke={color} strokeWidth={1.5} strokeLinecap="round" />
        </Svg>
    </AnimatedTabIcon>
);

export const StickerIcon = ({ size = 24, color = '#fff' }: IconProps) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M21.2 12 A9.2 9.2 0 1 1 12 2.8" />
        <Path d="M12 2.8c0 4.5 4.5 9.2 9.2 9.2" />
        <Path d="M12 2.8c4.5 0 9.2 4.5 9.2 9.2" />
    </Svg>
);

export const GifIcon = StickerIcon;

export const RecentPillIcon = ({ size = 22, color = '#000' }: IconProps) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={2.1} strokeLinecap="round" strokeLinejoin="round">
        <Circle cx="12" cy="12" r="9.25" />
        <Path d="M12 7.2v5l3.2 2.2" />
    </Svg>
);

export const AnimatedRecentToGifIcon = ({
    progress,
    size = 22,
    color = '#000',
}: {
    progress: SharedValue<number>;
    size?: number;
    color?: string;
}) => {
    const clockStyle = useAnimatedStyle(() => {
        const p = progress.value;
        return {
            opacity: 1 - p,
            transform: [{ scale: interpolate(p, [0, 1], [1, 0.88], Extrapolate.CLAMP) }]
        };
    });

    const gifStyle = useAnimatedStyle(() => {
        const p = progress.value;
        return {
            opacity: p,
            transform: [{ scale: interpolate(p, [0, 1], [0.88, 1], Extrapolate.CLAMP) }]
        };
    });

    return (
        <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>
            <Animated.View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }, clockStyle]}>
                <RecentPillIcon size={size} color={color} />
            </Animated.View>
            <Animated.View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }, gifStyle]}>
                <GifIcon size={size} color={color} />
            </Animated.View>
        </View>
    );
};

export const ShieldIcon = ({ size = 24, color = '#000' }: IconProps) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
    </Svg>
);

export const AnimatedShieldIcon = ({ size = 20, color }: IconProps) => {
    const { colors, effectiveTheme } = useThemeStore();
    const currentTheme = appTheme[effectiveTheme];

    // Separate states for Client vs Host
    const [clientConnected, setClientConnected] = useState(() => RelayClient.getInstance().isConnected());
    const [hostRunning, setHostRunning] = useState(() => RelayNode.getInstance().getStatus() === 'running');

    useEffect(() => {
        const unsubClient = RelayClient.getInstance().subscribe(() => {
            setClientConnected(RelayClient.getInstance().isConnected());
        });
        const unsubNode = RelayNode.getInstance().subscribe(() => {
            setHostRunning(RelayNode.getInstance().getStatus() === 'running');
        });

        return () => {
            unsubClient();
            unsubNode();
        };
    }, []);

    const isAnyActive = clientConnected || hostRunning;
    const progress = useSharedValue(isAnyActive ? 1 : 0);
    const pulse = useSharedValue(1);

    useEffect(() => {
        progress.value = withTiming(isAnyActive ? 1 : 0, { duration: 500 });
        if (!isAnyActive) {
            pulse.value = withRepeat(
                withSequence(
                    withTiming(1.06, { duration: 1000, easing: Easing.inOut(Easing.ease) }),
                    withTiming(1, { duration: 1000, easing: Easing.inOut(Easing.ease) })
                ),
                -1,
                true
            );
        } else {
            pulse.value = withTiming(1, { duration: 500 });
        }
    }, [isAnyActive]);

    const animatedStyle = useAnimatedStyle(() => {
        return {
            transform: [{ scale: pulse.value }],
            opacity: interpolate(progress.value, [0, 1], [0.8, 1]),
        };
    });

    // Color Logic:
    // Hosting prioritized if both active (rare but possible)
    const hostColor = currentTheme.palette?.violet || '#9B7BD4';
    const clientColor = currentTheme.bubble.me;
    const offColor = color || colors.text;

    const shieldColor = hostRunning ? hostColor : (clientConnected ? clientColor : offColor);

    // Checkmark scale and opacity
    const checkmarkProps = useAnimatedStyle(() => ({
        opacity: progress.value,
        transform: [
            { translateX: 4.5 }, // Adjust to center within the shield
            { translateY: 4.5 },
            { scale: interpolate(progress.value, [0, 1], [0.4, 0.7], Extrapolate.CLAMP) }
        ]
    }));

    return (
        <AnimatedView style={animatedStyle}>
            <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
                {/* Shield Body - Stroke when off, Fill when active */}
                <Path
                    d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"
                    fill={isAnyActive ? shieldColor : 'none'}
                    stroke={isAnyActive ? 'none' : shieldColor}
                    strokeWidth={isAnyActive ? 0 : 1.5}
                />
                {/* Checkmark - Solid White (Only visible when active) */}
                <AnimatedPath
                    d="M10.5 15.17L7.33 12l-1.08 1.08L10.5 17.34 17.75 10.09 16.67 9 10.5 15.17z"
                    fill={"#fff"}
                    animatedProps={checkmarkProps}
                />
            </Svg>
        </AnimatedView>
    );
};

const AnimatedPath = Animated.createAnimatedComponent(Path);

export const NewChatIcon = ({ size = 24, color = '#000' }: IconProps) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
        <Path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
    </Svg>
);
export const DocumentIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
        <Path d="M14 2v6h6" />
        <Path d="M16 13H8" />
        <Path d="M16 17H8" />
        <Path d="M10 9H8" />
    </Svg>
);

export const RefreshIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M23 4v6h-6" />
        <Path d="M1 20v-6h6" />
        <Path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15" />
    </Svg>
);

export const ThumbUpIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M7 10v12" />
        <Path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a2 2 0 0 1 3 3.88Z" />
    </Svg>
);

export const ThumbDownIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M17 14V2" />
        <Path d="M9 18.12 10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a2 2 0 0 1-3-3.88Z" />
    </Svg>
);

export const ChevronDownIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m6 9 6 6 6-6" />
    </Svg>
);

export const ChevronRightIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m9 18 6-6-6-6" />
    </Svg>
);

export const CurvedArrowIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m15 14 5-5-5-5" />
        <Path d="M4 20v-7a4 4 0 0 1 4-4h12" />
    </Svg>
);

export const MicIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
        <Path d="M19 10v1a7 7 0 0 1-14 0v-1" />
        <Path d="M12 19v3" />
        <Path d="M8 22h8" />
    </Svg>
);

export const PlayIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m7 3 14 9-14 9V3z" fill={color} />
    </Svg>
);

export const PauseIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M6 4h4v16H6z" fill={color} />
        <Path d="M14 4h4v16h-4z" fill={color} />
    </Svg>
);

export const SendIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m22 2-7 20-4-9-9-4Z" />
        <Path d="M22 2 11 13" />
    </Svg>
);

export const SendFilledIcon = ({ size = 24, color = "#000" }: IconProps) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <Path
            d="M2.01 21L23 12L2.01 3L2 10L17 12L2 14L2.01 21Z"
            fill={color}
        />
    </Svg>
);

export const WaveformIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M3 10v4" />
        <Path d="M6 6v12" />
        <Path d="M9 10v4" />
        <Path d="M12 2v20" />
        <Path d="M15 8v8" />
        <Path d="M18 10v4" />
        <Path d="M21 6v12" />
    </Svg>
);

export const VoiceIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
        <Path d="M19 10v1a7 7 0 0 1-14 0v-1" />
        <Path d="M12 19v3" />
    </Svg>
);

export const StopIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M6 6h12v12H6z" fill={color} />
    </Svg>
);

export const TelegramIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m22 2-20 7 8 3 3 8 7-20Z" />
    </Svg>
);

export const InstagramIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M16 3H8a5 5 0 0 0-5 5v8a5 5 0 0 0 5 5h8a5 5 0 0 0 5-5V8a5 5 0 0 0-5-5z" />
        <Circle cx="12" cy="12" r="4" />
        <Path d="M17.5 6.5h.01" />
    </Svg>
);

export const GlobeIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Circle cx="12" cy="12" r="10" />
        <Path d="M2 12h20" />
        <Path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
    </Svg>
);

export const GmailIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m22 6-10 7L2 6" />
        <Path d="M5.4 6h13.2a2.4 2.4 0 0 1 2.4 2.4v9.2a2.4 2.4 0 0 1-2.4 2.4H5.4a2.4 2.4 0 0 1-2.4-2.4V8.4A2.4 2.4 0 0 1 5.4 6z" />
    </Svg>
);

export const MessageCircleIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z" />
    </Svg>
);

export const PlusIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M12 5v14" />
        <Path d="M5 12h14" />
    </Svg>
);

export const EditIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M12 20h9" />
        <Path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" />
    </Svg>
);

export const ImageIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M3 3h18v18H3z" />
        <Circle cx="8.5" cy="8.5" r="1.5" />
        <Path d="m21 15-5-5L5 21" />
    </Svg>
);

export const VideoIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m22 8-6 4 6 4V8Z" />
        <Path d="M2 6h14a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2Z" />
    </Svg>
);

export const CallVideoIcon = ({ size = 24, color = "#000", strokeWidth = 2 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <Path
            d="M16 10L18.5768 8.45392C19.3699 7.97803 19.7665 7.74009 20.0928 7.77051C20.3773 7.79703 20.6369 7.944 20.806 8.17433C21 8.43848 21 8.90095 21 9.8259V14.1741C21 15.099 21 15.5615 20.806 15.8257C20.6369 16.056 20.3773 16.203 20.0928 16.2295C19.7665 16.2599 19.3699 16.022 18.5768 15.5461L16 14M6.2 18H12.8C13.9201 18 14.4802 18 14.908 17.782C15.2843 17.5903 15.5903 17.2843 15.782 16.908C16 16.4802 16 15.9201 16 14.8V9.2C16 8.0799 16 7.51984 15.782 7.09202C15.5903 6.71569 15.2843 6.40973 14.908 6.21799C14.4802 6 13.9201 6 12.8 6H6.2C5.0799 6 4.51984 6 4.09202 6.21799C3.71569 6.40973 3.40973 6.71569 3.21799 7.09202C3 7.51984 3 8.07989 3 9.2V14.8C3 15.9201 3 16.4802 3.21799 16.908C3.40973 17.2843 3.71569 17.5903 4.09202 17.782C4.51984 18 5.07989 18 6.2 18Z"
            stroke={color}
            strokeWidth={strokeWidth}
            strokeLinecap="round"
            strokeLinejoin="round"
        />
    </Svg>
);

export const CallVideoOffIcon = ({ size = 24, color = "#000", strokeWidth = 2 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <Path
            d="M16 10L18.5768 8.45392C19.3699 7.97803 19.7665 7.74009 20.0928 7.77051C20.3773 7.79703 20.6369 7.944 20.806 8.17433C21 8.43848 21 8.90095 21 9.8259V14.1741C21 15.099 21 15.5615 20.806 15.8257C20.6369 16.056 20.3773 16.203 20.0928 16.2295C19.7665 16.2599 19.3699 16.022 18.5768 15.5461L16 14M6.2 18H12.8C13.9201 18 14.4802 18 14.908 17.782C15.2843 17.5903 15.5903 17.2843 15.782 16.908C16 16.4802 16 15.9201 16 14.8V9.2C16 8.0799 16 7.51984 15.782 7.09202C15.5903 6.71569 15.2843 6.40973 14.908 6.21799C14.4802 6 13.9201 6 12.8 6H6.2C5.0799 6 4.51984 6 4.09202 6.21799C3.71569 6.40973 3.40973 6.71569 3.21799 7.09202C3 7.51984 3 8.07989 3 9.2V14.8C3 15.9201 3 16.4802 3.21799 16.908C3.40973 17.2843 3.71569 17.5903 4.09202 17.782C4.51984 18 5.07989 18 6.2 18Z"
            stroke={color}
            strokeWidth={strokeWidth}
            strokeLinecap="round"
            strokeLinejoin="round"
        />
        <Path
            d="M4 4L20 20"
            stroke={color}
            strokeWidth={strokeWidth}
            strokeLinecap="round"
            strokeLinejoin="round"
        />
    </Svg>
);

export const SparklesIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m12 3 1.912 5.813a2 2 0 0 0 1.275 1.275L21 12l-5.813 1.912a2 2 0 0 0-1.275 1.275L12 21l-1.912-5.813a2 2 0 0 0-1.275-1.275L3 12l5.813-1.912a2 2 0 0 0 1.275-1.275L12 3Z" />
        <Path d="M5 3v4" />
        <Path d="M3 5h4" />
        <Path d="M19 17v4" />
        <Path d="M17 19h4" />
    </Svg>
);

export const ZapIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z" />
    </Svg>
);

export const CloseIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M18 6 6 18" />
        <Path d="m6 6 12 12" />
    </Svg>
);

export const ExpandIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="m15 3 6 6" />
        <Path d="M9 21l-6-6" />
        <Path d="M21 3v6h-6" />
        <Path d="M3 21v-6h6" />
    </Svg>
);

export const MinimizeIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M2 22L9 15M9 15H3.14286M9 15V20.8571" />
        <Path d="M22 2L15 9M15 9H20.8571M15 9V3.14286" />
    </Svg>
);


export const HistoryIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
        <Path d="M3 3v5h5" />
        <Path d="M12 7v5l4 2" />
    </Svg>
);
export const WifiIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <Path d="M5 13a10 10 0 0 1 14 0" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
        <Path d="M2.5 10a14 14 0 0 1 19 0" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
        <Path d="M8 16a6 6 0 0 1 8 0" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
        <Circle cx="12" cy="19" r="1.5" fill={color} />
    </Svg>
);

export const AlignLeftIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M17 10H3" />
        <Path d="M21 6H3" />
        <Path d="M21 14H3" />
        <Path d="M17 18H3" />
    </Svg>
);

export const AlignCenterIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M18 10H6" />
        <Path d="M21 6H3" />
        <Path d="M21 14H3" />
        <Path d="M18 18H6" />
    </Svg>
);

export const AlignRightIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M21 10H7" />
        <Path d="M21 6H3" />
        <Path d="M21 14H3" />
        <Path d="M21 18H7" />
    </Svg>
);

export const PaletteIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Circle cx="13.5" cy="6.5" r="2" />
        <Circle cx="17.5" cy="10.5" r="2" />
        <Circle cx="8.5" cy="7.5" r="2" />
        <Circle cx="6.5" cy="12.5" r="2" />
        <Path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c.926 0 1.648-.746 1.648-1.688 0-.437-.18-.835-.437-1.125-.29-.289-.438-.652-.438-1.125a1.64 1.64 0 0 1 1.668-1.668h1.996c3.051 0 5.555-2.503 5.555-5.554C21.965 6.012 17.461 2 12 2z" />
    </Svg>
);

export const TextEffectsIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M4 20h16" />
        <Path d="m12 4-8 16" />
        <Path d="m12 4 8 16" />
        <Path d="M6 16h12" />
    </Svg>
);

export const PlusCircleVibeIcon = ({ size = 24, color = "#001A72" }: IconProps) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <Path
            d="M12.75 8C12.75 7.58579 12.4142 7.25 12 7.25C11.5858 7.25 11.25 7.58579 11.25 8H12.75ZM11.25 16C11.25 16.4142 11.5858 16.75 12 16.75C12.4142 16.75 12.75 16.4142 12.75 16H11.25ZM8 11.25C7.58579 11.25 7.25 11.5858 7.25 12C7.25 12.4142 7.58579 12.75 8 12.75V11.25ZM16 12.75C16.4142 12.75 16.75 12.4142 16.75 12C16.75 11.5858 16.4142 11.25 16 11.25V12.75ZM14.7501 4.21925C15.1406 4.35728 15.5691 4.15259 15.7071 3.76205C15.8452 3.37151 15.6405 2.94302 15.2499 2.80499L14.7501 4.21925ZM20.1077 6.58281C19.8773 6.23859 19.4115 6.14633 19.0673 6.37674C18.723 6.60715 18.6308 7.07298 18.8612 7.41719L20.1077 6.58281ZM10 12.75C10.4142 12.75 10.75 12.4142 10.75 12C10.75 11.5858 10.4142 11.25 10 11.25V12.75ZM12 11.25C11.5858 11.25 11.25 11.5858 11.25 12C11.25 12.4142 11.5858 12.75 12 12.75V11.25ZM11.25 8V16H12.75V8H11.25ZM20.25 12C20.25 16.5563 16.5563 20.25 12 20.25V21.75C17.3848 21.75 21.75 17.3848 21.75 12H20.25ZM12 20.25C7.44365 20.25 3.75 16.5563 3.75 12H2.25C2.25 17.3848 6.61522 21.75 12 21.75V20.25ZM3.75 12C3.75 7.44365 7.44365 3.75 12 3.75V2.25C6.61522 2.25 2.25 6.61522 2.25 12H3.75ZM12 3.75C12.9656 3.75 13.8909 3.91557 14.7501 4.21925L15.2499 2.80499C14.2324 2.44535 13.1382 2.25 12 2.25V3.75ZM18.8612 7.41719C19.7384 8.7277 20.25 10.303 20.25 12H21.75C21.75 9.99674 21.145 8.1325 20.1077 6.58281L18.8612 7.41719ZM8 12.75H10V11.25H8V12.75ZM12 12.75H16V11.25H12V12.75Z"
            fill={color}
        />
    </Svg>
);

export const EditChatVibeIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: IconProps & { strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 21 21">
        <G fill="none" fillRule="evenodd" stroke={color} strokeLinecap="round" strokeLinejoin="round" transform="translate(3 3)">
            <Path d="m14 1c.8284271.82842712.8284271 2.17157288 0 3l-9.5 9.5-4 1 1-3.9436508 9.5038371-9.55252193c.7829896-.78700064 2.0312313-.82943964 2.864366-.12506788z" strokeWidth={strokeWidth} />
            <Path d="m6.5 14.5h8" strokeWidth={strokeWidth} />
            <Path d="m12.5 3.5 1 1" strokeWidth={strokeWidth} />
        </G>
    </Svg>
);

export const AnimatedStickerIcon = ({
    progress,
    size = 24,
    color = '#000',
}: {
    progress: SharedValue<number>;
    size?: number;
    color?: string;
}) => {
    const circleStyle = useAnimatedStyle(() => {
        const p = progress.value;
        return {
            opacity: interpolate(p, [0, 0.5], [1, 0], Extrapolate.CLAMP),
            transform: [{ scale: interpolate(p, [0, 1], [1, 0.5], Extrapolate.CLAMP) }]
        };
    });

    const faceStyle = useAnimatedStyle(() => {
        const p = progress.value;
        return {
            opacity: interpolate(p, [0.5, 1], [0, 1], Extrapolate.CLAMP),
            transform: [
                { scale: interpolate(p, [0, 1], [0.5, 1], Extrapolate.CLAMP) },
                { rotate: `${interpolate(p, [0, 1], [0, 10], Extrapolate.CLAMP)}deg` }
            ]
        };
    });

    return (
        <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>
            <Animated.View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }, circleStyle]}>
                <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round">
                    <Circle cx="12" cy="12" r="10" />
                </Svg>
            </Animated.View>
            <Animated.View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }, faceStyle]}>
                <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round">
                    <Circle cx="12" cy="12" r="10" />
                    <Path d="M8 14s1.5 2 4 2 4-2 4-2" />
                    <Path d="M9 9h.01" />
                    <Path d="M15 9h.01" />
                </Svg>
            </Animated.View>
        </View>
    );
};

export const AnimatedGifToSmileIcon = ({
    progress,
    size = 22,
    color = '#000',
}: {
    progress: SharedValue<number>;
    size?: number;
    color?: string;
}) => {
    const gifStyle = useAnimatedStyle(() => {
        const p = progress.value;
        return {
            opacity: 1 - p,
            transform: [{ scale: interpolate(p, [0, 1], [1, 0.88], Extrapolate.CLAMP) }],
        };
    });

    const faceStyle = useAnimatedStyle(() => {
        const p = progress.value;
        return {
            opacity: p,
            transform: [{ scale: interpolate(p, [0, 1], [0.88, 1], Extrapolate.CLAMP) }],
        };
    });

    return (
        <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>
            <Animated.View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }, gifStyle]}>
                <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
                    <Path d="M21.2 12 A9.2 9.2 0 1 1 12 2.8" />
                    <Path d="M12 2.8c0 4.5 4.5 9.2 9.2 9.2" />
                    <Path d="M12 2.8c4.5 0 9.2 4.5 9.2 9.2" />
                </Svg>
            </Animated.View>
            <Animated.View style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }, faceStyle]}>
                <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round">
                    <Circle cx="12" cy="12" r="9.5" />
                    <Path d="M8.4 14.2c1 .95 2.1 1.4 3.6 1.4s2.6-.45 3.6-1.4" />
                    <Path d="M9 9.5h.01" />
                    <Path d="M15 9.5h.01" />
                </Svg>
            </Animated.View>
        </View>
    );
};

export const AnimatedCopyIcon = ({ size = 20, color = '#fff', strokeWidth = 2 }: { size?: number, color?: string, strokeWidth?: number }) => {
    return (
        <Animated.View entering={ZoomIn.duration(250).springify().damping(12)}>
            <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
                <Rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
                <Path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
            </Svg>
        </Animated.View>
    );
};

export const AnimatedTrashIcon = ({ size = 20, color = '#ef4444', strokeWidth = 2 }: { size?: number, color?: string, strokeWidth?: number }) => {
    return (
        <Animated.View entering={ZoomIn.duration(250).springify().damping(12)}>
            <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
                <Path d="M3 6h18" />
                <Path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6" />
                <Path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2" />
                <Line x1="10" y1="11" x2="10" y2="17" />
                <Line x1="14" y1="11" x2="14" y2="17" />
            </Svg>
        </Animated.View>
    );
};

export const AnimatedPinIcon = ({ size = 20, color = '#fff', strokeWidth = 2 }: { size?: number, color?: string, strokeWidth?: number }) => {
    return (
        <Animated.View entering={ZoomIn.duration(250).springify().damping(12)}>
            <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
                <Path d="M12 17v5" />
                <Path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z" />
            </Svg>
        </Animated.View>
    );
};

export const AnimatedSuccessIcon = ({ size = 20, color = '#4ade80', strokeWidth = 2.5 }: { size?: number, color?: string, strokeWidth?: number }) => {
    return (
        <Animated.View entering={ZoomIn.duration(250).springify().damping(12)}>
            <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
                <Polyline points="20 6 9 17 4 12" />
            </Svg>
        </Animated.View>
    );
};

export const AnimatedInfoIcon = ({ size = 20, color = '#3b82f6', strokeWidth = 2.5 }: { size?: number, color?: string, strokeWidth?: number }) => {
    return (
        <Animated.View entering={ZoomIn.duration(250).springify().damping(12)}>
            <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
                <Circle cx="12" cy="12" r="10" />
                <Line x1="12" y1="16" x2="12" y2="12" />
                <Line x1="12" y1="8" x2="12.01" y2="8" />
            </Svg>
        </Animated.View>
    );
};

export const HeaderBackIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M15 19l-7-7 7-7" />
    </Svg>
);

export const HeaderPhoneIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l2.11-1.29a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z" />
    </Svg>
);

export const HeaderVideoIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Path d="M23 7l-7 5 7 5V7z" />
        <Rect x="1" y="5" width="15" height="14" rx="2" ry="2" />
    </Svg>
);

export const HeaderSearchIcon = ({ size = 24, color = "#000", strokeWidth = 1.5 }: { size?: number, color?: string, strokeWidth?: number }) => (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round">
        <Circle cx="11" cy="11" r="8" />
        <Path d="M21 21l-4.35-4.35" />
    </Svg>
);

