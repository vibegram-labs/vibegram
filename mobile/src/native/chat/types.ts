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
  wallpaperGradient?: string[];
  wallpaperOpacity?: number;
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
