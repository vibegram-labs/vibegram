
import React, { useEffect, useRef, useState } from 'react';
import { View, Text, StyleSheet, TouchableOpacity } from 'react-native';
import Animated, {
    interpolate,
    useSharedValue,
    useAnimatedStyle,
    withTiming,
} from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { X } from 'lucide-react-native';
import { BlurView } from 'expo-blur';
import { useThemeStore } from '../../lib/stores/theme-store';
import { useToastStore } from '../../lib/stores/toast-store';
import { AnimatedCopyIcon, AnimatedTrashIcon, AnimatedPinIcon, AnimatedSuccessIcon, AnimatedInfoIcon } from '../Icons';

export default function GlassToast() {
    const { visible, message, type, hideToast } = useToastStore();
    const { colors, effectiveTheme } = useThemeStore();
    const insets = useSafeAreaInsets();
    const [rendered, setRendered] = useState(visible);
    const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const autoHideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

    // Clip-path style reveal: animate visible height + opacity only
    const reveal = useSharedValue(visible ? 1 : 0);

    useEffect(() => {
        if (hideTimerRef.current) {
            clearTimeout(hideTimerRef.current);
            hideTimerRef.current = null;
        }
        if (autoHideTimerRef.current) {
            clearTimeout(autoHideTimerRef.current);
            autoHideTimerRef.current = null;
        }

        if (visible) {
            setRendered(true);
            reveal.value = withTiming(1, { duration: 120 });
            autoHideTimerRef.current = setTimeout(() => {
                hideToast();
            }, 2400);
        } else {
            reveal.value = withTiming(0, { duration: 110 });
            hideTimerRef.current = setTimeout(() => {
                setRendered(false);
            }, 120);
        }
    }, [visible, message, hideToast, reveal]);

    useEffect(() => () => {
        if (hideTimerRef.current) {
            clearTimeout(hideTimerRef.current);
            hideTimerRef.current = null;
        }
        if (autoHideTimerRef.current) {
            clearTimeout(autoHideTimerRef.current);
            autoHideTimerRef.current = null;
        }
    }, []);

    const animatedStyle = useAnimatedStyle(() => ({
        opacity: reveal.value,
        height: interpolate(reveal.value, [0, 1], [0, 56]),
    }));

    // Icon logic
    const getIcon = () => {
        const typeStr = (type || '').toLowerCase();

        switch (typeStr) {
            case 'success': return <AnimatedSuccessIcon size={20} color={'#4ade80'} strokeWidth={2.5} />;
            case 'error': return <AnimatedTrashIcon size={20} color="#ef4444" strokeWidth={2.5} />;
            case 'copy':
            case 'copied': return <AnimatedCopyIcon size={20} color={colors.text} strokeWidth={2.5} />;
            case 'delete':
            case 'trash': return <AnimatedTrashIcon size={20} color="#ef4444" strokeWidth={2.5} />;
            case 'pin': return <AnimatedPinIcon size={20} color={colors.text} strokeWidth={2.5} />;
            default: return <AnimatedInfoIcon size={20} color={colors.primary} strokeWidth={2.5} />;
        }
    };

    const isDark = effectiveTheme === 'dark';

    if (!rendered) return null;

    return (
        <Animated.View style={[styles.container, { bottom: Math.max(insets.bottom + 4, 8) }, animatedStyle]}>
            <View style={styles.toast}>
                <BlurView
                    intensity={58}
                    tint={isDark ? 'dark' : 'light'}
                    style={StyleSheet.absoluteFill}
                />
                <View
                    pointerEvents="none"
                    style={[
                        StyleSheet.absoluteFill,
                        { backgroundColor: isDark ? 'rgba(10,12,18,0.42)' : 'rgba(255,255,255,0.46)' },
                    ]}
                />
                <View style={styles.content}>
                    <View style={[styles.iconCircle, { backgroundColor: isDark ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.05)' }]}>
                        {getIcon()}
                    </View>
                    <Text style={[styles.message, { color: colors.text }]}>{message}</Text>
                    <TouchableOpacity onPress={hideToast} style={{ padding: 4 }}>
                        <X size={16} color={colors.textSecondary} />
                    </TouchableOpacity>
                </View>
            </View>
        </Animated.View>
    );
}

const styles = StyleSheet.create({
    container: {
        position: 'absolute',
        left: 14,
        right: 14,
        zIndex: 9999, // Ensure it's on top of modals
        overflow: 'hidden',
    },
    toast: {
        borderRadius: 24,
        overflow: 'hidden',
        borderWidth: 0,
    },
    content: {
        flexDirection: 'row',
        alignItems: 'center',
        paddingVertical: 10,
        paddingHorizontal: 10,
        paddingRight: 16,
        gap: 12,
    },
    iconCircle: {
        width: 32,
        height: 32,
        borderRadius: 16,
        alignItems: 'center',
        justifyContent: 'center',
    },
    message: {
        flex: 1,
        fontSize: 14,
        fontWeight: '600',
    }
});
