/**
 * StoryAvatar - Avatar with story ring indicator
 * Features:
 * - Gradient ring for unseen stories
 * - Gray ring for seen stories
 * - Plus button for adding stories (self)
 * - Press to view stories
 * - Long press for options
 */

import React from 'react'
import {
    View,
    Text,
    StyleSheet,
    Image,
    Pressable
} from 'react-native'
import Animated, {
    useSharedValue,
    useAnimatedStyle,
    withSpring,
    interpolate,
    Extrapolate,
} from 'react-native-reanimated'
import { LinearGradient } from 'expo-linear-gradient'
import * as Haptics from 'expo-haptics'
import { PlusCircleVibeIcon } from '../Icons'
import DefaultAvatar from '../avatar/DefaultAvatar'

import { useThemeStore } from '../../lib/stores/theme-store'

interface StoryAvatarProps {
    // User info
    userId: string
    username?: string
    profileImage?: string | null

    // Story state
    hasStory?: boolean
    hasUnseenStory?: boolean
    storyCount?: number

    // Display options
    size?: 'small' | 'medium' | 'large'
    showName?: boolean
    showAddButton?: boolean  // For self avatar
    isOwnAvatar?: boolean

    // Actions
    onPress?: () => void
    onAddPress?: () => void
    onLongPress?: () => void
    isCompact?: boolean
    isOnline?: boolean
}

const SIZES = {
    small: { avatar: 44, ring: 48, border: 1.5, plus: 14 },
    medium: { avatar: 56, ring: 60, border: 1.6, plus: 16 },
    large: { avatar: 72, ring: 77, border: 1.8, plus: 18 }
}

export default function StoryAvatar({
    userId,
    username,
    profileImage,
    hasStory = false,
    hasUnseenStory = false,
    storyCount = 0,
    size = 'medium',
    showName = false,
    showAddButton = false,
    isOwnAvatar = false,
    onPress,
    onAddPress,
    onLongPress,
    isCompact,
    isOnline = false,
}: StoryAvatarProps) {
    const { colors, effectiveTheme } = useThemeStore()
    const dimensions = SIZES[size]

    // Scale animation on press
    const scale = useSharedValue(1)

    const handlePressIn = () => {
        scale.value = withSpring(0.95)
    }

    const handlePressOut = () => {
        scale.value = withSpring(1)
    }

    const handlePress = () => {
        if (hasStory && onPress) {
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light)
            onPress()
        } else if (isOwnAvatar && showAddButton && onAddPress) {
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light)
            onAddPress()
        }
    }

    const handleLongPress = () => {
        if (onLongPress) {
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)
            onLongPress()
        }
    }

    const animatedStyle = useAnimatedStyle(() => {
        const baseScale = scale.value;
        return {
            transform: [{ scale: baseScale }],
            opacity: 1
        }
    })

    // Ring colors - gradient for unseen, gray for seen
    const unseenGradient: readonly [string, string, ...string[]] = ['#FF6B6B', '#F857A6', '#FF5858', '#FFBD59', '#FF6B6B']
    const seenRingColor = colors.textTertiary + '60'

    const renderRing = () => {
        if (!hasStory) return null

        if (hasUnseenStory) {
            return (
                <LinearGradient
                    colors={unseenGradient}
                    style={[
                        styles.ring,
                        {
                            width: dimensions.ring,
                            height: dimensions.ring,
                            borderRadius: dimensions.ring / 2
                        }
                    ]}
                    start={{ x: 0, y: 0 }}
                    end={{ x: 1, y: 1 }}
                />
            )
        }

        // Seen ring (gray)
        return (
            <View
                style={[
                    styles.ring,
                    styles.seenRing,
                    {
                        width: dimensions.ring,
                        height: dimensions.ring,
                        borderRadius: dimensions.ring / 2,
                        borderColor: seenRingColor,
                        borderWidth: dimensions.border
                    }
                ]}
            />
        )
    }

    return (
        <Animated.View style={[styles.container, animatedStyle]}>
            <Pressable
                onPressIn={handlePressIn}
                onPressOut={handlePressOut}
                onPress={handlePress}
                onLongPress={handleLongPress}
                delayLongPress={300}
            >
                <View
                    style={[
                        styles.avatarWrapper,
                        {
                            width: dimensions.ring,
                            height: dimensions.ring
                        }
                    ]}
                >
                    {/* Story Ring */}
                    {renderRing()}

                    {/* Avatar */}
                    <View
                        style={[
                            styles.avatarContainer,
                            {
                                width: dimensions.avatar,
                                height: dimensions.avatar,
                                borderRadius: dimensions.avatar / 2,
                                borderWidth: hasStory ? dimensions.border : 0,
                                borderColor: colors.background
                            }
                        ]}
                    >
                        {profileImage ? (
                            <Image
                                source={{ uri: profileImage }}
                                style={[
                                    styles.avatar,
                                    {
                                        width: dimensions.avatar - (hasStory ? dimensions.border * 2 : 0),
                                        height: dimensions.avatar - (hasStory ? dimensions.border * 2 : 0),
                                        borderRadius: (dimensions.avatar - (hasStory ? dimensions.border * 2 : 0)) / 2
                                    }
                                ]}
                            />
                        ) : (
                            <DefaultAvatar
                                seed={userId || username}
                                theme={effectiveTheme}
                                size={dimensions.avatar - (hasStory ? dimensions.border * 2 : 0)}
                                style={styles.avatarPlaceholder}
                            />
                        )}
                    </View>

                    {/* Add Button for own avatar */}
                    {isOwnAvatar && showAddButton && (
                        <Pressable
                            onPress={() => onAddPress?.()}
                            style={[
                                styles.addButton,
                                {
                                    width: dimensions.plus + 8,
                                    height: dimensions.plus + 8,
                                    borderRadius: (dimensions.plus + 8) / 2,
                                    backgroundColor: colors.accent,
                                    borderColor: colors.background
                                }
                            ]}
                        >
                            <PlusCircleVibeIcon size={dimensions.plus + 6} color="#fff" />
                        </Pressable>
                    )}

                    {/* Online indicator */}
                    {isOnline && (
                        <View style={[
                            styles.onlineIndicator,
                            { backgroundColor: '#34d399', borderColor: colors.background }
                        ]} />
                    )}
                </View>

                {/* Username */}
                {showName && username && (
                    <Text
                        style={[
                            styles.username,
                            {
                                color: colors.text,
                                maxWidth: dimensions.ring + 20
                            }
                        ]}
                        numberOfLines={1}
                    >
                        {isOwnAvatar ? 'Your Story' : username}
                    </Text>
                )}
            </Pressable>
        </Animated.View>
    )
}

const styles = StyleSheet.create({
    container: {
        alignItems: 'center',
    },
    avatarWrapper: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    ring: {
        position: 'absolute',
    },
    seenRing: {
        backgroundColor: 'transparent',
    },
    avatarContainer: {
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
    },
    avatar: {
        backgroundColor: '#333',
    },
    avatarPlaceholder: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    addButton: {
        position: 'absolute',
        bottom: 0,
        right: 0,
        alignItems: 'center',
        justifyContent: 'center',
        borderWidth: 2,
    },
    username: {
        fontSize: 12,
        fontWeight: '500',
        marginTop: 6,
        textAlign: 'center',
    },
    onlineIndicator: {
        position: 'absolute',
        bottom: 2,
        right: 2,
        width: 12,
        height: 12,
        borderRadius: 6,
        borderWidth: 2,
        zIndex: 10,
    },
})
