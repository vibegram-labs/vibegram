import React, { useMemo } from 'react';
import { StyleProp, StyleSheet, ViewStyle } from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { AvatarBookmarkIcon, AvatarPersonIcon } from '../Icons';
import { AvatarVariant, getAvatarGradient } from '../../lib/avatar-colors';

interface DefaultAvatarProps {
  seed?: string | null;
  theme: string;
  size: number;
  variant?: AvatarVariant;
  style?: StyleProp<ViewStyle>;
  iconScale?: number;
}

export default function DefaultAvatar({
  seed,
  theme,
  size,
  variant = 'user',
  style,
  iconScale = 0.42,
}: DefaultAvatarProps) {
  const gradient = useMemo(
    () => getAvatarGradient(seed, theme, variant),
    [seed, theme, variant]
  );
  const iconSize = Math.max(18, Math.round(size * iconScale));
  const Icon = variant === 'saved' ? AvatarBookmarkIcon : AvatarPersonIcon;

  return (
    <LinearGradient
      colors={gradient}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={[
        styles.container,
        { width: size, height: size, borderRadius: size / 2 },
        style,
      ]}
    >
      <Icon size={iconSize} color="#fff" />
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
});
