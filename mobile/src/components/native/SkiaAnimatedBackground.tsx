import React, { useMemo } from 'react';
import { PixelRatio, StyleSheet, View, useWindowDimensions } from 'react-native';
import { Canvas, Rect, Shader, Skia } from '@shopify/react-native-skia';
import { useSharedValue, useDerivedValue, withRepeat, withTiming, Easing, SharedValue } from 'react-native-reanimated';

const SKSL_SHADER = `
uniform float2 iResolution;
uniform float iTime;
uniform float iPixelRatio;
uniform vec3 baseColor;
uniform vec3 glowColor;
uniform vec3 cyanColor;
uniform float slideProgress;
uniform float intensity;
uniform float contrast;
uniform float grainAmount;
uniform float darken;

// Noise for fluid transitions
vec2 fluidWarp(vec2 p, float t, float intensity) {
    vec2 pos = p;
    pos.x += sin(p.y * 5.0 + t * 1.2) * intensity;
    pos.y += cos(p.x * 4.0 - t * 0.9) * intensity;
    
    pos.x += sin(pos.y * 9.0 + t * 1.5) * (intensity * 0.6);
    pos.y += cos(pos.x * 8.0 - t * 1.1) * (intensity * 0.6);
    return pos;
}

half4 main(float2 fragCoord) {
    vec2 fragPx = fragCoord.xy * iPixelRatio;
    vec2 uv = fragPx / iResolution.xy;

    vec3 col = baseColor;
    float t = iTime * 0.02;
    float sp = mod(abs(slideProgress), 3.0);

    // Completely lock the shape in the center of the screen
    // It will NEVER drift left, right, up, or down across slides.
    vec2 basePos = vec2(0.5, 0.42);
    
    // Gentle hovering ambient motion
    basePos.x += sin(t * 0.4) * 0.06;
    basePos.y += cos(t * 0.5) * 0.06;

    // Fluid background distortion is perfectly intact
    float warpIntensity = 0.4 + sin(t * 0.3) * 0.1; 
    
    // CRITICAL FIX: To prevent the underlying fluidWarp from creating a slow
    // translation drift across the entire screen, we MUST warp the basePos as well 
    // to match. This effectively pins the geometric center of the effect in place
    // while the edges warp freely.
    vec2 warpedUv = fluidWarp(uv, t, warpIntensity);
    vec2 warpedBase = fluidWarp(basePos, t, warpIntensity);
    
    vec2 d = warpedUv - warpedBase;
    
    // Rotate domain continuously for swirling
    // We reverse the rotation from '+ sp' to '- sp' to match the reversed flow,
    // and multiply by 2.0943951 (which is 2*PI/3) so it seamlessly wraps at sp=3!
    float rot = t * 0.15 - (sp * 2.0943951);
    float c = cos(rot);
    float s = sin(rot);
    d = vec2(d.x * c - d.y * s, d.x * s + d.y * c);

    float dist = length(d);
    
    // Constant radiating star/liquid shape
    float angle = atan(d.y, d.x);
    dist -= sin(angle * 5.0 + t * 2.0) * 0.15;

    // Remove the hardcoded size hopping based on slide progress (sp <= 1.0 vs 2.0) 
    // which caused size skipping on loop reset.
    // Instead we drive a seamless gentle breathing using iTime
    float currentSize = 0.55 + sin(t * 1.5) * 0.05;

    float blob = smoothstep(currentSize, 0.0, dist);
    
    // Medium softness to let the fluid shapes show
    blob = pow(blob, 1.3);

    if (blob > 0.001) {
        // Color transition based on slide progress
        float colorShift;
        if (sp <= 1.0) colorShift = mix(0.1, 0.5, sp);
        else if (sp <= 2.0) colorShift = mix(0.5, 0.9, sp - 1.0);
        else colorShift = mix(0.9, 0.1, sp - 2.0);
        
        float gradientMix = smoothstep(0.0, 0.8, blob);

        vec3 innerCol = mix(glowColor, cyanColor, colorShift);
        vec3 outerCol = mix(cyanColor, glowColor, colorShift);
        vec3 blobCol  = mix(outerCol, innerCol, gradientMix);

        vec3 softenedBlob = mix(baseColor, blobCol, contrast);
        col = mix(col, softenedBlob, blob * intensity);
        
        // Film grain
        float grain = fract(sin(dot(fragPx * 0.9 + vec2(t * 11.0, t * 7.0), vec2(12.9898, 78.233))) * 43758.5453);
        col += (grain - 0.5) * 0.06 * blob * grainAmount;
    }

    // Rich dark vignette
    float vignette = 1.0 - smoothstep(0.3, 1.5, length(uv - 0.5));
    col *= (0.8 + 0.2 * vignette);
    col = mix(col, baseColor, darken);

    return half4(col, 1.0);
}
`;

const hexToRgb = (hex: string) => {
    'worklet';
    if (!hex) return [0, 0, 0];
    const r = parseInt(hex.slice(1, 3), 16) / 255;
    const g = parseInt(hex.slice(3, 5), 16) / 255;
    const b = parseInt(hex.slice(5, 7), 16) / 255;
    return [r, g, b];
}

interface SkiaAnimatedBackgroundProps {
    baseColor?: string;
    glowColor?: string;
    cyanColor?: string;
    backgroundColor?: string;
    /** 0→2 for welcome slides, omit for settled state */
    slideProgress?: SharedValue<number>;
    intensity?: number;
    contrast?: number;
    grainAmount?: number;
    darken?: number;
}

export const SkiaAnimatedBackground = ({
    baseColor = '#191919',
    glowColor = '#5EB1B2',
    cyanColor = '#06b6d4',
    backgroundColor = '#000000',
    slideProgress,
    intensity = 1,
    contrast = 1,
    grainAmount = 1,
    darken = 0,
}: SkiaAnimatedBackgroundProps) => {
    const { width, height } = useWindowDimensions();
    const pixelRatio = PixelRatio.get();
    const time = useSharedValue(0);

    const runtimeEffect = useMemo(() => Skia.RuntimeEffect.Make(SKSL_SHADER), []);

    const base = useDerivedValue(() => hexToRgb(baseColor), [baseColor]);
    const glow = useDerivedValue(() => hexToRgb(glowColor), [glowColor]);
    const cyan = useDerivedValue(() => hexToRgb(cyanColor), [cyanColor]);

    React.useEffect(() => {
        time.value = withRepeat(
            withTiming(100, { duration: 60000, easing: Easing.linear }),
            -1,
            false
        );
    }, []);

    const uniforms = useDerivedValue(() => ({
        iResolution: [width * pixelRatio, height * pixelRatio],
        iTime: time.value,
        iPixelRatio: pixelRatio,
        baseColor: base.value,
        glowColor: glow.value,
        cyanColor: cyan.value,
        slideProgress: slideProgress ? slideProgress.value : 2.0,
        intensity,
        contrast,
        grainAmount,
        darken,
    }), [width, height, pixelRatio, time, base, glow, cyan, slideProgress, intensity, contrast, grainAmount, darken]);

    if (!runtimeEffect) {
        return <View style={[StyleSheet.absoluteFill, { backgroundColor }]} />;
    }

    return (
        <View style={StyleSheet.absoluteFill}>
            <Canvas style={{ flex: 1 }}>
                <Rect x={0} y={0} width={width} height={height}>
                    <Shader source={runtimeEffect} uniforms={uniforms} />
                </Rect>
            </Canvas>
        </View>
    );
};
