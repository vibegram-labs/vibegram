import React from 'react'
import {
  Platform,
  processColor,
  StyleSheet,
  View,
  useColorScheme,
  type ColorValue,
  type ViewProps,
} from 'react-native'
import Constants from 'expo-constants'
import { BlurView } from 'expo-blur'
import { GlassView as ExpoGlassView, isGlassEffectAPIAvailable } from 'expo-glass-effect'
import { requireNativeViewManager } from 'expo-modules-core'

interface NativeLiquidGlassProps extends ViewProps {
  blurIntensity?: number
  blurReductionFactor?: number
  tint?: 'default' | 'light' | 'dark' | 'extraLight' | 'regular' | 'prominent'
  interactive?: boolean
  effect?: 'clear' | 'regular'
  tintColor?: ColorValue
  cornerRadius?: number
  pressFeedbackEnabled?: boolean
}

let NativeLiquidGlassView: React.ComponentType<NativeLiquidGlassProps> | null = null
let nativeLiquidGlassAvailable = false

if (Platform.OS === 'ios') {
  try {
    const isExpoGo = Constants.appOwnership === 'expo'
    if (!isExpoGo) {
      NativeLiquidGlassView = requireNativeViewManager<NativeLiquidGlassProps>('LiquidGlass')
      nativeLiquidGlassAvailable = !!NativeLiquidGlassView
    }
  } catch {
    nativeLiquidGlassAvailable = false
  }
}

interface SafeLiquidGlassProps extends ViewProps {
  children?: React.ReactNode
  interactive?: boolean
  effect?: 'clear' | 'regular'
  tintColor?: ColorValue
  colorScheme?: 'light' | 'dark' | 'system'
  style?: any
  blurIntensity?: number
  blurReductionFactor?: number
  tint?: 'default' | 'light' | 'dark' | 'extraLight' | 'regular' | 'prominent'
  pressFeedbackEnabled?: boolean
}

export default function SafeLiquidGlass({
  children,
  style,
  interactive = true,
  effect = 'regular',
  tintColor,
  colorScheme,
  blurIntensity = 10,
  blurReductionFactor = 4,
  tint,
  pressFeedbackEnabled,
  ...props
}: SafeLiquidGlassProps) {
  const systemColorScheme = useColorScheme()
  const effectiveColorScheme =
    colorScheme === 'system' || !colorScheme ? systemColorScheme : colorScheme
  const isDark = effectiveColorScheme === 'dark'
  const blurTint = tint || (isDark ? 'dark' : 'light')
  const isExpoGo = Constants.appOwnership === 'expo'

  if (Platform.OS === 'ios' && nativeLiquidGlassAvailable && NativeLiquidGlassView) {
    const flattenedStyle = StyleSheet.flatten(style) || {}
    const cornerRadius =
      typeof flattenedStyle.borderRadius === 'number' ? flattenedStyle.borderRadius : undefined
    const nativeTintColor =
      Platform.OS === 'android' && tintColor != null ? processColor(tintColor) : tintColor

    return (
      <NativeLiquidGlassView
        style={style}
        blurIntensity={blurIntensity}
        blurReductionFactor={blurReductionFactor}
        tint={tint}
        interactive={interactive}
        effect={effect}
        tintColor={nativeTintColor}
        cornerRadius={cornerRadius}
        pressFeedbackEnabled={pressFeedbackEnabled}
        {...props}
      >
        {children}
      </NativeLiquidGlassView>
    )
  }

  if (Platform.OS === 'ios') {
    const canUseExpoGlass = isExpoGo && isGlassEffectAPIAvailable()
    const expoGlassTintColor = typeof tintColor === 'string' ? tintColor : undefined
    const expoGlassColorScheme =
      effectiveColorScheme === 'dark' ? 'dark' : effectiveColorScheme === 'light' ? 'light' : 'auto'

    if (canUseExpoGlass) {
      return (
        <ExpoGlassView
          style={[style, { overflow: 'hidden' }]}
          glassEffectStyle={effect}
          tintColor={expoGlassTintColor}
          isInteractive={interactive}
          colorScheme={expoGlassColorScheme}
          {...props}
        >
          {children}
        </ExpoGlassView>
      )
    }

    return (
      <BlurView
        intensity={blurIntensity * 2}
        tint={blurTint}
        style={[style, { overflow: 'hidden' }]}
        shouldRasterizeIOS={true}
        {...props}
      >
        {children}
      </BlurView>
    )
  }

  const glassBg =
    tint === 'light' || !isDark ? 'rgba(255, 255, 255, 0.85)' : 'rgba(20, 20, 20, 0.85)'
  const glassBorder =
    tint === 'light' || !isDark ? 'rgba(255, 255, 255, 0.3)' : 'rgba(255, 255, 255, 0.08)'

  return (
    <View
      style={[
        {
          backgroundColor: glassBg,
          borderColor: glassBorder,
          borderWidth: 1,
          overflow: 'hidden',
        },
        style,
      ]}
      {...props}
    >
      {children}
    </View>
  )
}

export function isNativeLiquidGlassAvailable(): boolean {
  return Platform.OS === 'ios' && nativeLiquidGlassAvailable
}

export function isRealBlurAvailable(): boolean {
  return Platform.OS === 'ios' || Platform.OS === 'android'
}

export const LiquidGlassPresets = {
  subtle: {
    blurIntensity: 5,
    blurReductionFactor: 6,
  },
  default: {
    blurIntensity: 10,
    blurReductionFactor: 4,
  },
  medium: {
    blurIntensity: 15,
    blurReductionFactor: 4,
  },
  frosted: {
    blurIntensity: 25,
    blurReductionFactor: 3,
  },
  samsungOneUI: {
    blurIntensity: 8,
    blurReductionFactor: 5,
    tint: 'default' as const,
  },
  iOSStyle: {
    blurIntensity: 12,
    blurReductionFactor: 4,
  },
} as const
