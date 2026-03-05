import React, { useEffect, useState } from 'react'
import { View, Text, StyleSheet, Pressable, Platform } from 'react-native'
import { useRouter } from 'expo-router'
import { StatusBar } from 'expo-status-bar'
import { LinearGradient } from 'expo-linear-gradient'
import { BlurMask, Canvas, LinearGradient as SkiaLinearGradient, Path, Rect, Skia, vec, Group } from '@shopify/react-native-skia'
import Animated, {
    Extrapolation,
    Easing,
    interpolate,
    type SharedValue,
    useAnimatedStyle,
    useSharedValue,
    withDelay,
    withRepeat,
    withSequence,
    withTiming,
} from 'react-native-reanimated'
import { SkiaAnimatedBackground } from '../../src/components/native/SkiaAnimatedBackground'
import { useThemeStore } from '../../src/lib/stores/theme-store'
import SafeLiquidGlass from '../../src/components/native/SafeLiquidGlass'

const SLIDE_HOLD = 3200
const SLIDE_TRANSITION = 1600
const BACKGROUND_BASE = '#05070A'

const SLIDES = [
    {
        eyebrow: 'LOCAL IDENTITY',
        left: 'Keys stay',
        right: 'on-device',
        detail: 'A 2048-bit RSA pair is created locally, then the private key is stored encrypted for recovery.',
    },
    {
        eyebrow: 'SECRET KEY RECOVERY',
        left: 'Secret Key',
        right: 'restores access',
        detail: 'Your Secret Key derives the unlock material that decrypts the saved private key and rebuilds the session.',
    },
    {
        eyebrow: 'PRIVATE RELAY ROUTING',
        left: 'Relays carry',
        right: 'ciphertext only',
        detail: 'Traffic can route through private or public relays, but they only forward encrypted frames.',
    },
]

const withAlpha = (hex: string, alpha: number) => {
    const clamped = Math.round(Math.min(Math.max(alpha, 0), 1) * 255)
    return `${hex.slice(0, 7)}${clamped.toString(16).padStart(2, '0')}`
}

const mixHexColors = (from: string, to: string, amount: number) => {
    const clamped = Math.min(Math.max(amount, 0), 1)
    const fromR = parseInt(from.slice(1, 3), 16)
    const fromG = parseInt(from.slice(3, 5), 16)
    const fromB = parseInt(from.slice(5, 7), 16)
    const toR = parseInt(to.slice(1, 3), 16)
    const toG = parseInt(to.slice(3, 5), 16)
    const toB = parseInt(to.slice(5, 7), 16)

    const r = Math.round(fromR + (toR - fromR) * clamped)
    const g = Math.round(fromG + (toG - fromG) * clamped)
    const b = Math.round(fromB + (toB - fromB) * clamped)

    return `#${[r, g, b].map((value) => value.toString(16).padStart(2, '0')).join('')}`
}

function InsetBeamWord({
    word,
    color,
    textColor,
}: {
    word: string
    color: string
    textColor: string
}) {
    const [size, setSize] = useState({ width: 0, height: 0 })
    const pulse = useSharedValue(0.78)

    useEffect(() => {
        pulse.value = withRepeat(
            withTiming(1, { duration: 2200, easing: Easing.inOut(Easing.quad) }),
            -1,
            true
        )
    }, [pulse])

    const lightStyle = useAnimatedStyle(() => ({
        opacity: interpolate(pulse.value, [0.78, 1], [0.76, 1]),
    }))

    const width = Math.max(size.width, 1)
    const height = Math.max(size.height, 1)

    const dormantTextColor = mixHexColors(BACKGROUND_BASE, color, 0.48)
    const activeTextColor = mixHexColors(textColor, color, 0.14)
    const exitTextColor = mixHexColors(BACKGROUND_BASE, color, 0.34)
    const dormantGlowColor = mixHexColors(BACKGROUND_BASE, color, 0.72)
    const activeGlowColor = mixHexColors(textColor, color, 0.28)
    const exitGlowColor = mixHexColors(BACKGROUND_BASE, color, 0.56)

    // Extends the Canvas bounds so the blur doesn't get clipped
    const GLOW_OVERFLOW = 50;





    const corePath = Skia.Path.MakeFromSVGString(
        `M 4 ${height * 0.18}
         L ${Math.max(width * 0.22, 18)} ${height * 0.06}
         L ${width - 2} ${height * 0.28}
         L ${width - 2} ${height * 0.72}
         L ${Math.max(width * 0.22, 18)} ${height * 0.94}
         L 4 ${height * 0.82} Z`
    )
    const haloPath = Skia.Path.MakeFromSVGString(
        `M 0 ${height * 0.10}
         L ${Math.max(width * 0.16, 14)} ${height * 0.01}
         L ${width} ${height * 0.20}
         L ${width} ${height * 0.80}
         L ${Math.max(width * 0.16, 14)} ${height * 0.99}
         L 0 ${height * 0.90} Z`
    )

    return (
        <View
            style={styles.beamWord}
            onLayout={(event) => {
                const { width: nextWidth, height: nextHeight } = event.nativeEvent.layout
                if (nextWidth !== size.width || nextHeight !== size.height) {
                    setSize({ width: nextWidth, height: nextHeight })
                }
            }}
        >
            <Animated.View
                pointerEvents="none"
                style={[
                    { position: 'absolute', top: -GLOW_OVERFLOW, left: -GLOW_OVERFLOW, right: -GLOW_OVERFLOW, bottom: -GLOW_OVERFLOW },
                    lightStyle
                ]}
            >
                <Canvas style={StyleSheet.absoluteFill}>
                    <Group transform={[{ translateX: GLOW_OVERFLOW }, { translateY: GLOW_OVERFLOW }]}>
                        {haloPath && (
                            <Path path={haloPath}>
                                <SkiaLinearGradient
                                    start={vec(0, height * 0.5)}
                                    end={vec(width, height * 0.5)}
                                    colors={[withAlpha(color, 0.4), withAlpha(color, 0.1), 'transparent']}
                                />
                                <BlurMask blur={35} style="normal" />
                            </Path>
                        )}
                        {corePath && (
                            <Path path={corePath}>
                                <SkiaLinearGradient
                                    start={vec(0, height * 0.5)}
                                    end={vec(width + 40, height * 0.5)}
                                    colors={[withAlpha(color, 0.6), withAlpha(color, 0.15), 'transparent']}
                                />
                                <BlurMask blur={15} style="normal" />
                            </Path>
                        )}
                        <Rect
                            x={0}
                            y={height * 0.16}
                            width={5}
                            height={height * 0.68}
                            color={color}
                        >
                            <BlurMask blur={8} style="normal" />
                        </Rect>
                        <Rect
                            x={1}
                            y={height * 0.18}
                            width={2}
                            height={height * 0.64}
                            color="#FFFFFF"
                        >
                            <BlurMask blur={2} style="normal" />
                        </Rect>
                    </Group>
                </Canvas>
            </Animated.View>

            <Text
                style={[
                    styles.rightText,
                    {
                        color: withAlpha(textColor, 0.5),
                        textShadowColor: withAlpha(color, 0.3),
                    }
                ]}
            >
                {word}
            </Text>
        </View>
    )
}

function FeatureSlide({
    slide,
    index,
    progress,
    accent,
    textColor,
    mutedColor,
}: {
    slide: (typeof SLIDES)[number]
    index: number
    progress: SharedValue<number>
    accent: string
    textColor: string
    mutedColor: string
}) {
    const slideStyle = useAnimatedStyle(() => {
        const diff = progress.value - index
        // Dramatic reveal instead of sliding
        const translateY = interpolate(diff, [-0.72, 0, 0.72], [10, 0, -10], Extrapolation.CLAMP)
        const scale = interpolate(diff, [-0.72, 0, 0.72], [0.95, 1, 1.05], Extrapolation.CLAMP)
        const opacity = interpolate(diff, [-0.6, -0.4, 0.4, 0.6], [0, 1, 1, 0], Extrapolation.CLAMP)

        return {
            opacity,
            transform: [
                { translateY },
                { scale }
            ] as any,
        }
    })

    // Subtitle transitions softly out of focus
    const detailStyle = useAnimatedStyle(() => {
        const diff = progress.value - index
        const opacity = interpolate(diff, [-0.4, 0, 0.4], [0, 1, 0], Extrapolation.CLAMP)
        const translateY = interpolate(diff, [-0.5, 0, 0.5], [8, 0, -8], Extrapolation.CLAMP)

        return {
            opacity,
            transform: [{ translateY }]
        }
    })

    return (
        <Animated.View style={[styles.slideFrame, slideStyle]} pointerEvents="none">
            <View style={styles.headlineRow}>
                <Text style={[styles.leftText, { color: textColor }]}>{slide.left}</Text>
                <InsetBeamWord
                    word={slide.right}
                    color={accent}
                    textColor={textColor}
                />
            </View>

            <Animated.Text style={[styles.detailText, { color: mutedColor }, detailStyle]}>
                {slide.detail}
            </Animated.Text>
        </Animated.View>
    )
}

export default function WelcomeScreen() {
    const { colors } = useThemeStore()
    const router = useRouter()
    const slideProgress = useSharedValue(0)

    useEffect(() => {
        const ease = Easing.inOut(Easing.quad) // Smoother easing
        slideProgress.value = withRepeat(
            withSequence(
                withDelay(SLIDE_HOLD, withTiming(1, { duration: SLIDE_TRANSITION, easing: ease })),
                withDelay(SLIDE_HOLD, withTiming(2, { duration: SLIDE_TRANSITION, easing: ease })),
                withDelay(SLIDE_HOLD, withTiming(3, { duration: SLIDE_TRANSITION, easing: ease })),
                withTiming(0, { duration: 0 })
            ),
            -1,
            false
        )
    }, [slideProgress])

    const slideAccents = [colors.palette.orange, colors.primary, colors.palette.sky]

    return (
        <View style={[styles.container, { backgroundColor: BACKGROUND_BASE }]}> 
            <StatusBar style="light" />

            <SkiaAnimatedBackground
                baseColor={BACKGROUND_BASE}
                glowColor="#B9826B"
                cyanColor="#2E5D8A"
                slideProgress={slideProgress}
                intensity={0.56}
                contrast={0.6}
                grainAmount={0.32}
                darken={0.14}
            />

            {/* Gradient overlays to ensure text remains perfectly readable and cinematic */}
            <View pointerEvents="none" style={StyleSheet.absoluteFill}>
                <LinearGradient
                    colors={['transparent', withAlpha(BACKGROUND_BASE, 0.6), BACKGROUND_BASE]}
                    locations={[0, 0.6, 1]}
                    style={StyleSheet.absoluteFill}
                />
            </View>

            <View style={styles.mainContent}>
                <View style={styles.textContainer}>
                    {SLIDES.map((slide, index) => (
                        <FeatureSlide
                            key={index}
                            slide={slide}
                            index={index}
                            progress={slideProgress}
                            accent={slideAccents[index]}
                            textColor={'#FFFFFF'}
                            mutedColor={withAlpha('#FFFFFF', 0.6)}
                        />
                    ))}
                </View>
            </View>

            <View style={styles.bottomArea}>
                <View style={styles.buttonWrapper}>
                    <SafeLiquidGlass style={[StyleSheet.absoluteFill, { borderRadius: 30 }]} blurIntensity={20} pointerEvents="none" />
                    <Pressable
                        onPress={() => router.push('/(auth)/signup')}
                        style={({ pressed }) => [
                            styles.mainButton,
                            { backgroundColor: colors.button.background },
                            { opacity: pressed ? 0.85 : 1 }
                        ]}
                    >
                        <Text style={[styles.mainButtonText, { color: colors.button.text }]}>Create account</Text>
                    </Pressable>
                </View>

                <Pressable onPress={() => router.push('/(auth)/signin')} style={{ paddingVertical: 12 }}>
                    <Text style={[styles.signInTextBase, { color: withAlpha(colors.text, 0.6) }]}> 
                        Already have an account? <Text style={[styles.signInTextHighlight, { color: colors.primary }]}>Sign in</Text>
                    </Text>
                </Pressable>
            </View>
        </View>
    )
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    mainContent: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'flex-start',
        paddingHorizontal: 24,
        marginTop: 60, // Push it down slightly into the rich gradient
    },
    textContainer: {
        width: '100%',
        minHeight: 200,
        justifyContent: 'center',
        alignItems: 'flex-start',
    },
    slideFrame: {
        position: 'absolute',
        width: '100%',
        alignItems: 'flex-start',
    },
    headlineRow: {
        flexDirection: 'row',
        alignItems: 'center',
        justifyContent: 'flex-start',
        flexWrap: 'wrap', // Allow wrapping on small screens
        width: '100%',
        paddingRight: 20,
    },
    leftText: {
        fontSize: Platform.OS === 'ios' ? 44 : 38,
        lineHeight: Platform.OS === 'ios' ? 52 : 46,
        fontFamily: 'SpaceGrotesk-Regular',
        fontWeight: '300', // Thinner, larger, more elegant
        letterSpacing: -1.8,
    },
    beamWord: {
        minHeight: 52,
        marginLeft: 8,
        paddingLeft: 18,
        paddingRight: 8,
        justifyContent: 'center',
    },
    rightText: {
        fontSize: Platform.OS === 'ios' ? 44 : 38,
        lineHeight: Platform.OS === 'ios' ? 52 : 46,
        fontFamily: 'SpaceGrotesk-Regular',
        fontWeight: '300',
        letterSpacing: -1.8,
        textShadowOffset: { width: 0, height: 0 },
        textShadowRadius: 24, // Softer text shadow bleed
    },
    detailText: {
        marginTop: 24,
        maxWidth: 340, // Narrow column for easier reading
        textAlign: 'left',
        fontSize: 16,
        lineHeight: 24,
        fontFamily: 'SpaceGrotesk-Regular',
        fontWeight: '400',
        letterSpacing: 0,
    },
    bottomArea: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        paddingHorizontal: 32,
        paddingBottom: Platform.OS === 'ios' ? 50 : 40,
        alignItems: 'center',
        gap: 20,
    },
    buttonWrapper: {
        borderRadius: 30,
        overflow: 'hidden',
        width: '100%',
        maxWidth: 400,
        height: 56,
        position: 'relative',
        shadowColor: '#111',
        shadowOffset: { width: 0, height: 6 },
        shadowOpacity: 0.2,
        shadowRadius: 15,
    },
    mainButton: {
        flex: 1,
        justifyContent: 'center',
        alignItems: 'center',
        borderRadius: 30,
        overflow: 'hidden',
    },
    mainButtonText: {
        fontSize: 16,
        fontFamily: 'SpaceGrotesk-Bold',
        letterSpacing: 0.1,
    },
    signInTextBase: {
        fontSize: 15,
        fontFamily: 'SpaceGrotesk-Regular',
    },
    signInTextHighlight: {
        fontFamily: 'SpaceGrotesk-Bold',
    }
})
