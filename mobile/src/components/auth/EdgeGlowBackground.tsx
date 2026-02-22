
import React, { useMemo } from 'react';
import { PixelRatio, StyleSheet, View, useWindowDimensions } from 'react-native';
import { Canvas, Rect, Shader, Skia } from '@shopify/react-native-skia';
import { useSharedValue, useDerivedValue, withRepeat, withTiming, Easing } from 'react-native-reanimated';

// Premium Localized Glow - Top Left Focused
// Returns alpha-premultiplied colors for better blending with parent View background.
const SKSL_SHADER = `
uniform float2 iResolution;
uniform float iTime;
uniform float iPixelRatio;
uniform vec3 glowColor;
uniform vec3 cyanColor;

half4 main(float2 fragCoord) {
    vec2 fragPx = fragCoord.xy * iPixelRatio;
    vec2 uv = fragPx / iResolution.xy;
    
    // Slower, more elegant movement
    float t = iTime * 0.02;
    
    // Position: Slightly more centered behind header/title
    vec2 lightPos = vec2(0.12 + 0.05 * sin(t), -0.05 + 0.03 * cos(t * 0.7));
    
    vec2 d = uv - lightPos;
    d.x *= 0.7; // Stretch horizontally for "more width"
    float angle = atan(d.y, d.x);
    float dist = length(d);
    
    // Liquid distortion logic
    float distortion = sin(angle * 3.0 + t * 2.0) * 0.02 
                     + cos(angle * 5.0 - t * 1.5) * 0.01;
                     
    float distortedDist = dist - distortion;
    
    // Increased size but kept soft
    float blob = smoothstep(0.55, 0.0, distortedDist); 
    blob = pow(blob, 2.5); // Slightly steeper falloff for "not too large" feel
    
    if (blob > 0.001) {
        // Rich color blend
        float gradientMix = smoothstep(0.1, 0.8, blob);
        vec3 blobCol = mix(cyanColor, glowColor, gradientMix);
        
        // Subtle film grain
        float grain = fract(sin(dot(fragPx * 0.9 + vec2(t * 9.0, t * 5.0), vec2(12.9898, 78.233))) * 43758.5453);
        blobCol += (grain - 0.5) * 0.05;
        
        // Intensity slightly reduced for the larger size
        float alpha = blob * 0.32;
        return half4(blobCol * alpha, alpha);
    }
    
    return half4(0.0, 0.0, 0.0, 0.0);
}
`;

const hexToRgb = (hex: string) => {
    'worklet';
    if (!hex) return [0, 0, 0];
    const r = parseInt(hex.slice(1, 3), 16) / 255;
    const g = parseInt(hex.slice(3, 5), 16) / 255;
    const b = parseInt(hex.slice(5, 7), 16) / 255;
    return [r, g, b];
};

interface EdgeGlowProps {
    glowColor?: string;
    cyanColor?: string;
}

/**
 * Ambient glow component that renders a localized, liquid-distorted light blob.
 * Positioned permanently at the top-left for a luxury brand feel.
 * Transparent background - allows the screen's background color to show through.
 */
export const EdgeGlowBackground = ({
    glowColor = '#D4A544',
    cyanColor = '#2DD4BF',
}: EdgeGlowProps) => {
    const { width, height } = useWindowDimensions();
    const pixelRatio = PixelRatio.get();
    const time = useSharedValue(0);

    const runtimeEffect = useMemo(() => Skia.RuntimeEffect.Make(SKSL_SHADER), []);

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
        glowColor: glow.value,
        cyanColor: cyan.value,
    }), [width, height, pixelRatio, time, glow, cyan]);

    if (!runtimeEffect) {
        return null;
    }

    return (
        <View style={StyleSheet.absoluteFill} pointerEvents="none">
            <Canvas style={{ flex: 1 }}>
                <Rect x={0} y={0} width={width} height={height}>
                    <Shader source={runtimeEffect} uniforms={uniforms} />
                </Rect>
            </Canvas>
        </View>
    );
};
