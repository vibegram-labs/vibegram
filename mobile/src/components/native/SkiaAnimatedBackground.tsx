import React, { useMemo } from 'react';
import { PixelRatio, StyleSheet, View, useWindowDimensions } from 'react-native';
import { Canvas, Rect, Shader, Skia } from '@shopify/react-native-skia';
import { useSharedValue, useDerivedValue, withRepeat, withTiming, Easing } from 'react-native-reanimated';

// Solid base with localized gradient light blob (Theme + Cyan)
// Grain ONLY applied to the blob area, ensuring clean parent background.
const SKSL_SHADER = `
uniform float2 iResolution;
uniform float iTime;
uniform float iPixelRatio;
uniform vec3 baseColor;
uniform vec3 glowColor;
uniform vec3 cyanColor;

half4 main(float2 fragCoord) {
    vec2 fragPx = fragCoord.xy * iPixelRatio;
    vec2 uv = fragPx / iResolution.xy;
    
    // 1. Solid base color
    vec3 col = baseColor;
    
    // 2. Localized light blob - Organic Luxurious Shape
    // Slower, more elegant movement
    float t = iTime * 0.02;
    
    // Position: floating gently around the upper-left/center area
    vec2 lightPos = vec2(0.4 + 0.1 * sin(t), 0.4 + 0.1 * cos(t * 0.8));
    
    vec2 d = uv - lightPos;
    float angle = atan(d.y, d.x);
    float dist = length(d);
    
    // Create organic/fluid distortion
    // Using multiple sine waves to create a "liquid" non-uniform shape
    float distortion = sin(angle * 3.0 + t * 2.0) * 0.04 
                     + cos(angle * 5.0 - t * 1.5) * 0.02
                     + sin(angle * 8.0 + t) * 0.01;
                     
    // Distort the distance field
    float distortedDist = dist - distortion;
    
    // Luxurious falloff: smooth and wide
    float blob = smoothstep(0.6, 0.0, distortedDist);
    
    // Sharpen the curve slightly for a defined "shape" but keep it soft
    blob = pow(blob, 1.8);
    
    if (blob > 0.001) {
        // Gradient: rich blend from center
        float gradientMix = smoothstep(0.2, 0.9, blob); // Tweaked mix
        vec3 blobCol = mix(cyanColor, glowColor, gradientMix);
        
        // Add light to base - blending mode approximation (Screen/Add)
        col = mix(col, blobCol, blob * 0.7);
        
        // 3. Film grain - Luxurious texture
        // Kept subtle and only on the blob
        float grain = fract(sin(dot(fragPx * 0.9 + vec2(t * 11.0, t * 7.0), vec2(12.9898, 78.233))) * 43758.5453);
        col += (grain - 0.5) * 0.06 * blob;
    }
    
    // Vignette for extra premium feel (optional, but adds depth)
    float vignette = 1.0 - smoothstep(0.5, 1.5, length(uv - 0.5));
    col *= (0.8 + 0.2 * vignette);
    
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
}

export const SkiaAnimatedBackground = ({
    baseColor = '#191919',
    glowColor = '#5EB1B2',
    cyanColor = '#06b6d4',
    backgroundColor = '#000000'
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
    }), [width, height, pixelRatio, time, base, glow, cyan]);

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
