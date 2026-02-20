import React, { forwardRef, useImperativeHandle, useMemo } from 'react';
import { StyleSheet, View } from 'react-native';

import { getNativeChatListModule, isNativeChatEnabled } from './runtime';
import type { NativeChatAppearance, NativeChatRow } from './types';

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
  startSendTransition: (payload: Record<string, unknown>) => Promise<void>;
}

interface NativeChatSurfaceProps {
  surfaceId: string;
  rows: NativeChatRow[];
  appearance?: NativeChatAppearance;
  contentPaddingBottom?: number;
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
}

export const NativeChatSurface = forwardRef<NativeChatSurfaceRef, NativeChatSurfaceProps>(
  ({ surfaceId, rows, appearance, contentPaddingBottom, inputBarEnabled, inputPlaceholder, nativeSendEnabled, debugAnimationPanel, onViewportChanged, onNativeEvent, onNativeError }, ref) => {
    const nativeListModule = useMemo(() => getNativeChatListModule(), []);
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
      startSendTransition: async (payload) => {
        if (!nativeListModule?.startSendTransition) return;
        try {
          await nativeListModule.startSendTransition(surfaceId, payload);
        } catch (error) {
          reportNativeError(error, 'startSendTransition');
        }
      },
    }), [nativeListModule, surfaceId, onNativeError]);

    if (!isNativeChatEnabled() || !NativeChatListView) {
      return <View style={styles.fallback} />;
    }

    return (
      <NativeChatListView
        style={styles.fill}
        surfaceId={surfaceId}
        rows={rows}
        appearance={appearance}
        contentPaddingBottom={contentPaddingBottom}
        inputBarEnabled={inputBarEnabled}
        inputPlaceholder={inputPlaceholder}
        nativeSendEnabled={nativeSendEnabled}
        debugAnimationPanel={debugAnimationPanel}
        onViewportChanged={(event: any) => {
          // Log once to verify event bridge works
          if (onViewportChanged && !(onViewportChanged as any)._logged) {
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
          console.log('[NativeChatSurface] onNativeEvent raw:', JSON.stringify(event?.nativeEvent ?? event));
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
  },
  fallback: {
    flex: 1,
  },
});
