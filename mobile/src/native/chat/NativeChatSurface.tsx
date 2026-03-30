import React, { forwardRef, useImperativeHandle, useMemo } from 'react';
import { StyleSheet, View } from 'react-native';

import { getNativeChatListModule, isNativeChatEnabled } from './runtime';
import type {
  NativeChatAppearance,
  NativeChatRow,
  NativeReactionFxPayload,
  NativeSendTransitionPayload,
} from './types';

let NativeChatListView: React.ComponentType<any> | null = null;

try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const expoModulesCore = require('expo-modules-core');
  if (typeof expoModulesCore.requireNativeViewManager === 'function') {
    // Expo view managers are resolved by module name (Name("ChatNativeList")).
    NativeChatListView = expoModulesCore.requireNativeViewManager('ChatNativeList');
  }
} catch {
  NativeChatListView = null;
}

export interface NativeChatSurfaceRef {
  scrollToBottom: (animated?: boolean) => Promise<void>;
  scrollToMessage: (messageId: string, animated?: boolean, viewPosition?: number) => Promise<void>;
  applyTransactions: (transactions: Record<string, unknown>[]) => Promise<void>;
  startSendTransition: (payload: NativeSendTransitionPayload) => Promise<void>;
  playReactionFx: (payload: NativeReactionFxPayload) => Promise<void>;
}

interface NativeChatSurfaceProps {
  surfaceId: string;
  rows: NativeChatRow[];
  forceRender?: boolean;
  engineSurfaceId?: string;
  chatId?: string;
  myUserId?: string;
  peerUserId?: string;
  peerAgentId?: string;
  peerDisplayName?: string;
  statusAuthorityEnabled?: boolean;
  appearance?: NativeChatAppearance;
  contentPaddingTop?: number;
  contentPaddingBottom?: number;
  voicePlayback?: {
    messageId: string | null;
    isPlaying: boolean;
    progress: number;
  };
  /** Enable native input bar (text field + send button). When true, keyboard is handled natively. */
  inputBarEnabled?: boolean;
  /** Placeholder text for the native input bar. */
  inputPlaceholder?: string;
  /** When true, send taps append/update outgoing rows natively without requiring JS row updates. */
  nativeSendEnabled?: boolean;
  /** Show a floating debug panel with animation tuning sliders. */
  debugAnimationPanel?: boolean;
  onViewportChanged?: (event: { nativeEvent: Record<string, unknown> }) => void;
  onNativeEvent?: (event: { nativeEvent: Record<string, unknown> }) => void;
  onNativeError?: (error: unknown, context: string) => void;
  /** Testing/lab only: Strategy to use for cell hold animation. */
  holdStrategy?: string;
}

export const NativeChatSurface = forwardRef<NativeChatSurfaceRef, NativeChatSurfaceProps>(
  ({ surfaceId, rows, forceRender, engineSurfaceId, chatId, myUserId, peerUserId, peerAgentId, peerDisplayName, statusAuthorityEnabled, appearance, contentPaddingTop, contentPaddingBottom, voicePlayback, inputBarEnabled, inputPlaceholder, nativeSendEnabled, debugAnimationPanel, holdStrategy, onViewportChanged, onNativeEvent, onNativeError }, ref) => {
    const nativeListModule = useMemo(() => getNativeChatListModule(), []);
    const debugNativeEvents = __DEV__ && (globalThis as any).__VIBE_NATIVE_CHAT_DEBUG === true;
    const contentPaddingBottomProp = inputBarEnabled ? undefined : contentPaddingBottom;
    const reportNativeError = (error: unknown, context: string) => {
      console.error(`[NativeChatSurface] ${context} failed`, error);
      onNativeError?.(error, context);
    };

    useImperativeHandle(ref, () => ({
      scrollToBottom: async (animated = true) => {
        if (!nativeListModule?.scrollToBottom) return;
        try {
          await nativeListModule.scrollToBottom(surfaceId, animated);
        } catch (error) {
          reportNativeError(error, 'scrollToBottom');
        }
      },
      scrollToMessage: async (messageId: string, animated = true, viewPosition = 0.5) => {
        if (!nativeListModule?.scrollToMessage) return;
        try {
          await nativeListModule.scrollToMessage(surfaceId, messageId, animated, viewPosition);
        } catch (error) {
          reportNativeError(error, 'scrollToMessage');
        }
      },
      applyTransactions: async (transactions) => {
        if (!nativeListModule?.applyTransactions) return;
        try {
          await nativeListModule.applyTransactions(surfaceId, transactions);
        } catch (error) {
          reportNativeError(error, 'applyTransactions');
        }
      },
      startSendTransition: async (payload: NativeSendTransitionPayload) => {
        if (!nativeListModule?.startSendTransition) return;
        try {
          await nativeListModule.startSendTransition(surfaceId, payload);
        } catch (error) {
          reportNativeError(error, 'startSendTransition');
        }
      },
      playReactionFx: async (payload: NativeReactionFxPayload) => {
        if (!nativeListModule?.playReactionFx) return;
        try {
          await nativeListModule.playReactionFx(surfaceId, payload);
        } catch (error) {
          reportNativeError(error, 'playReactionFx');
        }
      },
    }), [nativeListModule, surfaceId, onNativeError]);

    if ((!forceRender && !isNativeChatEnabled()) || !NativeChatListView) {
      return <View style={styles.fallback} />;
    }

    return (
      <NativeChatListView
        style={styles.fill}
        surfaceId={surfaceId}
        rows={rows}
        engineSurfaceId={engineSurfaceId}
        chatId={chatId}
        myUserId={myUserId}
        peerUserId={peerUserId}
        peerAgentId={peerAgentId}
        peerDisplayName={peerDisplayName}
        statusAuthorityEnabled={statusAuthorityEnabled}
        appearance={appearance}
        contentPaddingTop={contentPaddingTop}
        contentPaddingBottom={contentPaddingBottomProp}
        voicePlayback={voicePlayback}
        inputBarEnabled={inputBarEnabled}
        inputPlaceholder={inputPlaceholder}
        nativeSendEnabled={nativeSendEnabled}
        debugAnimationPanel={debugAnimationPanel}
        holdStrategy={holdStrategy}
        onViewportChanged={(event: any) => {
          // Log once to verify event bridge works
          if (debugNativeEvents && onViewportChanged && !(onViewportChanged as any)._logged) {
            console.log('[NativeChatSurface] onViewportChanged first event received');
            (onViewportChanged as any)._logged = true;
          }
          try {
            onViewportChanged?.(event);
          } catch (error) {
            reportNativeError(error, 'onViewportChanged');
          }
        }}
        onNativeEvent={(event: any) => {
          if (debugNativeEvents) {
            console.log('[NativeChatSurface] onNativeEvent raw:', JSON.stringify(event?.nativeEvent ?? event));
          }
          try {
            onNativeEvent?.(event);
          } catch (error) {
            console.error('[NativeChatSurface] onNativeEvent handler error:', error);
            reportNativeError(error, 'onNativeEvent');
          }
        }}
      />
    );
  },
);

NativeChatSurface.displayName = 'NativeChatSurface';

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
