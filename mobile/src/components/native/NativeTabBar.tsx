import React from 'react';
import {
    Image,
    NativeSyntheticEvent,
    Platform,
    processColor,
    StyleSheet,
    Text,
    TouchableOpacity,
    View,
    type ColorValue,
    type ImageSourcePropType,
} from 'react-native';
import Constants from 'expo-constants';
import { LinearGradient } from 'expo-linear-gradient';
import { requireNativeViewManager } from 'expo-modules-core';
import Animated, {
    Extrapolation,
    interpolate,
    useAnimatedStyle,
} from 'react-native-reanimated';
import type { SharedValue } from 'react-native-reanimated';
import SafeLiquidGlass from './SafeLiquidGlass';
import AndroidBottomTabBar from './AndroidBottomTabBar';

interface NativeTabPressPayload {
    index: number;
}

interface NativeTabViewItem {
    key: string;
    title: string;
    sfSymbol?: string;
    iconUri?: string;
    badge?: string;
    isVibe?: boolean;
}

interface NativeChatTabsViewProps {
    tabs: NativeTabViewItem[];
    currentIndex: number;
    activeTintColor?: number | null;
    inactiveTintColor?: number | null;
    isDark?: boolean;
    isVibeExpanded?: boolean;
    onIndexChange?: (event: NativeSyntheticEvent<NativeTabPressPayload>) => void;
    onVibeSubmit?: (event: NativeSyntheticEvent<{ text: string }>) => void;
    style?: any;
}

let NativeChatTabsView: React.ComponentType<NativeChatTabsViewProps> | null = null;
let nativeTabsAvailable = false;

try {
    const isExpoGo = Constants.appOwnership === 'expo';
    if ((Platform.OS === 'ios' || Platform.OS === 'android') && !isExpoGo) {
        NativeChatTabsView = requireNativeViewManager<NativeChatTabsViewProps>('ChatNativeTabs');
        nativeTabsAvailable = !!NativeChatTabsView;
        console.log('[NativeTabBar] Native tabs available', { platform: Platform.OS });
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
    isVibeExpanded?: boolean;
    onVibeSubmit?: (text: string) => void;
}

const FALLBACK_TAB_WIDTH = 70;

function isVibeTab(tab: TabConfig): boolean {
    return tab.key.trim().toLowerCase() === 'vibe' || tab.preventsDefault === true;
}

export function isNativeTabBarAvailable(): boolean {
    return (Platform.OS === 'ios' || Platform.OS === 'android') && nativeTabsAvailable;
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
    isVibeExpanded,
    onVibeSubmit,
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

    const shouldUseNativeTabs =
        Platform.OS === 'ios' &&
        nativeTabsAvailable &&
        NativeChatTabsView &&
        tabs.length > 0;
    if (shouldUseNativeTabs) {
        const NativeTabsComponent = NativeChatTabsView as React.ComponentType<NativeChatTabsViewProps>;
        const normalizedIndex = Math.max(0, Math.min(currentIndex, tabs.length - 1));
        const nativeActiveTintColor = React.useMemo(() => (processColor(activeTintColor) ?? null) as number | null, [activeTintColor]);
        const nativeInactiveTintColor = React.useMemo(() => (processColor(inactiveTintColor) ?? null) as number | null, [inactiveTintColor]);

        const nativeTabs = React.useMemo(() => tabs.map((tab) => {
            const source = tab.iconSource;
            let resolvedIconUri: string | undefined;
            if (source && typeof source === 'object' && 'uri' in source && typeof (source as any).uri === 'string') {
                resolvedIconUri = (source as any).uri;
            } else if (source) {
                resolvedIconUri = Image.resolveAssetSource(source)?.uri;
            }

            return {
                key: tab.key,
                title: tab.title,
                sfSymbol: tab.sfSymbol || tab.unfocusedSfSymbol || (isVibeTab(tab) ? 'sparkles' : 'circle'),
                iconUri: resolvedIconUri,
                badge: tab.badge,
                isVibe: isVibeTab(tab),
            };
        }), [tabs]);

        const handleNativeIndexChange = React.useCallback((event: NativeSyntheticEvent<NativeTabPressPayload>) => {
            const payload: any = event?.nativeEvent ?? event;
            const rawIndex = payload?.index ?? payload?.payload?.index;
            const parsedIndex = typeof rawIndex === 'number' ? rawIndex : Number(rawIndex);
            if (!Number.isFinite(parsedIndex)) {
                return;
            }
            const next = Math.max(0, Math.min(Math.trunc(parsedIndex), tabs.length - 1));
            const targetTab = tabs[next];
            if (targetTab && isVibeTab(targetTab)) {
                handleSeparateVibePress();
                return;
            }
            onIndexChange(next);
        }, [tabs, handleSeparateVibePress, onIndexChange]);

        return (
            <View pointerEvents="box-none" style={styles.nativeTabsDock}>
                <NativeTabsComponent
                    style={styles.nativeTabsBar}
                    tabs={nativeTabs}
                    currentIndex={normalizedIndex}
                    activeTintColor={nativeActiveTintColor}
                    inactiveTintColor={nativeInactiveTintColor}
                    isDark={isDark}
                    isVibeExpanded={isVibeExpanded}
                    onIndexChange={handleNativeIndexChange}
                    onVibeSubmit={(e: any) => {
                        const payload = e?.nativeEvent ?? e;
                        if (payload?.text && onVibeSubmit) {
                            onVibeSubmit(payload.text);
                        }
                    }}
                />
            </View>
        );
    }

    if (Platform.OS === 'android') {
        return (
            <AndroidBottomTabBar
                currentIndex={currentIndex}
                onIndexChange={onIndexChange}
                tabs={tabs}
                activeTintColor={activeTintColor}
                inactiveTintColor={inactiveTintColor}
                isDark={isDark}
                labeled={labeled}
                onVibePress={onVibePress}
            />
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
    const isAndroid = Platform.OS === 'android';
    const tabWidth = fallbackTabWidth ?? FALLBACK_TAB_WIDTH;
    const vibeIndex = tabs.findIndex(isVibeTab);
    const vibeTab = vibeIndex >= 0 ? tabs[vibeIndex] : undefined;
    const mainTabs = vibeIndex >= 0 ? tabs.filter((_, index) => index !== vibeIndex) : tabs;
    const mainTabCount = mainTabs.length;
    const isVibeFocused = vibeIndex >= 0 && currentIndex === vibeIndex;
    const shiftedCurrentIndex = vibeIndex >= 0 && currentIndex > vibeIndex
        ? currentIndex - 1
        : currentIndex;
    const hasFocusedMainTab = !isVibeFocused && shiftedCurrentIndex >= 0 && shiftedCurrentIndex < mainTabCount;
    const focusedMainIndex = hasFocusedMainTab ? shiftedCurrentIndex : 0;

    const indicatorStyle = useAnimatedStyle(() => {
        if (mainTabCount <= 0) {
            return { opacity: 0, transform: [{ translateX: 0 }] };
        }
        if (isVibeFocused) {
            return {
                opacity: 0,
                transform: [{ translateX: focusedMainIndex * tabWidth }],
            };
        }
        if (!translateX) {
            return { opacity: 1, transform: [{ translateX: focusedMainIndex * tabWidth }] };
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
            opacity: 1,
            transform: [{ translateX: index * tabWidth }],
        };
    }, [focusedMainIndex, isVibeFocused, mainTabCount, screenWidth, tabWidth, translateX]);

    const handleVibePress = () => {
        if (onVibePress) {
            onVibePress();
            return;
        }
        if (vibeIndex >= 0) {
            onIndexChange(vibeIndex);
        }
    };

    const mainPillBackgroundColor = isAndroid
        ? (isDark ? 'rgba(18,22,30,0.86)' : 'rgba(247,250,255,0.92)')
        : (isDark ? 'rgba(30,30,30,0.85)' : 'rgba(255,255,255,0.85)');
    const mainPillBorderColor = isAndroid
        ? (isDark ? 'rgba(255,255,255,0.10)' : 'rgba(17,24,39,0.08)')
        : (isDark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)');
    const indicatorBg = isAndroid
        ? (isDark ? 'rgba(255,255,255,0.09)' : 'rgba(255,255,255,0.82)')
        : (isDark ? 'rgba(255,255,255,0.1)' : '#fff');

    if (isAndroid) {
        const dockBackground = isDark ? 'rgba(10,14,20,0.88)' : 'rgba(250,252,255,0.88)';
        const activeTileBg = isDark ? 'rgba(255,255,255,0.05)' : 'rgba(255,255,255,0.58)';
        const iconGlassBg = isDark ? 'rgba(255,255,255,0.04)' : 'rgba(255,255,255,0.38)';
        const iconGlassActiveBg = isDark ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.72)';
        const iconSheen = isDark ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.7)';
        const iconSheenActive = isDark ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.92)';

        return (
            <View style={fallbackStyles.androidAttachedDock}>
                <View pointerEvents="none" style={fallbackStyles.androidAttachedShadowWrap}>
                    <LinearGradient
                        colors={
                            isDark
                                ? ['rgba(0,0,0,0)', 'rgba(0,0,0,0.22)', 'rgba(0,0,0,0.05)']
                                : ['rgba(0,0,0,0)', 'rgba(0,0,0,0.12)', 'rgba(0,0,0,0.02)']
                        }
                        locations={[0, 0.68, 1]}
                        start={{ x: 0.5, y: 0 }}
                        end={{ x: 0.5, y: 1 }}
                        style={fallbackStyles.androidAttachedShadowGradient}
                    />
                </View>
                <View
                    style={[
                        fallbackStyles.androidAttachedSurface,
                        {
                            backgroundColor: dockBackground,
                            borderColor: 'transparent',
                        },
                    ]}
                >
                    <LinearGradient
                        pointerEvents="none"
                        colors={
                            isDark
                                ? ['rgba(255,255,255,0.035)', 'rgba(255,255,255,0.008)', 'rgba(0,0,0,0.12)']
                                : ['rgba(255,255,255,0.82)', 'rgba(255,255,255,0.62)', 'rgba(232,241,255,0.26)']
                        }
                        start={{ x: 0.05, y: 0 }}
                        end={{ x: 0.95, y: 1 }}
                        style={StyleSheet.absoluteFillObject}
                    />
                    <View
                        pointerEvents="none"
                        style={[
                            fallbackStyles.androidAttachedTopLine,
                            { backgroundColor: isDark ? 'rgba(255,255,255,0.05)' : 'rgba(255,255,255,0.62)' },
                        ]}
                    />
                    <View style={fallbackStyles.androidAttachedRow}>
                        {tabs.map((tab, index) => {
                            const isFocused = currentIndex === index;
                            const vibe = isVibeTab(tab);
                            const color = isFocused
                                ? (activeTintColor || (isDark ? '#EEF2FF' : '#121826'))
                                : (inactiveTintColor || '#8E8E93');
                            const handlePress = () => {
                                if (vibe) {
                                    handleVibePress();
                                    return;
                                }
                                onIndexChange(index);
                            };

                            return (
                                <TouchableOpacity
                                    key={tab.key}
                                    activeOpacity={0.9}
                                    onPress={handlePress}
                                    style={fallbackStyles.androidAttachedTab}
                                >
                                    <View
                                        style={[
                                            fallbackStyles.androidAttachedTabInner,
                                            isFocused && {
                                                backgroundColor: activeTileBg,
                                                borderColor: isDark ? 'rgba(255,255,255,0.10)' : 'rgba(18,24,38,0.06)',
                                                borderWidth: 1,
                                            },
                                            vibe && fallbackStyles.androidAttachedVibeInner,
                                        ]}
                                    >
                                        <View style={fallbackStyles.androidAttachedIconWrap}>
                                            <View
                                                style={[
                                                    fallbackStyles.androidAttachedIconGlass,
                                                    {
                                                        backgroundColor: isFocused ? iconGlassActiveBg : iconGlassBg,
                                                    },
                                                ]}
                                            >
                                                <LinearGradient
                                                    pointerEvents="none"
                                                    colors={
                                                        isDark
                                                            ? ['rgba(255,255,255,0.09)', 'rgba(255,255,255,0.015)', 'rgba(0,0,0,0.12)']
                                                            : ['rgba(255,255,255,0.98)', 'rgba(255,255,255,0.78)', 'rgba(235,243,255,0.35)']
                                                    }
                                                    start={{ x: 0.12, y: 0 }}
                                                    end={{ x: 0.88, y: 1 }}
                                                    style={StyleSheet.absoluteFillObject}
                                                />
                                                <View
                                                    pointerEvents="none"
                                                    style={[
                                                        fallbackStyles.androidAttachedIconSheen,
                                                        { backgroundColor: isFocused ? iconSheenActive : iconSheen },
                                                    ]}
                                                />
                                                {tab.renderIcon
                                                    ? tab.renderIcon({ focused: isFocused, color, size: vibe ? 23 : 21 })
                                                    : null}
                                            </View>
                                            {tab.badge && (
                                                <View style={[
                                                    fallbackStyles.badge,
                                                    fallbackStyles.androidAttachedBadge,
                                                    { borderColor: isDark ? 'rgba(15,18,24,0.95)' : '#fff' },
                                                ]}>
                                                    <Text style={fallbackStyles.badgeText}>{tab.badge}</Text>
                                                </View>
                                            )}
                                        </View>
                                        {labeled && (
                                            <Text
                                                numberOfLines={1}
                                                ellipsizeMode="clip"
                                                style={[
                                                    fallbackStyles.label,
                                                    fallbackStyles.androidAttachedLabel,
                                                    vibe && fallbackStyles.androidAttachedVibeLabel,
                                                    { color },
                                                ]}
                                            >
                                                {tab.title}
                                            </Text>
                                        )}
                                    </View>
                                </TouchableOpacity>
                            );
                        })}
                    </View>
                </View>
            </View>
        );
    }

    const renderMainTabs = (withBlurGlass: boolean) => (
        <>
            {withBlurGlass ? null : (
                <>
                    <LinearGradient
                        pointerEvents="none"
                        colors={
                            isDark
                                ? ['rgba(255,255,255,0.05)', 'rgba(255,255,255,0.015)', 'rgba(0,0,0,0.08)']
                                : ['rgba(255,255,255,0.92)', 'rgba(255,255,255,0.62)', 'rgba(221,232,255,0.38)']
                        }
                        start={{ x: 0.08, y: 0 }}
                        end={{ x: 0.92, y: 1 }}
                        style={[StyleSheet.absoluteFillObject, fallbackStyles.androidSurfaceGradient]}
                    />
                    <View
                        pointerEvents="none"
                        style={[
                            fallbackStyles.androidTopSheen,
                            { backgroundColor: isDark ? 'rgba(255,255,255,0.05)' : 'rgba(255,255,255,0.55)' },
                        ]}
                    />
                </>
            )}

            <Animated.View
                style={[
                    fallbackStyles.indicator,
                    isAndroid && fallbackStyles.androidIndicator,
                    {
                        backgroundColor: indicatorBg,
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
                        activeOpacity={0.9}
                        onPress={() => onIndexChange(originalIndex)}
                    >
                        <View style={{ alignItems: 'center' }}>
                            {tab.renderIcon
                                ? tab.renderIcon({ focused: isFocused, color, size: 22 })
                                : null}
                            {tab.badge && (
                                <View style={[
                                    fallbackStyles.badge,
                                    isAndroid && {
                                        borderColor: isDark ? 'rgba(24,28,36,0.95)' : '#fff',
                                    },
                                ]}>
                                    <Text style={fallbackStyles.badgeText}>
                                        {tab.badge}
                                    </Text>
                                </View>
                            )}
                        </View>
                        {labeled && (
                            <Text style={[
                                fallbackStyles.label,
                                isAndroid && fallbackStyles.androidLabel,
                                { color },
                            ]}>
                                {tab.title}
                            </Text>
                        )}
                    </TouchableOpacity>
                );
            })}
        </>
    );

    return (
        <View style={fallbackStyles.row}>
            {mainTabs.length > 0 && (
                isAndroid ? (
                    <View
                        style={[
                            fallbackStyles.pill,
                            fallbackStyles.androidPill,
                            {
                                backgroundColor: mainPillBackgroundColor,
                                borderColor: mainPillBorderColor,
                                borderWidth: 1,
                            },
                        ]}
                    >
                        {renderMainTabs(false)}
                    </View>
                ) : (
                    <SafeLiquidGlass
                        style={[
                            fallbackStyles.pill,
                            {
                                backgroundColor: mainPillBackgroundColor,
                                borderColor: mainPillBorderColor,
                                borderWidth: 0.5,
                            },
                        ]}
                        blurIntensity={25}
                        tint={isDark ? 'dark' : 'light'}
                    >
                        {renderMainTabs(true)}
                    </SafeLiquidGlass>
                )
            )}

            {vibeTab && (
                <TouchableOpacity
                    activeOpacity={0.85}
                    style={fallbackStyles.vibeButtonContainer}
                    onPress={handleVibePress}
                >
                    {(() => {
                        const vibeFocused = isVibeFocused;
                        const vibeColor = vibeFocused
                            ? (activeTintColor || (isDark ? '#fff' : '#000'))
                            : (inactiveTintColor || (isDark ? '#fff' : '#000'));

                        if (isAndroid) {
                            return (
                                <View
                                    style={[
                                        fallbackStyles.vibeButtonPill,
                                        fallbackStyles.androidVibePill,
                                        {
                                            backgroundColor: vibeFocused
                                                ? (isDark ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.98)')
                                                : (isDark ? 'rgba(20,24,32,0.92)' : 'rgba(248,251,255,0.95)'),
                                            borderColor: vibeFocused
                                                ? (isDark ? 'rgba(255,255,255,0.18)' : 'rgba(22,30,46,0.12)')
                                                : (isDark ? 'rgba(255,255,255,0.12)' : 'rgba(22,30,46,0.08)'),
                                            borderWidth: 1,
                                            transform: [{ scale: vibeFocused ? 1.02 : 1 }],
                                        },
                                    ]}
                                >
                                    <LinearGradient
                                        pointerEvents="none"
                                        colors={
                                            isDark
                                                ? (vibeFocused
                                                    ? ['rgba(255,255,255,0.12)', 'rgba(255,255,255,0.03)', 'rgba(0,0,0,0.12)']
                                                    : ['rgba(255,255,255,0.07)', 'rgba(255,255,255,0.01)', 'rgba(0,0,0,0.10)'])
                                                : (vibeFocused
                                                    ? ['rgba(255,255,255,1)', 'rgba(255,255,255,0.82)', 'rgba(226,238,255,0.5)']
                                                    : ['rgba(255,255,255,0.96)', 'rgba(255,255,255,0.7)', 'rgba(226,238,255,0.42)'])
                                        }
                                        start={{ x: 0.1, y: 0 }}
                                        end={{ x: 0.9, y: 1 }}
                                        style={[StyleSheet.absoluteFillObject, fallbackStyles.androidSurfaceGradient]}
                                    />
                                    {vibeTab.renderIcon
                                        ? vibeTab.renderIcon({
                                            focused: vibeFocused,
                                            color: vibeColor,
                                            size: 24,
                                        })
                                        : (
                                            <Text style={[fallbackStyles.vibeText, { color: vibeColor }]}>
                                                {vibeTab.title || 'Vibe'}
                                            </Text>
                                        )}
                                </View>
                            );
                        }

                        return (
                            <SafeLiquidGlass
                                style={[
                                    fallbackStyles.vibeButtonPill,
                                    {
                                        backgroundColor: vibeFocused
                                            ? (isDark ? 'rgba(255,255,255,0.12)' : 'rgba(255,255,255,0.98)')
                                            : (isDark ? 'rgba(18,20,28,0.6)' : 'rgba(244,248,255,0.66)'),
                                        borderColor: vibeFocused
                                            ? (isDark ? 'rgba(255,255,255,0.18)' : 'rgba(10,18,32,0.12)')
                                            : (isDark ? 'rgba(255,255,255,0.13)' : 'rgba(10,18,32,0.11)'),
                                        borderWidth: 1,
                                        transform: [{ scale: vibeFocused ? 1.02 : 1 }],
                                    },
                                ]}
                                blurIntensity={18}
                                tint={isDark ? 'dark' : 'light'}
                            >
                                {vibeTab.renderIcon
                                    ? vibeTab.renderIcon({
                                        focused: vibeFocused,
                                        color: vibeColor,
                                        size: 24,
                                    })
                                    : (
                                        <Text style={[fallbackStyles.vibeText, { color: vibeColor }]}>
                                            {vibeTab.title || 'Vibe'}
                                        </Text>
                                    )}
                            </SafeLiquidGlass>
                        );
                    })()}
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
        paddingHorizontal: 22,
        alignItems: 'stretch',
        justifyContent: 'flex-end',
        backgroundColor: 'transparent',
    },
    nativeTabsBar: {
        width: '100%',
        height: 64,
        backgroundColor: 'transparent',
    },
});

const fallbackStyles = StyleSheet.create({
    row: {
        flexDirection: 'row',
        alignItems: 'center',
        gap: 8,
    },
    androidAttachedDock: {
        width: '100%',
        alignSelf: 'stretch',
        position: 'relative',
    },
    androidAttachedShadowWrap: {
        position: 'absolute',
        left: 12,
        right: 12,
        top: 22,
        bottom: -10,
        borderRadius: 28,
        overflow: 'hidden',
    },
    androidAttachedShadowGradient: {
        flex: 1,
    },
    androidAttachedSurface: {
        width: '100%',
        height: 78,
        borderRadius: 24,
        overflow: 'hidden',
        position: 'relative',
        shadowColor: '#000',
        shadowOpacity: 0.05,
        shadowRadius: 8,
        shadowOffset: { width: 0, height: 2 },
        elevation: 2,
    },
    androidAttachedTopLine: {
        position: 'absolute',
        top: 1,
        left: 18,
        right: 18,
        height: 8,
        borderRadius: 999,
    },
    androidAttachedRow: {
        flex: 1,
        flexDirection: 'row',
        alignItems: 'stretch',
        paddingHorizontal: 8,
        paddingTop: 8,
        paddingBottom: 10,
    },
    androidAttachedTab: {
        flex: 1,
        alignSelf: 'stretch',
        justifyContent: 'center',
        alignItems: 'center',
        minWidth: 0,
    },
    androidAttachedTabInner: {
        width: '100%',
        minWidth: 0,
        maxWidth: 84,
        borderRadius: 18,
        paddingHorizontal: 4,
        paddingVertical: 5,
        alignItems: 'center',
        justifyContent: 'center',
    },
    androidAttachedVibeInner: {
        maxWidth: 88,
    },
    androidAttachedIconGlass: {
        width: 38,
        height: 34,
        borderRadius: 13,
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
        position: 'relative',
    },
    androidAttachedIconWrap: {
        width: 44,
        height: 36,
        alignItems: 'center',
        justifyContent: 'center',
        position: 'relative',
    },
    androidAttachedIconSheen: {
        position: 'absolute',
        top: 1,
        left: 5,
        right: 5,
        height: 8,
        borderRadius: 999,
    },
    androidAttachedLabel: {
        marginTop: 4,
        width: '100%',
        textAlign: 'center',
        fontSize: 9.5,
        fontWeight: '700',
        letterSpacing: 0,
    },
    androidAttachedVibeLabel: {
        fontWeight: '800',
    },
    pill: {
        flexDirection: 'row',
        alignItems: 'stretch',
        padding: 5,
        borderRadius: 32,
        height: 64,
        overflow: 'hidden',
        position: 'relative',
    },
    androidPill: {
        shadowColor: '#000',
        shadowOpacity: 0.14,
        shadowRadius: 18,
        shadowOffset: { width: 0, height: 8 },
        elevation: 10,
    },
    androidSurfaceGradient: {
        borderRadius: 32,
    },
    androidTopSheen: {
        position: 'absolute',
        top: 1,
        left: 10,
        right: 10,
        height: 16,
        borderRadius: 999,
    },
    indicator: {
        position: 'absolute',
        top: 5,
        left: 5,
        height: 54,
        borderRadius: 27,
    },
    androidIndicator: {
        borderWidth: 1,
        borderColor: 'rgba(255,255,255,0.12)',
        shadowColor: '#000',
        shadowOpacity: 0.08,
        shadowRadius: 10,
        shadowOffset: { width: 0, height: 4 },
        elevation: 2,
    },
    tabButton: {
        borderRadius: 32,
        alignSelf: 'stretch',
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
    androidLabel: {
        fontWeight: '700',
        letterSpacing: 0.1,
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
    androidAttachedBadge: {
        top: -5,
        right: -2,
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
    androidVibePill: {
        shadowColor: '#000',
        shadowOpacity: 0.16,
        shadowRadius: 16,
        shadowOffset: { width: 0, height: 8 },
        elevation: 10,
    },
    vibeText: {
        fontSize: 16,
        fontWeight: '800',
        textTransform: 'lowercase',
        letterSpacing: -0.5,
    },
});
