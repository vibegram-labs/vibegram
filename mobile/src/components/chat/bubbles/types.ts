export type BubbleStatus = 'sending' | 'pending' | 'sent' | 'delivered' | 'read' | 'error' | undefined;

export type BubbleMessageType =
    | 'text'
    | 'image'
    | 'video'
    | 'voice'
    | 'call'
    | 'gif'
    | 'file'
    | 'location'
    | 'music'
    | 'sticker'
    | 'contact';

export interface BubbleContact {
    id?: string;
    username?: string;
    phoneNumber?: string;
    profileImage?: string;
}

export interface ChatListBubbleMessage {
    id: string;
    chatId?: string;
    fromId?: string;
    type: BubbleMessageType;
    text: string;
    isMe: boolean;
    timestamp: string;
    status?: BubbleStatus;
    mediaUrl?: string;
    fileName?: string;
    fileSize?: number;
    duration?: number;
    latitude?: number;
    longitude?: number;
    caption?: string;
    viewOnce?: boolean;
    viewedBy?: string[];
    isVideoNote?: boolean;
    contact?: BubbleContact;
    replyToId?: string;
    isEdited?: boolean;
    isPinned?: boolean;
    editedAt?: number;
    extra?: {
        width?: number;
        height?: number;
        thumbnailBase64?: string;
        waveform?: number[];
        stickerId?: string;
        stickerPackId?: string;
        stickerBundleFileName?: string;
        emoji?: string;
    };
}
