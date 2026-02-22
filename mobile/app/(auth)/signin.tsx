
import React, { useState } from 'react'
import { View, Text, TouchableOpacity, StyleSheet, ActivityIndicator, Alert, KeyboardAvoidingView, Platform, ScrollView, I18nManager } from 'react-native'
import { useRouter } from 'expo-router'
import { useTranslation } from 'react-i18next'

import { ChevronLeft, ArrowRight } from 'lucide-react-native'
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass'
import { useAuthStore } from '../../src/lib/stores/auth-store'
import { apiClient } from '../../src/lib/api-client'
import { useThemeStore } from '../../src/lib/stores/theme-store'
import * as Crypto from 'expo-crypto'
import { deriveKeyFromPassphraseAsync, decryptPrivateKey } from '../../src/lib/crypto'
import AuthManager from '../../src/lib/AuthManager'
import FloatInput from '../../src/components/ui/FloatInput'
import { EdgeGlowBackground } from '../../src/components/auth/EdgeGlowBackground'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { Logo } from '../../src/components/ui/Logo'
import { LinearGradient } from 'expo-linear-gradient'
import Animated, { useSharedValue, useAnimatedStyle, withRepeat, withTiming, interpolate, Easing } from 'react-native-reanimated'
import MaskedView from '@react-native-masked-view/masked-view'
import { ModernLoader } from '../../src/components/ui/ModernLoader'

const withAlpha = (color: string, opacity: number) => {
    const _opacity = Math.round(Math.min(Math.max(opacity || 1, 0), 1) * 255);
    if (color.startsWith('#')) return color + _opacity.toString(16).toUpperCase().padStart(2, '0');
    return color; // Fallback
};

export default function SignInScreen() {
    const [secretKey, setSecretKey] = useState('')
    const [loading, setLoading] = useState(false)
    const [statusText, setStatusText] = useState('')
    const { login } = useAuthStore()
    const { t } = useTranslation()
    const { colors, effectiveTheme } = useThemeStore()
    const router = useRouter()
    const insets = useSafeAreaInsets()
    const isDark = effectiveTheme === 'dark'

    const isFormValid = secretKey.length > 5;

    // Shine animation
    const shineProgress = useSharedValue(-1)

    React.useEffect(() => {
        if (loading) {
            shineProgress.value = withRepeat(
                withTiming(1, { duration: 1500, easing: Easing.bezier(0.4, 0, 0.2, 1) }),
                -1,
                false
            )
        } else {
            shineProgress.value = -1
        }
    }, [loading])

    const shineStyle = useAnimatedStyle(() => ({
        transform: [{ translateX: interpolate(shineProgress.value, [-1, 1], [-200, 200]) }]
    }))

    const handleLogin = async () => {
        if (!secretKey.trim()) {
            Alert.alert('Error', 'Please enter your Secret Key')
            return
        }

        setLoading(true)
        try {
            setStatusText('Verifying identity...')
            const cleanSecret = secretKey.trim().toUpperCase().replace(/[^A-F0-9-]/g, '');

            if (!cleanSecret) {
                setStatusText('');
                setLoading(false);
                Alert.alert('Error', 'Invalid Secret Key format');
                return;
            }

            const response = await apiClient.login({
                credential: cleanSecret,
                password: cleanSecret,
                deviceId: typeof Crypto.randomUUID === 'function' ? Crypto.randomUUID() : Math.random().toString(36).substring(7)
            })
            const loginToken = response?.loginToken || response?.token || '';
            if (!loginToken) {
                throw new Error('Missing auth token in login response');
            }

            if (!response.encryptedPrivateKey) {
                throw new Error('Key sync unavailable for this account.')
            }

            setStatusText('Unlocking vault...')
            const decryptionKey = await deriveKeyFromPassphraseAsync(cleanSecret, response.username.toLowerCase().trim())
            console.log('[DEBUG-AUTH] Decrypting Key...');
            console.log('[DEBUG-AUTH] Enc blob len:', response.encryptedPrivateKey?.length);
            console.log('[DEBUG-AUTH] DecKey len:', decryptionKey?.length);
            const privateKeyPem = decryptPrivateKey(response.encryptedPrivateKey, decryptionKey)

            setStatusText('Restoring session...')
            const forge = require('node-forge');
            const privateKey = forge.pki.privateKeyFromPem(privateKeyPem);
            const publicKey = forge.pki.setRsaPublicKey(privateKey.n, privateKey.e);
            const publicKeyPem = forge.pki.publicKeyToPem(publicKey);

            const SecureStore = require('expo-secure-store');
            await SecureStore.setItemAsync('user_session_v2', JSON.stringify({
                userId: response.userId,
                secureId: response.secureId,
                privateKeyPem: privateKeyPem,
                publicKeyPem: publicKeyPem,
                secretKey: cleanSecret,
                loginToken
            }));

            AuthManager.getInstance().setSession({
                userId: response.userId,
                secureId: response.secureId,
                keyPair: { publicKey: publicKeyPem, privateKey: privateKeyPem },
                secretKey: cleanSecret,
                loginToken
            });

            login({ ...response, loginToken })

            try {
                const { useChatStore } = require('../../src/lib/ChatStore');
                // Force reset to ensure we don't skip init due to stale flag
                useChatStore.getState().disconnect();
                setTimeout(() => {
                    useChatStore.getState().initSocket();
                }, 50);
            } catch (e) {
                console.error('Socket init (signin) error:', e);
            }

            router.replace('/(tabs)/home')
        } catch (e: any) {
            console.error('Sign In Failed Stack:', e.stack);
            console.warn('Sign In Failed Details:', JSON.stringify(e));
            Alert.alert('Sign In Failed', e.message || 'Invalid key or network error')
        } finally {
            setLoading(false)
            setStatusText('')
        }
    }

    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <EdgeGlowBackground
                glowColor="#CFA352" // Temple Gold (Theme Palette)
                cyanColor="#D8875A" // Persimmon (Theme Palette)
            />

            <View style={[styles.navbar, { paddingTop: insets.top + 10, direction: 'ltr', flexDirection: 'row' }]}>
                <TouchableOpacity onPress={() => router.back()} style={styles.navAction}>
                    <SafeLiquidGlass style={styles.glassCircle} blurIntensity={15} tint={isDark ? 'dark' : 'light'} pointerEvents="none" />
                    <View pointerEvents="none" style={styles.navIconOverlay}>
                        <ChevronLeft size={20} color={colors.text} />
                    </View>
                </TouchableOpacity>
                <Logo size={22} />
                <View style={{ width: 44 }} />
            </View>

            <KeyboardAvoidingView
                behavior={Platform.OS === 'ios' ? 'padding' : undefined}
                style={{ flex: 1 }}
            >
                <ScrollView
                    contentContainerStyle={styles.scrollContainer}
                    showsVerticalScrollIndicator={false}
                    bounces={false}
                >
                    <View style={[styles.heroSection, { alignItems: I18nManager.isRTL ? 'flex-end' : 'flex-start' }]}>
                        <Text style={[styles.heroTitle, { color: colors.text, textAlign: I18nManager.isRTL ? 'right' : 'left' }]}>
                            {t('auth.welcomeBack')}
                        </Text>
                        <Text style={[styles.heroSubtitle, { color: colors.textSecondary, textAlign: I18nManager.isRTL ? 'right' : 'left' }]}>
                            {t('auth.enterSecretKey')}
                        </Text>
                    </View>

                    <View style={styles.formContainer}>
                        <FloatInput
                            label={t('auth.secretKeyLabel')}
                            value={secretKey}
                            onChangeText={setSecretKey}
                            secureTextEntry
                            autoCapitalize="none"
                            containerStyle={styles.inputSpacing}
                        />

                        <View style={{ marginTop: 8, height: 52, borderRadius: 22, overflow: 'hidden' }}>
                            <SafeLiquidGlass
                                style={[StyleSheet.absoluteFill, { borderRadius: 22 }]}
                                blurIntensity={20}
                                tint={isDark ? 'dark' : 'light'}
                                pointerEvents="none"
                            />
                            <View
                                pointerEvents="none"
                                style={[
                                    StyleSheet.absoluteFill,
                                    {
                                        backgroundColor: isFormValid ? withAlpha(colors.primary, 0.8) : withAlpha(colors.card, 0.5),
                                        borderRadius: 22,
                                    },
                                ]}
                            />
                            <TouchableOpacity
                                onPress={handleLogin}
                                disabled={loading || !isFormValid}
                                activeOpacity={0.8}
                                style={[styles.buttonTouchArea, { borderRadius: 22 }]}
                            >
                                {loading ? (
                                    <ModernLoader size={48} color="#fff" type="dots" />
                                ) : (
                                    <Text style={[styles.buttonLabel, { color: isFormValid ? '#fff' : colors.textSecondary }]}>
                                        {t('auth.signIn')}
                                    </Text>
                                )}
                            </TouchableOpacity>
                        </View>

                        <View style={styles.switchLink}>
                            <Text style={[styles.switchLinkText, { color: colors.textSecondary }]}>
                                {t('auth.noAccount')}{' '}
                                <Text
                                    onPress={() => router.push('/(auth)/signup')}
                                    style={{ color: colors.primary, fontWeight: '700' }}
                                >
                                    {t('auth.createOne')}
                                </Text>
                            </Text>
                        </View>
                    </View>

                    <View style={{ height: 100 }} />
                </ScrollView>
            </KeyboardAvoidingView>
        </View >
    )
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    navbar: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'space-between',
        paddingHorizontal: 20,
        zIndex: 50,
    },
    navAction: {
        width: 44,
        height: 44,
        position: 'relative',
    },
    glassCircle: {
        width: 44,
        height: 44,
        borderRadius: 22,
    },
    navIconOverlay: {
        ...StyleSheet.absoluteFillObject,
        alignItems: 'center',
        justifyContent: 'center',
    },
    scrollContainer: {
        paddingHorizontal: 32,
        paddingTop: 80,
    },
    heroSection: {
        marginBottom: 32,
    },
    heroTitle: {
        fontSize: 32,
        fontWeight: '900',
        letterSpacing: -1.0,
        lineHeight: 38,
        marginBottom: 8,
    },
    heroSubtitle: {
        fontSize: 15,
        lineHeight: 22,
        fontWeight: '400',
        maxWidth: '90%',
    },
    formContainer: {
        width: '100%',
    },
    inputSpacing: {
        marginBottom: 20,
    },
    primaryAction: {
        height: 52,
        borderRadius: 22, // Match input
        overflow: 'hidden',
    },
    buttonWrapper: {
        borderRadius: 22,
        overflow: 'hidden',
    },
    buttonTouchArea: {
        flex: 1,
        width: '100%',
        justifyContent: 'center',
        alignItems: 'center',
    },
    buttonInner: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        width: '100%',
        paddingHorizontal: 20,
    },
    arrowContainer: {
        position: 'absolute',
        right: 20,
    },
    buttonLabel: {
        fontSize: 16,
        fontWeight: '700',
    },
    loadingRow: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'center',
        width: '100%',
        gap: 12,
    },
    loadingText: {
        fontSize: 14,
        fontWeight: '500',
    },
    switchLink: {
        marginTop: 24,
        alignItems: 'center',
    },
    switchLinkText: {
        fontSize: 14,
    }
});
