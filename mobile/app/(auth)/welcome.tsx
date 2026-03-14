import React, { useEffect, useState } from 'react'
import { View, Text, StyleSheet, Pressable, Platform } from 'react-native'
import { useRouter } from 'expo-router'
import { StatusBar } from 'expo-status-bar'
import { LinearGradient } from 'expo-linear-gradient'
import { BlurMask, Canvas, LinearGradient as SkiaLinearGradient, Path, Rect, RoundedRect, Group, Mask, vec, Skia } from '@shopify/react-native-skia'
import Animated, {
    Extrapolation,
    Easing,
    interpolate,
    interpolateColor,
    type SharedValue,
    useAnimatedStyle,
    useDerivedValue,
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

const SLIDES = [
    {
        header: 'Unbreakable Privacy',
        detail: 'Your conversations are mathematically locked. No one else can ever read them.',
    },
    {
        header: 'Unstoppable Access',
        detail: 'Engineered to bypass network blocks. When other apps go dark, you stay connected.',
    },
    {
        header: 'Brilliant AI Built-in',
        detail: 'Your personal intelligent assistant is ready to help you draft, summarize, and translate.',
    },
]


function hexToRgba(color: string, alpha: number): string {
    'worklet';
    if (!color) return `rgba(127, 127, 127, ${alpha})`
    if (color.startsWith('#')) {
        const hex = color.replace('#', '')
        const r = parseInt(hex.substring(0, 2), 16)
        const g = parseInt(hex.substring(2, 4), 16)
        const b = parseInt(hex.substring(4, 6), 16)
        return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }
    if (color.startsWith('rgba')) {
        return color.replace(/[\d\.]+\)$/g, `${alpha})`)
    }
    return color
}

const getP = (val: number) => {
    'worklet';
    let p = val % 3;
    if (p < 0) p += 3;
    return p;
};

const getInterpolatedColor = (p: number, arr: string[]) => {
    'worklet';
    if (p < 1) return interpolateColor(p, [0, 1], [arr[0], arr[1]], 'RGB');
    if (p < 2) return interpolateColor(p - 1, [0, 1], [arr[1], arr[2]], 'RGB');
    return interpolateColor(p - 2, [0, 1], [arr[2], arr[0]], 'RGB');
};

function HeaderLightBeam({
    accents,
    outerHalo,
    innerHalo,
    outerCore,
    innerCore,
    progress,
    introProgress,
    size
}: {
    accents: string[]
    outerHalo: string[]
    innerHalo: string[]
    outerCore: string[]
    innerCore: string[]
    progress: SharedValue<number>
    introProgress?: SharedValue<number>
    size: { width: number, height: number }
}) {
    const pulse = useSharedValue(0.78)

    useEffect(() => {
        pulse.value = withRepeat(
            withTiming(1, { duration: 2200, easing: Easing.inOut(Easing.quad) }),
            -1,
            true
        )
    }, [pulse])

    const lightStyle = useAnimatedStyle(() => ({
        opacity: interpolate(pulse.value, [0.78, 1], [0.94, 1]),
    }))

    const activeColor = useDerivedValue(() => getInterpolatedColor(getP(progress.value), accents));
    const haloColors = useDerivedValue(() => [
        getInterpolatedColor(getP(progress.value), outerHalo),
        getInterpolatedColor(getP(progress.value), innerHalo),
        'transparent'
    ]);
    const coreColors = useDerivedValue(() => [
        getInterpolatedColor(getP(progress.value), outerCore),
        getInterpolatedColor(getP(progress.value), innerCore),
        'transparent'
    ]);

    const introStyle = useAnimatedStyle(() => {
        if (!introProgress) return {};
        return {
            opacity: interpolate(introProgress.value, [0.15, 0.45], [0, 1], Extrapolation.CLAMP)
        }
    });

    const width = Math.max(size.width, 1)
    const height = Math.max(size.height, 1)
    const GLOW_OVERFLOW = 64;

    const corePath = Skia.Path.MakeFromSVGString(
        `M 4 ${height * 0.18}
         L ${Math.min(width * 0.15, 30)} ${height * 0.06}
         L ${width + 10} ${height * 0.28}
         L ${width + 10} ${height * 0.72}
         L ${Math.min(width * 0.15, 30)} ${height * 0.94}
         L 4 ${height * 0.82} Z`
    )
    const haloPath = Skia.Path.MakeFromSVGString(
        `M 0 ${height * 0.10}
         L ${Math.max(width * 0.12, 10)} ${height * 0.01}
         L ${width + 20} ${height * 0.20}
         L ${width + 20} ${height * 0.80}
         L ${Math.max(width * 0.12, 10)} ${height * 0.99}
         L 0 ${height * 0.90} Z`
    )

    return (
        <Animated.View
            pointerEvents="none"
            style={[
                { position: 'absolute', top: -GLOW_OVERFLOW, left: -GLOW_OVERFLOW, right: -GLOW_OVERFLOW, bottom: -GLOW_OVERFLOW },
                lightStyle,
                introStyle
            ]}
        >
            <Canvas style={StyleSheet.absoluteFill}>
                <Group transform={[{ translateX: GLOW_OVERFLOW }, { translateY: GLOW_OVERFLOW }]}>
                    {haloPath && (
                        <Path path={haloPath}>
                            <SkiaLinearGradient
                                start={vec(0, height * 0.5)}
                                end={vec(width, height * 0.5)}
                                colors={haloColors}
                            />
                            <BlurMask blur={32} style="normal" />
                        </Path>
                    )}
                    {corePath && (
                        <Path path={corePath}>
                            <SkiaLinearGradient
                                start={vec(0, height * 0.5)}
                                end={vec(width + 40, height * 0.5)}
                                colors={coreColors}
                            />
                            <BlurMask blur={16} style="normal" />
                        </Path>
                    )}
                </Group>
                <Group transform={[{ translateX: GLOW_OVERFLOW }, { translateY: GLOW_OVERFLOW }]}>
                    <RoundedRect
                        x={0}
                        y={height * 0.08}
                        width={6}
                        height={height * 0.84}
                        r={3}
                        color={hexToRgba('#FFF6F1', 0.4)}
                    >
                        <BlurMask blur={8} style="normal" />
                    </RoundedRect>
                    <RoundedRect
                        x={0.5}
                        y={height * 0.12}
                        width={4.5}
                        height={height * 0.76}
                        r={2.25}
                        color={activeColor}
                    >
                        <BlurMask blur={4} style="normal" />
                    </RoundedRect>
                    <RoundedRect
                        x={1.5}
                        y={height * 0.18}
                        width={2.5}
                        height={height * 0.64}
                        r={1.25}
                        color="#FFFFFF"
                    >
                        <BlurMask blur={1.5} style="normal" />
                    </RoundedRect>
                </Group>
            </Canvas>
        </Animated.View>
    )
}

const AnimatedDetailWord = React.memo(({
    word,
    charIndex,
    progress,
    index,
    introProgress,
    isFirst,
    textStyle,
    hasSpace,
}: any) => {
    const wordStyle = useAnimatedStyle(() => {
        let diff = progress.value - index;
        if (diff > 1.5) diff -= 3;
        if (diff < -1.5) diff += 3;

        const introStagger = charIndex * 0.006;
        const outroStagger = charIndex * 0.004;

        const opacitySlide = interpolate(
            diff,
            [-0.7 + introStagger, -0.3 + introStagger, 0.1 + outroStagger, 0.5 + outroStagger],
            [0, 1, 1, 0],
            Extrapolation.CLAMP
        );

        let introOpacity = 1;
        if (isFirst && introProgress) {
            const introInitStagger = charIndex * 0.006;
            introOpacity = interpolate(
                introProgress.value,
                [0.35 + introInitStagger, 0.55 + introInitStagger],
                [0, 1],
                Extrapolation.CLAMP
            );
        }

        return {
            opacity: isFirst ? (opacitySlide * introOpacity) : opacitySlide,
        };
    });

    return (
        <Animated.Text style={[textStyle, wordStyle]}>
            {word}{hasSpace ? ' ' : ''}
        </Animated.Text>
    );
});

function AnimatedLetters({ text, progress, index, introProgress, isFirst, textStyle }: any) {
    const words = text.split(' ');
    let charIndex = 0;

    return (
        <View style={{ flexDirection: 'row', flexWrap: 'wrap' }}>
            {words.map((word: string, wIndex: number) => {
                const currentIdx = charIndex;
                charIndex += word.length + 1; // +1 for the space
                return (
                    <AnimatedDetailWord
                        key={`detail-word-${wIndex}`}
                        word={word}
                        charIndex={currentIdx}
                        progress={progress}
                        index={index}
                        introProgress={introProgress}
                        isFirst={isFirst}
                        textStyle={textStyle}
                        hasSpace={wIndex < words.length - 1}
                    />
                );
            })}
        </View>
    );
}

const AnimatedHeaderWord = React.memo(({
    word,
    charIndex,
    progress,
    index,
    introProgress,
    isFirst,
    textStyle,
    hasSpace,
}: any) => {
    const wordStyle = useAnimatedStyle(() => {
        let diff = progress.value - index;
        if (diff > 1.5) diff -= 3;
        if (diff < -1.5) diff += 3;

        const introStagger = charIndex * 0.012;
        const outroStagger = charIndex * 0.012;

        const opacitySlide = interpolate(
            diff,
            [-0.7 + introStagger, -0.3 + introStagger, 0.1 + outroStagger, 0.5 + outroStagger],
            [0, 1, 1, 0],
            Extrapolation.CLAMP
        );

        let introOpacity = 1;
        if (isFirst && introProgress) {
            const introInitStagger = charIndex * 0.012;
            introOpacity = interpolate(
                introProgress.value,
                [0.2 + introInitStagger, 0.6 + introInitStagger],
                [0, 1],
                Extrapolation.CLAMP
            );
        }

        const mergedOpacity = isFirst ? (opacitySlide * introOpacity) : opacitySlide;

        return {
            opacity: mergedOpacity,
        };
    });

    return (
        <Animated.Text style={[textStyle, wordStyle]}>
            {word}{hasSpace ? ' ' : ''}
        </Animated.Text>
    );
});

const AnimatedHeaderLetters = React.memo(({ text, progress, index, introProgress, isFirst, textStyle }: any) => {
    const words = text.split(' ');
    let charIndex = 0;

    return (
        <View style={{ flexDirection: 'row', flexWrap: 'wrap' }}>
            {words.map((word: string, wIndex: number) => {
                const currentIdx = charIndex;
                charIndex += word.length + 1;
                return (
                    <AnimatedHeaderWord
                        key={`word-${wIndex}`}
                        word={word}
                        charIndex={currentIdx}
                        progress={progress}
                        index={index}
                        introProgress={introProgress}
                        isFirst={isFirst}
                        textStyle={textStyle}
                        hasSpace={wIndex < words.length - 1}
                    />
                );
            })}
        </View>
    );
});

function FeatureSlide({
    slide,
    index,
    progress,
    textColor,
    mutedColor,
    introProgress,
    onHeaderLayout,
}: {
    slide: (typeof SLIDES)[number]
    index: number
    progress: SharedValue<number>
    textColor: string
    mutedColor: string
    introProgress: SharedValue<number>
    onHeaderLayout?: (size: { width: number, height: number }) => void
}) {
    const isFirst = index === 0;

    const opacStyle = useAnimatedStyle(() => {
        let diff = progress.value - index;
        if (diff > 1.5) diff -= 3;
        if (diff < -1.5) diff += 3;
        const op = interpolate(diff, [-1.1, -0.9, 0.9, 1.1], [0, 1, 1, 0], Extrapolation.CLAMP)
        return { opacity: op };
    });

    const introWordReveal = useAnimatedStyle(() => {
        if (!isFirst || !introProgress) return {};
        const op = interpolate(introProgress.value, [0.50, 0.70], [0, 1], Extrapolation.CLAMP);
        return { opacity: op };
    })

    return (
        <Animated.View style={[styles.slideFrame, opacStyle]} pointerEvents="none">
            <View
                style={styles.beamWord}
                onLayout={(event) => {
                    if (!isFirst || !onHeaderLayout) return
                    const { width, height } = event.nativeEvent.layout
                    onHeaderLayout({ width, height })
                }}
            >
                <AnimatedHeaderLetters
                    text={slide.header}
                    progress={progress}
                    index={index}
                    introProgress={introProgress}
                    isFirst={isFirst}
                    textStyle={[
                        styles.headerText,
                        { color: textColor }
                    ]}
                />
            </View>

            <View style={{ paddingLeft: 10, marginTop: 12 }}>
                <AnimatedLetters
                    text={slide.detail}
                    progress={progress}
                    index={index}
                    introProgress={introProgress}
                    isFirst={isFirst}
                    textStyle={[styles.detailText, { color: mutedColor }]}
                />
            </View>
        </Animated.View>
    )
}

export default function WelcomeScreen() {
    const { colors, effectiveTheme } = useThemeStore()
    const router = useRouter()
    const slideProgress = useSharedValue(0)
    const introProgress = useSharedValue(0)
    const [headerSize, setHeaderSize] = useState({ width: 300, height: 50 })
    const isDark = effectiveTheme === 'dark'

    useEffect(() => {
        introProgress.value = withTiming(1, { duration: 2500, easing: Easing.out(Easing.cubic) })

        const ease = Easing.inOut(Easing.quad)

        const timeout = setTimeout(() => {
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
        }, 2800)
        return () => clearTimeout(timeout)
    }, [slideProgress, introProgress])

    const backgroundBase = colors.background
    const shaderGlow = isDark ? '#8274B2' : '#C2B6E2' // Amethyst Pearl
    const shaderCyan = isDark ? '#436B95' : '#90A6C9' // Titanium Blue
    const primaryTextColor = colors.text
    const mutedTextColor = colors.textSecondary
    const buttonGlassColor = Platform.OS === 'ios' ? hexToRgba(colors.button, isDark ? 0.18 : 0.7) : colors.button
    const buttonWashStrong = Platform.OS === 'ios' ? hexToRgba(colors.button, isDark ? 0.28 : 0.26) : colors.button
    const buttonWashSoft = Platform.OS === 'ios' ? hexToRgba(colors.button, isDark ? 0.12 : 0.14) : colors.button
    const slideAccents = [
        isDark ? colors.palette.violet : colors.palette.mauve,
        colors.primary,
        isDark ? colors.palette.sky : colors.palette.blue,
    ]

    const outerHalo = slideAccents.map(c => hexToRgba(c, 0.78));
    const innerHalo = slideAccents.map(c => hexToRgba(c, 0.34));
    const outerCore = slideAccents.map(c => hexToRgba(c, 0.98));
    const innerCore = slideAccents.map(c => hexToRgba(c, 0.52));

    const pageIntroStyle = useAnimatedStyle(() => {
        const ty = interpolate(introProgress.value, [0, 1], [60, 0], Extrapolation.CLAMP);
        return { transform: [{ translateY: ty }] };
    })

    const bottomIntroStyle = useAnimatedStyle(() => {
        const ty = interpolate(introProgress.value, [0, 1], [60, 0], Extrapolation.CLAMP);
        const op = interpolate(introProgress.value, [0, 0.5], [0, 1], Extrapolation.CLAMP);
        return { opacity: op, transform: [{ translateY: ty }] };
    })

    return (
        <View style={[styles.container, { backgroundColor: backgroundBase }]}>
            <StatusBar style={isDark ? 'light' : 'dark'} />

            <SkiaAnimatedBackground
                baseColor={backgroundBase}
                glowColor={shaderGlow}
                cyanColor={shaderCyan}
                slideProgress={slideProgress}
                introProgress={introProgress}
                intensity={isDark ? 0.56 : 0.38}
                contrast={isDark ? 0.6 : 0.5}
                grainAmount={isDark ? 0.32 : 0.18}
                darken={isDark ? 0.14 : 0.03}
            />



            <Animated.View style={[styles.mainContent, pageIntroStyle]}>
                <View style={styles.textContainer}>
                    <View
                        style={[
                            styles.beamWordBackgroundTracker,
                            {
                                width: headerSize.width,
                                height: headerSize.height,
                            },
                        ]}
                        pointerEvents="none"
                    >
                        <HeaderLightBeam
                            size={headerSize}
                            accents={slideAccents}
                            outerHalo={outerHalo}
                            innerHalo={innerHalo}
                            outerCore={outerCore}
                            innerCore={innerCore}
                            progress={slideProgress}
                            introProgress={introProgress}
                        />
                    </View>

                    {SLIDES.map((slide, index) => (
                        <FeatureSlide
                            key={index}
                            slide={slide}
                            index={index}
                            progress={slideProgress}
                            introProgress={introProgress}
                            textColor={primaryTextColor}
                            mutedColor={mutedTextColor}
                            onHeaderLayout={(nextSize) => {
                                if (index !== 0) return
                                if (nextSize.width !== headerSize.width || nextSize.height !== headerSize.height) {
                                    setHeaderSize(nextSize)
                                }
                            }}
                        />
                    ))}
                </View>
            </Animated.View>

            <Animated.View style={[styles.bottomArea, bottomIntroStyle]}>
                <Pressable
                    onPress={() => router.push('/(auth)/signin')}
                    style={({ pressed }) => [
                        styles.mainButton,
                        { backgroundColor: colors.button },
                        { opacity: pressed ? 0.78 : 1 }
                    ]}
                >
                    <Text style={[styles.mainButtonText, { color: colors.buttonText }]}>Sign In</Text>
                </Pressable>

                <Pressable onPress={() => router.push('/(auth)/signup')} style={{ paddingVertical: 12 }}>
                    <Text style={[styles.signInTextBase, { color: colors.textSecondary }]}>
                        <Text style={[styles.signInTextHighlight, { color: colors.text }]}>Create account</Text>
                    </Text>
                </Pressable>
            </Animated.View>
        </View>
    )
}

const styles = StyleSheet.create({
    container: {
        flex: 1,
    },
    mainContent: {
        flex: 1,
        justifyContent: 'flex-end',
        alignItems: 'flex-start',
        paddingHorizontal: 24,
        paddingBottom: Platform.OS === 'ios' ? 220 : 196,
    },
    textContainer: {
        width: '100%',
        minHeight: 152,
        position: 'relative',
    },
    beamWordBackgroundTracker: {
        position: 'absolute',
        top: 0,
        left: 0,
        zIndex: 2,
    },
    slideFrame: {
        position: 'absolute',
        width: '100%',
        alignItems: 'flex-start',
        zIndex: 3,
    },
    beamWord: {
        alignSelf: 'flex-start',
        minHeight: Platform.OS === 'ios' ? 32 : 28,
        paddingLeft: 14,
        paddingTop: 0,
        paddingBottom: 0,
        justifyContent: 'center',
    },
    headerText: {
        fontSize: Platform.OS === 'ios' ? 26 : 22,
        lineHeight: Platform.OS === 'ios' ? 32 : 28,
        fontFamily: 'SpaceGrotesk-Bold',
        fontWeight: '700',
        letterSpacing: -0.8,
        includeFontPadding: false,
    },
    detailText: {
        maxWidth: 340,
        textAlign: 'left',
        fontSize: 16,
        lineHeight: 23,
        fontFamily: 'SpaceGrotesk-Regular',
        fontWeight: '400',
        letterSpacing: -0.2,
    },
    bottomArea: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        paddingHorizontal: 32,
        paddingBottom: Platform.OS === 'ios' ? 50 : 40,
        alignItems: 'center',
        gap: 16,
    },
    mainButton: {
        width: '100%',
        maxWidth: 400,
        height: 46,
        justifyContent: 'center',
        alignItems: 'center',
        borderRadius: 23,
    },
    mainButtonText: {
        fontSize: 16,
        fontFamily: 'SpaceGrotesk-Bold',
        letterSpacing: 0.1,
    },
    signInTextBase: {
        fontSize: 16,
        fontFamily: 'SpaceGrotesk-Regular',
    },
    signInTextHighlight: {
        fontFamily: 'SpaceGrotesk-Bold',
    }
})
