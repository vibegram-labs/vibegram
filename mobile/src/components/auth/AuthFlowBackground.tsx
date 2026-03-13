import React, { useMemo } from 'react'
import { PixelRatio, StyleSheet, View, useWindowDimensions } from 'react-native'
import { Canvas, Rect, Shader, Skia } from '@shopify/react-native-skia'
import { useDerivedValue } from 'react-native-reanimated'

export const AUTH_SIGNUP_GLOW = '#8274B2' // Next-Gen Amethyst
export const AUTH_SIGNUP_CYAN = '#436B95' // Deep Titanium Blue
export const AUTH_SIGNIN_GLOW = '#8274B2'
export const AUTH_SIGNIN_CYAN = '#436B95'

const SKSL_SHADER = `
uniform float2 iResolution;
uniform float iPixelRatio;
uniform vec3 baseColor;
uniform vec3 glowColor;
uniform vec3 cyanColor;
uniform float intensity;
uniform float contrast;
uniform float grainAmount;
uniform float darken;
uniform float2 anchor;
uniform float2 veilAnchor;
uniform float2 blobScale;
uniform float2 veilScale;
uniform float rotation;

vec2 fluidWarp(vec2 p, float t, float amount) {
    vec2 q = p;
    q.x += sin(p.y * 5.0 + t * 1.2) * amount;
    q.y += cos(p.x * 4.0 - t * 0.9) * amount;
    q.x += sin(q.y * 9.0 + t * 1.5) * (amount * 0.6);
    q.y += cos(q.x * 8.0 - t * 1.1) * (amount * 0.6);
    return q;
}

half4 main(float2 fragCoord) {
    vec2 fragPx = fragCoord.xy * iPixelRatio;
    vec2 uv = fragPx / iResolution.xy;
    vec3 col = baseColor;
    float t = 0.0;

    vec2 localUv = uv - anchor + vec2(0.5);
    float warpAmount = 0.36;
    vec2 warpedLocal = fluidWarp(localUv, t, warpAmount);
    vec2 warpedCenter = fluidWarp(vec2(0.5), t, warpAmount);
    vec2 d = warpedLocal - warpedCenter;

    float c = cos(rotation);
    float s = sin(rotation);
    d = vec2(d.x * c - d.y * s, d.x * s + d.y * c);
    d.x *= blobScale.x;
    d.y *= blobScale.y;

    float angle = atan(d.y, d.x);
    float dist = length(d);
    dist -= sin(angle * 3.0 + 0.92) * 0.06;

    float blob = smoothstep(0.9, 0.0, dist);
    blob = pow(blob, 1.8);

    vec2 veilVec = uv - veilAnchor;
    veilVec.x *= veilScale.x;
    veilVec.y *= veilScale.y;
    float veil = smoothstep(1.1, 0.0, length(veilVec));
    veil = pow(veil, 2.2);

    float materialMask = max(blob, veil * 0.3);

    if (materialMask > 0.001) {
        float colorShift = 0.34;
        float gradientMix = smoothstep(0.0, 0.8, blob);
        vec3 innerCol = mix(glowColor, cyanColor, colorShift);
        vec3 outerCol = mix(cyanColor, glowColor, colorShift);
        vec3 blobCol = mix(outerCol, innerCol, gradientMix);
        vec3 softenedBlob = mix(baseColor, blobCol, contrast);
        col = mix(col, softenedBlob, materialMask * intensity);

        float grain = fract(sin(dot(fragPx * 0.9 + vec2(11.0, 7.0), vec2(12.9898, 78.233))) * 43758.5453);
        col += (grain - 0.5) * 0.06 * materialMask * grainAmount;
    }

    float vignette = 1.0 - smoothstep(0.3, 1.5, length(uv - 0.5));
    col *= (0.8 + 0.2 * vignette);
    col = mix(col, baseColor, darken);

    return half4(col, 1.0);
}
`

const hexToRgb = (hex: string) => {
    'worklet'
    if (!hex) return [0, 0, 0]
    const r = parseInt(hex.slice(1, 3), 16) / 255
    const g = parseInt(hex.slice(3, 5), 16) / 255
    const b = parseInt(hex.slice(5, 7), 16) / 255
    return [r, g, b]
}

interface AuthFlowBackgroundProps {
    baseColor?: string
    glowColor?: string
    cyanColor?: string
    intensity?: number
    contrast?: number
    grainAmount?: number
    darken?: number
    anchor?: [number, number]
    veilAnchor?: [number, number]
    blobScale?: [number, number]
    veilScale?: [number, number]
    rotation?: number
}

export const AuthFlowBackground = ({
    baseColor = '#121212',
    glowColor = AUTH_SIGNUP_GLOW,
    cyanColor = AUTH_SIGNUP_CYAN,
    intensity = 1,
    contrast = 0.66,
    grainAmount = 0.28,
    darken = 0.08,
    anchor = [0.18, 0.84],
    veilAnchor = [0.22, 0.9],
    blobScale = [0.94, 1.22],
    veilScale = [0.86, 1.46],
    rotation = -0.54,
}: AuthFlowBackgroundProps) => {
    const { width, height } = useWindowDimensions()
    const pixelRatio = PixelRatio.get()

    const runtimeEffect = useMemo(() => Skia.RuntimeEffect.Make(SKSL_SHADER), [])

    const base = useDerivedValue(() => hexToRgb(baseColor), [baseColor])
    const glow = useDerivedValue(() => hexToRgb(glowColor), [glowColor])
    const cyan = useDerivedValue(() => hexToRgb(cyanColor), [cyanColor])

    const uniforms = useDerivedValue(
        () => ({
            iResolution: [width * pixelRatio, height * pixelRatio],
            iPixelRatio: pixelRatio,
            baseColor: base.value,
            glowColor: glow.value,
            cyanColor: cyan.value,
            intensity,
            contrast,
            grainAmount,
            darken,
            anchor,
            veilAnchor,
            blobScale,
            veilScale,
            rotation,
        }),
        [
            width,
            height,
            pixelRatio,
            base,
            glow,
            cyan,
            intensity,
            contrast,
            grainAmount,
            darken,
            anchor,
            veilAnchor,
            blobScale,
            veilScale,
            rotation,
        ]
    )

    if (!runtimeEffect) {
        return null
    }

    return (
        <View style={StyleSheet.absoluteFill} pointerEvents="none">
            <Canvas style={{ flex: 1 }}>
                <Rect x={0} y={0} width={width} height={height}>
                    <Shader source={runtimeEffect} uniforms={uniforms} />
                </Rect>
            </Canvas>
        </View>
    )
}
