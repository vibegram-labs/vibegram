
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
import { generateKeyPair, deriveKeyFromPassphraseAsync, encryptPrivateKey } from '../../src/lib/crypto'
import AuthManager from '../../src/lib/AuthManager'
import FloatInput from '../../src/components/ui/FloatInput'
import { EdgeGlowBackground } from '../../src/components/auth/EdgeGlowBackground'
import { sanitizeInput, validateUsername } from '../../src/lib/utils/security'
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

export default function SignUpScreen() {
    const [username, setUsername] = useState('')
    const [loading, setLoading] = useState(false)
    const [statusText, setStatusText] = useState('')
    const [usernameError, setUsernameError] = useState<string | undefined>(undefined)

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

    const { login } = useAuthStore()
    const { t } = useTranslation()
    const { colors, effectiveTheme } = useThemeStore()
    const router = useRouter()
    const insets = useSafeAreaInsets()
    const isDark = effectiveTheme === 'dark'

    const handleUsernameChange = (text: string) => {
        const sanitized = sanitizeInput(text);
        if (sanitized.length <= 20) {
            setUsername(sanitized.toLowerCase());
        }
        if (usernameError) setUsernameError(undefined);
    }

    const isFormValid = username.length > 2 && !usernameError;

    const handleSignUp = async () => {
        const validation = validateUsername(username);
        if (!validation.isValid) {
            setUsernameError(validation.error);
            return;
        }

        setLoading(true)
        try {
            const newSecret = Array.from(global.crypto.getRandomValues(new Uint8Array(24)))
                .map(b => b.toString(16).padStart(2, '0').toUpperCase())
                .join('')
                .match(/.{1,4}/g)?.join('-') || '';

            setStatusText('Signing up...')
            await new Promise(r => setTimeout(r, 100)); // Visual feedback

            const keyPair = await generateKeyPair();
            const encryptionKey = await deriveKeyFromPassphraseAsync(newSecret, username.toLowerCase().trim());
            const encryptedPrivateKey = encryptPrivateKey(keyPair.privateKey, encryptionKey);

            const response = await apiClient.register({
                username,
                password: newSecret,
                deviceId: Crypto.randomUUID(),
                identityKey: 'v2',
                publicKey: keyPair.publicKey,
                encryptedPrivateKey: encryptedPrivateKey
            });
            const loginToken = response?.loginToken || response?.token || '';
            if (!loginToken) {
                throw new Error('Missing auth token in signup response');
            }

            AuthManager.getInstance().setSession({
                userId: response.userId,
                secureId: response.secureId,
                keyPair: { publicKey: keyPair.publicKey, privateKey: keyPair.privateKey },
                secretKey: newSecret,
                loginToken
            });

            const SecureStore = require('expo-secure-store');
            await SecureStore.setItemAsync('user_session_v2', JSON.stringify({
                userId: response.userId,
                secureId: response.secureId,
                privateKeyPem: keyPair.privateKey,
                publicKeyPem: keyPair.publicKey,
                secretKey: newSecret,
                loginToken
            }));

            login({ ...response, loginToken });

            // Success! Direct navigation
            try {
                const { useChatStore } = require('../../src/lib/ChatStore');
                useChatStore.getState().disconnect();
                setTimeout(() => {
                    useChatStore.getState().initSocket();
                }, 100);
            } catch (e) {
                console.error('Socket init error:', e);
            }
            router.replace('/(tabs)/home');
        } catch (e: any) {
            console.error('Sign Up Failed Stack:', e.stack);
            console.warn('Sign Up Failed Details:', JSON.stringify(e));
            let message = e.message || 'Unknown error';
            if (message.toLowerCase().includes('username taken') || message.includes('409')) {
                setUsernameError("This username is already taken");
            } else {
                Alert.alert('Sign Up Failed', message)
            }
        } finally {
            setLoading(false)
            setStatusText('')
        }
    }



    return (
        <View style={[styles.container, { backgroundColor: colors.background }]}>
            <EdgeGlowBackground
                glowColor={colors.primary}
                cyanColor="#2DD4BF"
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
                keyboardVerticalOffset={Platform.OS === 'ios' ? 0 : 20}
            >
                <ScrollView
                    contentContainerStyle={styles.scrollContainer}
                    showsVerticalScrollIndicator={false}
                    bounces={false}
                >
                    <View style={[styles.heroSection, { alignItems: I18nManager.isRTL ? 'flex-end' : 'flex-start' }]}>
                        <Text style={[styles.heroTitle, { color: colors.text, textAlign: I18nManager.isRTL ? 'right' : 'left' }]}>
                            {t('auth.createAccount')}
                        </Text>
                        <Text style={[styles.heroSubtitle, { color: colors.textSecondary, textAlign: I18nManager.isRTL ? 'right' : 'left' }]}>
                            {t('auth.rhythmPrivateVibing')}
                        </Text>
                    </View>

                    <View style={styles.formContainer}>
                        <FloatInput
                            label={t('auth.chooseUsername')}
                            value={username}
                            onChangeText={handleUsernameChange}
                            error={usernameError}
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
                                onPress={handleSignUp}
                                disabled={loading || !isFormValid}
                                activeOpacity={0.8}
                                style={[styles.buttonTouchArea, { borderRadius: 22 }]}
                            >
                                {loading ? (
                                    <ModernLoader size={48} color="#fff" type="dots" />
                                ) : (
                                    <Text style={[styles.buttonLabel, { color: isFormValid ? '#fff' : colors.textSecondary }]}>
                                        {t('auth.signUp')}
                                    </Text>
                                )}
                            </TouchableOpacity>
                        </View>

                        <View style={styles.switchLink}>
                            <Text style={[styles.switchLinkText, { color: colors.textSecondary }]}>
                                {t('auth.alreadyHaveAccount')}{' '}
                                <Text
                                    onPress={() => router.push('/(auth)/signin')}
                                    style={{ color: colors.primary, fontWeight: '700' }}
                                >
                                    {t('auth.signIn')}
                                </Text>
                            </Text>
                        </View>
                    </View>

                    <View style={{ height: 100 }} />
                </ScrollView>
            </KeyboardAvoidingView>
        </View>
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
        paddingTop: 80, // Increased for spacious feel and glow headroom
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
        height: 52, // Match input
        borderRadius: 22, // Match input
        overflow: 'hidden', // Ensure glass effect is clipped
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
