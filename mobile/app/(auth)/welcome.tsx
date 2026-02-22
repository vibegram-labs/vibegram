import React, { useEffect } from 'react'
import { View, Text, StyleSheet, TouchableOpacity, Pressable, Platform, I18nManager } from 'react-native'
import { useRouter } from 'expo-router'
import { useTranslation } from 'react-i18next'
import { StatusBar } from 'expo-status-bar'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withTiming,
    Easing,
} from 'react-native-reanimated'
import { SkiaAnimatedBackground } from '../../src/components/native/SkiaAnimatedBackground'
import { useThemeStore } from '../../src/lib/stores/theme-store'
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass'

export default function WelcomeScreen() {
    const { colors, effectiveTheme } = useThemeStore()
    const router = useRouter()
    const { t } = useTranslation()

    const fadeAnim = useSharedValue(0)
    const slideAnim = useSharedValue(30)

    useEffect(() => {
        fadeAnim.value = withTiming(1, { duration: 1200, easing: Easing.out(Easing.cubic) })
        slideAnim.value = withTiming(0, { duration: 1200, easing: Easing.out(Easing.cubic) })
    }, [])

    const contentStyle = useAnimatedStyle(() => ({
        opacity: fadeAnim.value,
        transform: [{ translateY: slideAnim.value }]
    }))

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <StatusBar style={effectiveTheme === 'dark' ? 'light' : 'dark'} />
            <SkiaAnimatedBackground
                baseColor={colors.background}
                glowColor={colors.primary}
                cyanColor={colors.cyan}
            />

            <Animated.View style={[styles.content, contentStyle]}>
                <View style={styles.headerSpacer} />

                <View style={styles.header}>
                    <Text style={[styles.tagline, { color: colors.text, textAlign: 'center' }]}>
                        {t('auth.connectFreely')}
                    </Text>
                </View>

                <View style={styles.actions}>
                    <View style={styles.buttonWrapper}>
                        <SafeLiquidGlass style={[StyleSheet.absoluteFill, { borderRadius: 30 }]} blurIntensity={20} pointerEvents="none" />
                        <Pressable
                            onPress={() => router.push('/(auth)/signin')}
                            style={({ pressed }) => [
                                styles.primaryButton,
                                { backgroundColor: colors.primary, opacity: pressed ? 0.8 : 1, borderRadius: 30 }
                            ]}
                        >
                            <Text style={styles.primaryButtonText}>{t('auth.signIn')}</Text>
                        </Pressable>
                    </View>

                    <View style={styles.buttonWrapper}>
                        <SafeLiquidGlass style={[StyleSheet.absoluteFill, { borderRadius: 30 }]} blurIntensity={15} pointerEvents="none" />
                        <Pressable
                            onPress={() => router.push('/(auth)/signup')}
                            style={({ pressed }) => [
                                styles.secondaryButton,
                                { backgroundColor: colors.card, opacity: pressed ? 0.8 : 1, borderRadius: 30 }
                            ]}
                        >
                            <Text style={[styles.secondaryButtonText, { color: colors.text }]}>{t('auth.signUp')}</Text>
                        </Pressable>
                    </View>
                </View>
            </Animated.View>
        </View>
    )
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    content: {
        flex: 1,
        justifyContent: 'space-between',
        paddingHorizontal: 30,
        paddingBottom: 60,
    },
    headerSpacer: {
        flex: 1,
    },
    header: {
        flex: 2,
        alignItems: 'center',
        justifyContent: 'center',
        gap: 12,
    },
    logoText: {
        fontSize: Platform.OS === 'android' ? 42 : 56,
        fontWeight: '900',
        letterSpacing: Platform.OS === 'android' ? -0.5 : -2,
        textAlign: 'center',
    },
    tagline: {
        fontSize: Platform.OS === 'android' ? 14 : 18,
        textAlign: 'center',
        opacity: 0.8,
        letterSpacing: 0,
        fontWeight: Platform.OS === 'android' ? '400' : '500',
    },
    actions: {
        flex: 1,
        justifyContent: 'flex-end',
        gap: 16,
        width: '100%',
        maxWidth: 400,
        alignSelf: 'center',
    },
    buttonWrapper: {
        borderRadius: 30,
        overflow: 'hidden',
        width: '100%',
        height: 56,
        position: 'relative',
    },
    primaryButton: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'center',
    },
    primaryButtonText: {
        color: '#fff',
        fontSize: 17,
        fontWeight: 'bold',
        letterSpacing: 0.5,
    },
    secondaryButton: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'center',
    },
    secondaryButtonText: {
        fontSize: 17,
        fontWeight: '600',
        letterSpacing: 0.5,
    }
})
