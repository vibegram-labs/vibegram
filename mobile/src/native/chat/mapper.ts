import type { NativeBubbleShape, NativeChatMessagePayload, NativeChatRow } from './types';

const BUBBLE_RADIUS = 18;
const BUBBLE_INNER_RADIUS = 5;

export const AGENT_USER_ID = '00000000-0000-0000-0000-000000000001';

export interface RuntimeChatMessage {
  id: string;
  chatId?: string;
  fromId?: string;
  timestamp?: string;
  text?: string;
  type?: string;
  status?: string;
  mediaUrl?: string;
  fileName?: string;
  duration?: number;
  waveform?: number[];
  isVideoNote?: boolean;
  uploadProgress?: number;
  isMe: boolean;
  timestampMs: number;
  isEdited?: boolean;
  isPinned?: boolean;
  editedAt?: number;
  replyToId?: string;
  reactionEmoji?: string;
  encryptedContent?: string;
  plainContent?: string;
  agentName?: string;
  agentId?: string;
  isAgentMessage?: boolean;
  metadata?: Record<string, unknown>;
}

const toDayKey = (timestampMs: number) => {
  const d = new Date(timestampMs);
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
};

const sameCalendarDay = (aMs: number, bMs: number) => toDayKey(aMs) === toDayKey(bMs);

const formatDayLabel = (timestampMs: number) => {
  const date = new Date(timestampMs);
  return date.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' });
};

const formatTimeLabel = (timestampMs: number) => {
  return new Date(timestampMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
};

const normalizeRuntimeMessageId = (value: unknown): string | null => {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    return String(value);
  }
  return null;
};

const resolveBubbleShape = (
  isMe: boolean,
  isSequenceStart: boolean,
  isSequenceEnd: boolean,
  messageType?: string,
): NativeBubbleShape => {
  const shape: NativeBubbleShape = {
    isMe,
    showTail: isSequenceEnd && messageType !== 'sticker',
    borderTopLeftRadius: BUBBLE_RADIUS,
    borderTopRightRadius: BUBBLE_RADIUS,
    borderBottomLeftRadius: BUBBLE_RADIUS,
    borderBottomRightRadius: BUBBLE_RADIUS,
  };

  if (isMe) {
    if (!isSequenceStart) shape.borderTopRightRadius = BUBBLE_INNER_RADIUS;
    if (!isSequenceEnd) shape.borderBottomRightRadius = BUBBLE_INNER_RADIUS;
  } else {
    if (!isSequenceStart) shape.borderTopLeftRadius = BUBBLE_INNER_RADIUS;
    if (!isSequenceEnd) shape.borderBottomLeftRadius = BUBBLE_INNER_RADIUS;
  }

  return shape;
};

export const mapMessagesToNativeRows = (messages: RuntimeChatMessage[]): NativeChatRow[] => {
  const rows: NativeChatRow[] = [];

  for (let i = 0; i < messages.length; i++) {
    const current = messages[i];
    const normalizedId = normalizeRuntimeMessageId(current.id);
    if (!normalizedId) {
      continue;
    }
    const previous = i > 0 ? messages[i - 1] : undefined;
    const next = i < messages.length - 1 ? messages[i + 1] : undefined;

    // Put day separators before the first message of that day.
    // This keeps existing row keys/positions stable when appending newer messages.
    if (!previous || !sameCalendarDay(previous.timestampMs, current.timestampMs)) {
      rows.push({
        kind: 'day',
        key: `d-${toDayKey(current.timestampMs)}`,
        label: formatDayLabel(current.timestampMs),
        timestampMs: current.timestampMs,
      });
    }

    const isSequenceStart = !previous || previous.isMe !== current.isMe;
    const isSequenceEnd = !next || next.isMe !== current.isMe;

    const isAgentMessage =
      current.isAgentMessage === true
      || current.fromId === AGENT_USER_ID
      || !!current.agentId
      || !!current.agentName
      || current.metadata?.isAgentMessage === true
      || current.metadata?.is_agent_message === true;

    const metadata: Record<string, unknown> = current.metadata && typeof current.metadata === 'object'
      ? { ...current.metadata }
      : {};
    if (current.waveform && current.waveform.length > 0) {
      metadata.waveform = current.waveform;
    }

    const payload: NativeChatMessagePayload = {
      id: normalizedId,
      chatId: current.chatId,
      fromId: current.fromId,
      timestampMs: current.timestampMs,
      timestamp: current.timestamp || formatTimeLabel(current.timestampMs),
      text: isAgentMessage ? (current.plainContent || current.text) : current.text,
      type: current.type,
      status: current.status,
      mediaUrl: current.mediaUrl,
      fileName: current.fileName,
      duration: current.duration,
      isVideoNote: current.isVideoNote,
      uploadProgress: current.uploadProgress,
      isMe: current.isMe,
      isEdited: current.isEdited,
      isPinned: current.isPinned,
      editedAt: current.editedAt,
      replyToId: current.replyToId,
      reactionEmoji: current.reactionEmoji,
      encryptedContent: isAgentMessage ? undefined : current.encryptedContent,
      metadata: Object.keys(metadata).length > 0 ? metadata : undefined,
      bubbleShape: resolveBubbleShape(current.isMe, isSequenceStart, isSequenceEnd, current.type),
      isAgentMessage,
      agentName: isAgentMessage
        ? (
          current.agentName
          || String(current.metadata?.agentName || current.metadata?.agent_name || 'Vibe AI')
        )
        : undefined,
      plainContent: isAgentMessage ? (current.plainContent || current.text) : undefined,
    };

    rows.push({
      kind: 'message',
      key: `m-${normalizedId}`,
      message: payload,
    });
  }

  return rows;
};
