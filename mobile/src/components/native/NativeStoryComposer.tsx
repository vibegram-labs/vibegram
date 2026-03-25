import React from 'react'
import {
  Platform,
  StyleSheet,
  View,
  type NativeSyntheticEvent,
  type ViewProps,
} from 'react-native'
import Constants from 'expo-constants'
import { requireNativeViewManager } from 'expo-modules-core'

export type NativeStoryComposerEventPayload =
  | {
      type: 'discard' | 'saveDraft'
    }
  | {
      type: 'aiEdit'
      prompt: string
    }
  | {
      type: 'publish'
      audience: 'everyone' | 'contacts' | 'close_friends'
      allowScreenshots: boolean
      postToProfile: boolean
      duration: 12 | 24 | 48
    }

interface NativeStoryComposerViewProps extends ViewProps {
  mediaUri: string
  mediaType: 'image' | 'video'
  mirrored?: boolean
  onNativeEvent?: (event: NativeSyntheticEvent<NativeStoryComposerEventPayload>) => void
}

let NativeStoryComposerView: React.ComponentType<NativeStoryComposerViewProps> | null = null
let nativeStoryComposerAvailable = false

try {
  const isExpoGo = Constants.appOwnership === 'expo'
  if (Platform.OS === 'ios' && !isExpoGo) {
    NativeStoryComposerView =
      requireNativeViewManager<NativeStoryComposerViewProps>('NativeStoryComposer')
    nativeStoryComposerAvailable = !!NativeStoryComposerView
  }
} catch {
  nativeStoryComposerAvailable = false
}

export function isNativeStoryComposerAvailable(): boolean {
  return Platform.OS === 'ios' && nativeStoryComposerAvailable
}

export default function NativeStoryComposer(props: NativeStoryComposerViewProps) {
  if (!isNativeStoryComposerAvailable() || !NativeStoryComposerView) {
    return <View style={[styles.fill, props.style]} />
  }

  const Component = NativeStoryComposerView
  return <Component {...props} style={[styles.fill, props.style]} />
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
    backgroundColor: 'transparent',
  },
})
