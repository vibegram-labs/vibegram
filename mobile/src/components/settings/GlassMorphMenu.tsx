import React, { useEffect, useMemo, useState } from 'react';
import { View, Text, StyleSheet, Pressable, Platform, requireNativeComponent, UIManager } from 'react-native';
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withSpring,
    withTiming,
    interpolate,
    Extrapolation,
    interpolateColor,
    runOnJS,
} from 'react-native-reanimated';
import { Settings, Layers, Radio, Plus } from 'lucide-react-native';
import * as Haptics from 'expo-haptics';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import { useThemeStore } from '../../lib/stores/theme-store';

import SafeLiquidGlass from '../native/SafeLiquidGlass';
const AnimatedSafeLiquidGlass = Animated.createAnimatedComponent(SafeLiquidGlass);
const AnimatedView = Animated.View;

import Constants from 'expo-constants';

let NativeExpandableGlass: any = null;
try {
    if (Platform.OS === 'ios' && Constants.appOwnership !== 'expo') {
        if (UIManager.getViewManagerConfig('ExpandableGlassMenu')) {
            NativeExpandableGlass = requireNativeComponent('ExpandableGlassMenu');
        }
    }
} catch {
    // Native component not found; JS fallback is used.
}

const SPRING_CONFIG = { mass: 0.8, damping: 18, stiffness: 210, overshootClamping: true };

type Anchor = 'top-right' | 'top-left' | 'bottom-right' | 'bottom-left';

interface GlassMorphMenuItem {
    id: string;
    label: string;
    icon: any;
    destructive?: boolean;
}

interface GlassMorphMenuProps {
    onSelect: (id: string) => void;
    items?: GlassMorphMenuItem[];
    customIcon?: React.ReactNode;
    menuWidth?: number;
    menuHeight?: number;
    collapsedSize?: number;
    itemColumns?: number;
    anchor?: Anchor;
    open?: boolean;
    onOpenChange?: (open: boolean) => void;
    renderTrigger?: boolean;
    expandedContent?: React.ReactNode;
    openOffsetY?: number;
    openOffsetX?: number;
}

const anchorToStyle = (anchor: Anchor) => {
    if (anchor === 'top-left') return { left: 0, top: 0 };
    if (anchor === 'bottom-right') return { right: 0, bottom: 0 };
    if (anchor === 'bottom-left') return { left: 0, bottom: 0 };
    return { right: 0, top: 0 };
};

const GlassMorphMenu = ({
    onSelect,
    items,
    customIcon,
    menuWidth = 200,
    menuHeight,
    collapsedSize = 40,
    itemColumns = 1,
    anchor = 'top-right',
    open,
    onOpenChange,
    renderTrigger = true,
    expandedContent,
    openOffsetY = 0,
    openOffsetX = 0,
}: GlassMorphMenuProps) => {
    const { colors, effectiveTheme } = useThemeStore();
    const isLight = effectiveTheme === 'light';

    const isControlled = typeof open === 'boolean';
    const [internalOpen, setInternalOpen] = useState(false);
    const isOpen = isControlled ? !!open : internalOpen;
    const isBottomAnchor = anchor === 'bottom-left' || anchor === 'bottom-right';

    const progress = useSharedValue(isOpen ? 1 : 0);
    const dragOffsetY = useSharedValue(0);

    const displayItems = items || [
        { id: 'manual', label: 'Manual Config', icon: Settings },
        { id: 'import', label: 'Import Link', icon: Layers },
        { id: 'relay', label: 'Relay Node', icon: Radio },
    ];

    const finalMenuHeight =
        typeof menuHeight === 'number'
            ? menuHeight
            : (items ? (items.length * 44 + 32) : 180);

    const finalColumns = Math.max(1, Math.floor(itemColumns));
    const anchorStyle = useMemo(() => anchorToStyle(anchor), [anchor]);

    useEffect(() => {
        progress.value = withSpring(isOpen ? 1 : 0, SPRING_CONFIG);
        if (!isOpen) {
            dragOffsetY.value = withTiming(0, { duration: 140 });
        }
    }, [isOpen, progress]);

    const setOpenState = (next: boolean) => {
        if (!isControlled) {
            setInternalOpen(next);
        }
        onOpenChange?.(next);
    };

    const toggle = () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
        setOpenState(!isOpen);
    };

    const handleSelect = (id: string) => {
        setOpenState(false);
        setTimeout(() => onSelect(id), 180);
    };

    const canUseNative = !!NativeExpandableGlass && !isControlled && renderTrigger && anchor === 'top-right' && finalColumns === 1;

    if (canUseNative) {
        return (
            <NativeExpandableGlass
                style={{ width: menuWidth, height: finalMenuHeight }}
                menuWidth={menuWidth}
                menuHeight={finalMenuHeight}
                collapsedSize={collapsedSize}
                onSelect={(event: any) => onSelect(event.nativeEvent.id || event.nativeEvent.mode)}
                theme={effectiveTheme}
            />
        );
    }

    const RADIUS_CLOSED = collapsedSize / 2;
    const RADIUS_OPEN = Math.min(24, collapsedSize / 2 + 8);

    const containerStyle = useAnimatedStyle(() => ({
        width: interpolate(progress.value, [0, 1], [collapsedSize, menuWidth]),
        height: interpolate(progress.value, [0, 1], [collapsedSize, finalMenuHeight]),
        borderRadius: interpolate(progress.value, [0, 1], [RADIUS_CLOSED, RADIUS_OPEN]),
        position: 'absolute',
        overflow: 'hidden',
        backgroundColor: isLight
            ? interpolateColor(progress.value, [0, 1], ['rgba(255,255,255,0.42)', 'rgba(255,255,255,0.84)'])
            : interpolateColor(progress.value, [0, 1], ['rgba(28,28,32,0.42)', 'rgba(12,12,16,0.78)']),
        borderWidth: 0,
        transform: [
            { translateX: interpolate(progress.value, [0, 1], [0, openOffsetX]) },
            { translateY: dragOffsetY.value + interpolate(progress.value, [0, 1], [0, openOffsetY]) },
        ],
        zIndex: 100,
    }));

    const buttonStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0, 0.35], [1, 0], Extrapolation.CLAMP),
        transform: [{ scale: interpolate(progress.value, [0, 0.35], [1, 0.97], Extrapolation.CLAMP) }],
    }));

    const contentStyle = useAnimatedStyle(() => ({
        opacity: interpolate(progress.value, [0.1, 0.6], [0, 1], Extrapolation.CLAMP),
        transform: [
            { scale: interpolate(progress.value, [0, 1], [0.82, 1], Extrapolation.CLAMP) },
            { translateY: interpolate(progress.value, [0, 1], [-14, 0], Extrapolation.CLAMP) },
        ],
    }));

    const panGesture = Gesture.Pan()
        .enabled(isOpen)
        .onUpdate((event) => {
            if (isBottomAnchor) {
                dragOffsetY.value = Math.max(0, event.translationY);
                return;
            }
            dragOffsetY.value = Math.min(0, event.translationY);
        })
        .onEnd((event) => {
            const shouldClose = isBottomAnchor
                ? (event.translationY > 56 || event.velocityY > 700)
                : (event.translationY < -56 || event.velocityY < -700);

            if (shouldClose) {
                dragOffsetY.value = withTiming(0, { duration: 130 });
                runOnJS(setOpenState)(false);
                return;
            }

            dragOffsetY.value = withTiming(0, { duration: 180 });
        });

    return (
        <View style={{ width: collapsedSize, height: collapsedSize, zIndex: 9999 }}>
            {isOpen && (
                <Pressable
                    onPress={() => setOpenState(false)}
                    style={[
                        StyleSheet.absoluteFill,
                        {
                            width: 10000,
                            height: 10000,
                            left: -5000,
                            top: -5000,
                            zIndex: 1,
                        },
                    ]}
                />
            )}

            <GestureDetector gesture={panGesture}>
                <AnimatedSafeLiquidGlass
                    style={[containerStyle, anchorStyle]}
                    blurIntensity={Platform.OS === 'android' ? 5 : 25}
                >
                    {renderTrigger && (
                        <AnimatedView style={[buttonStyle, StyleSheet.absoluteFill, s.centered]}>
                            <Pressable onPress={toggle} style={s.fullSizeCenter}>
                                {customIcon || <Plus size={20} color={colors.text} strokeWidth={2.5} />}
                            </Pressable>
                        </AnimatedView>
                    )}

                    <AnimatedView style={[contentStyle, StyleSheet.absoluteFill, s.menuPadding]}>
                    {expandedContent ? (
                        <View style={s.customContentWrap}>{expandedContent}</View>
                    ) : finalColumns === 1 ? (
                        <View style={s.listWrap}>
                            {displayItems.map((item) => (
                                <Pressable
                                        key={item.id}
                                        style={s.menuItem}
                                        onPress={() => handleSelect(item.id)}
                                    >
                                        <item.icon size={18} color={item.destructive ? '#ef4444' : colors.text} />
                                        <Text style={[s.menuText, { color: item.destructive ? '#ef4444' : colors.text }]}>
                                            {item.label}
                                        </Text>
                                    </Pressable>
                                ))}
                            </View>
                        ) : (
                            <View style={s.gridWrap}>
                                {displayItems.map((item) => (
                                    <Pressable
                                        key={item.id}
                                        style={[s.gridItem, { width: `${100 / finalColumns}%` }]}
                                        onPress={() => handleSelect(item.id)}
                                    >
                                        <View style={s.gridIconWrap}>
                                            <item.icon size={20} color={item.destructive ? '#ef4444' : colors.text} />
                                        </View>
                                        <Text
                                            style={[s.gridText, { color: item.destructive ? '#ef4444' : colors.text }]}
                                            numberOfLines={1}
                                        >
                                            {item.label}
                                        </Text>
                                    </Pressable>
                                ))}
                            </View>
                        )}
                    </AnimatedView>
                </AnimatedSafeLiquidGlass>
            </GestureDetector>
        </View>
    );
};

const s = StyleSheet.create({
    centered: {
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 20,
    },
    fullSizeCenter: {
        width: '100%',
        height: '100%',
        alignItems: 'center',
        justifyContent: 'center',
    },
    menuPadding: {
        padding: 16,
        zIndex: 10,
    },
    listWrap: {
        flex: 1,
        justifyContent: 'center',
        gap: 6,
    },
    menuItem: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 10,
        gap: 12,
    },
    menuText: {
        fontSize: 16,
        fontWeight: '600',
    },
    gridWrap: {
        flex: 1,
        flexDirection: 'row',
        flexWrap: 'wrap',
        alignItems: 'flex-start',
    },
    gridItem: {
        alignItems: 'center',
        justifyContent: 'center',
        paddingVertical: 10,
        gap: 6,
    },
    gridIconWrap: {
        width: 46,
        height: 46,
        borderRadius: 23,
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: 0,
        backgroundColor: 'rgba(255,255,255,0.08)',
    },
    gridText: {
        fontSize: 12,
        fontWeight: '600',
    },
    customContentWrap: {
        flex: 1,
    },
});

export default GlassMorphMenu;
