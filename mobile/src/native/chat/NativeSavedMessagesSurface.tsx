import React, { forwardRef } from 'react';

import { NativeChatMainSurface } from './NativeChatMainSurface';
import type { NativeChatMainSurfaceRef } from './NativeChatMainSurface';
import type { NativeChatAppearance, NativeChatRow } from './types';

interface NativeSavedMessagesSurfaceProps {
  surfaceId: string;
  rows: NativeChatRow[];
  forceRender?: boolean;
  engineSurfaceId?: string;
  myUserId?: string;
  appearance?: NativeChatAppearance;
  contentPaddingTop?: number;
  contentPaddingBottom?: number;
  inputBarEnabled?: boolean;
  inputPlaceholder?: string;
  nativeSendEnabled?: boolean;
  onNativeEvent?: (event: { nativeEvent: Record<string, unknown> }) => void;
  onNativeError?: (error: unknown, context: string) => void;
}

export const NativeSavedMessagesSurface = forwardRef<
  NativeChatMainSurfaceRef,
  NativeSavedMessagesSurfaceProps
>(function NativeSavedMessagesSurface(
  {
    surfaceId,
    rows,
    forceRender,
    engineSurfaceId,
    myUserId,
    appearance,
    contentPaddingTop,
    contentPaddingBottom,
    inputBarEnabled,
    inputPlaceholder,
    nativeSendEnabled,
    onNativeEvent,
    onNativeError,
  },
  ref,
) {
  return (
    <NativeChatMainSurface
      ref={ref}
      forceRender={forceRender}
      surfaceId={surfaceId}
      rows={rows}
      engineSurfaceId={engineSurfaceId}
      chatId="saved_messages"
      myUserId={myUserId}
      appearance={appearance}
      contentPaddingTop={contentPaddingTop}
      contentPaddingBottom={contentPaddingBottom}
      inputBarEnabled={inputBarEnabled}
      inputPlaceholder={inputPlaceholder}
      nativeSendEnabled={nativeSendEnabled}
      headerMode="savedMessages"
      headerTitle="Saved Messages"
      headerSubtitle=""
      profileName="Saved Messages"
      profileHandle=""
      profileBio=""
      onNativeEvent={onNativeEvent}
      onNativeError={onNativeError}
    />
  );
});

