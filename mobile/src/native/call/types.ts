export type NativeCallPendingEvent = {
  type: string;
  timestamp?: number;
  payload?: Record<string, unknown>;
};

export type NativeCallPushTokens = {
  platform?: string;
  fcm?: string | null;
  apns?: string | null;
  voip?: string | null;
};

export interface NativeCallModule {
  isSupported?: () => boolean;
  supportsInAppUi?: () => boolean;
  setNativeEngineConfig?: (payload: Record<string, unknown>) => Record<string, unknown> | null | void;
  getNativeEngineConfig?: () => Record<string, unknown> | null;
  getNativeEngineStatus?: () => Record<string, unknown> | null;
  getNativeIceConfig?: () => Record<string, unknown> | null;
  getNativeSignalingJournal?: () => Array<Record<string, unknown>> | null;
  clearNativeSignalingJournal?: () => Record<string, unknown> | null | void;
  nativeRefreshTurnConfig?: () => Record<string, unknown> | null | void;
  nativeStartOutgoingCall?: (payload: Record<string, unknown>) => Record<string, unknown> | null | void;
  nativeAcceptIncomingCall?: (payload: Record<string, unknown>) => Record<string, unknown> | null | void;
  nativeHandleSignal?: (payload: Record<string, unknown>) => Record<string, unknown> | null | void;
  nativeEndCall?: (payload: Record<string, unknown>) => Record<string, unknown> | null | void;
  drainPendingEvents?: () => NativeCallPendingEvent[];
  getPushTokens?: () => NativeCallPushTokens | null;
  clearIncomingCallUi?: (payload: Record<string, unknown>) => void;
  setCallUiState?: (payload: Record<string, unknown>) => void;
  hideCallUi?: () => void;
}

export type NativeCallUiEvent = {
  type:
    | 'accept'
    | 'decline'
    | 'end'
    | 'toggleMute'
    | 'toggleSpeaker'
    | 'toggleVideo'
    | 'flipCamera'
    | 'message'
    | 'remind'
    | string;
};
