import React from 'react';
import { StyleSheet, View } from 'react-native';

import { isNativeChatEnabled } from './runtime';
import type {
  NativeChatAgentConfig,
  NativeChatAppearance,
  NativeChatGroupMember,
  NativeChatRow,
} from './types';

let NativeChatProfileView: React.ComponentType<any> | null = null;

try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const expoModulesCore = require('expo-modules-core');
  if (typeof expoModulesCore.requireNativeViewManager === 'function') {
    NativeChatProfileView = expoModulesCore.requireNativeViewManager('ChatNativeProfile');
  }
} catch {
  NativeChatProfileView = null;
}

interface NativeChatProfileSurfaceProps {
  surfaceId: string;
  rows: NativeChatRow[];
  forceRender?: boolean;
  engineSurfaceId?: string;
  chatId?: string;
  myUserId?: string;
  peerUserId?: string;
  statusAuthorityEnabled?: boolean;
  appearance?: NativeChatAppearance;
  headerTitle?: string;
  headerSubtitle?: string;
  profileName?: string;
  profileHandle?: string;
  profileBio?: string;
  avatarUri?: string;
  isOnline?: boolean;
  isChatMuted?: boolean;
  isGroupOrChannel?: boolean;
  groupMembers?: NativeChatGroupMember[];
  groupMemberCount?: number;
  agentConfig?: NativeChatAgentConfig | null;
  page?: 'profile' | 'agent';
  onViewportChanged?: (event: { nativeEvent: Record<string, unknown> }) => void;
  onNativeEvent?: (event: { nativeEvent: Record<string, unknown> }) => void;
  onNativeError?: (error: unknown, context: string) => void;
}

export function NativeChatProfileSurface({
  surfaceId,
  rows,
  forceRender,
  engineSurfaceId,
  chatId,
  myUserId,
  peerUserId,
  statusAuthorityEnabled,
  appearance,
  headerTitle,
  headerSubtitle,
  profileName,
  profileHandle,
  profileBio,
  avatarUri,
  isOnline,
  isChatMuted,
  isGroupOrChannel,
  groupMembers,
  groupMemberCount,
  agentConfig,
  page,
  onViewportChanged,
  onNativeEvent,
  onNativeError,
}: NativeChatProfileSurfaceProps) {
  const reportNativeError = (error: unknown, context: string) => {
    console.error(`[NativeChatProfileSurface] ${context} failed`, error);
    onNativeError?.(error, context);
  };

  if ((!forceRender && !isNativeChatEnabled()) || !NativeChatProfileView) {
    return <View style={styles.fallback} />;
  }

  return (
    <NativeChatProfileView
      style={styles.fill}
      profileOnly
      surfaceId={surfaceId}
      rows={rows}
      engineSurfaceId={engineSurfaceId}
      chatId={chatId}
      myUserId={myUserId}
      peerUserId={peerUserId}
      statusAuthorityEnabled={statusAuthorityEnabled}
      appearance={appearance}
      headerTitle={headerTitle}
      headerSubtitle={headerSubtitle}
      profileName={profileName}
      profileHandle={profileHandle}
      profileBio={profileBio}
      avatarUri={avatarUri}
      isOnline={isOnline}
      isChatMuted={isChatMuted}
      isGroupOrChannel={isGroupOrChannel}
      groupMembers={groupMembers}
      groupMemberCount={groupMemberCount}
      agentConfig={agentConfig}
      page={page}
      onViewportChanged={(event: any) => {
        try {
          onViewportChanged?.(event);
        } catch (error) {
          reportNativeError(error, 'onViewportChanged');
        }
      }}
      onNativeEvent={(event: any) => {
        try {
          onNativeEvent?.(event);
        } catch (error) {
          reportNativeError(error, 'onNativeEvent');
        }
      }}
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
