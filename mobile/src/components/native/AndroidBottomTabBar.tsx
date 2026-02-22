import React, { useEffect, useMemo, useState } from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'

import { theme } from '../../lib/theme'
import Animated, {
  interpolate,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
  withTiming,
} from 'react-native-reanimated'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import type { TabConfig } from './NativeTabBar'

export interface AndroidBottomTabBarProps {
  currentIndex: number
  onIndexChange: (index: number) => void
  tabs: TabConfig[]
  activeTintColor?: string
  inactiveTintColor?: string
  isDark?: boolean
  labeled?: boolean
  onVibePress?: () => void
}

interface AndroidTabItemProps {
  tab: TabConfig
  focused: boolean
  color: string
  labeled: boolean
  onPress: () => void
  onPressIn: () => void
  onPressOut: () => void
}

function isVibeTab(tab: TabConfig): boolean {
  return tab.key.trim().toLowerCase() === 'vibe' || tab.preventsDefault === true
}

function withAlpha(color: string, alpha: number): string {
  if (!color.startsWith('#')) return color
  let hex = color.slice(1)
  if (hex.length === 3) {
    hex = hex
      .split('')
      .map((c) => c + c)
      .join('')
  }
  if (hex.length !== 6) return color
  const a = Math.round(Math.max(0, Math.min(1, alpha)) * 255)
    .toString(16)
    .padStart(2, '0')
  return `#${hex}${a}`
}

function AndroidTabItem({
  tab,
  focused,
  color,
  labeled,
  onPress,
  onPressIn,
  onPressOut,
}: AndroidTabItemProps) {
  const pressProgress = useSharedValue(0)

  const animatedContentStyle = useAnimatedStyle(() => {
    const scale = interpolate(pressProgress.value, [0, 1], [1, 0.965])
    const translateY = interpolate(pressProgress.value, [0, 1], [0, 0.5])
    return {
      transform: [{ scale }, { translateY }],
    }
  })

  return (
    <Pressable
      onPress={onPress}
      onPressIn={() => {
        pressProgress.value = withTiming(1, { duration: 90 })
        onPressIn()
      }}
      onPressOut={() => {
        pressProgress.value = withSpring(0, { damping: 16, stiffness: 220 })
        onPressOut()
      }}
      style={styles.tabButton}
    >
      <Animated.View style={[styles.tabInner, animatedContentStyle]}>
        <View style={styles.iconWrap}>
          {tab.renderIcon ? tab.renderIcon({ focused, color, size: isVibeTab(tab) ? 21 : 20 }) : null}
        </View>
        {labeled && (
          <Text
            numberOfLines={1}
            ellipsizeMode="clip"
            style={[styles.label, isVibeTab(tab) && styles.vibeLabel, { color }]}
          >
            {tab.title}
          </Text>
        )}
      </Animated.View>
    </Pressable>
  )
}

export default function AndroidBottomTabBar({
  currentIndex,
  onIndexChange,
  tabs,
  activeTintColor = '#007AFF',
  inactiveTintColor = '#8E8E93',
  isDark = false,
  labeled = true,
  onVibePress,
}: AndroidBottomTabBarProps) {
  const insets = useSafeAreaInsets()
  const palette = isDark ? theme.dark : theme.light
  const surfaceBg = withAlpha(palette.bg.primary, isDark ? 0.985 : 0.975)
  const activePillBg = isDark
    ? withAlpha(palette.text.primary, 0.1)
    : withAlpha(palette.bg.card, 0.96)
  const bottomInsetPadding = Math.max(0, Math.min(insets.bottom, 18))
  const activePillInset = 3
  const rowHorizontalPadding = 6
  const [rowWidth, setRowWidth] = useState(0)
  const [previewIndex, setPreviewIndex] = useState<number | null>(null)

  const tabCount = tabs.length || 1
  const innerTrackWidth = Math.max(0, rowWidth - rowHorizontalPadding * 2)
  const slotWidth = tabCount > 0 ? innerTrackWidth / tabCount : 0
  const activePillWidth = Math.max(0, slotWidth - activePillInset * 2)
  const targetIndex = previewIndex ?? currentIndex
  const clampedTargetIndex = Math.max(0, Math.min(targetIndex, tabCount - 1))

  const indicatorX = useSharedValue(0)

  useEffect(() => {
    const nextX = slotWidth * clampedTargetIndex + rowHorizontalPadding + activePillInset
    indicatorX.value = withSpring(nextX, {
      damping: 20,
      stiffness: 220,
      mass: 0.7,
    })
  }, [clampedTargetIndex, indicatorX, rowHorizontalPadding, slotWidth])

  useEffect(() => {
    setPreviewIndex(null)
  }, [currentIndex])

  const indicatorStyle = useAnimatedStyle(() => ({
    transform: [{ translateX: indicatorX.value }],
  }))

  const itemHandlers = useMemo(
    () =>
      tabs.map((tab, index) => {
        const vibe = isVibeTab(tab)
        return {
          onPress: () => {
            if (vibe) {
              onVibePress?.()
              return
            }
            onIndexChange(index)
          },
          onPressIn: () => setPreviewIndex(index),
          onPressOut: () => setPreviewIndex(null),
        }
      }),
    [onIndexChange, onVibePress, tabs]
  )

  return (
    <View style={[styles.surface, { backgroundColor: surfaceBg }]}>
      <View
        style={[
          styles.row,
          bottomInsetPadding > 0 && {
            paddingBottom: 5 + bottomInsetPadding,
          },
        ]}
        onLayout={(event) => {
          setRowWidth(event.nativeEvent.layout.width)
        }}
      >
        {activePillWidth > 0 && (
          <Animated.View
            pointerEvents="none"
            style={[
              styles.activePill,
              {
                width: activePillWidth,
                backgroundColor: activePillBg,
              },
              indicatorStyle,
            ]}
          />
        )}
        {tabs.map((tab, index) => {
          const focused = currentIndex === index
          const color = focused ? activeTintColor : inactiveTintColor

          return (
            <AndroidTabItem
              key={tab.key}
              tab={tab}
              focused={focused}
              color={color}
              labeled={labeled}
              onPress={itemHandlers[index].onPress}
              onPressIn={itemHandlers[index].onPressIn}
              onPressOut={itemHandlers[index].onPressOut}
            />
          )
        })}
      </View>
    </View>
  )
}

const styles = StyleSheet.create({
  surface: {
    width: '100%',
    borderRadius: 24,
    overflow: 'hidden',
  },
  row: {
    position: 'relative',
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 6,
    paddingTop: 5,
    paddingBottom: 5,
  },
  activePill: {
    position: 'absolute',
    top: 3,
    bottom: 3,
    borderRadius: 18,
  },
  tabButton: {
    flex: 1,
    minWidth: 0,
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: 1,
  },
  tabInner: {
    width: '100%',
    minWidth: 0,
    borderRadius: 18,
    paddingHorizontal: 4,
    paddingVertical: 5,
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconWrap: {
    width: 24,
    height: 20,
    alignItems: 'center',
    justifyContent: 'center',
  },
  label: {
    marginTop: 2,
    width: '100%',
    textAlign: 'center',
    fontSize: 9,
    fontWeight: '700',
    letterSpacing: 0,
  },
  vibeLabel: {
    fontWeight: '800',
  },
})
