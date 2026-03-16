
import React, { useState } from 'react'
import { View, Text, StyleSheet, ActivityIndicator, Alert, KeyboardAvoidingView, Platform, ScrollView, I18nManager, Pressable } from 'react-native'
import { useRouter } from 'expo-router'
import { useTranslation } from 'react-i18next'

import { ChevronLeft } from 'lucide-react-native'
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass'
import { useAuthStore } from '../../src/lib/stores/auth-store'
import { apiClient } from '../../src/lib/api-client'
import { useThemeStore } from '../../src/lib/stores/theme-store'
import * as Crypto from 'expo-crypto'
import { deriveKeyFromPassphraseAsync, decryptPrivateKey } from '../../src/lib/crypto'
import AuthManager from '../../src/lib/AuthManager'
import FloatInput from '../../src/components/ui/FloatInput'
import { AuthFlowBackground, AUTH_SIGNIN_CYAN, AUTH_SIGNIN_GLOW } from '../../src/components/auth/AuthFlowBackground'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { Logo } from '../../src/components/ui/Logo'
import { ModernLoader } from '../../src/components/ui/ModernLoader'

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
    const buttonBackgroundColor = colors.button;

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

            try {
                const { clearSessionScopedClientCaches } = require('../../src/lib/session-cache');
                await clearSessionScopedClientCaches(response.userId);
            } catch (cacheError) {
                console.warn('Failed to clear session caches before signin handoff', cacheError);
            }

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
            <AuthFlowBackground
                baseColor={colors.background}

                intensity={0.72}
                contrast={0.74}
                grainAmount={0.3}
                darken={0.08}
                anchor={[0.85, -0.1]}
                veilAnchor={[0.85, -0.15]}
                blobScale={[1.2, 1.2]}
                veilScale={[1.2, 1.2]}
                rotation={0.1}
            />

            <View style={[styles.navbar, { paddingTop: insets.top + 10, direction: 'ltr', flexDirection: 'row' }]}>
                {Platform.OS === 'android' ? (
                    <View
                        style={[styles.glassCircle, { backgroundColor: isDark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)' }]}
                        onStartShouldSetResponder={() => true}
                        onResponderRelease={() => router.back()}
                    >
                        <ChevronLeft size={20} color={colors.text} />
                    </View>
                ) : (
                    <SafeLiquidGlass
                        style={styles.glassCircle}
                        blurIntensity={15}
                        tint={isDark ? 'dark' : 'light'}
                        onStartShouldSetResponder={() => true}
                        onResponderRelease={() => router.back()}
                    >
                        <ChevronLeft size={20} color={colors.text} />
                    </SafeLiquidGlass>
                )}
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

                        <View style={[styles.buttonWrapper, { marginTop: 8 }]}>
                            <Pressable
                                onPress={() => {
                                    if (!loading && isFormValid) {
                                        handleLogin()
                                    }
                                }}
                                style={({ pressed }) => [
                                    styles.nativeButtonGlass,
                                    { backgroundColor: buttonBackgroundColor, opacity: isFormValid ? (pressed ? 0.78 : 1) : 0.4 }
                                ]}
                            >
                                {loading ? (
                                    <View style={styles.loadingWrapper}>
                                        <ModernLoader size={48} color={colors.buttonText} type="dots" />
                                    </View>
                                ) : (
                                    <Text style={[styles.buttonLabel, { color: colors.buttonText }]}>
                                        {t('auth.signIn')}
                                    </Text>
                                )}
                            </Pressable>
                        </View>

                        <View style={styles.switchLink}>
                            <Text style={[styles.switchLinkText, { color: colors.textSecondary }]}>
                                {t('auth.noAccount')}{' '}
                                <Text
                                    onPress={() => router.replace('/(auth)/signup')}
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
    glassCircle: {
        width: 44,
        height: 44,
        borderRadius: 22,
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
        height: 54,
    },
    nativeButtonGlass: {
        height: 46,
        borderRadius: 23, // Match welcome screen
        overflow: 'hidden',
        justifyContent: 'center',
        alignItems: 'center',
        width: '100%',
        textAlign: 'center',
    },
    buttonLabel: {
        fontSize: 16,
        fontWeight: '700',
        textAlign: 'center',
        lineHeight: 46,
    },
    loadingWrapper: {
        height: 46,
        justifyContent: 'center',
        alignItems: 'center',
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
