import React from 'react'
import {
  Image,
  Platform,
  StyleSheet,
  Text,
  View,
  type StyleProp,
  type ViewProps,
  type ViewStyle,
} from 'react-native'
import Constants from 'expo-constants'
import { requireNativeViewManager } from 'expo-modules-core'

interface NativeProfileAvatarViewProps extends ViewProps {
  imageUri?: string
  fallbackText?: string
  collapsed?: boolean
  expandedSize?: number
  collapsedSize?: number
  expandedTopInset?: number
  collapsedTopInset?: number
  islandCoverColor?: string
}

let NativeProfileAvatarView: React.ComponentType<NativeProfileAvatarViewProps> | null = null
let nativeProfileAvatarAvailable = false

try {
  const isExpoGo = Constants.appOwnership === 'expo'
  if (Platform.OS === 'ios' && !isExpoGo) {
    NativeProfileAvatarView = requireNativeViewManager<NativeProfileAvatarViewProps>('NativeProfileAvatar')
    nativeProfileAvatarAvailable = !!NativeProfileAvatarView
  }
} catch {
  nativeProfileAvatarAvailable = false
}

export function isNativeProfileAvatarAvailable(): boolean {
  return Platform.OS === 'ios' && nativeProfileAvatarAvailable
}

interface ProfileAvatarProps extends ViewProps {
  imageUri?: string
  fallbackText?: string
  collapsed?: boolean
  expandedSize?: number
  collapsedSize?: number
  expandedTopInset?: number
  collapsedTopInset?: number
  islandCoverColor?: string
  style?: StyleProp<ViewStyle>
}

export default function NativeProfileAvatar({
  imageUri,
  fallbackText,
  collapsed,
  expandedSize,
  collapsedSize,
  expandedTopInset,
  collapsedTopInset,
  islandCoverColor,
  style,
  ...props
}: ProfileAvatarProps) {
  if (Platform.OS === 'ios' && nativeProfileAvatarAvailable && NativeProfileAvatarView) {
    const Component = NativeProfileAvatarView
    return (
      <Component
        style={style}
        imageUri={imageUri}
        fallbackText={fallbackText}
        collapsed={collapsed}
        expandedSize={expandedSize}
        collapsedSize={collapsedSize}
        expandedTopInset={expandedTopInset}
        collapsedTopInset={collapsedTopInset}
        islandCoverColor={islandCoverColor}
        {...props}
      />
    )
  }

  const initial = (fallbackText?.trim()?.[0] || 'U').toUpperCase()
  return (
    <View style={[styles.fallback, style]} {...props}>
      {imageUri ? (
        <Image source={{ uri: imageUri }} style={styles.image} />
      ) : (
        <Text style={styles.text}>{initial}</Text>
      )}
    </View>
  )
}

const styles = StyleSheet.create({
  fallback: {
    overflow: 'hidden',
    borderRadius: 999,
    backgroundColor: 'rgba(255,255,255,0.14)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  image: {
    width: '100%',
    height: '100%',
  },
  text: {
    color: '#fff',
    fontSize: 34,
    fontWeight: '700',
  },
})
