import type { NativeBubbleShape, NativeChatMessagePayload, NativeChatRow } from './types';

const BUBBLE_RADIUS = 18;
const BUBBLE_INNER_RADIUS = 5;

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

    const payload: NativeChatMessagePayload = {
      id: current.id,
      chatId: current.chatId,
      fromId: current.fromId,
      timestampMs: current.timestampMs,
      timestamp: current.timestamp || formatTimeLabel(current.timestampMs),
      text: current.text,
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
      encryptedContent: current.encryptedContent,
      metadata: current.waveform && current.waveform.length > 0
        ? { waveform: current.waveform }
        : undefined,
      bubbleShape: resolveBubbleShape(current.isMe, isSequenceStart, isSequenceEnd, current.type),
    };

    rows.push({
      kind: 'message',
      key: `m-${current.id}`,
      message: payload,
    });
  }

  return rows;
};
