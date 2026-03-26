import React, { forwardRef, useImperativeHandle, useMemo } from 'react';
import { Platform, StyleSheet, View } from 'react-native';

import { getNativeChatAgentModule, isNativeChatEnabled } from './runtime';
import type { NativeChatAgentModule, NativeChatAppearance } from './types';

let NativeAgentChatView: React.ComponentType<any> | null = null;

try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const expoModulesCore = require('expo-modules-core');
  if (typeof expoModulesCore.requireNativeViewManager === 'function') {
    NativeAgentChatView = expoModulesCore.requireNativeViewManager('ChatNativeAgent');
  }
} catch {
  NativeAgentChatView = null;
}

export interface NativeAgentChatSurfaceRef {
  submitText: (text: string) => Promise<void>;
  stopStreaming: () => Promise<void>;
}

interface NativeAgentChatSurfaceProps {
  surfaceId: string;
  appearance?: NativeChatAppearance;
  activeAgentId?: string | null;
  latestSecret?: string | null;
  forceRender?: boolean;
  onNativeEvent?: (event: { nativeEvent: Record<string, unknown> }) => void;
  onNativeError?: (error: unknown, context: string) => void;
}

export const NativeAgentChatSurface = forwardRef<
  NativeAgentChatSurfaceRef,
  NativeAgentChatSurfaceProps
>(({ surfaceId, appearance, activeAgentId, latestSecret, forceRender, onNativeEvent, onNativeError }, ref) => {
  const nativeAgentModule = useMemo(
    () => getNativeChatAgentModule() as NativeChatAgentModule | null,
    [],
  );

  const reportNativeError = (error: unknown, context: string) => {
    console.error(`[NativeAgentChatSurface] ${context} failed`, error);
    onNativeError?.(error, context);
  };

  useImperativeHandle(
    ref,
    () => ({
      submitText: async (text: string) => {
        if (!nativeAgentModule?.submitText) return;
        try {
          await nativeAgentModule.submitText(surfaceId, text);
        } catch (error) {
          reportNativeError(error, 'submitText');
        }
      },
      stopStreaming: async () => {
        if (!nativeAgentModule?.stopStreaming) return;
        try {
          await nativeAgentModule.stopStreaming(surfaceId);
        } catch (error) {
          reportNativeError(error, 'stopStreaming');
        }
      },
    }),
    [nativeAgentModule, onNativeError, surfaceId],
  );

  if (
    Platform.OS !== 'ios'
    || ((!forceRender && !isNativeChatEnabled()) || !NativeAgentChatView)
  ) {
    return <View style={styles.fill} />;
  }

  const NativeView = NativeAgentChatView as React.ComponentType<any>;

  return (
    <NativeView
      style={styles.fill}
      surfaceId={surfaceId}
      appearance={appearance}
      activeAgentId={activeAgentId ?? null}
      latestSecret={latestSecret ?? null}
      onNativeEvent={(event: any) => {
        try {
          onNativeEvent?.(event);
        } catch (error) {
          reportNativeError(error, 'onNativeEvent');
        }
      }}
    />
  );
});

NativeAgentChatSurface.displayName = 'NativeAgentChatSurface';

const styles = StyleSheet.create({
  fill: {
    flex: 1,
    backgroundColor: 'transparent',
  },
});
