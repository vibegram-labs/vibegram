import React from 'react';
import {
    NativeSyntheticEvent,
    Platform,
    StyleSheet,
    Text,
    TouchableOpacity,
    View,
    type ColorValue,
    type ImageSourcePropType,
} from 'react-native';
import Constants from 'expo-constants';
import { requireNativeViewManager } from 'expo-modules-core';
import Animated, {
    Extrapolation,
    interpolate,
    useAnimatedStyle,
} from 'react-native-reanimated';
import type { SharedValue } from 'react-native-reanimated';
import SafeLiquidGlass from './SafeLiquidGlass';

interface NativeTabPressPayload {
    index: number;
}

interface NativeTabViewItem {
    key: string;
    title: string;
    sfSymbol?: string;
    badge?: string;
    isVibe?: boolean;
}

interface NativeChatTabsViewProps {
    tabs: NativeTabViewItem[];
    currentIndex: number;
    activeTintColor?: ColorValue;
    inactiveTintColor?: ColorValue;
    isDark?: boolean;
    onIndexChange?: (event: NativeSyntheticEvent<NativeTabPressPayload>) => void;
    style?: any;
}

let NativeChatTabsView: React.ComponentType<NativeChatTabsViewProps> | null = null;
let nativeTabsAvailable = false;

try {
    const isExpoGo = Constants.appOwnership === 'expo';
    if (Platform.OS === 'ios' && !isExpoGo) {
        NativeChatTabsView = requireNativeViewManager<NativeChatTabsViewProps>('ChatNativeTabs');
        nativeTabsAvailable = !!NativeChatTabsView;
        console.log('[NativeTabBar] Native Swift tabs available');
    }
} catch {
    nativeTabsAvailable = false;
}

export interface TabConfig {
    key: string;
    title: string;
    sfSymbol?: string;
    unfocusedSfSymbol?: string;
    badge?: string;
    iconSource?: ImageSourcePropType;
    unfocusedIconSource?: ImageSourcePropType;
    preventsDefault?: boolean;
    renderIcon?: (props: { focused: boolean; color: string; size: number }) => React.ReactNode;
}

export interface NativeTabBarProps {
    currentIndex: number;
    onIndexChange: (index: number) => void;
    tabs: TabConfig[];
    activeTintColor?: string;
    inactiveTintColor?: string;
    activeIndicatorColor?: string;
    labeled?: boolean;
    hapticFeedback?: boolean;
    translucent?: boolean;
    isDark?: boolean;
    translateX?: SharedValue<number>;
    screenWidth?: number;
    onVibePress?: () => void;
    fallbackTabWidth?: number;
}

const FALLBACK_TAB_WIDTH = 70;

function isVibeTab(tab: TabConfig): boolean {
    return tab.key.trim().toLowerCase() === 'vibe' || tab.preventsDefault === true;
}

export function isNativeTabBarAvailable(): boolean {
    return nativeTabsAvailable;
}

export default function NativeTabBar({
    currentIndex,
    onIndexChange,
    tabs,
    activeTintColor = '#007AFF',
    inactiveTintColor = '#8E8E93',
    labeled = true,
    isDark = false,
    translateX,
    screenWidth,
    onVibePress,
    fallbackTabWidth,
}: NativeTabBarProps) {
    const vibeIndex = tabs.findIndex(isVibeTab);
    const vibeTab = vibeIndex >= 0 ? tabs[vibeIndex] : undefined;

    const handleSeparateVibePress = () => {
        if (onVibePress) {
            onVibePress();
            return;
        }
        if (vibeIndex >= 0) {
            onIndexChange(vibeIndex);
        }
    };

    if (nativeTabsAvailable && NativeChatTabsView && tabs.length > 0) {
        const normalizedIndex = Math.max(0, Math.min(currentIndex, tabs.length - 1));

        const nativeTabs = tabs.map((tab) => ({
            key: tab.key,
            title: tab.title,
            sfSymbol: tab.sfSymbol || tab.unfocusedSfSymbol || (isVibeTab(tab) ? 'sparkles' : 'circle'),
            badge: tab.badge,
            isVibe: isVibeTab(tab),
        }));

        const handleNativeIndexChange = (event: NativeSyntheticEvent<NativeTabPressPayload>) => {
            const index = event?.nativeEvent?.index;
            if (typeof index !== 'number') {
                return;
            }
            const next = Math.max(0, Math.min(index, tabs.length - 1));
            const targetTab = tabs[next];
            if (targetTab && isVibeTab(targetTab)) {
                handleSeparateVibePress();
                return;
            }
            onIndexChange(next);
        };

        return (
            <View pointerEvents="box-none" style={styles.nativeTabsDock}>
                <NativeChatTabsView
                    style={styles.nativeTabsBar}
                    tabs={nativeTabs}
                    currentIndex={normalizedIndex}
                    activeTintColor={activeTintColor}
                    inactiveTintColor={inactiveTintColor}
                    isDark={isDark}
                    onIndexChange={handleNativeIndexChange}
                />
            </View>
        );
    }

    return (
        <FallbackTabBar
            currentIndex={currentIndex}
            onIndexChange={onIndexChange}
            tabs={tabs}
            activeTintColor={activeTintColor}
            inactiveTintColor={inactiveTintColor}
            isDark={isDark}
            translateX={translateX}
            screenWidth={screenWidth}
            labeled={labeled}
            onVibePress={onVibePress}
            fallbackTabWidth={fallbackTabWidth}
        />
    );
}

type FallbackTabBarProps = NativeTabBarProps;

function FallbackTabBar({
    currentIndex,
    onIndexChange,
    activeTintColor,
    inactiveTintColor,
    isDark,
    translateX,
    screenWidth = 1,
    labeled = true,
    tabs,
    onVibePress,
    fallbackTabWidth,
}: FallbackTabBarProps) {
    const tabWidth = fallbackTabWidth ?? FALLBACK_TAB_WIDTH;
    const vibeIndex = tabs.findIndex(isVibeTab);
    const vibeTab = vibeIndex >= 0 ? tabs[vibeIndex] : undefined;
    const mainTabs = vibeIndex >= 0 ? tabs.filter((_, index) => index !== vibeIndex) : tabs;
    const mainTabCount = mainTabs.length;
    const shiftedCurrentIndex = vibeIndex >= 0 && currentIndex > vibeIndex
        ? currentIndex - 1
        : currentIndex;
    const hasFocusedMainTab = shiftedCurrentIndex >= 0 && shiftedCurrentIndex < mainTabCount;
    const focusedMainIndex = hasFocusedMainTab ? shiftedCurrentIndex : 0;

    const indicatorStyle = useAnimatedStyle(() => {
        if (mainTabCount <= 0) {
            return { transform: [{ translateX: 0 }] };
        }
        if (!translateX) {
            return { transform: [{ translateX: focusedMainIndex * tabWidth }] };
        }

        const inputRange = Array.from({ length: mainTabCount }, (_, i) => i * screenWidth);
        const outputRange = Array.from({ length: mainTabCount }, (_, i) => i);

        const index = interpolate(
            Math.abs(translateX.value),
            inputRange,
            outputRange,
            Extrapolation.CLAMP
        );

        return {
            transform: [{ translateX: index * tabWidth }],
        };
    }, [focusedMainIndex, mainTabCount, screenWidth, tabWidth, translateX]);

    const handleVibePress = () => {
        if (onVibePress) {
            onVibePress();
            return;
        }
        if (vibeIndex >= 0) {
            onIndexChange(vibeIndex);
        }
    };

    return (
        <View style={fallbackStyles.row}>
            {mainTabs.length > 0 && (
                <SafeLiquidGlass
                    style={[
                        fallbackStyles.pill,
                        {
                            backgroundColor: isDark ? 'rgba(30,30,30,0.85)' : 'rgba(255,255,255,0.85)',
                            borderColor: isDark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)',
                            borderWidth: 0.5,
                        },
                    ]}
                    blurIntensity={25}
                    tint={isDark ? 'dark' : 'light'}
                >
                    <Animated.View
                        style={[
                            fallbackStyles.indicator,
                            {
                                backgroundColor: isDark ? 'rgba(255,255,255,0.1)' : '#fff',
                                width: tabWidth,
                            },
                            indicatorStyle,
                        ]}
                    />

                    {mainTabs.map((tab, i) => {
                        const isFocused = hasFocusedMainTab && shiftedCurrentIndex === i;
                        const color = isFocused
                            ? (activeTintColor || (isDark ? '#e5e5e5' : '#000'))
                            : (inactiveTintColor || '#8E8E93');
                        const originalIndex = vibeIndex >= 0 && i >= vibeIndex ? i + 1 : i;

                        return (
                            <TouchableOpacity
                                key={tab.key}
                                style={[fallbackStyles.tabButton, { width: tabWidth }]}
                                onPress={() => onIndexChange(originalIndex)}
                            >
                                <View style={{ alignItems: 'center' }}>
                                    {tab.renderIcon
                                        ? tab.renderIcon({ focused: isFocused, color, size: 22 })
                                        : null}
                                    {tab.badge && (
                                        <View style={fallbackStyles.badge}>
                                            <Text style={fallbackStyles.badgeText}>
                                                {tab.badge}
                                            </Text>
                                        </View>
                                    )}
                                </View>
                                {labeled && (
                                    <Text style={[fallbackStyles.label, { color }]}>
                                        {tab.title}
                                    </Text>
                                )}
                            </TouchableOpacity>
                        );
                    })}
                </SafeLiquidGlass>
            )}

            {vibeTab && (
                <TouchableOpacity
                    activeOpacity={0.85}
                    style={fallbackStyles.vibeButtonContainer}
                    onPress={handleVibePress}
                >
                    <SafeLiquidGlass
                        style={[
                            fallbackStyles.vibeButtonPill,
                            {
                                backgroundColor: isDark ? 'rgba(18,20,28,0.6)' : 'rgba(244,248,255,0.66)',
                                borderColor: isDark ? 'rgba(255,255,255,0.13)' : 'rgba(10,18,32,0.11)',
                                borderWidth: 1,
                            },
                        ]}
                        blurIntensity={18}
                        tint={isDark ? 'dark' : 'light'}
                    >
                        {vibeTab.renderIcon
                            ? vibeTab.renderIcon({
                                focused: false,
                                color: isDark ? '#fff' : '#000',
                                size: 24,
                            })
                            : (
                                <Text style={[fallbackStyles.vibeText, { color: isDark ? '#fff' : '#000' }]}>
                                    {vibeTab.title || 'Vibe'}
                                </Text>
                            )}
                    </SafeLiquidGlass>
                </TouchableOpacity>
            )}
        </View>
    );
}

const styles = StyleSheet.create({
    nativeTabsDock: {
        width: '100%',
        paddingBottom: Platform.OS === 'ios' ? 10 : 8,
        paddingTop: 2,
        alignItems: 'stretch',
        justifyContent: 'flex-end',
    },
    nativeTabsBar: {
        width: '100%',
        height: 96,
    },
});

const fallbackStyles = StyleSheet.create({
    row: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 8,
    },
    pill: {
        flexDirection: 'row',
        alignItems: 'center',
        padding: 5,
        borderRadius: 32,
        height: 64,
        overflow: 'hidden',
        position: 'relative',
    },
    indicator: {
        position: 'absolute',
        top: 5,
        left: 5,
        height: 54,
        borderRadius: 27,
    },
    tabButton: {
        borderRadius: 32,
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 4,
        zIndex: 10,
    },
    label: {
        fontSize: 10,
        fontWeight: '600',
        marginTop: 2,
    },
    badge: {
        position: 'absolute',
        top: -6,
        right: -10,
        backgroundColor: '#ef4444',
        borderRadius: 10,
        paddingHorizontal: 5,
        paddingVertical: 1,
        minWidth: 18,
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: 1.5,
        borderColor: '#fff',
    },
    badgeText: {
        color: '#fff',
        fontSize: 10,
        fontWeight: 'bold',
    },
    vibeButtonContainer: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    vibeButtonPill: {
        width: 64,
        height: 64,
        borderRadius: 32,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
    },
    vibeText: {
        fontSize: 16,
        fontWeight: '800',
        textTransform: 'lowercase',
        letterSpacing: -0.5,
    },
});
