export type NativeRowKind = 'message' | 'day';

export interface NativeBubbleShape {
  isMe: boolean;
  showTail: boolean;
  borderTopLeftRadius: number;
  borderTopRightRadius: number;
  borderBottomLeftRadius: number;
  borderBottomRightRadius: number;
}

export interface NativeChatMessagePayload {
  id: string;
  chatId?: string;
  fromId?: string;
  timestampMs: number;
  timestamp?: string;
  text?: string;
  type?: string;
  status?: string;
  mediaUrl?: string;
  fileName?: string;
  duration?: number;
  isVideoNote?: boolean;
  uploadProgress?: number;
  isMe: boolean;
  isEdited?: boolean;
  isPinned?: boolean;
  editedAt?: number;
  replyToId?: string;
  reactionEmoji?: string;
  bubbleShape?: NativeBubbleShape;
  encryptedContent?: string;
  metadata?: Record<string, unknown>;
}

export interface NativeChatMessageRow {
  kind: 'message';
  key: string;
  message: NativeChatMessagePayload;
}

export interface NativeChatDayRow {
  kind: 'day';
  key: string;
  label: string;
  timestampMs: number;
}

export type NativeChatRow = NativeChatMessageRow | NativeChatDayRow;

export interface NativeChatViewport {
  contentHeight: number;
  layoutHeight: number;
  offsetY: number;
  distanceFromBottom: number;
  atBottom: boolean;
}

export interface NativeChatAppearance {
  backgroundMode?: 'transparent' | 'gradient';
  nativeThemeId?: string;
  nativeThemeIsDark?: boolean;
  wallpaperGradient?: string[];
  wallpaperOpacity?: number;
  wallpaperPatternGradient?: string[];
  wallpaperPatternLocations?: number[];
  wallpaperPatternOpacity?: number;
  wallpaperMaskKey?: string;
  bubbleMeGradient?: string[];
  bubbleThemColor?: string;
  textColorMe?: string;
  textColorThem?: string;
  timeColorMe?: string;
  timeColorThem?: string;
  dayTextColor?: string;
  dayBackgroundColor?: string;
  dayBorderColor?: string;
}

export interface NativeChatDecryptItem {
  id: string;
  encryptedContent: string;
  isFromMe: boolean;
}

export interface NativeChatDecryptBatchInput {
  privateKey: string;
  items: NativeChatDecryptItem[];
}

export interface NativeChatDecryptBatchResult {
  messages: Record<string, string>;
}

export interface NativeChatEncryptInput {
  recipientPublicKey: string;
  message: string;
  myPublicKey?: string;
}

export interface NativeChatNormalizeBatchInput {
  chatId: string;
  rows: NativeChatRow[];
}

export interface NativeChatNormalizeBatchResult {
  rows: NativeChatRow[];
  changed: boolean;
}

export interface NativeChatCoreModule {
  isSupported?: () => boolean;
  supportsCryptoPipeline?: () => boolean;
  decryptMessagesBatch?: (input: NativeChatDecryptBatchInput) => Promise<NativeChatDecryptBatchResult>;
  encryptMessage?: (input: NativeChatEncryptInput) => Promise<string>;
  normalizeRowsBatch?: (input: NativeChatNormalizeBatchInput) => Promise<NativeChatNormalizeBatchResult>;
  deriveKey?: (input: { passphrase: string; salt: string; iterations?: number; keyLength?: number }) => Promise<string>;
  encryptFileData?: (input: { data: string }) => Promise<{ encryptedBase64: string; keyBase64: string }>;
  decryptFileData?: (input: { encryptedBase64: string; keyBase64: string }) => Promise<string>;
}

export interface NativeChatListModule {
  isSupported?: () => boolean;
  supportsNativeList?: () => boolean;
  applyTransactions?: (surfaceId: string, transactions: Record<string, unknown>[]) => Promise<void>;
  scrollToBottom?: (surfaceId: string, animated: boolean) => Promise<void>;
  scrollToMessage?: (
    surfaceId: string,
    messageId: string,
    animated: boolean,
    viewPosition?: number,
  ) => Promise<void>;
  startSendTransition?: (surfaceId: string, payload: NativeSendTransitionPayload) => Promise<void>;
  playReactionFx?: (surfaceId: string, payload: NativeReactionFxPayload) => Promise<void>;
}

export interface NativeChatMainModule {
  isSupported?: () => boolean;
  supportsNativeMain?: () => boolean;
  setPage?: (surfaceId: string, page: 'chat' | 'profile', animated?: boolean) => Promise<void>;
  applyTransactions?: (surfaceId: string, transactions: Record<string, unknown>[]) => Promise<void>;
  scrollToBottom?: (surfaceId: string, animated: boolean) => Promise<void>;
  scrollToMessage?: (
    surfaceId: string,
    messageId: string,
    animated: boolean,
    viewPosition?: number,
  ) => Promise<void>;
  startSendTransition?: (surfaceId: string, payload: NativeSendTransitionPayload) => Promise<void>;
  playReactionFx?: (surfaceId: string, payload: NativeReactionFxPayload) => Promise<void>;
}

export interface NativeChatEngineModule {
  isSupported?: () => boolean;
  setChatEngineConfig?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  getChatEngineStatus?: () => Promise<Record<string, unknown>> | Record<string, unknown>;
  connectChatEngine?: () => Promise<Record<string, unknown>> | Record<string, unknown>;
  disconnectChatEngine?: () => Promise<Record<string, unknown>> | Record<string, unknown>;
  bindChatSurface?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  unbindChatSurface?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  openChatChannel?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  closeChatChannel?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  sendDeliveryReceipt?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  sendReadReceipt?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  upsertLocalMessageStatus?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  sendEncryptedMessage?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  sendMessage?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  retryOutgoingMessage?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  cancelOutgoingMessage?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  editMessage?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  deleteMessage?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  sendTypingState?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  sendRecordingState?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  sendEditMessage?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  sendDeleteMessage?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  setChatMuted?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  clearChat?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  blockUser?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  getChatProfileSummary?: (payload: Record<string, unknown>) => Promise<Record<string, unknown>> | Record<string, unknown>;
  getChatJournal?: () => Promise<Record<string, unknown>[]> | Record<string, unknown>[];
  clearChatJournal?: () => Promise<Record<string, unknown>> | Record<string, unknown>;
  // Shadow-mode bridge until native Phoenix transport is enabled.
  setPresenceSnapshot?: (payload: { userIds: string[] }) => Promise<Record<string, unknown>> | Record<string, unknown>;
}

export interface NativeSendTransitionPayload {
  messageId: string;
  text: string;
  timestamp: string;
  startX: number;
  startY: number;
  startWidth: number;
  startHeight: number;
  startBackgroundX?: number;
  startBackgroundY?: number;
  startBackgroundWidth?: number;
  startBackgroundHeight?: number;
  startContentX?: number;
  startContentY?: number;
  startContentWidth?: number;
  startContentHeight?: number;
  sourceScrollOffset?: number;
  sourceContainerX?: number;
  sourceContainerY?: number;
  sourceContainerWidth?: number;
  sourceContainerHeight?: number;
}

export interface NativeReactionFxPayload {
  emoji: string;
  x?: number;
  y?: number;
  sourceX?: number;
  sourceY?: number;
  color?: string;
}

export interface NativeChatRuntimeInfo {
  enabled: boolean;
  isExpoGo: boolean;
  remoteFlag: boolean;
  moduleAvailable: boolean;
  listModuleAvailable: boolean;
}
