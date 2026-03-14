
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
import { generateKeyPair, deriveKeyFromPassphraseAsync, encryptPrivateKey } from '../../src/lib/crypto'
import AuthManager from '../../src/lib/AuthManager'
import FloatInput from '../../src/components/ui/FloatInput'
import { AuthFlowBackground, AUTH_SIGNUP_CYAN, AUTH_SIGNUP_GLOW } from '../../src/components/auth/AuthFlowBackground'
import { sanitizeInput, validateUsername } from '../../src/lib/utils/security'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { Logo } from '../../src/components/ui/Logo'
import { ModernLoader } from '../../src/components/ui/ModernLoader'

export default function SignUpScreen() {
    const [username, setUsername] = useState('')
    const [loading, setLoading] = useState(false)
    const [statusText, setStatusText] = useState('')
    const [usernameError, setUsernameError] = useState<string | undefined>(undefined)

    const { login } = useAuthStore()
    const { t } = useTranslation()
    const { colors, effectiveTheme } = useThemeStore()
    const router = useRouter()
    const insets = useSafeAreaInsets()
    const isDark = effectiveTheme === 'dark'
    const isFormValid = username.length > 2 && !usernameError;
    const buttonBackgroundColor = colors.button;

    const handleUsernameChange = (text: string) => {
        const sanitized = sanitizeInput(text);
        if (sanitized.length <= 20) {
            setUsername(sanitized.toLowerCase());
        }
        if (usernameError) setUsernameError(undefined);
    }

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
            <AuthFlowBackground
                baseColor={colors.background}
                glowColor={AUTH_SIGNUP_GLOW}
                cyanColor={AUTH_SIGNUP_CYAN}
                intensity={0.74}
                contrast={0.74}
                grainAmount={0.3}
                darken={0.06}
                anchor={[0.85, -0.1]}
                veilAnchor={[0.85, -0.15]}
                blobScale={[1.2, 1.2]}
                veilScale={[1.2, 1.2]}
                rotation={-0.2}
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

                        <View style={[styles.buttonWrapper, { marginTop: 8 }]}>
                            <Pressable
                                onPress={() => {
                                    if (!loading && isFormValid) {
                                        handleSignUp()
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
                                        {t('auth.signUp')}
                                    </Text>
                                )}
                            </Pressable>
                        </View>

                        <View style={styles.switchLink}>
                            <Text style={[styles.switchLinkText, { color: colors.textSecondary }]}>
                                {t('auth.alreadyHaveAccount')}{' '}
                                <Text
                                    onPress={() => router.replace('/(auth)/signin')}
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
    glassCircle: {
        width: 44,
        height: 44,
        borderRadius: 22,
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
