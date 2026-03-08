import React, { forwardRef, useImperativeHandle, useMemo } from 'react';
import { Platform, StyleSheet, View } from 'react-native';

import { getNativeChatMainModule, isNativeChatEnabled } from './runtime';
import type {
  NativeChatAgentConfig,
  NativeChatAppearance,
  NativeChatGroupMember,
  NativeChatHeaderMode,
  NativeChatRow,
  NativeReactionFxPayload,
  NativeSendTransitionPayload,
} from './types';

let NativeChatMainView: React.ComponentType<any> | null = null;

try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const expoModulesCore = require('expo-modules-core');
  if (typeof expoModulesCore.requireNativeViewManager === 'function') {
    NativeChatMainView = expoModulesCore.requireNativeViewManager('ChatNativeMain');
  }
} catch {
  NativeChatMainView = null;
}

export type NativeChatMainPage = 'chat' | 'profile';

export interface NativeChatMainSurfaceRef {
  setPage: (page: NativeChatMainPage, animated?: boolean) => Promise<void>;
  scrollToBottom: (animated?: boolean) => Promise<void>;
  scrollToMessage: (messageId: string, animated?: boolean, viewPosition?: number) => Promise<void>;
  applyTransactions: (transactions: Record<string, unknown>[]) => Promise<void>;
  startSendTransition: (payload: NativeSendTransitionPayload) => Promise<void>;
  playReactionFx: (payload: NativeReactionFxPayload) => Promise<void>;
}

interface NativeChatMainSurfaceProps {
  surfaceId: string;
  rows: NativeChatRow[];
  forceRender?: boolean;
  engineSurfaceId?: string;
  chatId?: string;
  myUserId?: string;
  peerUserId?: string;
  statusAuthorityEnabled?: boolean;
  appearance?: NativeChatAppearance;
  contentPaddingTop?: number;
  contentPaddingBottom?: number;
  voicePlayback?: {
    messageId: string | null;
    isPlaying: boolean;
    progress: number;
  };
  inputBarEnabled?: boolean;
  inputPlaceholder?: string;
  nativeSendEnabled?: boolean;
  debugAnimationPanel?: boolean;
  headerMode?: NativeChatHeaderMode;
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
  canManageAgentConfig?: boolean;
  agentConfig?: NativeChatAgentConfig | null;
  page?: NativeChatMainPage;
  onViewportChanged?: (event: { nativeEvent: Record<string, unknown> }) => void;
  onNativeEvent?: (event: { nativeEvent: Record<string, unknown> }) => void;
  onNativeError?: (error: unknown, context: string) => void;
}

export const NativeChatMainSurface = forwardRef<NativeChatMainSurfaceRef, NativeChatMainSurfaceProps>(
  ({
    surfaceId,
    rows,
    forceRender,
    engineSurfaceId,
    chatId,
    myUserId,
    peerUserId,
    statusAuthorityEnabled,
    appearance,
    contentPaddingTop,
    contentPaddingBottom,
    voicePlayback,
    inputBarEnabled,
    inputPlaceholder,
    nativeSendEnabled,
    debugAnimationPanel,
    headerMode,
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
    canManageAgentConfig,
    agentConfig,
    page,
    onViewportChanged,
    onNativeEvent,
    onNativeError,
  }, ref) => {
    const nativeMainModule = useMemo(() => getNativeChatMainModule(), []);
    const normalizedContentPaddingTop =
      typeof contentPaddingTop === 'number' && Number.isFinite(contentPaddingTop)
        ? contentPaddingTop
        : undefined;
    const normalizedContentPaddingBottom =
      typeof contentPaddingBottom === 'number' && Number.isFinite(contentPaddingBottom)
        ? contentPaddingBottom
        : undefined;
    // Android ChatMainView currently crashes while applying this prop in some builds.
    // Keep the list stable by skipping only this prop on Android.
    const contentPaddingBottomProp =
      Platform.OS === 'android' ? undefined : normalizedContentPaddingBottom;
    const reportNativeError = (error: unknown, context: string) => {
      console.error(`[NativeChatMainSurface] ${context} failed`, error);
      onNativeError?.(error, context);
    };

    useImperativeHandle(
      ref,
      () => ({
        setPage: async (nextPage, animated = true) => {
          if (!nativeMainModule?.setPage) return;
          try {
            await nativeMainModule.setPage(surfaceId, nextPage, animated);
          } catch (error) {
            reportNativeError(error, 'setPage');
          }
        },
        scrollToBottom: async (animated = true) => {
          if (!nativeMainModule?.scrollToBottom) return;
          try {
            await nativeMainModule.scrollToBottom(surfaceId, animated);
          } catch (error) {
            reportNativeError(error, 'scrollToBottom');
          }
        },
        scrollToMessage: async (messageId: string, animated = true, viewPosition = 0.5) => {
          if (!nativeMainModule?.scrollToMessage) return;
          try {
            await nativeMainModule.scrollToMessage(surfaceId, messageId, animated, viewPosition);
          } catch (error) {
            reportNativeError(error, 'scrollToMessage');
          }
        },
        applyTransactions: async (transactions) => {
          if (!nativeMainModule?.applyTransactions) return;
          try {
            await nativeMainModule.applyTransactions(surfaceId, transactions);
          } catch (error) {
            reportNativeError(error, 'applyTransactions');
          }
        },
        startSendTransition: async (payload) => {
          if (!nativeMainModule?.startSendTransition) return;
          try {
            await nativeMainModule.startSendTransition(surfaceId, payload);
          } catch (error) {
            reportNativeError(error, 'startSendTransition');
          }
        },
        playReactionFx: async (payload) => {
          if (!nativeMainModule?.playReactionFx) return;
          try {
            await nativeMainModule.playReactionFx(surfaceId, payload);
          } catch (error) {
            reportNativeError(error, 'playReactionFx');
          }
        },
      }),
      [nativeMainModule, onNativeError, surfaceId],
    );

    if ((!forceRender && !isNativeChatEnabled()) || !NativeChatMainView) {
      return <View style={styles.fallback} />;
    }

    return (
      <NativeChatMainView
        style={styles.fill}
        surfaceId={surfaceId}
        rows={rows}
        engineSurfaceId={engineSurfaceId}
        chatId={chatId}
        myUserId={myUserId}
        peerUserId={peerUserId}
        statusAuthorityEnabled={statusAuthorityEnabled}
        appearance={appearance}
        contentPaddingTop={normalizedContentPaddingTop}
        contentPaddingBottom={contentPaddingBottomProp}
        voicePlayback={voicePlayback}
        inputBarEnabled={inputBarEnabled}
        inputPlaceholder={inputPlaceholder}
        nativeSendEnabled={nativeSendEnabled}
        debugAnimationPanel={debugAnimationPanel}
        headerMode={headerMode}
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
        canManageAgentConfig={canManageAgentConfig}
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
  },
);

NativeChatMainSurface.displayName = 'NativeChatMainSurface';

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
