import React, { useMemo } from 'react';
import { Platform, StyleSheet, View } from 'react-native';
import type { NativeChatAppearance, NativeChatRow } from '../chat/types';

let NativeHomeListView: React.ComponentType<any> | null = null;

try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const expoModulesCore = require('expo-modules-core');
  if (typeof expoModulesCore.requireNativeViewManager === 'function') {
    NativeHomeListView = expoModulesCore.requireNativeViewManager('ChatNativeHomeList');
  }
} catch {
  NativeHomeListView = null;
}

export interface NativeHomeListRow {
  chatId: string;
  name: string;
  preview: string;
  friendId?: string;
  chatType?: 'dm' | 'group' | 'channel';
  avatarUri?: string;
  timeLabel?: string;
  unreadCount?: number;
  markedUnread?: boolean;
  muted?: boolean;
  pinned?: boolean;
  isTyping?: boolean;
  isOnline?: boolean;
  avatarFallback?: string;
  previewRows?: NativeChatRow[];
}

interface NativeHomeListSurfaceProps {
  rows: NativeHomeListRow[];
  refreshing?: boolean;
  isDark?: boolean;
  previewAppearance?: NativeChatAppearance;
  contentTopInset?: number;
  contentBottomInset?: number;
  onNativeEvent?: (event: { nativeEvent: Record<string, unknown> }) => void;
}

export const isNativeHomeListAvailable = (): boolean => {
  return (Platform.OS === 'ios' || Platform.OS === 'android') && !!NativeHomeListView;
};

export default function NativeHomeListSurface({
  rows,
  refreshing = false,
  isDark = false,
  previewAppearance,
  contentTopInset = 0,
  contentBottomInset = 0,
  onNativeEvent,
}: NativeHomeListSurfaceProps) {
  const canRender = useMemo(() => isNativeHomeListAvailable(), []);
  if (!canRender || !NativeHomeListView) {
    return <View style={styles.fallback} />;
  }

  const NativeComponent = NativeHomeListView;
  return (
    <NativeComponent
      style={styles.fill}
      rows={rows}
      refreshing={refreshing}
      isDark={isDark}
      previewAppearance={previewAppearance}
      contentTopInset={contentTopInset}
      contentBottomInset={contentBottomInset}
      onNativeEvent={onNativeEvent}
    />
  );
}

const styles = StyleSheet.create({
  fill: {
    flex: 1,
    backgroundColor: 'transparent',
  },
  fallback: {
    flex: 1,
    backgroundColor: 'transparent',
  },
});
